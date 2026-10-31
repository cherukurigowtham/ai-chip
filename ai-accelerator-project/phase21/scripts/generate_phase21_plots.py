import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

# Set style
plt.style.use('seaborn-v0_8-whitegrid' if 'seaborn-v0_8-whitegrid' in plt.style.available else 'default')
fig, axs = plt.subplots(2, 2, figsize=(14, 10))

# 1. Frequency Progression across Architectural & Physical Phases
phases = [
    'Phase 16\n(Raw HFNS)',
    'Phase 17\n(Ctrl Buff)',
    'Phase 18\n(Pipelined)',
    'Phase 19\n(WLM RC)',
    'Phase 20\n(Opt WLM)',
    'Phase 21\n(Routed SPEF)'
]
freqs = [22.55, 425.39, 512.62, 448.85, 531.40, 476.55]
colors = ['#d9534f', '#f0ad4e', '#5bc0de', '#d9534f', '#5cb85c', '#0275d8']

bars = axs[0, 0].bar(phases, freqs, color=colors, width=0.55, edgecolor='black', linewidth=1)
axs[0, 0].axhline(500, color='red', linestyle='--', linewidth=1.5, label='Target (500 MHz)')
axs[0, 0].set_ylabel('Clock Frequency (MHz)', fontsize=11, fontweight='bold')
axs[0, 0].set_title('Frequency Evolution: Pre-Route vs. Genuine OpenROAD Routed SPEF', fontsize=12, fontweight='bold')
axs[0, 0].set_ylim(0, 600)
for bar in bars:
    yval = bar.get_height()
    axs[0, 0].text(bar.get_x() + bar.get_width()/2.0, yval + 10, f'{yval:.1f} MHz', ha='center', va='bottom', fontsize=9, fontweight='bold')
axs[0, 0].legend(loc='lower right')

# 2. Wirelength by Metal Layer (TritonRoute 1.533 meters total)
layers = ['metal1', 'metal2', 'metal3', 'metal4', 'metal5', 'metal6']
lengths_m = [13118 / 1e6, 594708 / 1e6, 695152 / 1e6, 213733 / 1e6, 13549 / 1e6, 2826 / 1e6]
layer_colors = ['#6baed6', '#3182bd', '#08519c', '#756bb1', '#bcbddc', '#dadaeb']

bars2 = axs[0, 1].bar(layers, lengths_m, color=layer_colors, edgecolor='black', linewidth=1)
axs[0, 1].set_ylabel('Wire Length (Meters)', fontsize=11, fontweight='bold')
axs[0, 1].set_title('Physical Routing Wirelength by Metal Layer (Total: 1.533 m)', fontsize=12, fontweight='bold')
axs[0, 1].set_ylim(0, 0.85)
for bar in bars2:
    yval = bar.get_height()
    axs[0, 1].text(bar.get_x() + bar.get_width()/2.0, yval + 0.02, f'{yval*1000:.1f} mm\n({yval/1.533088*100:.1f}%)', ha='center', va='bottom', fontsize=8, fontweight='bold')

# 3. Post-Route Power Breakdown (Total: 48.24 mW)
power_labels = ['Sequential\n(23.92 mW)', 'Clock Network\n(19.82 mW)', 'Combinational\n(4.50 mW)', 'Leakage\n(3.84 mW)']
power_vals = [23.92, 19.82, 4.50, 3.84]
power_colors = ['#1f77b4', '#aec7e8', '#ff7f0e', '#2ca02c']

wedges, texts, autotexts = axs[1, 0].pie(
    power_vals, labels=power_labels, autopct='%1.1f%%',
    colors=power_colors, startangle=140, explode=(0.04, 0.04, 0.04, 0.04),
    textprops=dict(fontsize=9, fontweight='bold')
)
axs[1, 0].set_title('Post-Route Sign-off Power Breakdown (Total: 48.24 mW)', fontsize=12, fontweight='bold')

# 4. Physical Area & Utilization Breakdown
labels_area = ['Std Cell Area\n(153,922 µm²)', 'Free Core Space\n(125,162 µm²)', 'IO/Die Margin\n(22,333 µm²)']
area_vals = [153922, 125162, 22333]
area_colors = ['#31a354', '#a1d99b', '#e5f5e0']

wedges2, texts2, autotexts2 = axs[1, 1].pie(
    area_vals, labels=labels_area, autopct='%1.1f%%',
    colors=area_colors, startangle=90, explode=(0.03, 0.03, 0.03),
    textprops=dict(fontsize=9, fontweight='bold')
)
axs[1, 1].set_title('Die Area Allocation (Total Die: 549 µm × 549 µm = 301,417 µm²)', fontsize=12, fontweight='bold')

plt.tight_layout()
output_path = '/Users/gowthamcherukuri/.gemini/antigravity/brain/808a4ef4-7e33-4a6a-8a47-69d82d739406/phase21_physical_validation_results.png'
plt.savefig(output_path, dpi=300)
print('Phase 21 results plot saved to:', output_path)
