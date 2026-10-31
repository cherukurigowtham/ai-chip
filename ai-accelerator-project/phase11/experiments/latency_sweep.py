"""
Phase 11: DRAM Latency Sensitivity & Backpressure Analysis
==========================================================
Investigates accelerator resilience under realistic variable memory latency.
Sweeps DRAM access latencies:
  L in {1, 4, 8, 16, 32} clock cycles per word/burst.

Measures:
  - MAC Utilization (%)
  - Total Execution Cycles
  - Compute vs. Memory Stall Cycles
  - Effective Bandwidth Demand (GB/s @ 500 MHz)
  - Full Physical Energy (uJ)

Outputs:
  - CSV: ai-accelerator-project/phase11/results/utilization_vs_latency.csv
  - Plot: ai-accelerator-project/phase11/results/utilization_vs_latency.png
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

# Hardware constants
ARRAY_R = 4
ARRAY_C = 4
NUM_PES = ARRAY_R * ARRAY_C # 16 MACs
CLOCK_FREQ_MHZ = 500.0

# Energy parameters (Nangate 45nm, 1.1V)
E_DRAM_WORD_BASE = 200.0   # pJ
E_SRAM_READ = 5.0          # pJ
E_SRAM_WRITE = 6.0         # pJ
P_SRAM_LEAK_KB = 0.15      # pJ/cycle/KB
E_MAC = 1.25               # pJ
E_CLK_DFF = 0.02           # pJ/DFF/cycle
NUM_DFFS = 4580
SRAM_SIZE_KB = 8.0


def simulate_latency(M, K, N, dram_latency_cycles, T_M=32, double_buf=True):
    total_macs = M * K * N
    ideal_cycles = total_macs / NUM_PES

    num_k_tiles = int(np.ceil(K / ARRAY_R))
    num_n_tiles = int(np.ceil(N / ARRAY_C))
    num_m_tiles = int(np.ceil(M / T_M))
    total_weight_tiles = num_k_tiles * num_n_tiles

    # Memory transactions
    weight_words_tile = ARRAY_R * ARRAY_C # 16
    act_words_tile = T_M * ARRAY_R        # 32 * 4 = 128
    out_words_total = M * N

    # DRAM transfer time per tile
    # Initial row access latency + transfer cycles
    dram_w_time = dram_latency_cycles + int(np.ceil(weight_words_tile / 4.0)) * dram_latency_cycles
    dram_act_time = dram_latency_cycles + int(np.ceil(act_words_tile / 4.0)) * dram_latency_cycles

    # Array compute time for continuous stream of T_M vectors
    stream_compute_time = T_M + (ARRAY_R + ARRAY_C - 2) # 32 + 6 = 38 cycles

    total_compute_cycles = 0
    total_stall_cycles = 0

    dram_reads = 0
    dram_writes = out_words_total
    sram_reads = 0
    sram_writes = 0

    for tile_idx in range(total_weight_tiles):
        dram_reads += weight_words_tile
        sram_writes += weight_words_tile

        for mt in range(num_m_tiles):
            cur_M = min(T_M, M - mt * T_M)
            act_words = cur_M * ARRAY_R
            dram_reads += act_words
            sram_writes += act_words
            sram_reads += act_words * 4 # read and forwarded horizontally

            tile_comp_cycles = cur_M + (ARRAY_R + ARRAY_C - 2)

            if double_buf:
                if tile_idx == 0 and mt == 0:
                    # Cold start: must wait for initial weight and activation load
                    total_stall_cycles += dram_w_time + dram_act_time
                elif mt == 0:
                    # First stream of a new weight tile: next weight was prefetched in background
                    # If DRAM weight load time exceeds previous stream compute time, backpressure stall!
                    refill_time = dram_w_time
                    if refill_time > tile_comp_cycles:
                        stall = refill_time - tile_comp_cycles
                        total_stall_cycles += stall

                total_compute_cycles += tile_comp_cycles
            else:
                # Baseline without double buffering: strictly sequential
                total_stall_cycles += dram_w_time + dram_act_time
                total_compute_cycles += tile_comp_cycles

    # Drain outputs to DRAM
    drain_time = int(np.ceil(out_words_total / 4.0)) * dram_latency_cycles
    total_stall_cycles += drain_time

    total_cycles = total_compute_cycles + total_stall_cycles
    end_to_end_util = (ideal_cycles / total_cycles) * 100.0
    compute_util = (ideal_cycles / total_compute_cycles) * 100.0

    # Physical Energy
    e_dram = (dram_reads + dram_writes) * (E_DRAM_WORD_BASE + dram_latency_cycles * 2.0)
    e_sram = (sram_reads * E_SRAM_READ) + (sram_writes * E_SRAM_WRITE) + (total_cycles * SRAM_SIZE_KB * P_SRAM_LEAK_KB)
    e_mac = total_macs * E_MAC
    e_clk = total_cycles * NUM_DFFS * E_CLK_DFF
    total_energy_uj = (e_dram + e_sram + e_mac + e_clk) / 1e6

    # Effective Bandwidth (GB/s at 500 MHz)
    time_sec = total_cycles / (CLOCK_FREQ_MHZ * 1e6)
    total_bytes = (dram_reads + dram_writes) * 2 # 16-bit words = 2 bytes
    bandwidth_gb_s = (total_bytes / 1e9) / time_sec

    return {
        "Matrix": f"{M}x{K}x{N}",
        "DRAM_Latency_Cycles": dram_latency_cycles,
        "Total_Cycles": total_cycles,
        "Compute_Cycles": total_compute_cycles,
        "Stall_Cycles": total_stall_cycles,
        "End_to_End_MAC_Util_%": round(end_to_end_util, 2),
        "Compute_MAC_Util_%": round(compute_util, 2),
        "DRAM_Reads": dram_reads,
        "DRAM_Writes": dram_writes,
        "Bandwidth_GB_s": round(bandwidth_gb_s, 3),
        "Total_Energy_uJ": round(total_energy_uj, 3)
    }


def run_latency_sweep():
    latencies = [1, 4, 8, 16, 32]
    workloads = [
        (16, 16, 16),
        (32, 32, 32),
        (64, 64, 64)
    ]

    records = []
    print("\n" + "=" * 100)
    print("  PHASE 11: DRAM LATENCY SENSITIVITY & BACKPRESSURE ANALYSIS")
    print("=" * 100)

    for M, K, N in workloads:
        print(f"\n---> Workload: {M}x{K}x{N} ({M*K*N:,} MACs) <---")
        for lat in latencies:
            res = simulate_latency(M, K, N, lat, T_M=32, double_buf=True)
            records.append(res)
            print(f"  Latency: {lat:2d} cycles | Cycles: {res['Total_Cycles']:7d} (Stall: {res['Stall_Cycles']:6d}) | "
                  f"E2E Util: {res['End_to_End_MAC_Util_%']:5.1f}% | BW: {res['Bandwidth_GB_s']:5.2f} GB/s | "
                  f"Energy: {res['Total_Energy_uJ']:6.3f} uJ")

    df = pd.DataFrame(records)
    results_dir = PROJECT_ROOT / "phase11" / "results"
    results_dir.mkdir(parents=True, exist_ok=True)
    out_csv = results_dir / "utilization_vs_latency.csv"
    df.to_csv(out_csv, index=False)
    print(f"\n[Saved] Latency sweep CSV saved to: {out_csv}")

    # Generate Chart
    generate_chart(df, results_dir)
    return df


def generate_chart(df: pd.DataFrame, out_dir: Path):
    fig, ax = plt.subplots(figsize=(10, 6))
    latencies = [1, 4, 8, 16, 32]
    workloads = ["16x16x16", "32x32x32", "64x64x64"]
    colors = ['#f0ad4e', '#5bc0de', '#5cb85c']
    markers = ['o', 's', '^']

    for i, w in enumerate(workloads):
        sub_df = df[df["Matrix"] == w]
        vals = [sub_df[sub_df["DRAM_Latency_Cycles"] == lat]["End_to_End_MAC_Util_%"].values[0] for lat in latencies]
        ax.plot(latencies, vals, marker=markers[i], linewidth=2.5, markersize=8, color=colors[i], label=f"Workload {w}")
        for x_val, y_val in zip(latencies, vals):
            ax.annotate(f"{y_val:.1f}%", xy=(x_val, y_val), xytext=(0, 7), textcoords="offset points",
                        ha='center', fontsize=9, fontweight='bold')

    ax.axhline(80.0, color='darkgreen', linestyle='--', linewidth=1.5, label='80%+ Research Target')
    ax.set_xlabel('DRAM Access Latency (Clock Cycles per Burst)', fontsize=12, fontweight='bold')
    ax.set_ylabel('End-to-End MAC Utilization (%)', fontsize=12, fontweight='bold')
    ax.set_title('Phase 11: MAC Utilization vs. Variable DRAM Latency (Backpressure)', fontsize=14, fontweight='bold')
    ax.set_xticks(latencies)
    ax.set_ylim(0, 100)
    ax.grid(True, linestyle=':', alpha=0.6)
    ax.legend(loc='lower left', framealpha=0.9)
    plt.tight_layout()
    out_png = out_dir / "utilization_vs_latency.png"
    plt.savefig(out_png, dpi=300)
    plt.close()
    print(f"[Saved] Latency Sensitivity Plot: {out_png}")


if __name__ == "__main__":
    run_latency_sweep()
