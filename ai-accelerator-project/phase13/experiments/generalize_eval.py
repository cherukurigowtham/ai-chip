#!/usr/bin/env python3
"""
generalize_eval.py - Generalization Evaluation on 25 Unseen Held-Out Workloads.

Tests whether the Phase 13 Hardware-Aware Cost-Model Optimizer generalizes
to completely unseen GEMM shapes without overfitting or manual tuning.
"""

import os
import sys
import csv

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../search_engine")))
from workload_generator import get_heldout_25_workloads
from optimizer import ArchitectureOptimizer, MAX_AREA_BUDGET_UM2

def run_generalization_test():
    heldout = get_heldout_25_workloads()
    opt = ArchitectureOptimizer()

    print("\n" + "="*85)
    print("  PHASE 13: GENERALIZATION VALIDATION ON 25 UNSEEN WORKLOADS")
    print("="*85)

    tot_ws = 0.0
    tot_os = 0.0
    tot_heur = 0.0
    tot_opt = 0.0
    tot_macs = 0

    results = []

    for w in heldout:
        M, K, N = w["M"], w["K"], w["N"]
        total_macs = M * K * N
        tot_macs += total_macs

        res_ws = opt.evaluate_fixed_ws(M, K, N)
        res_os = opt.evaluate_fixed_os(M, K, N)
        res_heur = opt.evaluate_heuristic_adaptive(M, K, N)
        res_opt = opt.optimize(M, K, N)

        assert res_opt["area_um2"] <= MAX_AREA_BUDGET_UM2

        tot_ws += res_ws["total_energy_uj"]
        tot_os += res_os["total_energy_uj"]
        tot_heur += res_heur["total_energy_uj"]
        tot_opt += res_opt["total_energy_uj"]

        savings = ((res_heur["total_energy_uj"] - res_opt["total_energy_uj"]) / res_heur["total_energy_uj"]) * 100.0
        results.append({
            "Name": w["name"], "M": M, "K": K, "N": N, "Desc": w["description"],
            "Heur_Energy_uJ": res_heur["total_energy_uj"],
            "Opt_Energy_uJ": res_opt["total_energy_uj"],
            "Opt_Dataflow": res_opt["dataflow"],
            "Tile": f"({res_opt['T_M']},{res_opt['T_K']},{res_opt['T_N']})",
            "Savings_%": savings
        })

    tot_savings_vs_heur = ((tot_heur - tot_opt) / tot_heur) * 100.0
    tot_savings_vs_ws = ((tot_ws - tot_opt) / tot_ws) * 100.0
    tot_savings_vs_os = ((tot_os - tot_opt) / tot_os) * 100.0

    print(f"{'Workload':<20} | {'M,K,N':<12} | {'Heur (uJ)':<10} | {'Opt (uJ)':<10} | {'Choice':<15} | {'Savings (%)':<10}")
    print("-"*85)
    for r in results:
        mkn = f"{r['M']},{r['K']},{r['N']}"
        choice = f"{r['Opt_Dataflow']} {r['Tile']}"
        print(f"{r['Name']:<20} | {mkn:<12} | {r['Heur_Energy_uJ']:10.4f} | {r['Opt_Energy_uJ']:10.4f} | {choice:<15} | {r['Savings_%']:9.2f}%")

    print("="*85)
    print("Generalization Summary (25 Held-Out Workloads):")
    print(f"  Fixed WS Total Energy:         {tot_ws:10.3f} uJ ({(tot_ws*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Fixed OS Total Energy:         {tot_os:10.3f} uJ ({(tot_os*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 12 Heuristic Energy:     {tot_heur:10.3f} uJ ({(tot_heur*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 13 Optimizer Energy:     {tot_opt:10.3f} uJ ({(tot_opt*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  >>> Optimizer Savings vs WS:   {tot_savings_vs_ws:6.2f}%")
    print(f"  >>> Optimizer Savings vs OS:   {tot_savings_vs_os:6.2f}%")
    print(f"  >>> Optimizer Savings vs Heur: {tot_savings_vs_heur:6.2f}%")
    print("="*85 + "\n")

if __name__ == "__main__":
    run_generalization_test()
