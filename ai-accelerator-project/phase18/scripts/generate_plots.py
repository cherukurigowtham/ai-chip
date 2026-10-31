import matplotlib.pyplot as plt
import numpy as np
import os

artifact_dir = "/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406"
out_img = os.path.join(artifact_dir, "phase18_pipeline_optimization_results.png")

fig, axs = plt.subplots(2, 2, figsize=(14, 10))
plt.subplots_adjust(hspace=0.35, wspace=0.3)

stages = ['Phase 16\n(Baseline)', 'Phase 17\n(HFNS Buffering)', 'Phase 18\n(Pipelined Sign-Off)']

# 1. Operating Frequency Fmax (MHz)
fmax = [22.55, 427.47, 512.62]
bars1 = axs[0, 0].bar(stages, fmax, color=['#d9534f', '#f0ad4e', '#28a745'], width=0.55, edgecolor='black', linewidth=1.2)
axs[0, 0].axhline(y=500, color='red', linestyle='--', linewidth=1.5, label='500 MHz Target')
axs[0, 0].set_title('Maximum Operating Frequency ($F_{max}$)', fontsize=13, fontweight='bold', pad=10)
axs[0, 0].set_ylabel('Frequency (MHz)', fontsize=11)
axs[0, 0].grid(axis='y', linestyle='--', alpha=0.5)
axs[0, 0].set_ylim(0, 580)
axs[0, 0].legend(loc='lower right')
for bar in bars1:
    yval = bar.get_height()
    axs[0, 0].text(bar.get_x() + bar.get_width()/2.0, yval + 10, f'{yval:.1f} MHz', ha='center', va='bottom', fontsize=10, fontweight='bold')

# 2. Total Negative Slack (TNS in ns)
tns_vals = [114481.29, 67.45, 0.0]
bars2 = axs[0, 1].bar(stages, [114481.29, 67.45, 0.001], color=['#d9534f', '#f0ad4e', '#28a745'], width=0.55, edgecolor='black', linewidth=1.2)
axs[0, 1].set_yscale('log')
axs[0, 1].set_title('Total Negative Slack Magnitude (|TNS|)', fontsize=13, fontweight='bold', pad=10)
axs[0, 1].set_ylabel('|TNS| (ns) [Log Scale]', fontsize=11)
axs[0, 1].grid(axis='y', linestyle='--', alpha=0.5)
axs[0, 1].text(bars2[0].get_x() + bars2[0].get_width()/2.0, 114481.29 * 1.3, '114,481.3 ns', ha='center', va='bottom', fontsize=10, fontweight='bold')
axs[0, 1].text(bars2[1].get_x() + bars2[1].get_width()/2.0, 67.45 * 1.5, '67.5 ns', ha='center', va='bottom', fontsize=10, fontweight='bold')
axs[0, 1].text(bars2[2].get_x() + bars2[2].get_width()/2.0, 0.01, '0.000 ns (MET!)', ha='center', va='bottom', fontsize=10, fontweight='bold', color='#28a745')

# 3. Setup Slack (WNS at 500 MHz, ns)
slack_vals = [-42.35, -0.339, +0.0492]
colors3 = ['#d9534f', '#f0ad4e', '#28a745']
bars3 = axs[1, 0].bar(stages, slack_vals, color=colors3, width=0.55, edgecolor='black', linewidth=1.2)
axs[1, 0].axhline(y=0, color='black', linestyle='-', linewidth=1.2)
axs[1, 0].set_title('Worst Setup Slack at 500 MHz (WNS)', fontsize=13, fontweight='bold', pad=10)
axs[1, 0].set_ylabel('Setup Slack (ns)', fontsize=11)
axs[1, 0].set_ylim(-45, 5)
axs[1, 0].grid(axis='y', linestyle='--', alpha=0.5)
axs[1, 0].text(bars3[0].get_x() + bars3[0].get_width()/2.0, -40, '-42.35 ns', ha='center', va='bottom', fontsize=10, fontweight='bold')
axs[1, 0].text(bars3[1].get_x() + bars3[1].get_width()/2.0, 1.0, '-339.4 ps', ha='center', va='bottom', fontsize=10, fontweight='bold')
axs[1, 0].text(bars3[2].get_x() + bars3[2].get_width()/2.0, 1.0, '+49.2 ps (MET!)', ha='center', va='bottom', fontsize=10, fontweight='bold', color='#28a745')

# 4. Silicon Logic Area (µm²)
area_vals = [153605.3, 142712.2, 143919.8]
bars4 = axs[1, 1].bar(stages, area_vals, color=['#6c757d', '#17a2b8', '#28a745'], width=0.55, edgecolor='black', linewidth=1.2)
axs[1, 1].axhline(y=180000, color='red', linestyle='--', linewidth=1.5, label='Budget (<180k µm²)')
axs[1, 1].set_title('Synthesized Standard Cell Area', fontsize=13, fontweight='bold', pad=10)
axs[1, 1].set_ylabel('Area (µm²)', fontsize=11)
axs[1, 1].set_ylim(0, 200000)
axs[1, 1].grid(axis='y', linestyle='--', alpha=0.5)
axs[1, 1].legend(loc='upper right')
for bar in bars4:
    yval = bar.get_height()
    axs[1, 1].text(bar.get_x() + bar.get_width()/2.0, yval + 3500, f'{yval:,.0f} µm²', ha='center', va='bottom', fontsize=10, fontweight='bold')

plt.suptitle('Phase 18 Pipeline Optimization & 500 MHz Timing Closure (OpenSTA + Nangate 45nm)', fontsize=16, fontweight='bold', y=0.98)
plt.savefig(out_img, dpi=300, bbox_inches='tight')
print(f"Chart saved successfully to {out_img}")
