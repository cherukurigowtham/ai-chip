#!/usr/bin/env python3
"""
run_100_workloads.py - Comprehensive 100-Workload AI Accelerator Benchmark.

Evaluates 100 diverse neural network GEMMs across 4 architectural strategies:
1. Fixed Weight-Stationary (WS)
2. Fixed Output-Stationary (OS)
3. Heuristic Adaptive (Phase 12 K/M rule)
4. Cost-Model Architecture Optimizer (Phase 13)

Outputs:
- ai-accelerator-project/phase13/results/optimizer_comparison.csv
- Detailed category and aggregate statistical reports.
"""

import os
import sys
import csv
from typing import List, Dict, Any

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../search_engine")))
from workload_generator import get_100_workloads
from optimizer import ArchitectureOptimizer, MAX_AREA_BUDGET_UM2

def run_benchmark():
    workloads = get_100_workloads()
    opt = ArchitectureOptimizer()

    results = []
    print("\n" + "="*85)
    print("  PHASE 13: 100-WORKLOAD ARCHITECTURE OPTIMIZER BENCHMARK")
    print("  Nangate 45nm @ 1.1V, 500 MHz | Area Budget: 200,000 um^2 (0.20 mm^2)")
    print("="*85)

    category_stats = {}

    for w in workloads:
        w_id = w["id"]
        cat = w["category"]
        name = w["name"]
        M, K, N = w["M"], w["K"], w["N"]
        total_macs = M * K * N

        res_ws = opt.evaluate_fixed_ws(M, K, N)
        res_os = opt.evaluate_fixed_os(M, K, N)
        res_heur = opt.evaluate_heuristic_adaptive(M, K, N)
        res_opt = opt.optimize(M, K, N)

        # Assert no area violations
        assert res_opt["area_um2"] <= MAX_AREA_BUDGET_UM2, f"Area constraint violated: {res_opt['area_um2']} > {MAX_AREA_BUDGET_UM2}"

        # Energy savings calculations
        savings_vs_ws = ((res_ws["total_energy_uj"] - res_opt["total_energy_uj"]) / res_ws["total_energy_uj"]) * 100.0
        savings_vs_os = ((res_os["total_energy_uj"] - res_opt["total_energy_uj"]) / res_os["total_energy_uj"]) * 100.0
        savings_vs_heur = ((res_heur["total_energy_uj"] - res_opt["total_energy_uj"]) / res_heur["total_energy_uj"]) * 100.0

        row = {
            "ID": w_id,
            "Category": cat,
            "Name": name,
            "M": M, "K": K, "N": N,
            "Total_MACs": total_macs,
            # Fixed WS
            "WS_Cycles": res_ws["total_cycles"],
            "WS_Util_%": res_ws["mac_util_%"],
            "WS_Energy_uJ": round(res_ws["total_energy_uj"], 5),
            "WS_pj_per_MAC": res_ws["energy_per_mac_pj"],
            # Fixed OS
            "OS_Cycles": res_os["total_cycles"],
            "OS_Util_%": res_os["mac_util_%"],
            "OS_Energy_uJ": round(res_os["total_energy_uj"], 5),
            "OS_pj_per_MAC": res_os["energy_per_mac_pj"],
            # Heuristic
            "Heur_Strategy": res_heur["strategy"],
            "Heur_Energy_uJ": round(res_heur["total_energy_uj"], 5),
            "Heur_pj_per_MAC": res_heur["energy_per_mac_pj"],
            # Optimizer
            "Opt_Dataflow": res_opt["dataflow"],
            "Opt_T_M": res_opt["T_M"],
            "Opt_T_K": res_opt["T_K"],
            "Opt_T_N": res_opt["T_N"],
            "Opt_DoubleBuffering": res_opt["double_buffering"],
            "Opt_Cycles": res_opt["total_cycles"],
            "Opt_Util_%": res_opt["mac_util_%"],
            "Opt_DRAM_Words": res_opt["total_dram_words"],
            "Opt_SRAM_Words": res_opt["total_sram_words"],
            "Opt_SRAM_Bytes": res_opt["sram_bytes"],
            "Opt_Area_um2": round(res_opt["area_um2"], 1),
            "Opt_Energy_uJ": round(res_opt["total_energy_uj"], 5),
            "Opt_pj_per_MAC": res_opt["energy_per_mac_pj"],
            # Savings
            "Savings_vs_WS_%": round(savings_vs_ws, 2),
            "Savings_vs_OS_%": round(savings_vs_os, 2),
            "Savings_vs_Heur_%": round(savings_vs_heur, 2)
        }
        results.append(row)

        if cat not in category_stats:
            category_stats[cat] = {
                "count": 0, "ws_energy": 0.0, "os_energy": 0.0,
                "heur_energy": 0.0, "opt_energy": 0.0, "macs": 0
            }
        category_stats[cat]["count"] += 1
        category_stats[cat]["ws_energy"] += res_ws["total_energy_uj"]
        category_stats[cat]["os_energy"] += res_os["total_energy_uj"]
        category_stats[cat]["heur_energy"] += res_heur["total_energy_uj"]
        category_stats[cat]["opt_energy"] += res_opt["total_energy_uj"]
        category_stats[cat]["macs"] += total_macs

    out_csv = "ai-accelerator-project/phase13/results/optimizer_comparison.csv"
    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    with open(out_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)

    print(f"\n[OK] Successfully executed all 100 workloads!")
    print(f"Results written to: {out_csv}")

    # Summary table
    print("\n" + "="*85)
    print("  PER-CATEGORY ENERGY AND EFFICIENCY BREAKDOWN")
    print("="*85)
    print(f"{'Category':<28} | {'Fixed WS':<10} | {'Fixed OS':<10} | {'Heuristic':<10} | {'Optimizer':<10} | {'Opt Savings':<12}")
    print(f"{'':<28} | {'(uJ)':<10} | {'(uJ)':<10} | {'(uJ)':<10} | {'(uJ)':<10} | {'vs Heur (%)':<12}")
    print("-"*85)

    tot_ws = sum(c["ws_energy"] for c in category_stats.values())
    tot_os = sum(c["os_energy"] for c in category_stats.values())
    tot_heur = sum(c["heur_energy"] for c in category_stats.values())
    tot_opt = sum(c["opt_energy"] for c in category_stats.values())
    tot_macs = sum(c["macs"] for c in category_stats.values())

    for cat, stats in category_stats.items():
        cat_savings = ((stats["heur_energy"] - stats["opt_energy"]) / stats["heur_energy"]) * 100.0
        print(f"{cat:<28} | {stats['ws_energy']:10.3f} | {stats['os_energy']:10.3f} | {stats['heur_energy']:10.3f} | {stats['opt_energy']:10.3f} | {cat_savings:10.2f}%")

    print("-"*85)
    tot_savings_vs_heur = ((tot_heur - tot_opt) / tot_heur) * 100.0
    tot_savings_vs_ws = ((tot_ws - tot_opt) / tot_ws) * 100.0
    tot_savings_vs_os = ((tot_os - tot_opt) / tot_os) * 100.0

    print(f"{'TOTAL (100 Workloads)':<28} | {tot_ws:10.3f} | {tot_os:10.3f} | {tot_heur:10.3f} | {tot_opt:10.3f} | {tot_savings_vs_heur:10.2f}%")
    print("="*85)

    print("\nAggregate Efficiency Comparison:")
    print(f"  Fixed WS Total Energy:         {tot_ws:12.3f} uJ ({(tot_ws*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Fixed OS Total Energy:         {tot_os:12.3f} uJ ({(tot_os*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 12 Heuristic Energy:     {tot_heur:12.3f} uJ ({(tot_heur*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 13 Optimizer Energy:     {tot_opt:12.3f} uJ ({(tot_opt*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  >>> Optimizer Savings vs WS:   {tot_savings_vs_ws:6.2f}%")
    print(f"  >>> Optimizer Savings vs OS:   {tot_savings_vs_os:6.2f}%")
    print(f"  >>> Optimizer Savings vs Heur: {tot_savings_vs_heur:6.2f}%")

    # Dataflow choices distribution
    ws_count = sum(1 for r in results if r["Opt_Dataflow"] == "WS")
    os_count = sum(1 for r in results if r["Opt_Dataflow"] == "OS")
    db_count = sum(1 for r in results if r["Opt_DoubleBuffering"])
    sb_count = sum(1 for r in results if not r["Opt_DoubleBuffering"])

    print(f"\nOptimizer Architectural Selections:")
    print(f"  Dataflow:         WS: {ws_count}/100 ({ws_count}%), OS: {os_count}/100 ({os_count}%)")
    print(f"  Buffering Scheme: Double: {db_count}/100 ({db_count}%), Single: {sb_count}/100 ({sb_count}%)")

    # Area distribution
    max_area = max(r["Opt_Area_um2"] for r in results)
    min_area = min(r["Opt_Area_um2"] for r in results)
    avg_area = sum(r["Opt_Area_um2"] for r in results) / len(results)
    print(f"  Silicon Area:     Min: {min_area:.1f} um^2 | Avg: {avg_area:.1f} um^2 | Max: {max_area:.1f} um^2 (Budget: {MAX_AREA_BUDGET_UM2:.0f} um^2)")
    print("="*85 + "\n")

    return results

if __name__ == "__main__":
    run_benchmark()
