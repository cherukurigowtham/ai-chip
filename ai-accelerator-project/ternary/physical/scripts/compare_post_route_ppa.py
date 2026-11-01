#!/usr/bin/env python3
"""
compare_post_route_ppa.py - Full Post-Route PPA & Silicon Verification Benchmark:
Baseline Adaptive Binary Accelerator (phase21) vs.
Complete Hybrid Binary-Ternary Accelerator (ternary/physical)
Platform: Genuine OpenROAD 26Q4 on Nangate 45nm Open Cell Library
Target: 500 MHz (2.0 ns clock period, post-SPEF extracted RC parasitics)
"""

import os
import re
import json
import sys

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))
BASE_PNR_DIR = os.path.join(BASE_DIR, "ai-accelerator-project/phase21/openroad_run")
TERNARY_PNR_DIR = os.path.join(BASE_DIR, "ai-accelerator-project/ternary/physical/openroad_run")
REPORTS_DIR = os.path.join(BASE_DIR, "ai-accelerator-project/ternary/physical/reports")
os.makedirs(REPORTS_DIR, exist_ok=True)

def parse_pnr_log(log_path):
    data = {
        "num_instances": 0,
        "inst_area_um2": 0.0,
        "core_area_um2": 0.0,
        "die_area_um2": 0.0,
        "core_utilization": 0.0,
        "die_dim_um": (0.0, 0.0),
        "total_nets": 0,
        "total_pins": 0,
        "hpwl_um": 0.0,
        "wirelength_um": 0.0
    }
    if not os.path.exists(log_path):
        return data

    with open(log_path, "r") as f:
        content = f.read()

    m_inst = re.search(r"Number of instances:\s*(\d+)", content)
    if m_inst:
        data["num_instances"] = int(m_inst.group(1))

    m_inst_area = re.search(r"Total instances area:\s*([0-9\.]+)\s*um\^2", content)
    if m_inst_area:
        data["inst_area_um2"] = float(m_inst_area.group(1))

    m_core_area = re.search(r"Core area:\s*([0-9\.]+)\s*um\^2", content)
    if m_core_area:
        data["core_area_um2"] = float(m_core_area.group(1))

    m_die = re.search(r"Die BBox:\s*\(\s*0\.000\s*0\.000\s*\)\s*\(\s*([0-9\.]+)\s*([0-9\.]+)\s*\)", content)
    if m_die:
        w = float(m_die.group(1))
        h = float(m_die.group(2))
        data["die_dim_um"] = (w, h)
        data["die_area_um2"] = w * h

    m_util = re.search(r"Effective utilization:\s*([0-9\.]+)", content)
    if m_util:
        data["core_utilization"] = float(m_util.group(1))

    m_nets = re.search(r"Number of nets:\s*(\d+)", content)
    if m_nets:
        data["total_nets"] = int(m_nets.group(1))

    m_pins = re.search(r"Number of pins:\s*(\d+)", content)
    if m_pins:
        data["total_pins"] = int(m_pins.group(1))

    m_hpwl = re.search(r"legalized HPWL\s*([0-9\.]+)\s*u", content)
    if m_hpwl:
        data["hpwl_um"] = float(m_hpwl.group(1))

    return data

def parse_power(power_path):
    power = {
        "sequential_mw": 0.0,
        "combinational_mw": 0.0,
        "clock_mw": 0.0,
        "total_mw": 0.0,
        "internal_mw": 0.0,
        "switching_mw": 0.0,
        "leakage_mw": 0.0
    }
    if not os.path.exists(power_path):
        return power

    with open(power_path, "r") as f:
        for line in f:
            if "Sequential" in line:
                parts = line.split()
                if len(parts) >= 5:
                    power["sequential_mw"] = float(parts[4]) * 1e3
            elif "Combinational" in line:
                parts = line.split()
                if len(parts) >= 5:
                    power["combinational_mw"] = float(parts[4]) * 1e3
            elif "Clock" in line:
                parts = line.split()
                if len(parts) >= 5:
                    power["clock_mw"] = float(parts[4]) * 1e3
            elif line.strip().startswith("Total"):
                parts = line.split()
                if len(parts) >= 5:
                    power["internal_mw"] = float(parts[1]) * 1e3
                    power["switching_mw"] = float(parts[2]) * 1e3
                    power["leakage_mw"] = float(parts[3]) * 1e3
                    power["total_mw"] = float(parts[4]) * 1e3
    return power

def parse_timing(dir_path):
    timing = {
        "wns_setup_ns": 0.0,
        "tns_setup_ns": 0.0,
        "wns_hold_ns": 0.0,
        "f_max_mhz": 0.0,
        "critical_path_ps": 0.0,
        "clock_skew_ns": 0.0,
        "meets_500mhz": False
    }

    wns_file = os.path.join(dir_path, "post_route_constrained_wns.rpt")
    if os.path.exists(wns_file):
        with open(wns_file) as f:
            m = re.search(r"worst slack max\s*([-0-9\.]+)", f.read())
            if m:
                timing["wns_setup_ns"] = float(m.group(1))

    hold_file = os.path.join(dir_path, "post_route_constrained_hold.rpt")
    if os.path.exists(hold_file):
        with open(hold_file) as f:
            m = re.search(r"worst slack min\s*([-0-9\.]+)", f.read())
            if m:
                timing["wns_hold_ns"] = float(m.group(1))

    tns_file = os.path.join(dir_path, "post_route_constrained_tns.rpt")
    if os.path.exists(tns_file):
        with open(tns_file) as f:
            m = re.search(r"tns max\s*([-0-9\.]+)", f.read())
            if m:
                timing["tns_setup_ns"] = float(m.group(1))

    skew_file = os.path.join(dir_path, "post_route_clock_skew.rpt")
    if os.path.exists(skew_file):
        with open(skew_file) as f:
            m = re.search(r"clock skew\s*([-0-9\.]+)", f.read())
            if m:
                timing["clock_skew_ns"] = float(m.group(1))

    # Critical path & Fmax: Clock period is 2.0 ns (2000 ps)
    # Slack = Period - Delay - Uncertainty => Delay + Uncertainty = Period - Slack
    period_ps = 2000.0
    crit_path_ps = period_ps - (timing["wns_setup_ns"] * 1000.0)
    timing["critical_path_ps"] = round(crit_path_ps, 2)
    timing["f_max_mhz"] = round(1e6 / crit_path_ps, 1)
    timing["meets_500mhz"] = (timing["wns_setup_ns"] >= 0.0)

    return timing

def parse_drc(drc_path):
    if not os.path.exists(drc_path):
        return -1
    with open(drc_path) as f:
        content = f.read().strip()
    if not content:
        return 0
    # Count violations
    return len(content.splitlines())

def main():
    print("=" * 84)
    print("      POST-ROUTE PPA BENCHMARK: BASELINE BINARY VS TERNARY ACCELERATOR")
    print("      Genuine OpenROAD Physical Implementation (Nangate 45nm, 500 MHz Target)")
    print("=" * 84)

    base_log = parse_pnr_log(os.path.join(BASE_PNR_DIR, "pnr_run.log"))
    tern_log = parse_pnr_log(os.path.join(TERNARY_PNR_DIR, "pnr_run.log"))

    base_pwr = parse_power(os.path.join(BASE_PNR_DIR, "post_route_power.rpt"))
    tern_pwr = parse_power(os.path.join(TERNARY_PNR_DIR, "post_route_power.rpt"))

    base_time = parse_timing(BASE_PNR_DIR)
    tern_time = parse_timing(TERNARY_PNR_DIR)

    base_drc = parse_drc(os.path.join(BASE_PNR_DIR, "drc.rpt"))
    tern_drc = parse_drc(os.path.join(TERNARY_PNR_DIR, "drc.rpt"))

    # Compute Deltas & Improvements
    inst_area_red_pct = ((base_log["inst_area_um2"] - tern_log["inst_area_um2"]) / base_log["inst_area_um2"]) * 100.0 if base_log["inst_area_um2"] else 0.0
    die_area_red_pct  = ((base_log["die_area_um2"] - tern_log["die_area_um2"]) / base_log["die_area_um2"]) * 100.0 if base_log["die_area_um2"] else 0.0
    core_area_red_pct = ((base_log["core_area_um2"] - tern_log["core_area_um2"]) / base_log["core_area_um2"]) * 100.0 if base_log["core_area_um2"] else 0.0
    inst_count_red_pct = ((base_log["num_instances"] - tern_log["num_instances"]) / base_log["num_instances"]) * 100.0 if base_log["num_instances"] else 0.0
    power_red_pct = ((base_pwr["total_mw"] - tern_pwr["total_mw"]) / base_pwr["total_mw"]) * 100.0 if base_pwr["total_mw"] else 0.0
    wirelength_red_pct = ((base_log["hpwl_um"] - tern_log["hpwl_um"]) / base_log["hpwl_um"]) * 100.0 if base_log["hpwl_um"] else 0.0

    # Energy per 4x4 GEMM tile: 18 cycles @ 2.0 ns
    cycles = 18
    base_energy_nj = (base_pwr["total_mw"] * 1e-3) * (cycles * 2.0e-9) * 1e9
    tern_energy_nj = (tern_pwr["total_mw"] * 1e-3) * (cycles * 2.0e-9) * 1e9
    energy_red_pct = ((base_energy_nj - tern_energy_nj) / base_energy_nj) * 100.0 if base_energy_nj else 0.0

    print(f"{'Physical Metric':<34} | {'Baseline Binary (Phase 21)':<22} | {'Ternary Core (Phase 7)':<22} | {'Improvement'}")
    print("-" * 96)
    print(f"{'Routed Die Area (um^2)':<34} | {base_log['die_area_um2']:>16.2f} um2   | {tern_log['die_area_um2']:>16.2f} um2   | {die_area_red_pct:>6.2f}%")
    print(f"{'Routed Core Area (um^2)':<34} | {base_log['core_area_um2']:>16.2f} um2   | {tern_log['core_area_um2']:>16.2f} um2   | {core_area_red_pct:>6.2f}%")
    print(f"{'Placed Standard Cell Area':<34} | {base_log['inst_area_um2']:>16.2f} um2   | {tern_log['inst_area_um2']:>16.2f} um2   | {inst_area_red_pct:>6.2f}%")
    print(f"{'Placed Instance Count':<34} | {base_log['num_instances']:>19d}    | {tern_log['num_instances']:>19d}    | {inst_count_red_pct:>6.2f}%")
    print(f"{'Effective Core Utilization':<34} | {base_log['core_utilization']*100:>18.1f} %    | {tern_log['core_utilization']*100:>18.1f} %    | 55.0% Target")
    print(f"{'Die Dimensions (X x Y)':<34} | {base_log['die_dim_um'][0]:.1f} x {base_log['die_dim_um'][1]:.1f} um     | {tern_log['die_dim_um'][0]:.1f} x {tern_log['die_dim_um'][1]:.1f} um     | Compact Die")
    print(f"{'Legalized Wirelength (HPWL)':<34} | {base_log['hpwl_um']:>16.1f} um    | {tern_log['hpwl_um']:>16.1f} um    | {wirelength_red_pct:>6.2f}%")
    print(f"{'Post-Route Worst Setup Slack':<34} | {base_time['wns_setup_ns']:>17.4f} ns   | {tern_time['wns_setup_ns']:>17.4f} ns   | {'MET' if tern_time['meets_500mhz'] else 'VIOLATED'}")
    print(f"{'Post-Route Worst Hold Slack':<34} | {base_time['wns_hold_ns']:>17.4f} ns   | {tern_time['wns_hold_ns']:>17.4f} ns   | {'Clean' if tern_time['wns_hold_ns'] >= 0 else 'Hold'}")
    print(f"{'Extracted Critical Path Delay':<34} | {base_time['critical_path_ps']:>16.2f} ps   | {tern_time['critical_path_ps']:>16.2f} ps   | {((base_time['critical_path_ps']-tern_time['critical_path_ps'])/base_time['critical_path_ps'])*100:>6.2f}%")
    print(f"{'Post-Route Max Frequency':<34} | {base_time['f_max_mhz']:>16.1f} MHz  | {tern_time['f_max_mhz']:>16.1f} MHz  | 500 MHz Target")
    print(f"{'Routing DRC Violations':<34} | {base_drc:>19d}    | {tern_drc:>19d}    | {'PASS' if tern_drc == 0 else 'FAIL'}")
    print(f"{'Total Extracted Power':<34} | {base_pwr['total_mw']:>16.2f} mW   | {tern_pwr['total_mw']:>16.2f} mW   | {power_red_pct:>6.2f}%")
    print(f"{'  - Sequential Power':<34} | {base_pwr['sequential_mw']:>16.2f} mW   | {tern_pwr['sequential_mw']:>16.2f} mW   | -")
    print(f"{'  - Combinational Power':<34} | {base_pwr['combinational_mw']:>16.2f} mW   | {tern_pwr['combinational_mw']:>16.2f} mW   | -")
    print(f"{'  - Clock Tree Power':<34} | {base_pwr['clock_mw']:>16.2f} mW   | {tern_pwr['clock_mw']:>16.2f} mW   | -")
    print(f"{'Post-Route Energy / Inference':<34} | {base_energy_nj:>16.3f} nJ   | {tern_energy_nj:>16.3f} nJ   | {energy_red_pct:>6.2f}%")
    print("=" * 96)

    out_data = {
        "baseline_binary_phase21": {
            "log": base_log,
            "power": base_pwr,
            "timing": base_time,
            "drc": base_drc,
            "energy_nj": base_energy_nj
        },
        "ternary_accelerator_phase7": {
            "log": tern_log,
            "power": tern_pwr,
            "timing": tern_time,
            "drc": tern_drc,
            "energy_nj": tern_energy_nj
        },
        "comparison_deltas": {
            "die_area_reduction_pct": round(die_area_red_pct, 2),
            "core_area_reduction_pct": round(core_area_red_pct, 2),
            "cell_area_reduction_pct": round(inst_area_red_pct, 2),
            "instance_count_reduction_pct": round(inst_count_red_pct, 2),
            "wirelength_reduction_pct": round(wirelength_red_pct, 2),
            "power_reduction_pct": round(power_red_pct, 2),
            "energy_reduction_pct": round(energy_red_pct, 2),
            "passes_phase7_criteria": (tern_drc == 0 and tern_time["meets_500mhz"] and die_area_red_pct >= 30.0 and power_red_pct >= 30.0)
        }
    }

    out_json = os.path.join(REPORTS_DIR, "post_route_ppa_comparison.json")
    with open(out_json, "w") as f:
        json.dump(out_data, f, indent=2)
    print(f"Post-route comparative report written to: {out_json}")

if __name__ == "__main__":
    main()
