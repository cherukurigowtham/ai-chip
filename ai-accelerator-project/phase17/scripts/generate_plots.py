import matplotlib.pyplot as plt
import numpy as np
import os

artifact_dir = "/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406"
out_img = os.path.join(artifact_dir, "phase17_timing_optimization_results.png")

fig, axs = plt.subplots(2, 2, figsize=(14, 10))
plt.subplots_adjust(hspace=0.35, wspace=0.3)

stages = ['Baseline\n(Phase 16)', 'HFNS Buffering\n(Step 2)', 'Timing Sign-Off\n(Step 3)']

# 1. Operating Frequency Fmax (MHz)
fmax = [22.55, 425.39, 427.47]
bars1 = axs[0, 0].bar(stages, fmax, color=['#d9534f', '#f0ad4e', '#5cb85c'], width=0.55, edgecolor='black', linewidth=1.2)
axs[0, 0].set_title('Maximum Operating Frequency ($F_{max}$)', fontsize=13, fontweight='bold', pad=10)
axs[0, 0].set_ylabel('Frequency (MHz)', fontsize=11)
axs[0, 0].grid(axis='y', linestyle='--', alpha=0.5)
axs[0, 0].set_ylim(0, 500)
for bar in bars1:
    yval = bar.get_height()
    axs[0, 0].text(bar.get_x() + bar.get_width()/2.0, yval + 10, f'{yval:.1f} MHz\n(+{yval/22.55:.1f}x)' if yval > 30 else f'{yval:.1f} MHz', ha='center', va='bottom', fontsize=10, fontweight='bold')

# 2. Total Negative Slack (TNS in ns) - Log Scale
tns_vals = [114481.29, 221.94, 67.45]
bars2 = axs[0, 1].bar(stages, tns_vals, color=['#d9534f', '#5bc0de', '#0275d8'], width=0.55, edgecolor='black', linewidth=1.2)
axs[0, 1].set_yscale('log')
axs[0, 1].set_title('Total Negative Slack Magnitude (|TNS|)', fontsize=13, fontweight='bold', pad=10)
axs[0, 1].set_ylabel('|TNS| (ns) [Log Scale]', fontsize=11)
axs[0, 1].grid(axis='y', linestyle='--', alpha=0.5)
for bar, val in zip(bars2, tns_vals):
    axs[0, 1].text(bar.get_x() + bar.get_width()/2.0, val * 1.3, f'{val:,.1f} ns', ha='center', va='bottom', fontsize=10, fontweight='bold')
axs[0, 1].text(0.7, 0.75, '99.94% TNS\nReduction!', transform=axs[0, 1].transAxes, fontsize=11, fontweight='bold', color='#0275d8', bbox=dict(boxstyle="round,pad=0.3", fc="#e8f4fd", ec="#0275d8"))

# 3. Maximum Fanout per Net
fanout_vals = [1984, 16, 8]
bars3 = axs[1, 0].bar(stages, fanout_vals, color=['#d9534f', '#f0ad4e', '#5cb85c'], width=0.55, edgecolor='black', linewidth=1.2)
axs[1, 0].set_yscale('log')
axs[1, 0].axhline(y=16, color='red', linestyle='--', linewidth=1.5, label='Constraint Target (<=16)')
axs[1, 0].set_title('Maximum Control Signal Fanout', fontsize=13, fontweight='bold', pad=10)
axs[1, 0].set_ylabel('Loads per Net [Log Scale]', fontsize=11)
axs[1, 0].grid(axis='y', linestyle='--', alpha=0.5)
axs[1, 0].legend(loc='upper right')
for bar, val in zip(bars3, fanout_vals):
    axs[1, 0].text(bar.get_x() + bar.get_width()/2.0, val * 1.25, f'{val}', ha='center', va='bottom', fontsize=10, fontweight='bold')

# 4. Silicon Logic Area (µm²)
area_vals = [153605.3, 155120.4, 142712.2]
bars4 = axs[1, 1].bar(stages, area_vals, color=['#6c757d', '#17a2b8', '#28a745'], width=0.55, edgecolor='black', linewidth=1.2)
axs[1, 1].set_title('Synthesized Standard Cell Area', fontsize=13, fontweight='bold', pad=10)
axs[1, 1].set_ylabel('Area (µm²)', fontsize=11)
axs[1, 1].set_ylim(0, 180000)
axs[1, 1].grid(axis='y', linestyle='--', alpha=0.5)
for bar, val in zip(bars4, area_vals):
    axs[1, 1].text(bar.get_x() + bar.get_width()/2.0, val + 3500, f'{val:,.0f} µm²', ha='center', va='bottom', fontsize=10, fontweight='bold')

plt.suptitle('Phase 17 Timing Optimization & Sign-Off Results (OpenSTA + Nangate 45nm)', fontsize=16, fontweight='bold', y=0.98)
plt.savefig(out_img, dpi=300, bbox_inches='tight')
print(f"Chart saved successfully to {out_img}")
