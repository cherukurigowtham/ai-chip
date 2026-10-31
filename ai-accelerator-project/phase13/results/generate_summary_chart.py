#!/usr/bin/env python3
"""
generate_summary_chart.py - Generates Publication-Quality SVG Visualization for Phase 13.
"""

import os
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

def generate_svg():
    csv_path = "ai-accelerator-project/phase13/results/optimizer_comparison.csv"
    assert os.path.exists(csv_path), f"CSV not found: {csv_path}"
    df = pd.read_csv(csv_path)

    fig, axes = plt.subplots(2, 2, figsize=(15, 11))
    plt.subplots_adjust(hspace=0.32, wspace=0.25)

    categories = [
        "Small Edge", "Batched Inference", "Deep Reduction / Attention",
        "Convolution im2col", "Large / Square Layers"
    ]
    colors = {
        "WS": "#e74c3c",      # Red
        "OS": "#3498db",      # Blue
        "Heur": "#f39c12",    # Orange
        "Opt": "#2ecc71"      # Green
    }

    # ---------------------------------------------------------
    # Panel 1: Energy per Category (Log Scale uJ)
    # ---------------------------------------------------------
    ax1 = axes[0, 0]
    cat_summary = df.groupby("Category")[["WS_Energy_uJ", "OS_Energy_uJ", "Heur_Energy_uJ", "Opt_Energy_uJ"]].sum().reindex(categories)

    x = np.arange(len(categories))
    width = 0.2

    ax1.bar(x - 1.5*width, cat_summary["WS_Energy_uJ"], width, label="Fixed WS", color=colors["WS"], alpha=0.9)
    ax1.bar(x - 0.5*width, cat_summary["OS_Energy_uJ"], width, label="Fixed OS", color=colors["OS"], alpha=0.9)
    ax1.bar(x + 0.5*width, cat_summary["Heur_Energy_uJ"], width, label="Phase 12 Heuristic", color=colors["Heur"], alpha=0.9)
    ax1.bar(x + 1.5*width, cat_summary["Opt_Energy_uJ"], width, label="Phase 13 Optimizer", color=colors["Opt"], alpha=0.9)

    ax1.set_yscale("log")
    ax1.set_xticks(x)
    ax1.set_xticklabels(["Small\nEdge", "Batched\nInference", "Deep Reduction\n(Attention)", "Convolution\n(im2col)", "Large / Square\nLayers"], fontsize=9)
    ax1.set_ylabel("Total Energy (µJ, Log Scale)", fontsize=11, fontweight="bold")
    ax1.set_title("(A) Energy Consumption by Workload Category", fontsize=12, fontweight="bold")
    ax1.grid(True, which="both", ls="--", alpha=0.4)
    ax1.legend(frameon=True, facecolor="white", edgecolor="none")

    # ---------------------------------------------------------
    # Panel 2: Energy per MAC (pJ/MAC)
    # ---------------------------------------------------------
    ax2 = axes[0, 1]
    mac_summary = df.groupby("Category").apply(
        lambda g: pd.Series({
            "WS_pJ": (g["WS_Energy_uJ"].sum() * 1e6) / g["Total_MACs"].sum(),
            "OS_pJ": (g["OS_Energy_uJ"].sum() * 1e6) / g["Total_MACs"].sum(),
            "Heur_pJ": (g["Heur_Energy_uJ"].sum() * 1e6) / g["Total_MACs"].sum(),
            "Opt_pJ": (g["Opt_Energy_uJ"].sum() * 1e6) / g["Total_MACs"].sum()
        })
    ).reindex(categories)

    ax2.bar(x - 1.5*width, mac_summary["WS_pJ"], width, label="Fixed WS", color=colors["WS"], alpha=0.9)
    ax2.bar(x - 0.5*width, mac_summary["OS_pJ"], width, label="Fixed OS", color=colors["OS"], alpha=0.9)
    ax2.bar(x + 0.5*width, mac_summary["Heur_pJ"], width, label="Heuristic", color=colors["Heur"], alpha=0.9)
    ax2.bar(x + 1.5*width, mac_summary["Opt_pJ"], width, label="Optimizer", color=colors["Opt"], alpha=0.9)

    ax2.set_xticks(x)
    ax2.set_xticklabels(["Small\nEdge", "Batched\nInference", "Deep Reduction\n(Attention)", "Convolution\n(im2col)", "Large / Square\nLayers"], fontsize=9)
    ax2.set_ylabel("Energy Efficiency (pJ / MAC)", fontsize=11, fontweight="bold")
    ax2.set_title("(B) Energy Efficiency Across Architectural Domains", fontsize=12, fontweight="bold")
    ax2.grid(True, ls="--", alpha=0.4)
    ax2.legend(frameon=True, facecolor="white", edgecolor="none")

    # ---------------------------------------------------------
    # Panel 3: Pareto Frontier: Silicon Area vs Energy
    # ---------------------------------------------------------
    ax3 = axes[1, 0]
    ax3.scatter(df["Opt_Area_um2"], df["Opt_Energy_uJ"], color=colors["Opt"], label="Optimizer Configs", alpha=0.7, s=40, edgecolors="none")
    ax3.axvline(200000.0, color="red", linestyle="--", linewidth=1.8, label="Silicon Budget (200,000 µm²)")

    ax3.set_yscale("log")
    ax3.set_xlabel("Silicon Area (µm²)", fontsize=11, fontweight="bold")
    ax3.set_ylabel("Workload Energy (µJ, Log Scale)", fontsize=11, fontweight="bold")
    ax3.set_title("(C) Area Constraint Adherence & Pareto Distribution", fontsize=12, fontweight="bold")
    ax3.grid(True, which="both", ls="--", alpha=0.4)
    ax3.legend(frameon=True, facecolor="white", edgecolor="none")

    # ---------------------------------------------------------
    # Panel 4: Histogram of Optimizer Energy Savings vs Heuristic
    # ---------------------------------------------------------
    ax4 = axes[1, 1]
    savings = df["Savings_vs_Heur_%"]
    bins = np.linspace(0, 80, 17)
    n, bins_out, patches = ax4.hist(savings, bins=bins, color="#27ae60", edgecolor="white", alpha=0.85)

    mean_savings = savings.mean()
    median_savings = savings.median()
    ax4.axvline(mean_savings, color="#c0392b", linestyle="-", linewidth=2.0, label=f"Mean Savings: {mean_savings:.1f}%")
    ax4.axvline(median_savings, color="#2980b9", linestyle="--", linewidth=2.0, label=f"Median Savings: {median_savings:.1f}%")

    ax4.set_xlabel("Energy Savings vs Phase 12 Heuristic (%)", fontsize=11, fontweight="bold")
    ax4.set_ylabel("Number of Workloads (out of 100)", fontsize=11, fontweight="bold")
    ax4.set_title("(D) Distribution of Energy Savings Across 100 Workloads", fontsize=12, fontweight="bold")
    ax4.grid(True, ls="--", alpha=0.4)
    ax4.legend(frameon=True, facecolor="white", edgecolor="none")

    out_svg = "ai-accelerator-project/phase13/results/architecture_search_summary.svg"
    plt.savefig(out_svg, format="svg", bbox_inches="tight")
    plt.close()
    print(f"Generated publication SVG chart: {out_svg}")

if __name__ == "__main__":
    generate_svg()
