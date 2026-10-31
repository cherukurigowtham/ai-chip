#!/usr/bin/env python3
"""
ws_benchmark.py - Architectural Simulator for Weight-Stationary (WS) Dataflow.

Models a 4x4 Systolic Array with local weight registers:
- Weights are preloaded into PE registers and remain stationary.
- Activations stream horizontally across PEs.
- Partial sums accumulate vertically and flow out of the bottom row.
- Measures execution cycles, active MAC cycles, memory accesses (Weights, Activations, Partial Sums),
  bandwidth, and energy consumption across standard neural network workloads.
"""

import math
from typing import Dict, Any

class WeightStationarySimulator:
    def __init__(self, rows: int = 4, cols: int = 4, clk_mhz: float = 500.0,
                 dram_latency: int = 4, bus_width_bits: int = 64):
        self.rows = rows
        self.cols = cols
        self.clk_mhz = clk_mhz
        self.t_clk_ns = 1000.0 / clk_mhz
        self.dram_latency = dram_latency
        self.bus_words = bus_width_bits // 16 # 4 words (16-bit) per cycle

        # Energy coefficients (Nangate 45nm @ 1.1V)
        self.E_mac_pj = 1.25       # 16-bit MAC
        self.E_sram_rd_pj = 5.0    # 16-bit SRAM read
        self.E_sram_wr_pj = 5.0    # 16-bit SRAM write
        self.E_dram_pj = 120.0     # 16-bit DRAM transfer (15 pJ/bit * 16)
        self.P_leakage_mw = 3.8    # On-chip leakage power

    def run_workload(self, name: str, M: int, K: int, N: int) -> Dict[str, Any]:
        """
        Simulate GEMM C[M, N] = A[M, K] x B[K, N] on 4x4 WS array.
        Tiling:
        - T_K = ceil(K / rows)
        - T_N = ceil(N / cols)
        - For each (k_tile, n_tile):
            - Load 16 weights.
            - Stream M activation vectors (each of length rows).
            - Stream M partial sum vectors (accumulate if k_tile > 0).
        """
        T_K = math.ceil(K / self.rows)
        T_N = math.ceil(N / self.cols)
        total_tiles = T_K * T_N

        total_mac_ops = M * K * N
        total_cycles = 0
        active_mac_cycles = 0
        stall_cycles = 0

        dram_weight_reads = 0
        dram_act_reads = 0
        dram_psum_reads = 0
        dram_psum_writes = 0
        sram_reads = 0
        sram_writes = 0

        # Weights: each 4x4 tile is loaded from DRAM once per tile
        # Total weights = T_K * T_N * 16 words
        tile_weights_words = self.rows * self.cols
        dram_weight_reads = total_tiles * tile_weights_words
        sram_writes += dram_weight_reads

        # Activations: for each n_tile, activations A[M, K] are streamed
        # With double-buffered activation buffer, A is read from DRAM T_N times
        dram_act_reads = T_N * (M * K)
        sram_writes += dram_act_reads

        # Partial Sums in WS:
        # If T_K > 1, intermediate partial sums must be stored to SRAM/DRAM and read back
        # For k_tile = 0: write intermediate psum
        # For k_tile = 1..T_K-2: read intermediate psum, write updated psum
        # For k_tile = T_K-1: read intermediate psum, write final output
        if T_K > 1:
            # (T_K - 1) reads and (T_K - 1) writes of intermediate M x cols elements per n_tile
            inter_words = (T_K - 1) * (M * self.cols) * T_N
            dram_psum_reads += inter_words
            dram_psum_writes += inter_words
            sram_reads += inter_words
            sram_writes += inter_words

        # Final output writes
        final_output_words = M * N
        dram_psum_writes += final_output_words
        sram_writes += final_output_words

        # Execution Cycle Modeling:
        # Per tile compute: T_stream = M + rows + cols - 2
        # Setup: 2 cycles (weight read + latch)
        # DRAM refill time for 16 weights = 5 * latency
        t_refill = 5 * self.dram_latency
        t_compute = M + self.rows + self.cols - 2
        t_setup = 2

        # Pipelined / double-buffered tile step:
        # First tile has cold-start weight + act preload
        cold_start = (tile_weights_words // self.bus_words) * self.dram_latency + \
                     ((min(M, 32) * self.rows) // self.bus_words) * self.dram_latency + t_setup
        total_cycles += cold_start

        for tile_idx in range(total_tiles):
            # Compute phase
            tile_step = max(t_compute + t_setup, t_refill)
            total_cycles += tile_step
            # In each cycle of steady streaming (M vectors), all 16 MACs active
            active_mac_cycles += min(M, M) * (self.rows * self.cols)
            # Ramp-up and ramp-down cycles have partial MAC activity
            partial_macs = (self.rows + self.cols - 2) * 8
            active_mac_cycles += partial_macs

            # SRAM reads: 16 weights read once per tile, M vectors of 4 elements read
            sram_reads += tile_weights_words + (M * self.rows)

        # Output draining overhead
        drain_cycles = (final_output_words // self.bus_words)
        total_cycles += drain_cycles

        # Metrics
        possible_mac_ops = total_cycles * (self.rows * self.cols)
        mac_utilization = (total_mac_ops / possible_mac_ops) * 100.0 if possible_mac_ops > 0 else 0.0

        total_dram_words = dram_weight_reads + dram_act_reads + dram_psum_reads + dram_psum_writes
        total_dram_bytes = total_dram_words * 2
        exec_time_ns = total_cycles * self.t_clk_ns
        bandwidth_gb_s = (total_dram_bytes / (exec_time_ns * 1e-9)) / 1e9 if exec_time_ns > 0 else 0.0

        # Energy Breakdown (uJ)
        e_mac_uj = (total_mac_ops * self.E_mac_pj) / 1e6
        e_sram_uj = ((sram_reads * self.E_sram_rd_pj) + (sram_writes * self.E_sram_wr_pj)) / 1e6
        e_dram_uj = (total_dram_words * self.E_dram_pj) / 1e6
        e_leak_uj = (self.P_leakage_mw * exec_time_ns) / 1e6
        total_energy_uj = e_mac_uj + e_sram_uj + e_dram_uj + e_leak_uj

        return {
            "workload": name,
            "dataflow": "Weight-Stationary (WS)",
            "M": M, "K": K, "N": N,
            "total_mac_ops": total_mac_ops,
            "total_cycles": total_cycles,
            "mac_utilization_%": round(mac_utilization, 2),
            "dram_weight_words": dram_weight_reads,
            "dram_act_words": dram_act_reads,
            "dram_psum_words": dram_psum_reads + dram_psum_writes,
            "total_dram_words": total_dram_words,
            "total_dram_bytes": total_dram_bytes,
            "bandwidth_GB_s": round(bandwidth_gb_s, 2),
            "energy_mac_uJ": round(e_mac_uj, 4),
            "energy_sram_uJ": round(e_sram_uj, 4),
            "energy_dram_uJ": round(e_dram_uj, 4),
            "total_energy_uJ": round(total_energy_uj, 4),
            "energy_per_mac_pJ": round((total_energy_uj * 1e6) / total_mac_ops, 2) if total_mac_ops > 0 else 0.0
        }

if __name__ == "__main__":
    sim = WeightStationarySimulator()
    print("Weight Stationary Benchmark Module Loaded.")
