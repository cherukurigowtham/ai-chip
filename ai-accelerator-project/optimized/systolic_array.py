"""
Optimized Architecture (Architecture B): Tiled Systolic Array Accelerator
=========================================================================
Implements a 2D Systolic Array with Weight-Stationary (WS) dataflow (Google TPU style):
- Processing Elements (PEs) arranged in an (array_rows x array_cols) 2D grid.
- Each PE has:
  * Local weight register (holds stationary weight across the activation stream).
  * Activation pipeline register (forwards activation horizontally to right neighbor).
  * Partial sum adder/pipeline register (forwards partial sum vertically down the column).
- Large matrices partitioned into tiles matching array dimensions.
- Eliminates external memory traffic via spatial data reuse, local register retention,
  and neighbor-forwarding.
"""

from dataclasses import dataclass
from typing import Tuple
import numpy as np


@dataclass
class SystolicConfig:
    array_rows: int = 4          # PE array height (R)
    array_cols: int = 4          # PE array width (C) -> Total PEs = R * C = 16
    bus_width_words: int = 4     # Shared memory bus bandwidth: words transferred per clock cycle
    # Energy figures (16-bit word in 28/45nm CMOS):
    mac_energy_pj: float = 0.25
    pe_forward_energy_pj: float = 0.05   # Inter-PE register forwarding (short local wire)
    sram_read_energy_pj: float = 5.0
    sram_write_energy_pj: float = 5.0
    dram_access_energy_pj: float = 150.0
    dram_hit_ratio: float = 0.0


@dataclass
class SystolicMetrics:
    M: int
    K: int
    N: int
    total_mac_ops: int
    mem_reads: int
    mem_writes: int
    total_mem_accesses: int
    execution_cycles: int
    mac_utilization_pct: float
    data_reuse_ratio: float
    total_energy_uj: float
    compute_energy_uj: float
    memory_energy_uj: float
    is_correct: bool


class ProcessingElement:
    """Cycle-accurate model of an individual Processing Element (PE)."""
    def __init__(self, r: int, c: int):
        self.r = r
        self.c = c
        self.weight_reg: float = 0.0
        self.act_in: float = 0.0
        self.act_out: float = 0.0
        self.psum_in: float = 0.0
        self.psum_out: float = 0.0
        self.active_cycles: int = 0

    def load_weight(self, weight: float):
        self.weight_reg = weight

    def step(self, act_in: float, psum_in: float) -> Tuple[float, float]:
        """
        Executes one clock cycle:
        - Computes: psum_out = psum_in + (act_in * weight_reg)
        - Forwards: act_out = act_in (to right neighbor)
        - Forwards: psum_out = psum_out (to bottom neighbor)
        """
        self.act_in = act_in
        self.psum_in = psum_in

        self.psum_out = self.psum_in + (self.act_in * self.weight_reg)
        self.act_out = self.act_in

        if self.act_in != 0.0 or self.weight_reg != 0.0:
            self.active_cycles += 1

        return self.act_out, self.psum_out


class SystolicArrayAccelerator:
    """
    Architecture B: Tiled 2D Systolic Array with Weight-Stationary Dataflow.
    """
    def __init__(self, config: SystolicConfig = None):
        self.config = config or SystolicConfig()
        self.R = self.config.array_rows
        self.C = self.config.array_cols
        self.total_pes = self.R * self.C
        self.grid = [[ProcessingElement(r, c) for c in range(self.C)] for r in range(self.R)]

    def run(self, A: np.ndarray, B: np.ndarray) -> Tuple[np.ndarray, SystolicMetrics]:
        """
        Executes GEMM: C = A @ B using tiled weight-stationary systolic execution.
        A: shape (M, K)
        B: shape (K, N)
        """
        assert A.shape[1] == B.shape[0], "Dimension mismatch between A and B"
        M, K = A.shape
        _, N = B.shape
        total_mac_ops = M * K * N

        C_golden = np.matmul(A, B)

        # Pad dimensions to multiples of tile size (R x C)
        pad_m = (self.R - (M % self.R)) % self.R
        pad_k = (self.R - (K % self.R)) % self.R
        pad_n = (self.C - (N % self.C)) % self.C

        A_padded = np.pad(A, ((0, pad_m), (0, pad_k)), mode='constant')
        B_padded = np.pad(B, ((0, pad_k), (0, pad_n)), mode='constant')
        M_p, K_p = A_padded.shape
        _, N_p = B_padded.shape

        C_accum = np.zeros((M_p, N_p), dtype=np.float64)

        total_cycles = 0
        total_pe_active_cycles = 0
        total_mem_reads = 0
        total_mem_writes = 0
        total_pe_forwardings = 0

        # Tiling loops:
        # Loop over output column tiles (N), then reduction tiles (K), then batch tiles (M)
        # In Weight-Stationary, keeping weights stationary across batch rows (M) maximizes weight reuse!
        for j_tile in range(0, N_p, self.C):
            for k_tile in range(0, K_p, self.R):
                # 1. Fetch Weight Tile B_sub: shape (R, C)
                # Loaded once into stationary registers for this (k_tile, j_tile)
                B_sub = B_padded[k_tile:k_tile + self.R, j_tile:j_tile + self.C]
                total_mem_reads += self.R * self.C
                weight_load_cycles = int(np.ceil((self.R * self.C) / self.config.bus_width_words))
                total_cycles += weight_load_cycles

                # Load weights into stationary registers of PEs
                for r in range(self.R):
                    for c in range(self.C):
                        self.grid[r][c].load_weight(B_sub[r, c])

                # 2. Iterate across batch dimension M (reusing stationary weights!)
                for i_tile in range(0, M_p, self.R):
                    A_sub = A_padded[i_tile:i_tile + self.R, k_tile:k_tile + self.R]
                    # Memory read for activation tile: R * R words
                    total_mem_reads += self.R * self.R
                    act_load_cycles = int(np.ceil((self.R * self.R) / self.config.bus_width_words))

                    # 3. Systolic Execution:
                    # Wavefront execution: stream activations horizontally, partial sums vertically
                    stream_cycles = self.R + self.R + self.C
                    act_wire = np.zeros((self.R, self.C + 1))
                    psum_wire = np.zeros((self.R + 1, self.C))

                    for t in range(stream_cycles):
                        # Feed skewed activations on left edge (col 0)
                        for r in range(self.R):
                            row_batch_idx = t - r
                            if 0 <= row_batch_idx < self.R:
                                act_wire[r, 0] = A_sub[row_batch_idx, r]
                            else:
                                act_wire[r, 0] = 0.0

                        # Cycle execution of PEs
                        next_act = np.zeros((self.R, self.C + 1))
                        next_psum = np.zeros((self.R + 1, self.C))

                        for r in range(self.R):
                            for c in range(self.C):
                                a_in = act_wire[r, c]
                                p_in = psum_wire[r, c]
                                a_out, p_out = self.grid[r][c].step(a_in, p_in)

                                next_act[r, c + 1] = a_out
                                next_psum[r + 1, c] = p_out

                                if c < self.C - 1:
                                    total_pe_forwardings += 1  # Horizontal activation wire
                                if r < self.R - 1:
                                    total_pe_forwardings += 1  # Vertical partial-sum wire

                                # Collect outputs emerging from bottom row (r = R - 1)
                                if r == self.R - 1:
                                    out_batch_idx = t - (self.R - 1) - c
                                    if 0 <= out_batch_idx < self.R:
                                        C_accum[i_tile + out_batch_idx, j_tile + c] += p_out

                        act_wire = next_act
                        psum_wire = next_psum

                    # Streaming cycles (overlapped with load)
                    total_cycles += max(act_load_cycles, stream_cycles)

        # Write final result back to memory
        # Only non-padded M x N elements written back
        total_mem_writes = M * N
        drain_cycles = int(np.ceil(total_mem_writes / self.config.bus_width_words))
        total_cycles += drain_cycles

        # Slice computed matrix back to original shape
        C_computed = C_accum[:M, :N]
        is_correct = bool(np.allclose(C_computed, C_golden, atol=1e-5))
        total_accesses = total_mem_reads + total_mem_writes

        # MAC utilization
        total_capacity_cycles = total_cycles * self.total_pes
        mac_utilization = (total_mac_ops / total_capacity_cycles) * 100.0
        data_reuse_ratio = total_mac_ops / total_accesses

        # Energy calculation
        compute_energy_uj = (total_mac_ops * self.config.mac_energy_pj) / 1e6
        forwarding_energy_uj = (total_pe_forwardings * self.config.pe_forward_energy_pj) / 1e6

        avg_read_energy = (
            (1.0 - self.config.dram_hit_ratio) * self.config.sram_read_energy_pj +
            self.config.dram_hit_ratio * self.config.dram_access_energy_pj
        )
        avg_write_energy = (
            (1.0 - self.config.dram_hit_ratio) * self.config.sram_write_energy_pj +
            self.config.dram_hit_ratio * self.config.dram_access_energy_pj
        )
        memory_energy_uj = (
            (total_mem_reads * avg_read_energy) +
            (total_mem_writes * avg_write_energy) +
            forwarding_energy_uj
        ) / 1e6
        total_energy_uj = compute_energy_uj + memory_energy_uj

        metrics = SystolicMetrics(
            M=M,
            K=K,
            N=N,
            total_mac_ops=total_mac_ops,
            mem_reads=total_mem_reads,
            mem_writes=total_mem_writes,
            total_mem_accesses=total_accesses,
            execution_cycles=total_cycles,
            mac_utilization_pct=mac_utilization,
            data_reuse_ratio=data_reuse_ratio,
            total_energy_uj=total_energy_uj,
            compute_energy_uj=compute_energy_uj,
            memory_energy_uj=memory_energy_uj,
            is_correct=is_correct
        )

        return C_computed, metrics


if __name__ == "__main__":
    np.random.seed(42)
    M, K, N = 16, 16, 16
    A = np.random.randn(M, K).astype(np.float32)
    B = np.random.randn(K, N).astype(np.float32)

    accel = SystolicArrayAccelerator()
    C, m = accel.run(A, B)

    print("=" * 60)
    print(f"SYSTOLIC ARRAY ACCELERATOR (Architecture B) TEST: GEMM {M}x{K}x{N}")
    print("=" * 60)
    print(f"Correctness check:     {'PASS' if m.is_correct else 'FAIL'}")
    print(f"Total MAC Operations:  {m.total_mac_ops:,}")
    print(f"Memory Reads:          {m.mem_reads:,}")
    print(f"Memory Writes:         {m.mem_writes:,}")
    print(f"Total Memory Accesses: {m.total_mem_accesses:,}")
    print(f"Execution Cycles:      {m.execution_cycles:,}")
    print(f"MAC Utilization:       {m.mac_utilization_pct:.2f}%")
    print(f"Data Reuse Ratio:      {m.data_reuse_ratio:.4f} MACs / Memory Access")
    print(f"Total Energy:          {m.total_energy_uj:.4f} uJ")
    print(f"Memory Energy Share:   {(m.memory_energy_uj / m.total_energy_uj) * 100:.1f}%")
    print("=" * 60)
