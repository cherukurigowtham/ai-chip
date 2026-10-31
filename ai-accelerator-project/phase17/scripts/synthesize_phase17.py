#!/usr/bin/env python3
"""
synthesize_phase17.py - Yosys Logic Synthesis for Phase 17 Timing Closure
Synthesizes accelerator_top (BUFFER_VECS=16, OUT_BUF_DEPTH=64) against Nangate 45nm library.
Targeting 500 MHz (2.0 ns period).
"""

import os
import subprocess
import re
import sys

RTL_DIR = os.path.abspath("ai-accelerator-project/phase17/rtl")
PDK_DIR = os.path.abspath("ai-accelerator-project/phase17/pdk")
SYNTH_DIR = os.path.abspath("ai-accelerator-project/phase17/synthesis")
os.makedirs(SYNTH_DIR, exist_ok=True)

RTL_FILES = [
    os.path.join(RTL_DIR, "pe_adaptive.sv"),
    os.path.join(RTL_DIR, "systolic_array_adaptive.sv"),
    os.path.join(RTL_DIR, "dynamic_config_reg.sv"),
    os.path.join(RTL_DIR, "dataflow_controller.sv"),
    os.path.join(RTL_DIR, "accelerator_top.sv")
]
LIB_FILE = os.path.join(PDK_DIR, "nangate45.lib")
OUT_RAW_NETLIST = os.path.join(SYNTH_DIR, "accelerator_top.raw.v")

def run_synthesis():
    print("=" * 80)
    print("  PHASE 17: RUNNING LOGIC SYNTHESIS WITH TIMING-OPTIMIZED ARITHMETIC")
    print("=" * 80)

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
write_verilog -noattr {OUT_RAW_NETLIST}
"""

    print("Executing Yosys...")
    res = subprocess.run(["yosys", "-p", ys_script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    out = res.stdout

    # Parse statistics
    area_matches = re.findall(r"Chip area for (?:top )?module [^\n:]*accelerator_top[^\n:]*:\s*([0-9\.]+)", out)
    if area_matches:
        non_zeros = [float(a) for a in area_matches if float(a) > 0.0]
        total_area = non_zeros[-1] if non_zeros else float(area_matches[-1])
        print(f"\n>>> Total Synthesized Area: {total_area:,.2f} µm²")

    cell_matches = re.findall(r"Number of cells:\s*([0-9]+)", out)
    if cell_matches:
        print(f">>> Total Cell Count: {int(cell_matches[-1]):,}")

    with open(os.path.join(SYNTH_DIR, "yosys_synth.log"), "w") as f:
        f.write(out)

    print(f"\nRaw synthesized netlist written to: {OUT_RAW_NETLIST}")
    print("=" * 80)

if __name__ == "__main__":
    run_synthesis()
