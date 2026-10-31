#!/usr/bin/env python3
"""
generalize_calib.py - Held-Out Generalization Evaluation under Silicon Calibration.
"""

import os
import sys

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../calibration")))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../phase13/search_engine")))

from workload_generator import get_heldout_25_workloads
from calibrated_optimizer import CalibratedOptimizer
from calibrated_cost_model import MAX_AREA_BUDGET_UM2

def run_heldout_calib():
    heldout = get_heldout_25_workloads()
    opt = CalibratedOptimizer()

    print("\n" + "="*85)
    print("  PHASE 14: GENERALIZATION EVALUATION (25 HELD-OUT WORKLOADS)")
    print("  Silicon-Calibrated Nangate 45nm @ 1.10V, 500 MHz (A <= 200,000 um^2)")
    print("="*85)

    tot_ws = 0.0
    tot_os = 0.0
    tot_heur = 0.0
    tot_calib = 0.0
    tot_macs = 0

    results = []
    for w in heldout:
        M, K, N = w["M"], w["K"], w["N"]
        total_macs = M * K * N
        tot_macs += total_macs

        res_ws = opt.evaluate_fixed_ws(M, K, N)
        res_os = opt.evaluate_fixed_os(M, K, N)
        res_heur = opt.evaluate_heuristic_adaptive(M, K, N)
        res_calib = opt.optimize(M, K, N)

        assert res_calib["area_um2"] <= MAX_AREA_BUDGET_UM2

        tot_ws += res_ws["total_energy_uj"]
        tot_os += res_os["total_energy_uj"]
        tot_heur += res_heur["total_energy_uj"]
        tot_calib += res_calib["total_energy_uj"]

        savings = ((res_heur["total_energy_uj"] - res_calib["total_energy_uj"]) / res_heur["total_energy_uj"]) * 100.0
        results.append({
            "Name": w["name"], "M": M, "K": K, "N": N,
            "Heur_uJ": res_heur["total_energy_uj"],
            "Calib_uJ": res_calib["total_energy_uj"],
            "Mode": res_calib["dataflow"],
            "Tile": f"({res_calib['T_M']},{res_calib['T_K']},{res_calib['T_N']})",
            "Area_um2": res_calib["area_um2"],
            "Savings_%": savings
        })

    tot_savings_vs_heur = ((tot_heur - tot_calib) / tot_heur) * 100.0
    tot_savings_vs_ws = ((tot_ws - tot_calib) / tot_ws) * 100.0
    tot_savings_vs_os = ((tot_os - tot_calib) / tot_os) * 100.0

    print(f"{'Workload':<18} | {'M,K,N':<12} | {'Heur (uJ)':<10} | {'Calib (uJ)':<10} | {'Choice':<15} | {'Area (um^2)':<11} | {'Savings':<9}")
    print("-"*85)
    for r in results:
        mkn = f"{r['M']},{r['K']},{r['N']}"
        choice = f"{r['Mode']} {r['Tile']}"
        print(f"{r['Name']:<18} | {mkn:<12} | {r['Heur_uJ']:10.4f} | {r['Calib_uJ']:10.4f} | {choice:<15} | {r['Area_um2']:11.1f} | {r['Savings_%']:8.2f}%")

    print("="*85)
    print("Held-Out Generalization Summary (25 Unseen Workloads):")
    print(f"  Fixed WS Total Energy:         {tot_ws:10.3f} uJ ({(tot_ws*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Fixed OS Total Energy:         {tot_os:10.3f} uJ ({(tot_os*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 12 Heuristic Energy:     {tot_heur:10.3f} uJ ({(tot_heur*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  Phase 14 Calib Optimizer:      {tot_calib:10.3f} uJ ({(tot_calib*1e6)/tot_macs:6.2f} pJ/MAC)")
    print(f"  >>> Calibrated Savings vs WS:   {tot_savings_vs_ws:6.2f}%")
    print(f"  >>> Calibrated Savings vs OS:   {tot_savings_vs_os:6.2f}%")
    print(f"  >>> Calibrated Savings vs Heur: {tot_savings_vs_heur:6.2f}%")
    print("="*85 + "\n")

if __name__ == "__main__":
    run_heldout_calib()
