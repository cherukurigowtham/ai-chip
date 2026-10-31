#!/usr/bin/env python3
"""
os_benchmark.py - Architectural Simulator for Output-Stationary (OS) Dataflow.

Models a 4x4 Systolic Array with local output accumulators:
- Each PE(r, c) holds a stationary 32-bit accumulator register for output element C[r, c].
- Activations stream horizontally from the left (skewed by row).
- Weights stream vertically from the top (skewed by column).
- Accumulation occurs locally inside PE registers for K reduction cycles.
- Zero intermediate partial sum movement to memory!
- Drains 16 completed 32-bit outputs once all K reduction steps complete.
"""

import math
from typing import Dict, Any

class OutputStationarySimulator:
    def __init__(self, rows: int = 4, cols: int = 4, clk_mhz: float = 500.0,
                 dram_latency: int = 4, bus_width_bits: int = 64):
        self.rows = rows
        self.cols = cols
        self.clk_mhz = clk_mhz
        self.t_clk_ns = 1000.0 / clk_mhz
        self.dram_latency = dram_latency
        self.bus_words = bus_width_bits // 16 # 4 words (16-bit) per cycle

        # Energy coefficients (Nangate 45nm @ 1.1V)
        self.E_mac_pj = 1.25       # 16-bit MAC + local 32-bit accumulation
        self.E_sram_rd_pj = 5.0    # 16-bit SRAM read
        self.E_sram_wr_pj = 5.0    # 16-bit SRAM write
        self.E_dram_pj = 120.0     # 16-bit DRAM transfer (15 pJ/bit * 16)
        self.P_leakage_mw = 3.9    # Slightly higher leakage for dual streaming MUXes

    def run_workload(self, name: str, M: int, K: int, N: int) -> Dict[str, Any]:
        """
        Simulate GEMM C[M, N] = A[M, K] x B[K, N] on 4x4 OS array.
        Tiling:
        - T_M = ceil(M / rows)
        - T_N = ceil(N / cols)
        - Total output tiles = T_M * T_N.
        - For each (m_tile, n_tile):
            - Clear 16 local accumulators (1 cycle).
            - Stream K activation vectors (4 words each) horizontally.
            - Stream K weight vectors (4 words each) vertically.
            - Accumulate locally for K cycles.
            - Drain 16 output words (4 cycles).
        """
        T_M = math.ceil(M / self.rows)
        T_N = math.ceil(N / self.cols)
        total_tiles = T_M * T_N

        total_mac_ops = M * K * N
        total_cycles = 0
        active_mac_cycles = 0

        # Memory Access Tracking
        # In OS, for each (m_tile, n_tile):
        # We need activation tile A[m_tile*4 : (m_tile+1)*4, :] of size 4 x K.
        # We need weight tile B[:, n_tile*4 : (n_tile+1)*4] of size K x 4.
        # With on-chip buffering:
        # A tile is read T_N times (once per column tile).
        # B tile is read T_M times (once per row tile).
        dram_act_reads = T_N * (M * K)
        dram_weight_reads = T_M * (K * N)

        # Zero intermediate partial sum transfers!
        dram_psum_reads = 0
        dram_psum_writes = 0

        # Only the final finished outputs are written out strictly ONCE!
        final_output_words = M * N
        dram_psum_writes = final_output_words

        sram_writes = dram_act_reads + dram_weight_reads + final_output_words
        sram_reads = (total_tiles * 4 * K) + (total_tiles * 4 * K) # Streaming into PEs

        # Execution Cycle Modeling:
        # Per output tile:
        # T_accum = K + rows + cols - 2 = K + 6 cycles
        # Local accumulator reset = 1 cycle
        # Output drain shift = 4 cycles
        t_accum = K + self.rows + self.cols - 2
        t_reset = 1
        t_drain = self.rows

        # DRAM refill double-buffering:
        # Prefetching K words of A (4 vectors = 4K words) and B (4 vectors = 4K words)
        # Using double-buffered ping-pong streaming
        t_stream_refill = ((2 * self.rows) // self.bus_words) * self.dram_latency

        cold_start = ((4 * min(K, 16)) // self.bus_words) * self.dram_latency + t_reset
        total_cycles += cold_start

        for tile_idx in range(total_tiles):
            # Compute time for deep reduction K:
            tile_step = t_accum + t_drain
            total_cycles += tile_step

            # Active MACs: during steady state K steps, all 16 MACs active
            active_mac_cycles += K * (self.rows * self.cols)
            partial_macs = (self.rows + self.cols - 2) * 8
            active_mac_cycles += partial_macs

        # Metrics
        possible_mac_ops = total_cycles * (self.rows * self.cols)
        mac_utilization = (total_mac_ops / possible_mac_ops) * 100.0 if possible_mac_ops > 0 else 0.0

        total_dram_words = dram_weight_reads + dram_act_reads + dram_psum_writes
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
            "dataflow": "Output-Stationary (OS)",
            "M": M, "K": K, "N": N,
            "total_mac_ops": total_mac_ops,
            "total_cycles": total_cycles,
            "mac_utilization_%": round(mac_utilization, 2),
            "dram_weight_words": dram_weight_reads,
            "dram_act_words": dram_act_reads,
            "dram_psum_words": dram_psum_writes,
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
    sim = OutputStationarySimulator()
    print("Output Stationary Benchmark Module Loaded.")
