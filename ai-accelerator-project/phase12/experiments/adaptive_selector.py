#!/usr/bin/env python3
"""
adaptive_selector.py - Adaptive Dataflow Selector & Cross-Workload Analysis.

Compares Weight-Stationary (WS) vs Output-Stationary (OS) across 5 AI workloads:
1. Small GEMM (M=4, K=16, N=4)
2. Large GEMM (M=64, K=64, N=64)
3. Batch Inference (M=32, K=16, N=16)
4. Convolution (M=16, K=36, N=16)
5. Transformer Attention (M=4, K=64, N=4)

Evaluates:
- MAC Utilization (%)
- Memory Traffic (DRAM Words / Bytes)
- Total Energy (uJ)
- Energy per MAC (pJ)
- Automated Selection Decision & Gains
"""

from __future__ import annotations
import os
import csv
import sys
try:
    import pandas as pd
    import matplotlib.pyplot as plt
    HAS_PLOT_DEPS = True
except ImportError:
    HAS_PLOT_DEPS = False
    pd = None
    plt = None
from ws_benchmark import WeightStationarySimulator
from os_benchmark import OutputStationarySimulator

def evaluate_all():
    ws_sim = WeightStationarySimulator()
    os_sim = OutputStationarySimulator()

    workloads = [
        ("Small GEMM", 4, 16, 4, "Reduce pipeline overhead"),
        ("Large Batch Inference", 64, 4, 64, "Maximize weight reuse across long batch"),
        ("Batch Inference", 32, 4, 16, "Reuse stationary weights (T_K=1)"),
        ("Convolution (im2col)", 16, 36, 16, "Reuse activations & filter channels"),
        ("Transformer Attention", 4, 64, 4, "Deep reduction / Eliminate psum spill")
    ]

    results = []

    print("\n" + "="*80)
    print("  PHASE 12: ADAPTIVE DATAFLOW BENCHMARK (WS vs OS)")
    print("="*80)

    for name, M, K, N, objective in workloads:
        res_ws = ws_sim.run_workload(name, M, K, N)
        res_os = os_sim.run_workload(name, M, K, N)

        # Dynamic Adaptive Selection Rule:
        # If K <= 4 or M >= 2*K: Weight reuse dominates with zero/minimal psum spills -> Select WS
        # If K > 4 and K >= M: Deep reduction makes psum traffic prohibitive -> Select OS
        if K <= 4 or (M >= 2 * K):
            decision = "Weight-Stationary (WS)"
            chosen = res_ws
            alternative = res_os
        else:
            decision = "Output-Stationary (OS)"
            chosen = res_os
            alternative = res_ws

        energy_savings_pct = ((alternative["total_energy_uJ"] - chosen["total_energy_uJ"]) / alternative["total_energy_uJ"]) * 100.0
        util_gain_pct = chosen["mac_utilization_%"] - alternative["mac_utilization_%"]
        traffic_reduction_pct = ((alternative["total_dram_words"] - chosen["total_dram_words"]) / alternative["total_dram_words"]) * 100.0

        print(f"\nWorkload: {name} (M={M}, K={K}, N={N}) - Objective: {objective}")
        print(f"  [WS] Util: {res_ws['mac_utilization_%']:5.1f}% | DRAM Words: {res_ws['total_dram_words']:6d} | Energy: {res_ws['total_energy_uJ']:8.4f} uJ | {res_ws['energy_per_mac_pJ']:5.2f} pJ/MAC")
        print(f"  [OS] Util: {res_os['mac_utilization_%']:5.1f}% | DRAM Words: {res_os['total_dram_words']:6d} | Energy: {res_os['total_energy_uJ']:8.4f} uJ | {res_os['energy_per_mac_pJ']:5.2f} pJ/MAC")
        print(f"  >>> ADAPTIVE DECISION: {decision}")
        print(f"      Traffic Reduction: {traffic_reduction_pct:+.1f}% | Energy Savings: {energy_savings_pct:+.1f}% | Util Delta: {util_gain_pct:+.1f}%")

        results.append({
            "Workload": name,
            "M": M, "K": K, "N": N,
            "Total_MACs": res_ws["total_mac_ops"],
            "WS_Cycles": res_ws["total_cycles"],
            "OS_Cycles": res_os["total_cycles"],
            "WS_Util_%": res_ws["mac_utilization_%"],
            "OS_Util_%": res_os["mac_utilization_%"],
            "WS_DRAM_Words": res_ws["total_dram_words"],
            "OS_DRAM_Words": res_os["total_dram_words"],
            "WS_Energy_uJ": res_ws["total_energy_uJ"],
            "OS_Energy_uJ": res_os["total_energy_uJ"],
            "Adaptive_Choice": "OS" if "Output" in decision else "WS",
            "Adaptive_Util_%": chosen["mac_utilization_%"],
            "Adaptive_Energy_uJ": chosen["total_energy_uJ"],
            "Energy_Savings_%": round(energy_savings_pct, 2),
            "Traffic_Reduction_%": round(traffic_reduction_pct, 2)
        })

    out_csv = "ai-accelerator-project/phase12/results/dataflow_comparison.csv"
    os.makedirs(os.path.dirname(out_csv), exist_ok=True)
    with open(out_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)
    print(f"\nSaved benchmark results to: {out_csv}")
    return results

def plot_comparison(df):
    if not HAS_PLOT_DEPS:
        print("[INFO] pandas/matplotlib not installed. Use generate_svg_chart.py for standalone SVG plotting.")
        return
    plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
    fig, axes = plt.subplots(2, 2, figsize=(14, 10))

    workloads = df["Workload"]
    x = range(len(workloads))
    width = 0.35

    # 1. MAC Utilization
    ax1 = axes[0, 0]
    ax1.bar([i - width/2 for i in x], df["WS_Util_%"], width, label="Weight-Stationary (WS)", color="#1f77b4", alpha=0.9)
    ax1.bar([i + width/2 for i in x], df["OS_Util_%"], width, label="Output-Stationary (OS)", color="#ff7f0e", alpha=0.9)
    ax1.set_ylabel("MAC Utilization (%)", fontsize=11, fontweight='bold')
    ax1.set_title("MAC Utilization: WS vs OS Across Workloads", fontsize=12, fontweight='bold')
    ax1.set_xticks(x)
    ax1.set_xticklabels(workloads, rotation=15, ha='right')
    ax1.legend(loc="upper left")
    ax1.set_ylim(0, 100)

    # 2. Total Energy (log scale)
    ax2 = axes[0, 1]
    ax2.bar([i - width/2 for i in x], df["WS_Energy_uJ"], width, label="WS Energy", color="#1f77b4", alpha=0.9)
    ax2.bar([i + width/2 for i in x], df["OS_Energy_uJ"], width, label="OS Energy", color="#ff7f0e", alpha=0.9)
    ax2.set_ylabel("Total Energy (uJ)", fontsize=11, fontweight='bold')
    ax2.set_yscale("log")
    ax2.set_title("Energy Consumption (uJ, Log Scale)", fontsize=12, fontweight='bold')
    ax2.set_xticks(x)
    ax2.set_xticklabels(workloads, rotation=15, ha='right')
    ax2.legend()

    # 3. Memory Traffic (Words)
    ax3 = axes[1, 0]
    ax3.bar([i - width/2 for i in x], df["WS_DRAM_Words"], width, label="WS DRAM Words", color="#1f77b4", alpha=0.9)
    ax3.bar([i + width/2 for i in x], df["OS_DRAM_Words"], width, label="OS DRAM Words", color="#ff7f0e", alpha=0.9)
    ax3.set_ylabel("Total DRAM Words (16-bit)", fontsize=11, fontweight='bold')
    ax3.set_yscale("log")
    ax3.set_title("DRAM Memory Traffic (Words, Log Scale)", fontsize=12, fontweight='bold')
    ax3.set_xticks(x)
    ax3.set_xticklabels(workloads, rotation=15, ha='right')
    ax3.legend()

    # 4. Adaptive Optimization Advantage (% Energy Saved by Adaptive Choice)
    ax4 = axes[1, 1]
    colors = ['#2ca02c' if s >= 0 else '#d62728' for s in df["Energy_Savings_%"]]
    bars = ax4.bar(x, df["Energy_Savings_%"], width=0.5, color=colors, alpha=0.9)
    ax4.set_ylabel("Energy Savings vs Fixed Baseline (%)", fontsize=11, fontweight='bold')
    ax4.set_title("Adaptive Advantage: Energy Savings by Switching Dataflow", fontsize=12, fontweight='bold')
    ax4.set_xticks(x)
    ax4.set_xticklabels(workloads, rotation=15, ha='right')
    ax4.axhline(0, color='black', linewidth=0.8, linestyle='--')

    for bar, choice in zip(bars, df["Adaptive_Choice"]):
        yval = bar.get_height()
        ax4.text(bar.get_x() + bar.get_width()/2.0, yval + (1.5 if yval >= 0 else -4.0),
                 f"Select {choice}\n({yval:+.1f}%)", ha='center', va='bottom' if yval >= 0 else 'top',
                 fontsize=9, fontweight='bold')

    plt.tight_layout()
    out_png = "ai-accelerator-project/phase12/results/dataflow_comparison.png"
    plt.savefig(out_png, dpi=300)
    print(f"Saved visualization plot to: {out_png}")

if __name__ == "__main__":
    evaluate_all()
