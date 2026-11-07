#!/usr/bin/env python3
"""
generate_multisize_pareto_chart.py - Generates 4-Panel Publication SVG for Phase 13.
"""

import json
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

def generate_chart():
    csv_file = "ai-accelerator-project/phase13/results/multisize_architecture_exploration.csv"
    json_file = "ai-accelerator-project/phase13/results/pareto_frontiers.json"
    df = pd.read_csv(csv_file)
    with open(json_file) as f:
        pareto_data = json.load(f)

    fig, axes = plt.subplots(2, 2, figsize=(15, 12))
    plt.subplots_adjust(hspace=0.32, wspace=0.28)

    colors = {"4x4": "#3498db", "8x8": "#2ecc71", "16x16": "#e74c3c"}
    markers = {"4x4": "o", "8x8": "s", "16x16": "^"}

    # -------------------------------------------------------------
    # Panel 1: Area vs Performance (Throughput GOPS) + Pareto Frontier
    # -------------------------------------------------------------
    ax1 = axes[0, 0]
    for arr in ["4x4", "8x8", "16x16"]:
        sub = df[df["Array"] == arr]
        ax1.scatter(sub["Adapt_Area_um2"] / 1000.0, sub["Throughput_GOPS"],
                    color=colors[arr], marker=markers[arr], alpha=0.45, s=35, label=f"{arr} Design Points")

    # Overlay Pareto curve
    p_pts = pareto_data["Pareto_Area_vs_Performance"]
    p_pts_sorted = sorted(p_pts, key=lambda x: x["Area_um2"])
    px = [p["Area_um2"] / 1000.0 for p in p_pts_sorted]
    py = [p["Throughput_GOPS"] for p in p_pts_sorted]
    ax1.plot(px, py, color="#8e44ad", linewidth=2.5, linestyle="--", label="Pareto Frontier (Optimal)", zorder=6)

    ax1.set_xlabel("Silicon Area (kµm², Logic + SRAM)", fontsize=11, fontweight="bold")
    ax1.set_ylabel("Throughput (GOPS @ 500 MHz)", fontsize=11, fontweight="bold")
    ax1.set_title("(A) Area vs. Performance Pareto Frontier", fontsize=12, fontweight="bold")
    ax1.grid(True, linestyle="--", alpha=0.4)
    ax1.legend(frameon=True, facecolor="white", edgecolor="none", fontsize=9)

    # -------------------------------------------------------------
    # Panel 2: Energy per MAC vs Performance (Throughput GOPS)
    # -------------------------------------------------------------
    ax2 = axes[0, 1]
    for arr in ["4x4", "8x8", "16x16"]:
        sub = df[df["Array"] == arr]
        ax2.scatter(sub["Throughput_GOPS"], sub["Adapt_pJ_per_MAC"],
                    color=colors[arr], marker=markers[arr], alpha=0.5, s=35, label=f"{arr} Array")

    ax2.set_xlabel("Throughput (GOPS @ 500 MHz)", fontsize=11, fontweight="bold")
    ax2.set_ylabel("Energy per MAC (pJ/MAC, Architectural Est.)", fontsize=11, fontweight="bold")
    ax2.set_title("(B) Energy Efficiency vs. Throughput Tradeoff", fontsize=12, fontweight="bold")
    ax2.grid(True, linestyle="--", alpha=0.4)
    ax2.legend(frameon=True, facecolor="white", edgecolor="none", fontsize=9)

    # -------------------------------------------------------------
    # Panel 3: Silicon Area vs Total Workload Energy (Tradeoff)
    # -------------------------------------------------------------
    ax3 = axes[1, 0]
    for arr in ["4x4", "8x8", "16x16"]:
        sub = df[df["Array"] == arr]
        ax3.scatter(sub["Adapt_Area_um2"] / 1000.0, sub["Adapt_Energy_uJ"],
                    color=colors[arr], marker=markers[arr], alpha=0.5, s=35, label=f"{arr} Array")

    # Mark 8x8 sweet spot
    avg_area_8x8 = df[df["Array"] == "8x8"]["Adapt_Area_um2"].mean() / 1000.0
    tot_energy_8x8 = df[df["Array"] == "8x8"]["Adapt_Energy_uJ"].sum() / len(df[df["Array"] == "8x8"])
    ax3.plot(avg_area_8x8, tot_energy_8x8, marker="*", markersize=15, color="#f39c12", label="8x8 Mean Operating Point", zorder=8)

    ax3.set_xlabel("Silicon Area (kµm²)", fontsize=11, fontweight="bold")
    ax3.set_ylabel("Workload Energy (µJ, Architectural Est.)", fontsize=11, fontweight="bold")
    ax3.set_title("(C) Area vs. Energy Tradeoff (8x8 Sweet Spot)", fontsize=12, fontweight="bold")
    ax3.grid(True, linestyle="--", alpha=0.4)
    ax3.legend(frameon=True, facecolor="white", edgecolor="none", fontsize=9)

    # -------------------------------------------------------------
    # Panel 4: Heuristic Mismatches & Energy Savings by Array
    # -------------------------------------------------------------
    ax4 = axes[1, 1]
    arrays = ["4x4", "8x8", "16x16"]
    x = np.arange(len(arrays))
    width = 0.35

    mismatches = [pareto_data["Heuristic_Mismatch_Count"][a] for a in arrays]
    savings_heur = []
    for a in arrays:
        sub = df[df["Array"] == a]
        s = ((sub["Heur_Energy_uJ"].sum() - sub["Adapt_Energy_uJ"].sum()) / sub["Heur_Energy_uJ"].sum()) * 100.0
        savings_heur.append(s)

    ax4_twin = ax4.twinx()
    b1 = ax4.bar(x - width/2, mismatches, width, color="#e67e22", alpha=0.85, label="Heuristic Mismatches (Errors)")
    b2 = ax4_twin.bar(x + width/2, savings_heur, width, color="#27ae60", alpha=0.85, label="Energy Savings vs Heuristic (%)")

    ax4.set_xticks(x)
    ax4.set_xticklabels(["4x4\n(16 PEs)", "8x8\n(64 PEs)", "16x16\n(256 PEs)"], fontsize=10, fontweight="bold")
    ax4.set_ylabel("Number of Workloads Mispredicted (out of 100)", fontsize=10, fontweight="bold", color="#e67e22")
    ax4_twin.set_ylabel("Energy Savings vs Heuristic (%)", fontsize=10, fontweight="bold", color="#27ae60")
    ax4.set_title("(D) Adaptive Controller Validation vs Phase 12 Heuristic", fontsize=12, fontweight="bold")
    ax4.grid(True, linestyle="--", alpha=0.4)

    # Add legend
    lines1, labels1 = ax4.get_legend_handles_labels()
    lines2, labels2 = ax4_twin.get_legend_handles_labels()
    ax4.legend(lines1 + lines2, labels1 + labels2, loc="upper right", frameon=True, facecolor="white", edgecolor="none", fontsize=9)

    out_svg = "ai-accelerator-project/phase13/results/multisize_pareto_frontiers.svg"
    plt.savefig(out_svg, format="svg", bbox_inches="tight")
    plt.close()
    print(f"[OUTPUT] Generated publication SVG chart at: {out_svg}")

if __name__ == "__main__":
    generate_chart()
