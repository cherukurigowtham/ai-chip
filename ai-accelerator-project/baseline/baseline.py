"""
Baseline Simulator (Architecture A)
===================================
Simulates a conventional AI accelerator architecture:
- Shared memory feeding a bank of MAC units.
- No Processing Element (PE) local data reuse.
- Operands (A, B) and partial sums (C) must be fetched from and written back
  to shared memory for every MAC operation.
- Models memory bus contention and quantifies memory traffic, execution cycles,
  MAC utilization, and estimated energy consumption.
"""

from dataclasses import dataclass
from typing import Dict, Any, Tuple
import numpy as np


@dataclass
class BaselineConfig:
    num_macs: int = 16          # Number of parallel MAC units (e.g. 16 for fair 4x4 comparison)
    bus_width_words: int = 4    # Memory bus bandwidth: words transferred per clock cycle
    mem_read_latency: int = 1   # Clock cycles per memory read burst
    mem_write_latency: int = 1  # Clock cycles per memory write burst
    # Standard Horowitz energy figures (16-bit word in 28/45nm CMOS):
    mac_energy_pj: float = 0.25
    sram_read_energy_pj: float = 5.0
    sram_write_energy_pj: float = 5.0
    dram_access_energy_pj: float = 150.0
    dram_hit_ratio: float = 0.0  # Fraction that hits DRAM vs on-chip buffer (default: all external/shared)


@dataclass
class BaselineMetrics:
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


class BaselineAccelerator:
    """
    Architecture A: Baseline accelerator with shared memory and zero PE-level data reuse.
    """
    def __init__(self, config: BaselineConfig = None):
        self.config = config or BaselineConfig()

    def run(self, A: np.ndarray, B: np.ndarray) -> Tuple[np.ndarray, BaselineMetrics]:
        """
        Executes GEMM: C = A @ B
        A: shape (M, K)
        B: shape (K, N)
        Returns:
            C: Computed output matrix
            metrics: BaselineMetrics detailing hardware utilization and memory traffic
        """
        assert A.shape[1] == B.shape[0], "Dimension mismatch between A and B"
        M, K = A.shape
        _, N = B.shape
        total_mac_ops = M * K * N

        # Golden reference for correctness check
        C_golden = np.matmul(A, B)
        C_computed = np.zeros((M, N), dtype=np.float64)

        # Track memory traffic
        # In Architecture A (no reuse), each MAC operation (i, k, j) requires:
        # 1 read of A[i, k]
        # 1 read of B[k, j]
        # 1 read of current partial sum C[i, j]
        # 1 write-back of updated partial sum C[i, j]
        read_accesses = 3 * total_mac_ops
        write_accesses = 1 * total_mac_ops
        total_accesses = read_accesses + write_accesses

        # Functional simulation & verification
        for i in range(M):
            for j in range(N):
                for k in range(K):
                    C_computed[i, j] += A[i, k] * B[k, j]

        is_correct = bool(np.allclose(C_computed, C_golden, atol=1e-5))

        # Cycle calculation:
        # The workload is partitioned across `num_macs` parallel MAC units.
        # However, the memory bus can only deliver `bus_width_words` per cycle.
        # Each batch of `num_macs` MACs requires:
        # - 2 * num_macs operand reads
        # - 1 * num_macs partial-sum read
        # - 1 * num_macs partial-sum write
        # Total data movement per batch = 4 * num_macs words.
        # Cycles constrained by memory bandwidth vs compute:
        words_per_batch = 4 * self.config.num_macs
        mem_cycles_per_batch = int(np.ceil(words_per_batch / self.config.bus_width_words))
        compute_cycles_per_batch = 1  # 1 cycle to execute MAC once operands are ready

        # Because memory bus and MAC units are in series for non-buffered architecture:
        cycles_per_batch = mem_cycles_per_batch + compute_cycles_per_batch
        num_batches = int(np.ceil(total_mac_ops / self.config.num_macs))
        total_cycles = num_batches * cycles_per_batch

        # Active MAC cycles vs total available MAC capacity
        active_mac_cycles = total_mac_ops
        total_capacity_cycles = total_cycles * self.config.num_macs
        mac_utilization = (active_mac_cycles / total_capacity_cycles) * 100.0

        # Data reuse ratio: Total compute ops performed / total unique inputs loaded
        unique_inputs = (M * K) + (K * N)
        data_reuse_ratio = total_mac_ops / total_accesses

        # Energy modeling (in microjoules, uJ)
        compute_energy_uj = (total_mac_ops * self.config.mac_energy_pj) / 1e6

        # Average energy per memory access (combining SRAM scratchpad & external DRAM)
        avg_read_energy = (
            (1.0 - self.config.dram_hit_ratio) * self.config.sram_read_energy_pj +
            self.config.dram_hit_ratio * self.config.dram_access_energy_pj
        )
        avg_write_energy = (
            (1.0 - self.config.dram_hit_ratio) * self.config.sram_write_energy_pj +
            self.config.dram_hit_ratio * self.config.dram_access_energy_pj
        )
        memory_energy_uj = ((read_accesses * avg_read_energy) + (write_accesses * avg_write_energy)) / 1e6
        total_energy_uj = compute_energy_uj + memory_energy_uj

        metrics = BaselineMetrics(
            M=M,
            K=K,
            N=N,
            total_mac_ops=total_mac_ops,
            mem_reads=read_accesses,
            mem_writes=write_accesses,
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
    # Self-test on a 16x16x16 matrix multiplication
    np.random.seed(42)
    M, K, N = 16, 16, 16
    A = np.random.randn(M, K).astype(np.float32)
    B = np.random.randn(K, N).astype(np.float32)

    sim = BaselineAccelerator()
    C, m = sim.run(A, B)

    print("=" * 60)
    print(f"BASELINE ACCELERATOR (Architecture A) TEST: GEMM {M}x{K}x{N}")
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
