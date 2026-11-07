#!/usr/bin/env python3
"""
run_comprehensive_exploration.py - Multi-Array (4x4, 8x8, 16x16) Architectural Space Exploration.

Phase 13 Priority Objectives:
1. Explore array dimensions: 4x4, 8x8, and 16x16.
2. Benchmark both dataflows: Weight-Stationary (WS), Output-Stationary (OS), and Adaptive Selection.
3. Sweep 100 diverse neural network GEMM workloads across batch M, reduction K, and output width N.
4. Measure: execution cycles, MAC utilization, estimated memory traffic, silicon area, and estimated energy.
5. Generate Pareto frontiers: Area vs Performance, Energy vs Performance, and Area vs Energy.
6. Validate the adaptive controller: confirm dataflow selection matches the best measured dataflow
   and quantify where naive heuristic rules (M >> K vs K >> M) fail.
7. Label all energy/traffic results strictly as architectural estimates.
"""

import os
import sys
import math
import json
import csv
from typing import Dict, Any, List, Tuple

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../search_engine")))
from workload_generator import get_100_workloads

# Hardware & Technology Constants (Nangate 45nm @ 1.1V, 500 MHz)
CLK_MHZ = 500.0
T_CLK_NS = 1000.0 / CLK_MHZ  # 2.0 ns
DRAM_LATENCY_CYCLES = 4
BUS_WORDS_PER_CYCLE = 4      # 64-bit bus = 4x 16-bit words

# Energy Constants (Calibrated Architectural Estimates)
E_MAC_PJ = 1.25              # 1.25 pJ per 16-bit MAC
E_SRAM_RD_PJ = 5.0           # 5.0 pJ per 16-bit SRAM read
E_SRAM_WR_PJ = 5.0           # 5.0 pJ per 16-bit SRAM write
E_DRAM_PJ = 120.0            # 120.0 pJ per 16-bit word (15 pJ/bit LPDDR4 PHY)

# Area & Leakage Scaling Parameters
PE_AREA_UM2 = 3800.0         # Synthesized dual-mode ternary PE
SRAM_AREA_PER_BYTE_UM2 = 28.5
SRAM_LEAKAGE_MW_PER_BYTE = 0.0028

ARRAY_CONFIGS = {
    "4x4": {
        "rows": 4, "cols": 4, "array_size": 16,
        "base_logic_area_um2": 70488.0,      # 16 PEs + controller + interconnect
        "base_leakage_mw": 2.2,
        "max_area_budget_um2": 250000.0,
        "tile_candidates": [4, 8, 16, 32, 64]
    },
    "8x8": {
        "rows": 8, "cols": 8, "array_size": 64,
        "base_logic_area_um2": 265200.0,     # 64 PEs + 2D tree interconnect + controller
        "base_leakage_mw": 7.5,
        "max_area_budget_um2": 650000.0,
        "tile_candidates": [8, 16, 32, 64, 128]
    },
    "16x16": {
        "rows": 16, "cols": 16, "array_size": 256,
        "base_logic_area_um2": 1057800.0,    # 256 PEs + H-tree network + controller
        "base_leakage_mw": 26.0,
        "max_area_budget_um2": 2200000.0,
        "tile_candidates": [16, 32, 64, 128, 256]
    }
}


class ParameterizedCostModel:
    def __init__(self, config_name: str):
        self.cfg_name = config_name
        self.cfg = ARRAY_CONFIGS[config_name]
        self.rows = self.cfg["rows"]
        self.cols = self.cfg["cols"]
        self.array_size = self.cfg["array_size"]
        self.base_logic_area = self.cfg["base_logic_area_um2"]
        self.base_leakage = self.cfg["base_leakage_mw"]
        self.max_area = self.cfg["max_area_budget_um2"]

    def compute_sram_bytes(self, dataflow: str, T_M: int, T_K: int, T_N: int, double_buffering: bool) -> int:
        factor = 2 if double_buffering else 1
        if dataflow == "WS":
            act_words = T_M * T_K
            wt_words = T_K * T_N
            psum_words = T_M * T_N * 2  # 32-bit accum = 2x 16-bit words
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

    def evaluate_ws(self, M: int, K: int, N: int, T_M: int, T_K: int, T_N: int, double_buffering: bool) -> Optional[Dict[str, Any]]:
        sram_bytes = self.compute_sram_bytes("WS", T_M, T_K, T_N, double_buffering)
        total_area = self.base_logic_area + (sram_bytes * SRAM_AREA_PER_BYTE_UM2)
        if total_area > self.max_area:
            return None

        total_mac_ops = M * K * N
        P_leak_mw = self.base_leakage + (sram_bytes * SRAM_LEAKAGE_MW_PER_BYTE)

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

        sram_psum_capacity = T_M * T_N * 2
        dram_psum_spill = max(0, inter_psum_words - sram_psum_capacity)
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
        cold_start = math.ceil(((self.array_size + T_M * self.rows) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + t_setup

        if double_buffering:
            step_cycles = max(t_sub_compute + t_setup, t_refill)
        else:
            step_cycles = t_sub_compute + t_setup + t_refill

        total_cycles = cold_start + (total_sub_tiles * step_cycles) + math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

        possible_macs = total_cycles * self.array_size
        mac_util = (total_mac_ops / possible_macs) * 100.0 if possible_macs > 0 else 0.0

        exec_time_ns = total_cycles * T_CLK_NS
        throughput_gops = (total_mac_ops * 2) / (exec_time_ns * 1.0)  # 2 ops per MAC (multiply + accumulate)

        e_mac_uj = (total_mac_ops * E_MAC_PJ) / 1e6
        e_sram_uj = ((sram_reads * E_SRAM_RD_PJ) + (sram_writes * E_SRAM_WR_PJ)) / 1e6
        e_dram_uj = (total_dram_words * E_DRAM_PJ) / 1e6
        e_leak_uj = (P_leak_mw * exec_time_ns) / 1e6
        total_energy_uj = e_mac_uj + e_sram_uj + e_dram_uj + e_leak_uj
        energy_per_mac_pj = (total_energy_uj * 1e6) / total_mac_ops if total_mac_ops > 0 else 0.0

        return {
            "array": self.cfg_name, "dataflow": "WS",
            "M": M, "K": K, "N": N, "T_M": T_M, "T_K": T_K, "T_N": T_N,
            "double_buffering": double_buffering,
            "sram_bytes": sram_bytes, "area_um2": total_area,
            "total_cycles": total_cycles, "exec_time_ns": exec_time_ns,
            "throughput_gops": throughput_gops,
            "mac_util_%": round(mac_util, 2),
            "dram_words": total_dram_words, "sram_words": sram_reads + sram_writes,
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }

    def evaluate_os(self, M: int, K: int, N: int, T_M: int, T_K: int, T_N: int, double_buffering: bool) -> Optional[Dict[str, Any]]:
        sram_bytes = self.compute_sram_bytes("OS", T_M, T_K, T_N, double_buffering)
        total_area = self.base_logic_area + (sram_bytes * SRAM_AREA_PER_BYTE_UM2)
        if total_area > self.max_area:
            return None

        total_mac_ops = M * K * N
        P_leak_mw = self.base_leakage + (sram_bytes * SRAM_LEAKAGE_MW_PER_BYTE)

        n_m_tiles = math.ceil(M / T_M)
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
        t_drain = self.rows
        words_to_refill = (K * self.rows) + (K * self.cols)
        t_refill = math.ceil((words_to_refill / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES)

        cold_start = math.ceil(((2 * self.rows * min(K, self.cols * 4)) / BUS_WORDS_PER_CYCLE) * DRAM_LATENCY_CYCLES) + 1

        if double_buffering:
            step_cycles = max(t_accum + t_drain, t_refill)
        else:
            step_cycles = t_accum + t_drain + t_refill

        total_cycles = cold_start + (output_sub_tiles * step_cycles) + math.ceil((M * N) / BUS_WORDS_PER_CYCLE)

        possible_macs = total_cycles * self.array_size
        mac_util = (total_mac_ops / possible_macs) * 100.0 if possible_macs > 0 else 0.0

        exec_time_ns = total_cycles * T_CLK_NS
        throughput_gops = (total_mac_ops * 2) / (exec_time_ns * 1.0)

        e_mac_uj = (total_mac_ops * E_MAC_PJ) / 1e6
        e_sram_uj = ((sram_reads * E_SRAM_RD_PJ) + (sram_writes * E_SRAM_WR_PJ)) / 1e6
        e_dram_uj = (total_dram_words * E_DRAM_PJ) / 1e6
        e_leak_uj = (P_leak_mw * exec_time_ns) / 1e6
        total_energy_uj = e_mac_uj + e_sram_uj + e_dram_uj + e_leak_uj
        energy_per_mac_pj = (total_energy_uj * 1e6) / total_mac_ops if total_mac_ops > 0 else 0.0

        return {
            "array": self.cfg_name, "dataflow": "OS",
            "M": M, "K": K, "N": N, "T_M": T_M, "T_K": T_K, "T_N": T_N,
            "double_buffering": double_buffering,
            "sram_bytes": sram_bytes, "area_um2": total_area,
            "total_cycles": total_cycles, "exec_time_ns": exec_time_ns,
            "throughput_gops": throughput_gops,
            "mac_util_%": round(mac_util, 2),
            "dram_words": total_dram_words, "sram_words": sram_reads + sram_writes,
            "total_energy_uj": total_energy_uj,
            "energy_per_mac_pj": round(energy_per_mac_pj, 3)
        }

    def find_optimal_ws(self, M: int, K: int, N: int) -> Dict[str, Any]:
        best = None
        candidates = self.cfg["tile_candidates"]
        for tm in [c for c in candidates if c <= max(M, self.rows)]:
            for tk in [c for c in candidates if c <= max(K, self.rows)]:
                for tn in [c for c in candidates if c <= max(N, self.cols)]:
                    for db in [True, False]:
                        res = self.evaluate_ws(M, K, N, tm, tk, tn, db)
                        if res is not None:
                            if best is None or res["total_energy_uj"] < best["total_energy_uj"]:
                                best = res
        if best is None:
            # Fallback to minimal tile
            best = self.evaluate_ws(M, K, N, self.rows, self.rows, self.cols, False)
        return best

    def find_optimal_os(self, M: int, K: int, N: int) -> Dict[str, Any]:
        best = None
        candidates = self.cfg["tile_candidates"]
        for tm in [c for c in candidates if c <= max(M, self.rows)]:
            for tk in [c for c in candidates if c <= max(K, self.rows)]:
                for tn in [c for c in candidates if c <= max(N, self.cols)]:
                    for db in [True, False]:
                        res = self.evaluate_os(M, K, N, tm, tk, tn, db)
                        if res is not None:
                            if best is None or res["total_energy_uj"] < best["total_energy_uj"]:
                                best = res
        if best is None:
            best = self.evaluate_os(M, K, N, self.rows, self.rows, self.cols, False)
        return best

    def evaluate_heuristic(self, M: int, K: int, N: int) -> Dict[str, Any]:
        """Phase 12 Heuristic: If K/M > 1.0 => OS, else WS."""
        is_os = (K / M) > 1.0
        if is_os:
            res = self.find_optimal_os(M, K, N)
            res = dict(res)
            res["strategy"] = "Heuristic OS"
            return res
        else:
            res = self.find_optimal_ws(M, K, N)
            res = dict(res)
            res["strategy"] = "Heuristic WS"
            return res

    def evaluate_cost_model_adaptive(self, M: int, K: int, N: int) -> Dict[str, Any]:
        """Phase 13 Adaptive Controller: Evaluates analytical cost of both dataflows and selects measured minimum."""
        best_ws = self.find_optimal_ws(M, K, N)
        best_os = self.find_optimal_os(M, K, N)

        if best_ws["total_energy_uj"] <= best_os["total_energy_uj"]:
            chosen = dict(best_ws)
            chosen["strategy"] = "Adaptive (Cost Model -> WS)"
            chosen["true_optimum"] = "WS"
        else:
            chosen = dict(best_os)
            chosen["strategy"] = "Adaptive (Cost Model -> OS)"
            chosen["true_optimum"] = "OS"

        chosen["ws_energy_uj"] = best_ws["total_energy_uj"]
        chosen["os_energy_uj"] = best_os["total_energy_uj"]
        chosen["ws_cycles"] = best_ws["total_cycles"]
        chosen["os_cycles"] = best_os["total_cycles"]
        return chosen


def run_full_space_exploration():
    workloads = get_100_workloads()
    print("=" * 90)
    print("  PHASE 13: COMPREHENSIVE ARCHITECTURAL SPACE EXPLORATION")
    print("  Array Configurations: 4x4 (16 MACs), 8x8 (64 MACs), 16x16 (256 MACs)")
    print("  Workloads Evaluated: 100 Real-World Deep Learning Shapes across 5 Domains")
    print("=" * 90)

    all_records = []
    heuristic_mismatch_count = {"4x4": 0, "8x8": 0, "16x16": 0}
    pareto_candidates = []

    for cfg_name in ["4x4", "8x8", "16x16"]:
        print(f"\n[EXPLORATION] Sweeping Array Dimension: {cfg_name} ...")
        model = ParameterizedCostModel(cfg_name)

        for w in workloads:
            w_id = w["id"]
            cat = w["category"]
            name = w["name"]
            M, K, N = w["M"], w["K"], w["N"]
            total_macs = M * K * N

            res_ws = model.find_optimal_ws(M, K, N)
            res_os = model.find_optimal_os(M, K, N)
            res_heur = model.evaluate_heuristic(M, K, N)
            res_adapt = model.evaluate_cost_model_adaptive(M, K, N)

            # Check if heuristic made a sub-optimal choice
            heur_choice = "OS" if (K / M) > 1.0 else "WS"
            true_opt_choice = res_adapt["true_optimum"]
            heur_mismatch = (heur_choice != true_opt_choice)
            if heur_mismatch:
                heuristic_mismatch_count[cfg_name] += 1

            # Energy savings calculation
            savings_vs_ws = ((res_ws["total_energy_uj"] - res_adapt["total_energy_uj"]) / res_ws["total_energy_uj"]) * 100.0
            savings_vs_os = ((res_os["total_energy_uj"] - res_adapt["total_energy_uj"]) / res_os["total_energy_uj"]) * 100.0
            savings_vs_heur = ((res_heur["total_energy_uj"] - res_adapt["total_energy_uj"]) / res_heur["total_energy_uj"]) * 100.0

            record = {
                "Array": cfg_name,
                "Workload_ID": w_id,
                "Category": cat,
                "Name": name,
                "M": M, "K": K, "N": N, "Total_MACs": total_macs,
                "WS_Cycles": res_ws["total_cycles"],
                "OS_Cycles": res_os["total_cycles"],
                "Adapt_Cycles": res_adapt["total_cycles"],
                "WS_Util_%": res_ws["mac_util_%"],
                "OS_Util_%": res_os["mac_util_%"],
                "Adapt_Util_%": res_adapt["mac_util_%"],
                "WS_DRAM_Words": res_ws["dram_words"],
                "OS_DRAM_Words": res_os["dram_words"],
                "Adapt_DRAM_Words": res_adapt["dram_words"],
                "WS_Area_um2": res_ws["area_um2"],
                "OS_Area_um2": res_os["area_um2"],
                "Adapt_Area_um2": res_adapt["area_um2"],
                "WS_Energy_uJ": res_ws["total_energy_uj"],
                "OS_Energy_uJ": res_os["total_energy_uj"],
                "Heur_Energy_uJ": res_heur["total_energy_uj"],
                "Adapt_Energy_uJ": res_adapt["total_energy_uj"],
                "Adapt_pJ_per_MAC": res_adapt["energy_per_mac_pj"],
                "Throughput_GOPS": res_adapt["throughput_gops"],
                "Heur_Choice": heur_choice,
                "True_Optimum": true_opt_choice,
                "Heur_Mismatch": heur_mismatch,
                "Savings_vs_WS_%": round(savings_vs_ws, 2),
                "Savings_vs_OS_%": round(savings_vs_os, 2),
                "Savings_vs_Heur_%": round(savings_vs_heur, 2)
            }
            all_records.append(record)

            # Store Pareto evaluation candidate
            pareto_candidates.append({
                "Array": cfg_name, "Workload": name, "Category": cat,
                "Dataflow": res_adapt["true_optimum"],
                "Area_um2": res_adapt["area_um2"],
                "Throughput_GOPS": res_adapt["throughput_gops"],
                "Energy_uJ": res_adapt["total_energy_uj"],
                "Energy_pJ_MAC": res_adapt["energy_per_mac_pj"],
                "Cycles": res_adapt["total_cycles"]
            })

    # Save to CSV
    os.makedirs("ai-accelerator-project/phase13/results", exist_ok=True)
    csv_file = "ai-accelerator-project/phase13/results/multisize_architecture_exploration.csv"
    with open(csv_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(all_records[0].keys()))
        writer.writeheader()
        writer.writerows(all_records)
    print(f"\n[OUTPUT] Saved complete 300-run exploration dataset to {csv_file}")

    # Compute Pareto Frontiers
    pareto_area_perf = compute_pareto(pareto_candidates, "Area_um2", "Throughput_GOPS", min_x=True, max_y=True)
    pareto_energy_perf = compute_pareto(pareto_candidates, "Energy_pJ_MAC", "Throughput_GOPS", min_x=True, max_y=True)
    pareto_area_energy = compute_pareto(pareto_candidates, "Area_um2", "Energy_uJ", min_x=True, max_y=False)

    pareto_summary = {
        "Pareto_Area_vs_Performance": pareto_area_perf,
        "Pareto_Energy_vs_Performance": pareto_energy_perf,
        "Pareto_Area_vs_Energy": pareto_area_energy,
        "Heuristic_Mismatch_Count": heuristic_mismatch_count
    }
    pareto_json = "ai-accelerator-project/phase13/results/pareto_frontiers.json"
    with open(pareto_json, "w") as f:
        json.dump(pareto_summary, f, indent=2)
    print(f"[OUTPUT] Saved Pareto Frontiers to {pareto_json}")

    # Summary Statistics
    print("\n" + "=" * 90)
    print("  SUMMARY: ARRAY SCALING & CONTROLLER VALIDATION")
    print("=" * 90)
    for arr in ["4x4", "8x8", "16x16"]:
        arr_recs = [r for r in all_records if r["Array"] == arr]
        tot_ws_e = sum(r["WS_Energy_uJ"] for r in arr_recs)
        tot_os_e = sum(r["OS_Energy_uJ"] for r in arr_recs)
        tot_heur_e = sum(r["Heur_Energy_uJ"] for r in arr_recs)
        tot_opt_e = sum(r["Adapt_Energy_uJ"] for r in arr_recs)
        tot_macs = sum(r["Total_MACs"] for r in arr_recs)

        avg_gops = sum(r["Throughput_GOPS"] for r in arr_recs) / len(arr_recs)
        avg_area = sum(r["Adapt_Area_um2"] for r in arr_recs) / len(arr_recs)
        mismatches = heuristic_mismatch_count[arr]

        savings_vs_ws = ((tot_ws_e - tot_opt_e) / tot_ws_e) * 100.0
        savings_vs_os = ((tot_os_e - tot_opt_e) / tot_os_e) * 100.0
        savings_vs_heur = ((tot_heur_e - tot_opt_e) / tot_heur_e) * 100.0

        print(f"Array {arr:5s} | Avg Area: {avg_area:9.1f} um^2 | Avg Throughput: {avg_gops:6.1f} GOPS | Heuristic Errors: {mismatches:2d}/100")
        print(f"            Total Energy: {tot_opt_e:9.2f} uJ ({(tot_opt_e*1e6)/tot_macs:5.2f} pJ/MAC)")
        print(f"            >>> Savings vs Fixed WS: {savings_vs_ws:5.2f}% | vs Fixed OS: {savings_vs_os:5.2f}% | vs Heuristic: {savings_vs_heur:5.2f}%")
        print("-" * 90)

    print("\n[NOTE] All energy, throughput, and DRAM traffic values are architectural estimates.")
    print("       Zero financial cost incurred (zero-rupee budget execution).\n")


def compute_pareto(candidates: List[Dict[str, Any]], x_key: str, y_key: str, min_x: bool = True, max_y: bool = True) -> List[Dict[str, Any]]:
    """Identifies non-dominated Pareto-optimal points."""
    sorted_pts = sorted(candidates, key=lambda p: p[x_key], reverse=not min_x)
    pareto = []
    best_y = -float("inf") if max_y else float("inf")

    for pt in sorted_pts:
        y_val = pt[y_key]
        if max_y:
            if y_val > best_y:
                pareto.append(pt)
                best_y = y_val
        else:
            if y_val < best_y:
                pareto.append(pt)
                best_y = y_val
    return pareto


if __name__ == "__main__":
    run_full_space_exploration()
