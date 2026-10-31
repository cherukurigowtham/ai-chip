#!/usr/bin/env python3
"""
Generate publication-quality validation plots for Phase 19:
Physical Implementation and Interconnect Parasitic Sensitivity Analysis
"""

import matplotlib.pyplot as plt
import numpy as np
import os

os.makedirs("ai-accelerator-project/phase19/sta_reports", exist_ok=True)
artifact_dir = "/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406"
os.makedirs(artifact_dir, exist_ok=True)

# Data Definition
# 1. Models Evaluated
models = ["Phase 18 Pre-Route\n(Ideal Interconnect)", 
          "Wire-Load 1K\n(Local Wiring)", 
          "Wire-Load 3K\n(Medium Wiring)", 
          "Wire-Load 5K\n(Standard 45nm)", 
          "Target Spec\n(500 MHz)"]

fmax_vals = [512.62, 448.85, 448.85, 448.85, 500.00]
wns_vals  = [+49.2, -227.9, -227.9, -227.9, 0.0]
tns_vals  = [0.0, -44.25, -44.25, -44.25, 0.0]

plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, axs = plt.subplots(2, 2, figsize=(14, 10))
fig.suptitle("Phase 19: Physical Interconnect Parasitic Sensitivity & Pre-Route Validation", fontsize=16, fontweight='bold', y=0.98)

# Subplot 1: Maximum Achievable Frequency (Fmax)
ax1 = axs[0, 0]
bars1 = ax1.bar(models[:4], fmax_vals[:4], color=['#2ca02c', '#1f77b4', '#ff7f0e', '#d62728'], width=0.55, edgecolor='black', linewidth=1.2)
ax1.axhline(500.0, color='red', linestyle='--', linewidth=2, label='Target (500 MHz)')
ax1.set_ylabel("Maximum Frequency (MHz)", fontsize=11, fontweight='bold')
ax1.set_title("Clock Frequency Across Interconnect Models", fontsize=12, fontweight='bold')
ax1.set_ylim(400, 550)
for bar in bars1:
    yval = bar.get_height()
    ax1.text(bar.get_x() + bar.get_width()/2.0, yval + 3, f"{yval:.1f} MHz", ha='center', va='bottom', fontsize=10, fontweight='bold')
ax1.legend(loc='lower left', frameon=True)

# Subplot 2: Worst Negative Slack (WNS) at 500 MHz (2.0 ns)
ax2 = axs[0, 1]
bars2 = ax2.bar(models[:4], wns_vals[:4], color=['#2ca02c', '#d62728', '#d62728', '#d62728'], width=0.55, edgecolor='black', linewidth=1.2)
ax2.axhline(0.0, color='black', linestyle='-', linewidth=1.5)
ax2.set_ylabel("Worst Setup Slack (ps)", fontsize=11, fontweight='bold')
ax2.set_title("Worst Setup Slack at 500 MHz Clock Target", fontsize=12, fontweight='bold')
ax2.set_ylim(-300, 100)
for bar in bars2:
    yval = bar.get_height()
    offset = 8 if yval >= 0 else -20
    ax2.text(bar.get_x() + bar.get_width()/2.0, yval + offset, f"{yval:+.1f} ps", ha='center', va='bottom', fontsize=10, fontweight='bold')

# Subplot 3: Critical Path Delay Breakdown (Logic vs Interconnect Wire-Load)
ax3 = axs[1, 0]
categories = ["Pre-Route Baseline\n(Ideal)", "Wire-Load 5K\n(Estimated Interconnect)"]
logic_delay = [1.869, 1.869]
interconnect_delay = [0.000, 0.277]

bars_logic = ax3.bar(categories, logic_delay, label='Cell Logic Delay', color='#1f77b4', width=0.45, edgecolor='black')
bars_wire = ax3.bar(categories, interconnect_delay, bottom=logic_delay, label='Interconnect RC Delay', color='#ff7f0e', width=0.45, edgecolor='black')
ax3.axhline(2.000 - 0.082, color='red', linestyle='--', linewidth=2, label='Max Arrival Budget (1.918 ns)')
ax3.set_ylabel("Delay (ns)", fontsize=11, fontweight='bold')
ax3.set_title("Critical Path Delay: Logic vs. Wire Parasitics", fontsize=12, fontweight='bold')
ax3.set_ylim(0, 2.5)
ax3.text(0, 1.869/2, "1.869 ns\n(Logic)", ha='center', va='center', color='white', fontweight='bold', fontsize=10)
ax3.text(1, 1.869/2, "1.869 ns\n(Logic)", ha='center', va='center', color='white', fontweight='bold', fontsize=10)
ax3.text(1, 1.869 + 0.277/2, "+0.277 ns\n(Wire RC)", ha='center', va='center', color='black', fontweight='bold', fontsize=9)
ax3.legend(loc='upper left', frameon=True)

# Subplot 4: Total Negative Slack (TNS)
ax4 = axs[1, 1]
bars4 = ax4.bar(models[:4], tns_vals[:4], color=['#2ca02c', '#d62728', '#d62728', '#d62728'], width=0.55, edgecolor='black', linewidth=1.2)
ax4.axhline(0.0, color='black', linestyle='-', linewidth=1.5)
ax4.set_ylabel("Total Negative Slack (ns)", fontsize=11, fontweight='bold')
ax4.set_title("Total Negative Slack (TNS) Across Design", fontsize=12, fontweight='bold')
ax4.set_ylim(-60, 10)
for bar in bars4:
    yval = bar.get_height()
    offset = 2 if yval >= 0 else -6
    ax4.text(bar.get_x() + bar.get_width()/2.0, yval + offset, f"{yval:.2f} ns", ha='center', va='bottom', fontsize=10, fontweight='bold')

plt.tight_layout()

out1 = "ai-accelerator-project/phase19/sta_reports/phase19_physical_validation_results.png"
out2 = os.path.join(artifact_dir, "phase19_physical_validation_results.png")
plt.savefig(out1, dpi=300)
plt.savefig(out2, dpi=300)
print(f"[SUCCESS] Saved plots to:\n  - {out1}\n  - {out2}")
