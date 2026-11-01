#!/usr/bin/env python3
"""
synth_pe_comparison.py - Automated Yosys Synthesis & PPA Comparison:
Baseline 16-bit Binary PE (pe.sv) vs. 2-bit Hybrid Ternary PE (pe_ternary.sv)
using Nangate45 Open Cell Library.
"""

import os
import sys
import re
import json
import subprocess
import tempfile
from typing import Dict, Any

LIBERTY_PATH = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../../phase21/pdk/nangate45.lib")
)
if not os.path.exists(LIBERTY_PATH):
    LIBERTY_PATH = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../phase9/synthesis/nangate45.lib")
    )

T_CLK_Q_PS   = 76.7   # DFF_X1 CK -> Q
T_SETUP_PS   = 36.8   # DFF_X1 Setup
T_WIRE_RC_PS = 35.0   # M3 Interconnect Wire RC
TARGET_PERIOD_PS = 2000.0 # 500 MHz Target

def run_yosys_synth(rtl_file: str, top_module: str, liberty_path: str) -> Dict[str, Any]:
    assert os.path.exists(rtl_file), f"RTL file not found: {rtl_file}"
    assert os.path.exists(liberty_path), f"Liberty file not found: {liberty_path}"
    
    yosys_script = f"""
read_verilog -sv {os.path.abspath(rtl_file)}
hierarchy -top {top_module}
proc; opt; fsm; opt; memory; opt
techmap; opt
dfflibmap -liberty {liberty_path}
abc -liberty {liberty_path} -script +strash;map;topo;print_stats
stat -liberty {liberty_path}
"""
    with tempfile.NamedTemporaryFile("w", suffix=".ys", delete=False) as f:
        script_path = f.name
        f.write(yosys_script)

    try:
        res = subprocess.run(["yosys", script_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
        out = res.stdout
    finally:
        if os.path.exists(script_path):
            os.remove(script_path)

    stats = parse_yosys_stat(out, top_module)
    return stats

def parse_yosys_stat(output: str, top_module: str) -> Dict[str, Any]:
    stats = {
        "top_module": top_module,
        "total_cells": 0,
        "dff_count": 0,
        "total_area_um2": 0.0,
        "sequential_area_um2": 0.0,
        "combinational_area_um2": 0.0,
        "logic_delay_ps": 0.0,
        "logic_levels": 0,
        "cell_counts": {}
    }
    
    # Parse ABC netlist stats: e.g.:
    # ABC: netlist : i/o = 106/ 51 lat = 0 nd = 832 edge = 1888 area =785.78 delay =483.10 lev = 18
    for line in output.splitlines():
        if "ABC: netlist" in line and "delay =" in line:
            m_delay = re.search(r"delay\s*=\s*([0-9.]+)", line)
            m_lev = re.search(r"lev\s*=\s*([0-9]+)", line)
            if m_delay:
                stats["logic_delay_ps"] = float(m_delay.group(1))
            if m_lev:
                stats["logic_levels"] = int(m_lev.group(1))
                
        elif "Chip area for module" in line:
            val = line.split(":")[-1].strip()
            try:
                stats["total_area_um2"] = float(val)
            except ValueError:
                pass
        elif "used for sequential elements:" in line:
            val = line.split("used for sequential elements:")[-1].split()[0].strip()
            try:
                stats["sequential_area_um2"] = float(val)
            except ValueError:
                pass
        elif "cells" in line and not line.strip().startswith("=== design hierarchy"):
            toks = line.strip().split()
            if len(toks) >= 2 and toks[0].isdigit():
                stats["total_cells"] = int(toks[0])
        elif "_X1" in line or "_X2" in line or "_X4" in line or "DFF" in line:
            toks = line.strip().split()
            if len(toks) >= 3 and toks[0].isdigit():
                count = int(toks[0])
                cell_name = toks[-1]
                stats["cell_counts"][cell_name] = count
                if "DFF" in cell_name:
                    stats["dff_count"] += count

    stats["combinational_area_um2"] = stats["total_area_um2"] - stats["sequential_area_um2"]
    
    # Static timing closure metrics
    t_crit_ps = T_CLK_Q_PS + T_WIRE_RC_PS + stats["logic_delay_ps"] + T_SETUP_PS
    f_max_mhz = 1e6 / t_crit_ps
    slack_ps = TARGET_PERIOD_PS - t_crit_ps
    
    stats["sta"] = {
        "t_clk_q_ps": T_CLK_Q_PS,
        "t_wire_ps": T_WIRE_RC_PS,
        "t_logic_ps": stats["logic_delay_ps"],
        "t_setup_ps": T_SETUP_PS,
        "t_crit_ps": round(t_crit_ps, 2),
        "t_crit_ns": round(t_crit_ps / 1000.0, 3),
        "f_max_mhz": round(f_max_mhz, 1),
        "slack_500mhz_ps": round(slack_ps, 2),
        "timing_met": slack_ps >= 0.0
    }
    return stats

def main():
    base_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
    binary_pe_rtl = os.path.join(base_dir, "rtl/pe.sv")
    ternary_pe_rtl = os.path.join(base_dir, "ternary/rtl/pe_ternary.sv")

    print(f"Synthesizing Baseline Binary PE ({binary_pe_rtl}) against Nangate45...")
    base_stats = run_yosys_synth(binary_pe_rtl, "pe", LIBERTY_PATH)

    print(f"Synthesizing Ternary PE ({ternary_pe_rtl}) against Nangate45...")
    ternary_stats = run_yosys_synth(ternary_pe_rtl, "pe_ternary", LIBERTY_PATH)

    # Compute comparative deltas
    area_reduction_um2 = base_stats["total_area_um2"] - ternary_stats["total_area_um2"]
    area_reduction_pct = (area_reduction_um2 / base_stats["total_area_um2"]) * 100.0
    comb_reduction_pct = ((base_stats["combinational_area_um2"] - ternary_stats["combinational_area_um2"]) / base_stats["combinational_area_um2"]) * 100.0
    seq_reduction_pct = ((base_stats["sequential_area_um2"] - ternary_stats["sequential_area_um2"]) / base_stats["sequential_area_um2"]) * 100.0
    cell_reduction_pct = ((base_stats["total_cells"] - ternary_stats["total_cells"]) / base_stats["total_cells"]) * 100.0
    delay_reduction_pct = ((base_stats["logic_delay_ps"] - ternary_stats["logic_delay_ps"]) / base_stats["logic_delay_ps"]) * 100.0
    fmax_speedup_pct = ((ternary_stats["sta"]["f_max_mhz"] - base_stats["sta"]["f_max_mhz"]) / base_stats["sta"]["f_max_mhz"]) * 100.0

    comparison = {
        "baseline_binary_pe": base_stats,
        "ternary_pe": ternary_stats,
        "ppa_delta": {
            "area_reduction_um2": area_reduction_um2,
            "area_reduction_pct": round(area_reduction_pct, 2),
            "combinational_area_reduction_pct": round(comb_reduction_pct, 2),
            "sequential_area_reduction_pct": round(seq_reduction_pct, 2),
            "cell_count_reduction_pct": round(cell_reduction_pct, 2),
            "logic_delay_reduction_pct": round(delay_reduction_pct, 2),
            "fmax_speedup_pct": round(fmax_speedup_pct, 2),
            "baseline_dff_count": base_stats["dff_count"],
            "ternary_dff_count": ternary_stats["dff_count"],
            "baseline_fmax_mhz": base_stats["sta"]["f_max_mhz"],
            "ternary_fmax_mhz": ternary_stats["sta"]["f_max_mhz"]
        }
    }

    results_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../results"))
    os.makedirs(results_dir, exist_ok=True)
    out_json = os.path.join(results_dir, "pe_synthesis_comparison.json")
    with open(out_json, "w") as f:
        json.dump(comparison, f, indent=2)

    print("\n" + "=" * 80)
    print("      SILICON PPA BENCHMARK: BASELINE BINARY PE vs. TERNARY PE (Nangate 45nm)")
    print("=" * 80)
    print(f"{'Physical Metric':<32} | {'Baseline (Binary)':<18} | {'Ternary PE':<18} | {'Improvement':<12}")
    print("-" * 80)
    print(f"{'Total Cell Area (um^2)':<32} | {base_stats['total_area_um2']:>14.2f} um2 | {ternary_stats['total_area_um2']:>14.2f} um2 | {area_reduction_pct:>10.2f}%")
    print(f"{'Combinational Area (um^2)':<32} | {base_stats['combinational_area_um2']:>14.2f} um2 | {ternary_stats['combinational_area_um2']:>14.2f} um2 | {comb_reduction_pct:>10.2f}%")
    print(f"{'Sequential Area (um^2)':<32} | {base_stats['sequential_area_um2']:>14.2f} um2 | {ternary_stats['sequential_area_um2']:>14.2f} um2 | {seq_reduction_pct:>10.2f}%")
    print(f"{'Total Standard Cells':<32} | {base_stats['total_cells']:>18d} | {ternary_stats['total_cells']:>18d} | {cell_reduction_pct:>10.2f}%")
    print(f"{'Flip-Flop Count (DFF)':<32} | {base_stats['dff_count']:>18d} | {ternary_stats['dff_count']:>18d} | {((base_stats['dff_count']-ternary_stats['dff_count'])/base_stats['dff_count'])*100:>10.2f}%")
    print(f"{'Combinational Logic Levels':<32} | {base_stats['logic_levels']:>18d} | {ternary_stats['logic_levels']:>18d} | {((base_stats['logic_levels']-ternary_stats['logic_levels'])/base_stats['logic_levels'])*100:>10.2f}%")
    print(f"{'Logic Propagation Delay (ps)':<32} | {base_stats['logic_delay_ps']:>15.2f} ps | {ternary_stats['logic_delay_ps']:>15.2f} ps | {delay_reduction_pct:>10.2f}%")
    print(f"{'Critical Path Delay (ps)':<32} | {base_stats['sta']['t_crit_ps']:>15.2f} ps | {ternary_stats['sta']['t_crit_ps']:>15.2f} ps | {((base_stats['sta']['t_crit_ps']-ternary_stats['sta']['t_crit_ps'])/base_stats['sta']['t_crit_ps'])*100:>10.2f}%")
    print(f"{'Maximum Frequency (F_max)':<32} | {base_stats['sta']['f_max_mhz']:>14.1f} MHz | {ternary_stats['sta']['f_max_mhz']:>14.1f} MHz | {fmax_speedup_pct:>10.2f}%")
    print(f"{'Setup Slack @ 500 MHz (ps)':<32} | {base_stats['sta']['slack_500mhz_ps']:>15.2f} ps | {ternary_stats['sta']['slack_500mhz_ps']:>15.2f} ps | +{ternary_stats['sta']['slack_500mhz_ps']-base_stats['sta']['slack_500mhz_ps']:>9.2f} ps")
    print("=" * 80)
    print(f"Detailed PPA summary stored to: {out_json}")

if __name__ == "__main__":
    main()
