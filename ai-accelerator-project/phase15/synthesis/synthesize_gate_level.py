#!/usr/bin/env python3
"""
synthesize_gate_level.py - Gate-Level Synthesis for Phase 15 Physical Design.

Synthesizes accelerator_top (BUFFER_VECS=16, OUT_BUF_DEPTH=64) against Nangate 45nm
and exports:
- structural Verilog netlist: accelerator_top.netlist.v
- synthesis summary JSON: accelerator_top_synth.json
"""

import os
import subprocess
import json
import re

RTL_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../rtl"))
PDK_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../pdk"))
OUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../reports"))
os.makedirs(OUT_DIR, exist_ok=True)

RTL_FILES = [
    os.path.join(RTL_DIR, "pe_adaptive.sv"),
    os.path.join(RTL_DIR, "systolic_array_adaptive.sv"),
    os.path.join(RTL_DIR, "dynamic_config_reg.sv"),
    os.path.join(RTL_DIR, "dataflow_controller.sv"),
    os.path.join(RTL_DIR, "accelerator_top.sv")
]
LIB_FILE = os.path.join(PDK_DIR, "nangate45.lib")
OUT_NETLIST = os.path.join(OUT_DIR, "accelerator_top.netlist.v")
OUT_JSON = os.path.join(OUT_DIR, "accelerator_top_synth.json")

def run_gate_level_synthesis():
    read_cmds = "\n".join([f"read_verilog -sv {f}" for f in RTL_FILES])

    ys_script = f"""
{read_cmds}
chparam -set BUFFER_VECS 16 -set OUT_BUF_DEPTH 64 accelerator_top
hierarchy -top accelerator_top
proc; opt; fsm; opt; memory; opt
techmap; opt
dfflibmap -liberty {LIB_FILE}
abc -liberty {LIB_FILE} -script +strash;map
clean
stat -liberty {LIB_FILE}
write_verilog -noattr {OUT_NETLIST}
"""
    print("\n" + "="*80)
    print("  PHASE 15: RUNNING GATE-LEVEL LOGIC SYNTHESIS (YOSYS + NANGATE 45nm)")
    print("="*80)

    res = subprocess.run(["yosys", "-p", ys_script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    out = res.stdout

    # Parse statistics
    total_area = None
    area_matches = re.findall(r"Chip area for (?:top )?module [^\n:]*accelerator_top[^\n:]*:\s*([0-9\.]+)", out)
    if area_matches:
        non_zeros = [float(a) for a in area_matches if float(a) > 0.0]
        total_area = non_zeros[-1] if non_zeros else float(area_matches[-1])

    dff_matches = re.findall(r"^\s*([0-9]+)\s+[0-9\.\+E\-]+\s+DFF[A-Z0-9_]*", out, re.MULTILINE)
    dff_count = sum(int(m) for m in dff_matches)

    cell_matches = re.findall(r"Number of cells:\s*([0-9]+)", out)
    gate_count = int(cell_matches[-1]) if cell_matches else 0

    stats = {
        "design_name": "accelerator_top",
        "parameters": {"BUFFER_VECS": 16, "OUT_BUF_DEPTH": 64},
        "total_cell_area_um2": total_area,
        "dff_count": dff_count,
        "total_cells": gate_count,
        "netlist_path": OUT_NETLIST
    }

    with open(OUT_JSON, "w") as f:
        json.dump(stats, f, indent=2)

    print(f"Synthesis Successful!")
    print(f"  Gate Count:        {gate_count:,}")
    print(f"  Sequential DFFs:   {dff_count:,}")
    print(f"  Total Cell Area:   {total_area:,.2f} um^2")
    print(f"  Exported Netlist:  {OUT_NETLIST}")
    print("="*80 + "\n")

    return stats

if __name__ == "__main__":
    run_gate_level_synthesis()
