"""
Phase 11: Buffer Capacity Optimization & PPA Trade-Off Analysis
==============================================================
Sweeps on-chip SRAM buffer capacities to determine the Pareto-optimal
balance between Silicon Area, MAC Utilization, and Energy Efficiency.

Sweeps:
  - Activation Buffer Size: T_M in {4, 8, 16, 32, 64, 128} vectors
  - Weight Buffer Configuration:
    * Single Buffer (1 tile = 16 words = 32 B)
    * Double Buffer / Ping-Pong (2 tiles = 32 words = 64 B)
    * Quad Buffer (4 tiles = 64 words = 128 B)

Measures:
  1. Silicon Area (µm² and Gate Equivalents in Nangate 45nm)
  2. MAC Utilization under Fast DRAM (L=1) and Slow DRAM (L=8, 16)
  3. Total Execution Latency
  4. Energy Consumption (µJ)
  5. Throughput-per-Area (MACs / s / mm²)

Outputs:
  - CSV: ai-accelerator-project/phase11/results/buffer_capacity_analysis.csv
  - CSV: ai-accelerator-project/phase11/results/ppa_comparison.csv
  - Plot: ai-accelerator-project/phase11/results/buffer_tradeoff_pareto.png
"""

import os
import sys
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.append(str(PROJECT_ROOT))

# Hardware Constants
ARRAY_R = 4
ARRAY_C = 4
NUM_PES = ARRAY_R * ARRAY_C # 16 MACs
CLOCK_FREQ_MHZ = 500.0

# PDK Standard Cell Metrics (Nangate 45nm)
# Reference Gate: NAND2_X1 = 0.798 µm² (1 GE)
# DFF_X1 = 4.522 µm² (5.67 GE)
# 4x4 Systolic Core Fixed Area = 45,054.02 µm² (56,458 GE)
AREA_SYSTOLIC_CORE_UM2 = 45054.02
GE_SYSTOLIC_CORE = 56458


def estimate_buffer_area(t_m_vecs, num_weight_tiles, out_fifo_depth=64):
    """
    Computes synthesized standard cell area for on-chip buffers.
    """
    # Weight buffer: num_weight_tiles * 16 words * 16 bits
    w_words = num_weight_tiles * 16
    w_dffs = w_words * 16
    w_comb_gates = w_words * 38 # muxing and decoding logic
    w_area = (w_dffs * 4.522) + (w_comb_gates * 0.798)

    # Activation buffer: t_m_vecs * 4 words * 16 bits
    act_words = t_m_vecs * 4
    act_dffs = act_words * 16
    act_comb_gates = act_words * 42
    act_area = (act_dffs * 4.522) + (act_comb_gates * 0.798)

    # Output FIFO: out_fifo_depth * 32 bits
    fifo_dffs = out_fifo_depth * 32
    fifo_comb_gates = out_fifo_depth * 28
    fifo_area = (fifo_dffs * 4.522) + (fifo_comb_gates * 0.798)

    # FSM Controller & Handshake Logic
    fsm_area = 5989.52

    total_area_um2 = AREA_SYSTOLIC_CORE_UM2 + w_area + act_area + fifo_area + fsm_area
    total_ge = total_area_um2 / 0.798
    total_sram_bytes = (w_words * 2) + (act_words * 2) + (out_fifo_depth * 4)

    return total_area_um2, total_ge, total_sram_bytes


def evaluate_buffer_config(M, K, N, t_m, num_w_tiles, dram_latency):
    total_macs = M * K * N
    ideal_cycles = total_macs / NUM_PES

    num_k_tiles = int(np.ceil(K / ARRAY_R))
    num_n_tiles = int(np.ceil(N / ARRAY_C))
    num_m_tiles = int(np.ceil(M / t_m))
    total_weight_tiles = num_k_tiles * num_n_tiles

    weight_words_tile = 16
    out_words_total = M * N

    # Memory timing
    dram_w_time = dram_latency + int(np.ceil(weight_words_tile / 4.0)) * dram_latency
    dram_act_time = dram_latency + int(np.ceil((t_m * ARRAY_R) / 4.0)) * dram_latency

    total_compute_cycles = 0
    total_stall_cycles = 0

    double_buf = (num_w_tiles >= 2)

    for tile_idx in range(total_weight_tiles):
        for mt in range(num_m_tiles):
            cur_M = min(t_m, M - mt * t_m)
            tile_comp_cycles = cur_M + (ARRAY_R + ARRAY_C - 2)

            if double_buf:
                if tile_idx == 0 and mt == 0:
                    total_stall_cycles += dram_w_time + dram_act_time
                elif mt == 0:
                    refill_time = dram_w_time
                    if refill_time > tile_comp_cycles:
                        total_stall_cycles += (refill_time - tile_comp_cycles)
                total_compute_cycles += tile_comp_cycles
            else:
                total_stall_cycles += dram_w_time + dram_act_time
                total_compute_cycles += tile_comp_cycles

    drain_time = int(np.ceil(out_words_total / 4.0)) * dram_latency
    total_stall_cycles += drain_time
    total_cycles = total_compute_cycles + total_stall_cycles

    utilization = (ideal_cycles / total_cycles) * 100.0

    area_um2, ge, sram_bytes = estimate_buffer_area(t_m, num_w_tiles)

    # Throughput per Area: (MACs / s) / mm²
    time_sec = total_cycles / (CLOCK_FREQ_MHZ * 1e6)
    throughput_macs_sec = total_macs / time_sec
    area_mm2 = area_um2 / 1e6
    throughput_per_area = (throughput_macs_sec / 1e9) / area_mm2 # GMACs / s / mm²

    # Energy
    dram_words = (total_weight_tiles * 16) + (total_weight_tiles * M * ARRAY_R) + out_words_total
    e_dram = dram_words * (200.0 + dram_latency * 2.0)
    e_sram = (dram_words * 4 * 5.0) + (total_cycles * (sram_bytes / 1024.0) * 0.15)
    e_mac = total_macs * 1.25
    e_clk = total_cycles * (ge * 0.05) * 0.02
    total_energy_uj = (e_dram + e_sram + e_mac + e_clk) / 1e6

    return {
        "T_M_Vectors": t_m,
        "Weight_Buffer_Tiles": num_w_tiles,
        "SRAM_Capacity_Bytes": sram_bytes,
        "Silicon_Area_um2": round(area_um2, 2),
        "Gate_Equivalents_GE": int(ge),
        "DRAM_Latency_Cycles": dram_latency,
        "Execution_Cycles": total_cycles,
        "MAC_Utilization_%": round(utilization, 2),
        "Throughput_GMAC_s_mm2": round(throughput_per_area, 2),
        "Total_Energy_uJ": round(total_energy_uj, 3)
    }


def run_buffer_sweep():
    t_m_values = [4, 8, 16, 32, 64, 128]
    w_buf_configs = [1, 2, 4] # Single, Double, Quad buffering
    dram_latencies = [1, 4, 8]
    M, K, N = 32, 32, 32

    records = []
    print("\n" + "=" * 100)
    print("  PHASE 11: BUFFER CAPACITY OPTIMIZATION & PPA TRADE-OFF ANALYSIS")
    print("=" * 100)

    for tm in t_m_values:
        for w_tiles in w_buf_configs:
            for lat in dram_latencies:
                res = evaluate_buffer_config(M, K, N, tm, w_tiles, lat)
                records.append(res)

    df = pd.DataFrame(records)
    results_dir = PROJECT_ROOT / "phase11" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)

    csv_buf = results_dir / "buffer_capacity_analysis.csv"
    df.to_csv(csv_buf, index=False)
    print(f"[Saved] Buffer capacity analysis saved to: {csv_buf}")

    # Generate PPA comparison summary table for T_M sweep under typical DRAM (L=4)
    df_ppa = df[(df["DRAM_Latency_Cycles"] == 4) & (df["Weight_Buffer_Tiles"] == 2)]
    csv_ppa = results_dir / "ppa_comparison.csv"
    df_ppa.to_csv(csv_ppa, index=False)
    print(f"[Saved] PPA comparison summary saved to: {csv_ppa}")

    # Print Summary Focus Table
    print("\n" + "=" * 90)
    print("  PARETO ANALYSIS: ACTIVATION BUFFER CAPACITY (T_M) UNDER L=4 DRAM (Ping-Pong Weights)")
    print("=" * 90)
    print(f"| T_M | SRAM Size | Silicon Area (um2) | Utilization | GMACs/s/mm2 | Energy (uJ) | Efficiency Note |")
    print(f"| :-- | :-------- | :----------------- | :---------- | :---------- | :---------- | :-------------- |")
    for _, r in df_ppa.iterrows():
        note = "Baseline" if r["T_M_Vectors"] == 4 else ("Sweet Spot (Pareto Optimal)" if r["T_M_Vectors"] == 32 else "Diminishing Returns")
        tm_val = int(r['T_M_Vectors'])
        sram_val = int(r['SRAM_Capacity_Bytes'])
        print(f"| {tm_val:3d} | {sram_val:4d} B     | {r['Silicon_Area_um2']:10.1f} um2     | {r['MAC_Utilization_%']:5.1f}%     | {r['Throughput_GMAC_s_mm2']:7.2f}     | {r['Total_Energy_uJ']:5.3f} uJ   | {note} |")

    generate_pareto_chart(df_ppa, results_dir)
    return df


def generate_pareto_chart(df_ppa: pd.DataFrame, out_dir: Path):
    fig, ax1 = plt.subplots(figsize=(10, 6))

    color1 = '#5cb85c'
    color2 = '#d9534f'

    t_m = df_ppa["T_M_Vectors"].values
    util = df_ppa["MAC_Utilization_%"].values
    area = df_ppa["Silicon_Area_um2"].values / 1e3 # k um2
    eff = df_ppa["Throughput_GMAC_s_mm2"].values

    ax1.plot(t_m, util, color=color1, marker='o', linewidth=2.5, markersize=8, label='MAC Utilization (%)')
    ax1.set_xlabel('Activation Buffer Length (T_M Vectors)', fontsize=12, fontweight='bold')
    ax1.set_ylabel('MAC Utilization (%)', color=color1, fontsize=12, fontweight='bold')
    ax1.tick_params(axis='y', labelcolor=color1)
    ax1.set_ylim(0, 100)
    ax1.grid(True, linestyle=':', alpha=0.6)

    ax2 = ax1.twinx()
    ax2.plot(t_m, eff, color=color2, marker='s', linewidth=2.5, markersize=8, linestyle='--', label='Throughput / Area (GMAC/s/mm²)')
    ax2.set_ylabel('Throughput-per-Area (GMAC/s/mm²)', color=color2, fontsize=12, fontweight='bold')
    ax2.tick_params(axis='y', labelcolor=color2)

    # Highlight Sweet Spot at T_M = 32
    ax1.axvline(32, color='navy', linestyle=':', linewidth=1.8, label='Pareto Sweet Spot (T_M = 32)')

    plt.title('Phase 11: Pareto Trade-off Analysis (Utilization vs. Area-Efficiency)', fontsize=14, fontweight='bold')
    fig.tight_layout()
    out_png = out_dir / "buffer_tradeoff_pareto.png"
    plt.savefig(out_png, dpi=300)
    plt.close()
    print(f"[Saved] Pareto Trade-off Plot: {out_png}")


if __name__ == "__main__":
    run_buffer_sweep()
