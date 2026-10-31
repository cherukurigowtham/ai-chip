"""
Phase 1: Memory Wall & Data Reuse Analysis
-------------------------------------------
This script compares:
- Architecture A (Naive MAC with Direct Memory Access)
- Architecture B (Tiled & Systolic Data Reuse)

It calculates the operational intensity, memory bandwidth demand,
and estimated energy profile for Matrix Multiplication (GEMM):
C [M x N] = A [M x K] * B [K x N]
"""

import numpy as np

# Energy figures based on standard energy models (Horowitz 2014, ISSCC)
# Values in picojoules (pJ) for 16-bit operations:
ENERGY_MAC_OP = 0.25       # 16-bit Integer/Fixed-point MAC compute energy
ENERGY_LOCAL_REG = 0.05    # Local register access inside PE
ENERGY_SRAM_ACCESS = 5.0   # On-chip SRAM / Global Buffer read/write per 16-bit word
ENERGY_DRAM_ACCESS = 150.0 # External DRAM access per 16-bit word


def analyze_gemm(M=64, K=64, N=64, tile_size=8):
    """
    Evaluates GEMM across Architecture A and Architecture B.
    M: Batch / Output height
    K: Input / Reduction dimension
    N: Output width / Number of output channels
    tile_size: Physical PE grid dimension (tile_size x tile_size)
    """
    total_macs = M * K * N
    
    # -------------------------------------------------------------
    # Architecture A: Naive MAC (Zero Local Reuse)
    # Each MAC operation:
    # 1. Fetch activation A[i, k] from memory
    # 2. Fetch weight B[k, j] from memory
    # 3. Fetch current partial sum C[i, j] from memory
    # 4. Write updated partial sum C[i, j] back to memory
    # -------------------------------------------------------------
    arch_a_mem_reads = 3 * total_macs
    arch_a_mem_writes = 1 * total_macs
    arch_a_total_mem_accesses = arch_a_mem_reads + arch_a_mem_writes
    
    # Assume 10% comes from cache, 90% hits main memory/DRAM
    arch_a_dram_accesses = arch_a_total_mem_accesses * 0.9
    arch_a_sram_accesses = arch_a_total_mem_accesses * 0.1

    arch_a_compute_energy_uj = (total_macs * ENERGY_MAC_OP) / 1e6
    arch_a_memory_energy_uj = (
        (arch_a_sram_accesses * ENERGY_SRAM_ACCESS) +
        (arch_a_dram_accesses * ENERGY_DRAM_ACCESS)
    ) / 1e6
    arch_a_total_energy_uj = arch_a_compute_energy_uj + arch_a_memory_energy_uj

    # -------------------------------------------------------------
    # Architecture B: Systolic / Tiled Architecture with Local Reuse
    # Tiled by (tile_size x tile_size).
    # Inside each tile:
    # - Activations streamed across rows (reused across 'tile_size' PEs)
    # - Weights held stationary inside PEs or streamed down columns
    # - Partial sums accumulated inside PE registers!
    # DRAM only accessed for the tiled matrix blocks:
    # -------------------------------------------------------------
    # Number of tiles in M, N, K
    num_tiles_m = (M + tile_size - 1) // tile_size
    num_tiles_n = (N + tile_size - 1) // tile_size
    num_tiles_k = (K + tile_size - 1) // tile_size

    # With on-chip SRAM double-buffering (Tiling):
    # Matrix A elements loaded: M * K * num_tiles_n times
    # Matrix B elements loaded: K * N * num_tiles_m times
    # Matrix C final writeout: M * N times
    arch_b_dram_reads = (M * K * num_tiles_n) + (K * N * num_tiles_m)
    arch_b_dram_writes = M * N
    arch_b_dram_accesses = arch_b_dram_reads + arch_b_dram_writes

    # Local register & inter-PE forwarding accesses:
    arch_b_local_reg_accesses = 2 * total_macs
    arch_b_sram_accesses = arch_b_dram_accesses * 2 # Buffer staging

    arch_b_compute_energy_uj = (total_macs * ENERGY_MAC_OP) / 1e6
    arch_b_memory_energy_uj = (
        (arch_b_local_reg_accesses * ENERGY_LOCAL_REG) +
        (arch_b_sram_accesses * ENERGY_SRAM_ACCESS) +
        (arch_b_dram_accesses * ENERGY_DRAM_ACCESS)
    ) / 1e6
    arch_b_total_energy_uj = arch_b_compute_energy_uj + arch_b_memory_energy_uj

    # Metrics summary
    reduction_ratio = arch_a_total_mem_accesses / arch_b_dram_accesses
    energy_savings = (1 - (arch_b_total_energy_uj / arch_a_total_energy_uj)) * 100

    report = {
        "dimensions": (M, K, N),
        "total_macs": total_macs,
        "tile_size": tile_size,
        "arch_a": {
            "total_mem_accesses": int(arch_a_total_mem_accesses),
            "dram_accesses": int(arch_a_dram_accesses),
            "compute_energy_uj": arch_a_compute_energy_uj,
            "memory_energy_uj": arch_a_memory_energy_uj,
            "total_energy_uj": arch_a_total_energy_uj,
            "memory_energy_pct": (arch_a_memory_energy_uj / arch_a_total_energy_uj) * 100
        },
        "arch_b": {
            "total_mem_accesses": int(arch_b_dram_accesses),
            "dram_accesses": int(arch_b_dram_accesses),
            "compute_energy_uj": arch_b_compute_energy_uj,
            "memory_energy_uj": arch_b_memory_energy_uj,
            "total_energy_uj": arch_b_total_energy_uj,
            "memory_energy_pct": (arch_b_memory_energy_uj / arch_b_total_energy_uj) * 100
        },
        "reduction_ratio": reduction_ratio,
        "energy_savings_pct": energy_savings
    }
    return report


if __name__ == "__main__":
    rep = analyze_gemm(M=64, K=64, N=64, tile_size=8)
    print("=" * 65)
    print("  AI ACCELERATOR MEMORY BOTTLENECK ANALYSIS (GEMM 64x64x64)")
    print("=" * 65)
    print(f"Total MAC Operations: {rep['total_macs']:,}")
    print("\n[Architecture A: Naive Un-tiled MAC]")
    print(f"  Memory Accesses:    {rep['arch_a']['total_mem_accesses']:,}")
    print(f"  DRAM Accesses:      {rep['arch_a']['dram_accesses']:,}")
    print(f"  Total Energy:       {rep['arch_a']['total_energy_uj']:.2f} uJ")
    print(f"  Memory Energy %:    {rep['arch_a']['memory_energy_pct']:.1f}%")

    print("\n[Architecture B: Tiled / Systolic Array (Tile: 8x8)]")
    print(f"  DRAM Accesses:      {rep['arch_b']['dram_accesses']:,}")
    print(f"  Total Energy:       {rep['arch_b']['total_energy_uj']:.2f} uJ")
    print(f"  Memory Energy %:    {rep['arch_b']['memory_energy_pct']:.1f}%")

    print("-" * 65)
    print(f">> Memory Access Reduction: {rep['reduction_ratio']:.1f}x fewer DRAM accesses")
    print(f">> Estimated Energy Savings: {rep['energy_savings_pct']:.1f}%")
    print("=" * 65)
