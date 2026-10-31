#!/usr/bin/env python3
"""
generate_phase20_plots.py - Visualization of Phase 20 Interconnect-Aware Optimization
Compares Global Control Broadcast (Phase 19) vs Localized Control Architecture (Phase 20)
"""

import matplotlib.pyplot as plt
import numpy as np
import os

artifact_dir = "/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406"
os.makedirs(artifact_dir, exist_ok=True)
os.makedirs("ai-accelerator-project/phase20/sta_reports", exist_ok=True)

plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, axs = plt.subplots(2, 2, figsize=(14, 10))
fig.suptitle("Phase 20: Interconnect-Aware Timing Optimization & Localized Control", fontsize=16, fontweight='bold', y=0.98)

# 1. Setup Slack Comparison (WNS at 500 MHz / 2.0 ns)
ax1 = axs[0, 0]
categories = ["Phase 19\n(Global Broadcast)", "Phase 20\n(Localized Mode)", "Phase 20\n(Live Datapath)", "Target\n(500 MHz)"]
wns_vals = [-227.9, -25.1, +118.8, 0.0]
colors = ['#d62728', '#ff7f0e', '#2ca02c', 'black']

bars1 = ax1.bar(categories, wns_vals, color=colors, width=0.55, edgecolor='black', linewidth=1.2)
ax1.axhline(0.0, color='black', linestyle='-', linewidth=1.2)
ax1.set_ylabel("Worst Setup Slack (ps)", fontsize=11, fontweight='bold')
ax1.set_title("Worst Setup Slack Recovery at 500 MHz", fontsize=12, fontweight='bold')
ax1.set_ylim(-260, 150)
for bar in bars1:
    y = bar.get_height()
    offset = 6 if y >= 0 else -18
    ax1.text(bar.get_x() + bar.get_width()/2.0, y + offset, f"{y:+.1f} ps", ha='center', va='bottom', fontsize=10, fontweight='bold')

# 2. Maximum Achievable Frequency (Fmax)
ax2 = axs[0, 1]
fmax_vals = [448.85, 493.80, 531.40, 500.00]
bars2 = ax2.bar(categories, fmax_vals, color=['#d62728', '#ff7f0e', '#2ca02c', '#1f77b4'], width=0.55, edgecolor='black', linewidth=1.2)
ax2.axhline(500.0, color='red', linestyle='--', linewidth=2, label='Target (500 MHz)')
ax2.set_ylabel("Clock Frequency (MHz)", fontsize=11, fontweight='bold')
ax2.set_title("Estimated Operating Frequency Across Optimizations", fontsize=12, fontweight='bold')
ax2.set_ylim(420, 560)
for bar in bars2:
    y = bar.get_height()
    ax2.text(bar.get_x() + bar.get_width()/2.0, y + 4, f"{y:.1f} MHz", ha='center', va='bottom', fontsize=10, fontweight='bold')
ax2.legend(loc='lower left', frameon=True)

# 3. Total Negative Slack (TNS) Reduction
ax3 = axs[1, 0]
tns_vals = [-44.25, -0.76, 0.00]
tns_cats = ["Phase 19\n(Global Broadcast)", "Phase 20\n(Localized Control)", "Phase 20\n(Live Datapath)"]
bars3 = ax3.bar(tns_cats, tns_vals, color=['#d62728', '#ff7f0e', '#2ca02c'], width=0.5, edgecolor='black', linewidth=1.2)
ax3.axhline(0.0, color='black', linestyle='-', linewidth=1.2)
ax3.set_ylabel("Total Negative Slack (ns)", fontsize=11, fontweight='bold')
ax3.set_title("Total Negative Slack (TNS) - 98.3% Elimination", fontsize=12, fontweight='bold')
ax3.set_ylim(-50, 8)
for bar in bars3:
    y = bar.get_height()
    offset = 2 if y >= 0 else -5
    ax3.text(bar.get_x() + bar.get_width()/2.0, y + offset, f"{y:.2f} ns", ha='center', va='bottom', fontsize=10, fontweight='bold')

# 4. Timing Recovery Waterfall Breakdown
ax4 = axs[1, 1]
breakdown_labels = ["Phase 19\nSlack", "Outer MUX\nRemoval", "Local Reg\nDecoupling", "Adder Control\nRestructure", "Phase 20\nSlack"]
waterfall_steps = [-227.9, +57.6, +84.5, +60.7, -25.1]
step_colors = ['#d62728', '#1f77b4', '#1f77b4', '#1f77b4', '#2ca02c']
bars4 = ax4.bar(breakdown_labels, waterfall_steps, color=step_colors, width=0.55, edgecolor='black', linewidth=1.2)
ax4.axhline(0.0, color='black', linestyle='-', linewidth=1.2)
ax4.set_ylabel("Slack Delta / Level (ps)", fontsize=11, fontweight='bold')
ax4.set_title("Interconnect Timing Recovery Breakdown (+202.8 ps)", fontsize=12, fontweight='bold')
ax4.set_ylim(-260, 100)
for bar in bars4:
    y = bar.get_height()
    offset = 4 if y >= 0 else -16
    ax4.text(bar.get_x() + bar.get_width()/2.0, y + offset, f"{y:+.1f} ps", ha='center', va='bottom', fontsize=9, fontweight='bold')

plt.tight_layout()

out1 = "ai-accelerator-project/phase20/sta_reports/phase20_interconnect_optimization_results.png"
out2 = os.path.join(artifact_dir, "phase20_interconnect_optimization_results.png")
plt.savefig(out1, dpi=300)
plt.savefig(out2, dpi=300)
print(f"[SUCCESS] Saved plots to:\n  - {out1}\n  - {out2}")
