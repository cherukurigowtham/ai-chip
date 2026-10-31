#!/usr/bin/env python3
"""
calibrated_cost_model.py - Physical Silicon-Calibrated Cost Model for Phase 14.

Updated with measured Nangate 45nm post-synthesis silicon data:
- Base Logic Area: 114,958.92 um^2 (vs 70,488 um^2 uncalibrated)
- On-Chip DFF Buffer Storage Density: 78.5386 um^2 / Byte (vs 28.5 um^2/Byte uncalibrated)
- Max Feasible On-Chip Buffer Capacity within 200,000 um^2: 1,082 Bytes (541 words)
- Calibrated Leakage: 3.6 mW base + 0.0077 mW/Byte
- Timing: Critical path delay = 1.322 ns (F_max = 756.6 MHz), Slack @ 500 MHz = +678.4 ps
"""

import math
from typing import Dict, Any, Optional

# Hardware constants
CLK_MHZ = 500.0
T_CLK_NS = 1000.0 / CLK_MHZ # 2.0 ns
DRAM_LATENCY_CYCLES = 4
BUS_WORDS_PER_CYCLE = 4     # 64-bit bus = 4 words of 16-bit

# Energy coefficients (Nangate 45nm @ 1.1V)
E_MAC_PJ = 1.25
E_SRAM_RD_PJ = 5.0
E_SRAM_WR_PJ = 5.0
E_DRAM_PJ = 120.0

# Calibrated Silicon Parameters (from physical synthesis of accelerator_top)
CALIB_LOGIC_AREA_UM2 = 114958.92
CALIB_SRAM_DENSITY_UM2_PER_BYTE = 78.5386
CALIB_BASE_LEAKAGE_MW = 3.6
CALIB_SRAM_LEAKAGE_MW_PER_BYTE = 0.0077

MAX_AREA_BUDGET_UM2 = 200000.0
MAX_FEASIBLE_SRAM_BYTES = int((MAX_AREA_BUDGET_UM2 - CALIB_LOGIC_AREA_UM2) / CALIB_SRAM_DENSITY_UM2_PER_BYTE) # 1,082 Bytes


class CalibratedCostModel:
    def __init__(self, rows: int = 4, cols: int = 4):
        self.rows = rows
        self.cols = cols
        self.array_size = rows * cols

    def compute_sram_capacity_bytes(self, dataflow: str, T_M: int, T_K: int, T_N: int,
                                     double_buffering: bool) -> int:
        factor = 2 if double_buffering else 1
        if dataflow == "WS":
            act_words = T_M * T_K
            wt_words = T_K * T_N
            psum_words = T_M * T_N * 2
            total_words = factor * (act_words + wt_words) + psum_words
            return total_words * 2
        elif dataflow == "OS":
            act_words = self.rows * T_K
            wt_words = T_K * self.cols
            out_words = T_M * T_N * 2
            total_words = factor * (act_words + wt_words) + out_words
            return total_words * 2
        else:
            raise ValueError(f"Unknown dataflow: {dataflow}")

    def evaluate(self, M: int, K: int, N: int, dataflow: str,
                 T_M: int, T_K: int, T_N: int, double_buffering: bool) -> Optional[Dict[str, Any]]:
        sram_bytes = self.compute_sram_capacity_bytes(dataflow, T_M, T_K, T_N, double_buffering)
        total_area_um2 = CALIB_LOGIC_AREA_UM2 + (sram_bytes * CALIB_SRAM_DENSITY_UM2_PER_BYTE)

        # Strict Silicon Area Constraint
        if total_area_um2 > MAX_AREA_BUDGET_UM2 or sram_bytes > MAX_FEASIBLE_SRAM_BYTES:
            return None

        total_mac_ops = M * K * N
        P_leakage_mw = CALIB_BASE_LEAKAGE_MW + (sram_bytes * CALIB_SRAM_LEAKAGE_MW_PER_BYTE)

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
        n_m_tiles = math.ceil(M / T_M)
        n_k_tiles = math.ceil(K / T_K)
        n_n_tiles = math.ceil(N / T_N)

        sub_k = math.ceil(T_K / self.rows)
        sub_n = math.ceil(T_N / self.cols)
        tiles_per_block = sub_k * sub_n

        dram_weight_reads = n_k_tiles * n_n_tiles * (T_K * T_N)
        dram_act_reads = n_n_tiles * (M * K)

        inter_psum_words = 0
        if n_k_tiles > 1 or sub_k > 1:
            reduction_steps = n_k_tiles * sub_k
            inter_psum_words = (reduction_steps - 1) * M * N

        sram_psum_capacity_words = (T_M * T_N * 2)
        dram_psum_spill = max(0, inter_psum_words - sram_psum_capacity_words)
        dram_psum_reads = dram_psum_spill
        dram_psum_writes = dram_psum_spill + (M * N)

        total_dram_words = dram_weight_reads + dram_act_reads + dram_psum_reads + dram_psum_writes

        sram_writes = dram_act_reads + dram_weight_reads + inter_psum_words + (M * N)
        sram_reads = (n_m_tiles * n_k_tiles * n_n_tiles * (T_M * T_K + T_K * T_N)) + inter_psum_words

        t_sub_compute = T_M + self.rows + self.cols - 2
        t_setup = 2
        words_to_refill = (T_K * self.cols) + (T_M * self.rows)
        t_refill = math.ceil((words_to_refill / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES)

        total_sub_tiles = n_m_tiles * n_k_tiles * n_n_tiles * tiles_per_block
        cold_start = math.ceil(((16 + T_M * self.rows) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + t_setup
        total_cycles = cold_start

        if double_buffering:
            step_cycles = max(t_sub_compute + t_setup, t_refill)
        else:
            step_cycles = t_sub_compute + t_setup + t_refill
        total_cycles += total_sub_tiles * step_cycles
        total_cycles += math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

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
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }

    def _eval_os(self, M: int, K: int, N: int, T_M: int, T_K: int, T_N: int,
                 double_buffering: bool, sram_bytes: int, total_area_um2: float,
                 P_leakage_mw: float, total_mac_ops: int) -> Dict[str, Any]:
        n_m_tiles = math.ceil(M / T_M)
        n_k_tiles = math.ceil(K / T_K)
        n_n_tiles = math.ceil(N / T_N)

        sub_m = math.ceil(T_M / self.rows)
        sub_n = math.ceil(T_N / self.cols)
        output_sub_tiles = n_m_tiles * n_n_tiles * sub_m * sub_n

        dram_act_reads = n_n_tiles * (M * K)
        dram_weight_reads = n_m_tiles * (K * N)
        dram_psum_writes = M * N
        total_dram_words = dram_act_reads + dram_weight_reads + dram_psum_writes

        sram_writes = dram_act_reads + dram_weight_reads + (M * N)
        sram_reads = output_sub_tiles * (K * self.rows + K * self.cols)

        t_accum = K + self.rows + self.cols - 2
        t_reset = 1
        t_drain = self.rows

        words_to_refill = (K * self.rows) + (K * self.cols)
        t_refill = math.ceil((words_to_refill / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES)

        cold_start = math.ceil(((2 * self.rows * min(K, 16)) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + t_reset
        total_cycles = cold_start

        if double_buffering:
            step_cycles = max(t_accum + t_drain, t_refill)
        else:
            step_cycles = t_accum + t_drain + t_refill
        total_cycles += output_sub_tiles * step_cycles
        total_cycles += math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

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
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }
