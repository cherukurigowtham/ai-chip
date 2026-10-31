#!/usr/bin/env python3
"""
cost_model.py - Hardware-Aware Analytical Cost Model for AI Accelerators.

Calibrated against Nangate 45nm standard cell library @ 1.1V, 500 MHz:
- Dynamic MAC energy: 1.25 pJ / 16-bit MAC
- Dynamic SRAM read/write energy: 5.0 pJ / 16-bit word
- Dynamic DRAM transfer energy: 120.0 pJ / 16-bit word (15 pJ/bit * 16 bits)
- Logic area (16 PEs + Controller + Array Interconnect): 70,488 um^2
- SRAM bitcell & peripheral area: 28.5 um^2 / Byte
- Static leakage: 2.2 mW (base logic) + 0.0028 mW/Byte * SRAM_bytes
- Strict Area Constraint: Area_total <= 200,000 um^2 (0.20 mm^2)
"""

import math
from typing import Dict, Any, Optional

# Hardware constants
CLK_MHZ = 500.0
T_CLK_NS = 1000.0 / CLK_MHZ # 2.0 ns
DRAM_LATENCY_CYCLES = 4
BUS_WORDS_PER_CYCLE = 4     # 64-bit bus = 4 words of 16-bit

# Technology constants (Nangate 45nm)
E_MAC_PJ = 1.25
E_SRAM_RD_PJ = 5.0
E_SRAM_WR_PJ = 5.0
E_DRAM_PJ = 120.0

LOGIC_AREA_UM2 = 70488.0
SRAM_AREA_PER_BYTE_UM2 = 28.5
BASE_LEAKAGE_MW = 2.2
SRAM_LEAKAGE_MW_PER_BYTE = 0.0028
MAX_AREA_BUDGET_UM2 = 200000.0


class HardwareCostModel:
    def __init__(self, rows: int = 4, cols: int = 4):
        self.rows = rows
        self.cols = cols
        self.array_size = rows * cols # 16 MACs

    def compute_sram_capacity_bytes(self, dataflow: str, T_M: int, T_K: int, T_N: int,
                                     double_buffering: bool) -> int:
        """
        Calculates required SRAM capacity in bytes for given tiling and buffering mode.
        Each word is 16-bit = 2 bytes. Accumulator buffer in OS stores 32-bit = 4 bytes.
        """
        factor = 2 if double_buffering else 1

        if dataflow == "WS":
            # Activation buffer: stores T_M rows of T_K words
            act_words = T_M * T_K
            # Weight buffer: stores T_K * T_N weights
            wt_words = T_K * T_N
            # Intermediate / output partial-sum buffer: stores T_M * T_N words (32-bit accum = 2 words)
            psum_words = T_M * T_N * 2
            total_words = factor * (act_words + wt_words) + psum_words
            return total_words * 2 # 2 bytes per word
        elif dataflow == "OS":
            # Activation buffer: stores rows * T_K words
            act_words = self.rows * T_K
            # Weight buffer: stores T_K * cols words
            wt_words = T_K * self.cols
            # Output buffer: stores T_M * T_N accumulators (32-bit = 2 words)
            out_words = T_M * T_N * 2
            total_words = factor * (act_words + wt_words) + out_words
            return total_words * 2
        else:
            raise ValueError(f"Unknown dataflow: {dataflow}")

    def evaluate(self, M: int, K: int, N: int, dataflow: str,
                 T_M: int, T_K: int, T_N: int, double_buffering: bool) -> Optional[Dict[str, Any]]:
        """
        Analytically models execution cycles, memory traffic, energy, area, and MAC utilization.
        Returns None if physical constraints (e.g. area budget) are violated.
        """
        # Calculate SRAM and total silicon area
        sram_bytes = self.compute_sram_capacity_bytes(dataflow, T_M, T_K, T_N, double_buffering)
        sram_area_um2 = sram_bytes * SRAM_AREA_PER_BYTE_UM2
        total_area_um2 = LOGIC_AREA_UM2 + sram_area_um2

        # Hard area constraint
        if total_area_um2 > MAX_AREA_BUDGET_UM2:
            return None

        total_mac_ops = M * K * N
        P_leakage_mw = BASE_LEAKAGE_MW + (sram_bytes * SRAM_LEAKAGE_MW_PER_BYTE)

        if dataflow == "WS":
            return self._eval_ws(M, K, N, T_M, T_K, T_N, double_buffering,
                                sram_bytes, total_area_um2, P_leakage_mw, total_mac_ops)
        elif dataflow == "OS":
            return self._eval_os(M, K, N, T_M, T_K, T_N, double_buffering,
                                sram_bytes, total_area_um2, P_leakage_mw, total_mac_ops)
        else:
            return None

    def _eval_ws(self, M: int, K: int, N: int, T_M: int, T_K: int, T_N: int,
                 double_buffering: bool, sram_bytes: int, total_area_um2: float,
                 P_leakage_mw: float, total_mac_ops: int) -> Dict[str, Any]:
        """
        Weight-Stationary analytical execution model.
        Weights are held stationary in PE registers for the duration of streaming activation batch T_M.
        """
        n_m_tiles = math.ceil(M / T_M)
        n_k_tiles = math.ceil(K / T_K)
        n_n_tiles = math.ceil(N / T_N)

        sub_k = math.ceil(T_K / self.rows)
        sub_n = math.ceil(T_N / self.cols)
        tiles_per_block = sub_k * sub_n

        # DRAM Traffic
        # Weights: loaded for each (m_tile, k_tile, n_tile) block if not retained across m_tiles.
        # Across M, weights can be reused across all m_tiles if stationary in SRAM!
        # Weight DRAM reads: loaded once into SRAM if T_K*T_N fits, else reloaded.
        dram_weight_reads = n_k_tiles * n_n_tiles * (T_K * T_N)
        # Activations: read from DRAM for each n_tile
        dram_act_reads = n_n_tiles * (M * K)
        # Partial sums: if K > rows or sub_k > 1, intermediate partial sums must spill
        inter_psum_words = 0
        if n_k_tiles > 1 or sub_k > 1:
            # (total reduction steps - 1) partial sum spills to SRAM/DRAM
            reduction_steps = n_k_tiles * sub_k
            inter_psum_words = (reduction_steps - 1) * M * N

        # Intermediate psums that exceed SRAM spill to DRAM; otherwise stay in SRAM
        sram_psum_capacity_words = (T_M * T_N * 2)
        if inter_psum_words > sram_psum_capacity_words:
            dram_psum_spill = inter_psum_words - sram_psum_capacity_words
        else:
            dram_psum_spill = 0

        dram_psum_reads = dram_psum_spill
        dram_psum_writes = dram_psum_spill + (M * N) # final output written to DRAM

        total_dram_words = dram_weight_reads + dram_act_reads + dram_psum_reads + dram_psum_writes

        # SRAM accesses
        # SRAM writes = all data coming from DRAM + intermediate psums generated
        sram_writes = dram_act_reads + dram_weight_reads + inter_psum_words + (M * N)
        # SRAM reads = streaming activations into array + loading weights into array + reading psums for accum
        sram_reads = (n_m_tiles * n_k_tiles * n_n_tiles * (T_M * T_K + T_K * T_N)) + inter_psum_words

        # Cycle Modeling
        # Array compute time per 4x4 sub-tile: T_stream = actual_tm + rows + cols - 2
        t_sub_compute = T_M + self.rows + self.cols - 2
        t_setup = 2 # weight load + latch

        # DRAM refill cycles for double buffering vs single buffering
        words_to_refill = (T_K * self.cols) + (T_M * self.rows)
        t_refill = math.ceil((words_to_refill / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES)

        total_sub_tiles = n_m_tiles * n_k_tiles * n_n_tiles * tiles_per_block

        # Cold start
        cold_start = math.ceil(((16 + T_M * self.rows) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + t_setup
        total_cycles = cold_start

        if double_buffering:
            # Overlapped execution: max of compute and background refill
            step_cycles = max(t_sub_compute + t_setup, t_refill)
            total_cycles += total_sub_tiles * step_cycles
        else:
            # Sequential execution: compute + refill
            step_cycles = t_sub_compute + t_setup + t_refill
            total_cycles += total_sub_tiles * step_cycles

        # Drain cycles for final output
        total_cycles += math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

        # Metrics
        possible_macs = total_cycles * self.array_size
        mac_util = (total_mac_ops / possible_macs) * 100.0 if possible_macs > 0 else 0.0

        exec_time_ns = total_cycles * T_CLK_NS
        e_mac_uj = (total_mac_ops * E_MAC_PJ) / 1e6
        e_sram_uj = ((sram_reads * E_SRAM_RD_PJ) + (sram_writes * E_SRAM_WR_PJ)) / 1e6
        e_dram_uj = (total_dram_words * E_DRAM_PJ) / 1e6
        e_leak_uj = (P_leakage_mw * exec_time_ns) / 1e6
        total_energy_uj = e_mac_uj + e_sram_uj + e_dram_uj + e_leak_uj
        energy_per_mac_pj = (total_energy_uj * 1e6) / total_mac_ops if total_mac_ops > 0 else 0.0

        return {
            "dataflow": "WS",
            "M": M, "K": K, "N": N,
            "T_M": T_M, "T_K": T_K, "T_N": T_N,
            "double_buffering": double_buffering,
            "sram_bytes": sram_bytes,
            "area_um2": total_area_um2,
            "total_cycles": total_cycles,
            "exec_time_ns": exec_time_ns,
            "mac_util_%": round(mac_util, 2),
            "total_dram_words": total_dram_words,
            "total_sram_words": sram_reads + sram_writes,
            "e_mac_uj": e_mac_uj,
            "e_sram_uj": e_sram_uj,
            "e_dram_uj": e_dram_uj,
            "e_leak_uj": e_leak_uj,
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }

    def _eval_os(self, M: int, K: int, N: int, T_M: int, T_K: int, T_N: int,
                 double_buffering: bool, sram_bytes: int, total_area_um2: float,
                 P_leakage_mw: float, total_mac_ops: int) -> Dict[str, Any]:
        """
        Output-Stationary analytical execution model.
        Accumulators hold C[r, c] stationary inside PE registers for all K reductions.
        Intermediate partial sums are never transferred off-PE.
        """
        n_m_tiles = math.ceil(M / T_M)
        n_k_tiles = math.ceil(K / T_K)
        n_n_tiles = math.ceil(N / T_N)

        sub_m = math.ceil(T_M / self.rows)
        sub_n = math.ceil(T_N / self.cols)
        output_sub_tiles = n_m_tiles * n_n_tiles * sub_m * sub_n

        # DRAM Traffic
        # In OS, activations for a row tile are read n_n_tiles times
        dram_act_reads = n_n_tiles * (M * K)
        # Weights for a column tile are read n_m_tiles times
        dram_weight_reads = n_m_tiles * (K * N)

        # Intermediate partial sums: ZERO in OS!
        dram_psum_reads = 0
        dram_psum_writes = M * N # Only final outputs written

        total_dram_words = dram_act_reads + dram_weight_reads + dram_psum_writes

        # SRAM accesses
        sram_writes = dram_act_reads + dram_weight_reads + (M * N)
        # Streaming K vectors of 4 activations + 4 weights per 4x4 sub-tile
        sram_reads = output_sub_tiles * (K * self.rows + K * self.cols)

        # Cycle Modeling
        # For each output sub-tile, accumulate for K cycles: T_accum = K + rows + cols - 2
        t_accum = K + self.rows + self.cols - 2
        t_reset = 1
        t_drain = self.rows # 4 cycles shift drain

        words_to_refill = (K * self.rows) + (K * self.cols)
        t_refill = math.ceil((words_to_refill / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES)

        cold_start = math.ceil(((2 * self.rows * min(K, 16)) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + t_reset
        total_cycles = cold_start

        if double_buffering:
            step_cycles = max(t_accum + t_drain, t_refill)
            total_cycles += output_sub_tiles * step_cycles
        else:
            step_cycles = t_accum + t_drain + t_refill
            total_cycles += output_sub_tiles * step_cycles

        # Final drain
        total_cycles += math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

        # Metrics
        possible_macs = total_cycles * self.array_size
        mac_util = (total_mac_ops / possible_macs) * 100.0 if possible_macs > 0 else 0.0

        exec_time_ns = total_cycles * T_CLK_NS
        e_mac_uj = (total_mac_ops * E_MAC_PJ) / 1e6
        e_sram_uj = ((sram_reads * E_SRAM_RD_PJ) + (sram_writes * E_SRAM_WR_PJ)) / 1e6
        e_dram_uj = (total_dram_words * E_DRAM_PJ) / 1e6
        e_leak_uj = (P_leakage_mw * exec_time_ns) / 1e6
        total_energy_uj = e_mac_uj + e_sram_uj + e_dram_uj + e_leak_uj
        energy_per_mac_pj = (total_energy_uj * 1e6) / total_mac_ops if total_mac_ops > 0 else 0.0

        return {
            "dataflow": "OS",
            "M": M, "K": K, "N": N,
            "T_M": T_M, "T_K": T_K, "T_N": T_N,
            "double_buffering": double_buffering,
            "sram_bytes": sram_bytes,
            "area_um2": total_area_um2,
            "total_cycles": total_cycles,
            "exec_time_ns": exec_time_ns,
            "mac_util_%": round(mac_util, 2),
            "total_dram_words": total_dram_words,
            "total_sram_words": sram_reads + sram_writes,
            "e_mac_uj": e_mac_uj,
            "e_sram_uj": e_sram_uj,
            "e_dram_uj": e_dram_uj,
            "e_leak_uj": e_leak_uj,
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }
