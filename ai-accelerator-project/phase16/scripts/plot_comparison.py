#!/usr/bin/env python3
"""
plot_comparison.py - Generate Phase 16 Real EDA vs Phase 15 Model Visualizations
"""

import matplotlib.pyplot as plt
import numpy as np
import os
import shutil

ARTIFACT_DIR = "/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406"
LOCAL_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../comparison"))
os.makedirs(LOCAL_DIR, exist_ok=True)

fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(14, 10))
plt.subplots_adjust(hspace=0.35, wspace=0.3)

# 1. Critical Path Delay (ns)
categories = ['Phase 15 Model', 'Phase 16 OpenSTA']
delays = [1.363, 44.350]
colors = ['#3498db', '#e74c3c']
bars1 = ax1.bar(categories, delays, color=colors, width=0.5, edgecolor='black', linewidth=1.2)
ax1.set_ylabel('Delay (ns)', fontsize=11, fontweight='bold')
ax1.set_title('Critical Path Delay Comparison\n(Target: 2.00 ns @ 500 MHz)', fontsize=12, fontweight='bold')
ax1.axhline(y=2.00, color='green', linestyle='--', linewidth=1.5, label='Target Period (2.0 ns)')
ax1.legend(loc='upper left')
for bar in bars1:
    yval = bar.get_height()
    ax1.text(bar.get_x() + bar.get_width()/2.0, yval + 1.0, f"{yval:.2f} ns", ha='center', va='bottom', fontweight='bold')
ax1.set_ylim(0, 50)
ax1.grid(axis='y', linestyle=':', alpha=0.6)

# 2. Maximum Clock Frequency Fmax (MHz)
fmax = [733.7, 22.55]
bars2 = ax2.bar(categories, fmax, color=['#2ecc71', '#e67e22'], width=0.5, edgecolor='black', linewidth=1.2)
ax2.set_ylabel('Fmax (MHz)', fontsize=11, fontweight='bold')
ax2.set_title('Maximum Operating Frequency (Fmax)\n(Discrepancy: -96.9%)', fontsize=12, fontweight='bold')
ax2.axhline(y=500.0, color='purple', linestyle='--', linewidth=1.5, label='Target Clock (500 MHz)')
ax2.legend(loc='upper right')
for bar in bars2:
    yval = bar.get_height()
    ax2.text(bar.get_x() + bar.get_width()/2.0, yval + 15, f"{yval:.1f} MHz", ha='center', va='bottom', fontweight='bold')
ax2.set_ylim(0, 850)
ax2.grid(axis='y', linestyle=':', alpha=0.6)

# 3. Power Breakdown Comparison (mW)
labels = ['Dynamic', 'Leakage', 'Total']
p15_power = [68.40, 3.12, 71.52]
p16_power = [24.37, 3.59, 27.96]

x = np.arange(len(labels))
width = 0.35

ax3.bar(x - width/2, p15_power, width, label='Phase 15 Model', color='#9b59b6', edgecolor='black')
ax3.bar(x + width/2, p16_power, width, label='Phase 16 OpenSTA', color='#1abc9c', edgecolor='black')
ax3.set_ylabel('Power (mW)', fontsize=11, fontweight='bold')
ax3.set_title('Power Dissipation Comparison\n(Nangate 45nm, 1.1V, 25°C)', fontsize=12, fontweight='bold')
ax3.set_xticks(x)
ax3.set_xticklabels(labels, fontweight='bold')
ax3.legend()
ax3.grid(axis='y', linestyle=':', alpha=0.6)
for i in range(len(labels)):
    ax3.text(x[i] - width/2, p15_power[i] + 1.5, f"{p15_power[i]:.1f}", ha='center', va='bottom', fontsize=9)
    ax3.text(x[i] + width/2, p16_power[i] + 1.5, f"{p16_power[i]:.1f}", ha='center', va='bottom', fontsize=9)
ax3.set_ylim(0, 85)

# 4. Critical Path Delay Anatomy (Why 44.35 ns?)
anatomy_labels = ['Unbuffered High-Fanout\nNets (4 gates, FO>500)', 'Logic Depth\n(PE Multiplier / Adders)', 'Clock Setup\n& Uncertainty']
anatomy_delays = [37.69, 6.57, 0.09]
anatomy_colors = ['#c0392b', '#f39c12', '#7f8c8d']

wedges, texts, autotexts = ax4.pie(anatomy_delays, labels=anatomy_labels, autopct='%1.1f%%',
                                  startangle=140, colors=anatomy_colors, explode=(0.08, 0, 0),
                                  textprops={'fontsize': 10, 'fontweight': 'bold'})
ax4.set_title('Root Cause Analysis of 44.35 ns Critical Path\n(Impact of Missing High-Fanout Net Synthesis)', fontsize=12, fontweight='bold')

plt.suptitle('Phase 16: Genuine OpenSTA Sign-Off vs. Phase 15 Python Modeling\nASIC Physical Design Verification (Nangate 45nm)', fontsize=14, fontweight='bold', y=0.98)

out_file = os.path.join(LOCAL_DIR, "eda_vs_modeled_comparison.png")
plt.savefig(out_file, dpi=300, bbox_inches='tight')
print(f"Saved plot to: {out_file}")

# Copy to conversation artifacts
artifact_out = os.path.join(ARTIFACT_DIR, "eda_vs_modeled_comparison.png")
shutil.copyfile(out_file, artifact_out)
print(f"Copied to artifact dir: {artifact_out}")
