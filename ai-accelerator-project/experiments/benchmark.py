"""
Experiments & Benchmarking Harness
==================================
Compares Architecture A (Baseline Naive MAC) vs Architecture B (Tiled Systolic Array)
across a sweep of matrix dimensions.

Outputs:
- Terminal comparison table
- CSV log: results/benchmark_summary.csv
- Figures:
  * results/memory_access_comparison.png
  * results/mac_utilization_comparison.png
  * results/energy_comparison.png
"""

import sys
import os
from pathlib import Path
import numpy as np
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

# Add project root to sys.path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.append(str(PROJECT_ROOT))

from baseline.baseline import BaselineAccelerator, BaselineConfig
from optimized.systolic_array import SystolicArrayAccelerator, SystolicConfig


def run_benchmark():
    matrix_sizes = [
        (8, 8, 8),
        (16, 16, 16),
        (32, 32, 32),
        (64, 64, 64),
        (128, 128, 128)
    ]

    base_config = BaselineConfig(num_macs=16, bus_width_words=4)
    syst_config = SystolicConfig(array_rows=4, array_cols=4, bus_width_words=4)

    base_accel = BaselineAccelerator(base_config)
    syst_accel = SystolicArrayAccelerator(syst_config)

    records = []

    print("\n" + "=" * 90)
    print("  RUNNING COMPREHENSIVE ARCHITECTURAL BENCHMARK")
    print("=" * 90)

    for M, K, N in matrix_sizes:
        print(f"\nEvaluating GEMM Matrix Shape: ({M} x {K}) * ({K} x {N}) ...")
        np.random.seed(42)
        A = np.random.randn(M, K).astype(np.float32)
        B = np.random.randn(K, N).astype(np.float32)

        # Run Baseline
        _, m_base = base_accel.run(A, B)
        # Run Systolic
        _, m_syst = syst_accel.run(A, B)

        assert m_base.is_correct, f"Baseline verification failed for ({M},{K},{N})"
        assert m_syst.is_correct, f"Systolic verification failed for ({M},{K},{N})"

        mem_reduction = m_base.total_mem_accesses / m_syst.total_mem_accesses
        speedup = m_base.execution_cycles / m_syst.execution_cycles
        energy_saved_pct = (1.0 - (m_syst.total_energy_uj / m_base.total_energy_uj)) * 100.0

        records.append({
            "Matrix_Size": f"{M}x{K}x{N}",
            "Total_MACs": m_base.total_mac_ops,
            "ArchA_MemAccesses": m_base.total_mem_accesses,
            "ArchB_MemAccesses": m_syst.total_mem_accesses,
            "Mem_Reduction_Factor": mem_reduction,
            "ArchA_Cycles": m_base.execution_cycles,
            "ArchB_Cycles": m_syst.execution_cycles,
            "Cycle_Speedup": speedup,
            "ArchA_Util_Pct": m_base.mac_utilization_pct,
            "ArchB_Util_Pct": m_syst.mac_utilization_pct,
            "ArchA_Energy_uJ": m_base.total_energy_uj,
            "ArchB_Energy_uJ": m_syst.total_energy_uj,
            "Energy_Savings_Pct": energy_saved_pct
        })

    df = pd.DataFrame(records)
    results_dir = PROJECT_ROOT / "results"
    results_dir.mkdir(exist_ok=True)

    csv_path = results_dir / "benchmark_summary.csv"
    df.to_csv(csv_path, index=False)
    print(f"\n[+] Results saved to: {csv_path}")

    # Display clean table
    print("\n" + "=" * 90)
    print("  ARCHITECTURAL BENCHMARK SUMMARY TABLE")
    print("=" * 90)
    display_cols = [
        "Matrix_Size", "Total_MACs", "ArchA_MemAccesses", "ArchB_MemAccesses",
        "Mem_Reduction_Factor", "ArchA_Util_Pct", "ArchB_Util_Pct", "Cycle_Speedup", "Energy_Savings_Pct"
    ]
    print(df[display_cols].to_string(index=False))
    print("=" * 90)

    # Plot 1: Memory Access Comparison (Log Scale)
    plt.figure(figsize=(9, 5))
    x = np.arange(len(df))
    width = 0.35
    plt.bar(x - width/2, df["ArchA_MemAccesses"], width, label="Arch A (Baseline Naive)", color="#e74c3c", alpha=0.9)
    plt.bar(x + width/2, df["ArchB_MemAccesses"], width, label="Arch B (Systolic Array)", color="#2ecc71", alpha=0.9)
    plt.yscale("log")
    plt.xticks(x, df["Matrix_Size"], fontsize=11)
    plt.ylabel("External Memory Accesses (Log Scale)", fontsize=12)
    plt.title("Memory Traffic: Baseline vs Systolic Array (Lower is Better)", fontsize=13, fontweight='bold')
    plt.grid(axis='y', linestyle='--', alpha=0.6)
    plt.legend(fontsize=11)
    plt.tight_layout()
    plot1_path = results_dir / "memory_access_comparison.png"
    plt.savefig(plot1_path, dpi=300)
    plt.close()

    # Plot 2: MAC Utilization Comparison
    plt.figure(figsize=(9, 5))
    plt.plot(df["Matrix_Size"], df["ArchA_Util_Pct"], marker='o', linewidth=2.5, color="#e74c3c", label="Arch A (Baseline)")
    plt.plot(df["Matrix_Size"], df["ArchB_Util_Pct"], marker='s', linewidth=2.5, color="#2ecc71", label="Arch B (Systolic Array)")
    plt.ylabel("MAC Utilization (%)", fontsize=12)
    plt.xlabel("Matrix Workload Dimension", fontsize=12)
    plt.title("MAC Unit Utilization: Memory-Stalled vs Data-Reused (Higher is Better)", fontsize=13, fontweight='bold')
    plt.grid(True, linestyle='--', alpha=0.6)
    plt.legend(fontsize=11)
    plt.tight_layout()
    plot2_path = results_dir / "mac_utilization_comparison.png"
    plt.savefig(plot2_path, dpi=300)
    plt.close()

    # Plot 3: Energy Consumption Comparison
    plt.figure(figsize=(9, 5))
    plt.bar(x - width/2, df["ArchA_Energy_uJ"], width, label="Arch A Energy (Baseline)", color="#e74c3c", alpha=0.9)
    plt.bar(x + width/2, df["ArchB_Energy_uJ"], width, label="Arch B Energy (Systolic Array)", color="#3498db", alpha=0.9)
    plt.yscale("log")
    plt.xticks(x, df["Matrix_Size"], fontsize=11)
    plt.ylabel("Total Energy Consumption [uJ] (Log Scale)", fontsize=12)
    plt.title("Total Energy Consumption: Baseline vs Systolic Array (Lower is Better)", fontsize=13, fontweight='bold')
    plt.grid(axis='y', linestyle='--', alpha=0.6)
    plt.legend(fontsize=11)
    plt.tight_layout()
    plot3_path = results_dir / "energy_comparison.png"
    plt.savefig(plot3_path, dpi=300)
    plt.close()

    print(f"[+] Plots successfully generated in: {results_dir}")


if __name__ == "__main__":
    run_benchmark()
