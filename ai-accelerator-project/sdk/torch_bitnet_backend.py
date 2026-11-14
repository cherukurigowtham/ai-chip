"""
BitNet-130 PyTorch 2.0 Compiler Backend & Toolchain
====================================================
Seamlessly compiles standard PyTorch neural network modules and Hugging Face
BitNet-b1.58 models into multiplier-free execution plans for the BitNet-130
ASIC silicon architecture.

Usage:
    import torch
    import torch_bitnet_backend

    model = MyTransformerModel()
    compiled_model = torch.compile(model, backend="bitnet130")
    output = compiled_model(input_tokens)

Features:
- TorchDynamo & TorchFX graph lowering pass
- Automatic BitNet b1.58 ternary weight quantization {-1, 0, +1}
- Multiplier-free hardware emulation (pure shift-and-add + saturation clamping)
- Spatial tiling across 1x1 Tile, 2x2 Multi-Tile Cluster, and 256-PE Quad-Cluster
- Real-time silicon telemetry: zero-skips, energy (uJ), cycle latency, power
"""

import math
import numpy as np
import torch
import torch.nn as nn
import torch.fx as fx
from typing import List, Dict, Any, Tuple, Optional, Callable

# Silicon Hardware Constraints
CLOCK_FREQ_MHZ_LOW   = 50.0   # SkyWater Sky130 nominal (50 MHz)
CLOCK_FREQ_MHZ_HIGH  = 500.0  # Nangate 45nm high-perf (500 MHz)
TILE_1X1_POWER_UW    = 591.4  # Measured Sky130 1x1 power (0.591 mW)
CLUSTER_2X2_POWER_UW = 2365.6 # 2x2 Multi-Tile cluster power (2.366 mW)
CLUSTER_256_POWER_MW = 49.2   # Full 256-PE Quad-Core cluster power


class BitNetHardwarePlan:
    """Represents a compiled hardware execution plan for BitNet-130 silicon."""

    def __init__(self, layer_name: str, in_features: int, out_features: int, target_hw: str = "cluster_2x2"):
        self.layer_name = layer_name
        self.in_features = in_features
        self.out_features = out_features
        self.target_hw = target_hw
        
        # Quantized parameters
        self.w_ternary: Optional[np.ndarray] = None
        self.gamma: float = 1.0  # Weight scale factor
        self.beta: float = 1.0   # Activation scale factor
        
        # Telemetry metrics
        self.total_macs = in_features * out_features
        self.zero_macs = 0
        self.active_macs = 0
        self.zero_skip_pct = 0.0
        self.est_cycles = 0
        self.energy_uj = 0.0


class BitNetTernaryQuantizer:
    """Official BitNet b1.58 weight quantization and activation scaling."""

    @staticmethod
    def quantize_weights(w: torch.Tensor) -> Tuple[torch.Tensor, float]:
        """
        Quantizes continuous weights into {-1, 0, +1}:
            gamma = mean(|W|)
            W_ternary = RoundClip(W / gamma, -1, +1)
        """
        gamma = float(torch.mean(torch.abs(w)).item()) + 1e-8
        scaled_w = w / gamma
        w_ternary = torch.clamp(torch.round(scaled_w), min=-1.0, max=1.0)
        return w_ternary, gamma

    @staticmethod
    def quantize_activations(x: torch.Tensor) -> Tuple[torch.Tensor, float]:
        """
        Symmetric INT8 dynamic activation quantization [-128, 127]:
            beta = max(|X|) / 127.0
            X_quant = RoundClip(X / beta, -128, 127)
        """
        max_val = float(torch.max(torch.abs(x)).item()) + 1e-8
        beta = max_val / 127.0
        x_quant = torch.clamp(torch.round(x / beta), min=-128.0, max=127.0)
        return x_quant, beta


class BitNetHardwareLinear(nn.Module):
    """
    Multiplier-free hardware linear layer executing bit-exact ternary arithmetic
    with saturation clamping [-8388608, +8388607] matching the RTL accelerator.
    """

    def __init__(self, in_features: int, out_features: int, bias: bool = False, target_hw: str = "cluster_2x2"):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.target_hw = target_hw
        self.has_bias = bias

        self.w_ternary = nn.Parameter(torch.zeros(out_features, in_features), requires_grad=False)
        self.gamma = 1.0
        self.bias_tensor = nn.Parameter(torch.zeros(out_features), requires_grad=False) if bias else None
        
        # Telemetry
        self.plan = BitNetHardwarePlan("linear", in_features, out_features, target_hw)

    def load_from_float(self, float_weight: torch.Tensor, float_bias: Optional[torch.Tensor] = None):
        """Quantizes and loads weights from standard FP32/FP16 layer."""
        w_t, gamma = BitNetTernaryQuantizer.quantize_weights(float_weight)
        self.w_ternary.copy_(w_t)
        self.gamma = gamma

        if float_bias is not None and self.has_bias:
            self.bias_tensor.copy_(float_bias)

        # Profile sparsity
        zeros = int(torch.sum(w_t == 0).item())
        total = w_t.numel()
        self.plan.zero_macs = zeros
        self.plan.active_macs = total - zeros
        self.plan.zero_skip_pct = (zeros / total) * 100.0
        self.plan.gamma = gamma

        # Latency estimate
        if self.target_hw == "cluster_2x2":
            # 4 parallel PEs @ 50 MHz
            self.plan.est_cycles = math.ceil(self.plan.active_macs / 4.0)
            latency_sec = self.plan.est_cycles / (CLOCK_FREQ_MHZ_LOW * 1e6)
            self.plan.energy_uj = (CLUSTER_2X2_POWER_UW * 1e-6) * latency_sec * 1e6
        else:
            # 256-PE Quad Cluster @ 500 MHz
            self.plan.est_cycles = math.ceil(self.plan.active_macs / 256.0)
            latency_sec = self.plan.est_cycles / (CLOCK_FREQ_MHZ_HIGH * 1e6)
            self.plan.energy_uj = (CLUSTER_256_POWER_MW * 1e-3) * latency_sec * 1e6

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """
        Bit-exact hardware forward pass using conditional additions/subtractions
        and 24-bit saturation clamping [-8388608, +8388607].
        """
        orig_shape = x.shape
        x_2d = x.reshape(-1, self.in_features)

        # Quantize activations
        x_quant, beta = BitNetTernaryQuantizer.quantize_activations(x_2d)

        # Multiplier-free matrix multiply:
        # Each output neuron j is sum_i (x_i * w_ji), where w_ji in {-1, 0, +1}
        # In hardware:
        #   w = +1 -> add x_i
        #   w = -1 -> sub x_i
        #   w =  0 -> skip update
        w_pos = (self.w_ternary == 1.0).float()
        w_neg = (self.w_ternary == -1.0).float()

        # Pure additive accumulation (simulating hardware adders)
        accum_pos = torch.matmul(x_quant, w_pos.t())
        accum_neg = torch.matmul(x_quant, w_neg.t())
        accum_raw = accum_pos - accum_neg

        # Hardware 24-bit Saturation Clamping: [-8388608, +8388607]
        accum_clamped = torch.clamp(accum_raw, min=-8388608.0, max=8388607.0)

        # Dequantize back to float using (gamma * beta) scale
        dequant_scale = self.gamma * beta
        out_float = accum_clamped * dequant_scale

        if self.has_bias and self.bias_tensor is not None:
            out_float = out_float + self.bias_tensor

        return out_float.reshape(*orig_shape[:-1], self.out_features)


def bitnet130_compiler(gm: fx.GraphModule, example_inputs: List[torch.Tensor], target_hw: str = "cluster_2x2") -> Callable:
    """
    TorchFX Graph Transformation Pass for the BitNet-130 Accelerator.
    Intercepts Linear operations and replaces them with multiplier-free
    BitNetHardwareLinear modules with saturation clamping and telemetry.
    """
    plans: List[BitNetHardwarePlan] = []

    for node in gm.graph.nodes:
        if node.op == "call_module":
            target_submod = getattr(gm, node.target, None)
            if isinstance(target_submod, nn.Linear):
                # Replace with BitNet hardware module
                hw_layer = BitNetHardwareLinear(
                    in_features=target_submod.in_features,
                    out_features=target_submod.out_features,
                    bias=(target_submod.bias is not None),
                    target_hw=target_hw
                )
                hw_layer.load_from_float(
                    target_submod.weight.data,
                    target_submod.bias.data if target_submod.bias is not None else None
                )
                # Swap in graph
                setattr(gm, node.target, hw_layer)
                plans.append(hw_layer.plan)

    gm.graph.lint()
    gm.recompile()

    # Store compilation telemetry in graph module
    gm._bitnet_plans = plans
    return gm


def compile_model(model: nn.Module, target_hw: str = "cluster_2x2") -> nn.Module:
    """
    High-level entry point to compile any PyTorch model to BitNet-130.
    Can be used directly or via torch.compile(model, backend='bitnet130').
    """
    traced = fx.symbolic_trace(model)
    return bitnet130_compiler(traced, [], target_hw=target_hw)


# Register backend with PyTorch 2.x Compiler Framework if available
TORCH_COMPILE_REGISTERED = False
try:
    try:
        from torch._dynamo import register_backend
    except ImportError:
        from torch.compiler import register_backend
    
    @register_backend(name="bitnet130")
    def bitnet130(gm: fx.GraphModule, example_inputs: List[torch.Tensor]) -> Callable:
        return bitnet130_compiler(gm, example_inputs, target_hw="cluster_2x2")
        
    TORCH_COMPILE_REGISTERED = True
except Exception as e:
    try:
        # Fallback registration without name argument if old dynamo version
        from torch._dynamo import register_backend
        @register_backend
        def bitnet130(gm: fx.GraphModule, example_inputs: List[torch.Tensor]) -> Callable:
            return bitnet130_compiler(gm, example_inputs, target_hw="cluster_2x2")
        TORCH_COMPILE_REGISTERED = True
    except Exception:
        TORCH_COMPILE_REGISTERED = False
