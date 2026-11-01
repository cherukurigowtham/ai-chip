#!/usr/bin/env python3
"""
synthesize_ternary_physical.py - Logic Synthesis & HFNS for accelerator_ternary_top
Target: Nangate 45nm Open Cell Library
Clock: 500 MHz (2.0 ns period)
"""

import os
import subprocess
import re
import sys

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
RTL_DIR = os.path.join(BASE_DIR, "ternary/rtl")
PDK_DIR = os.path.join(BASE_DIR, "ternary/physical/pdk")
SYNTH_DIR = os.path.join(BASE_DIR, "ternary/physical/synthesis")
SCRIPTS_DIR = os.path.join(BASE_DIR, "ternary/physical/scripts")
os.makedirs(SYNTH_DIR, exist_ok=True)

RTL_FILES = [
    os.path.join(BASE_DIR, "phase21/rtl/dynamic_config_reg.sv"),
    os.path.join(RTL_DIR, "pe_ternary.sv"),
    os.path.join(RTL_DIR, "ternary_weight_unpacker.sv"),
    os.path.join(RTL_DIR, "ternary_weight_buffer.sv"),
    os.path.join(RTL_DIR, "systolic_array_ternary.sv"),
    os.path.join(RTL_DIR, "ternary_controller.sv"),
    os.path.join(RTL_DIR, "accelerator_ternary_top.sv")
]
LIB_FILE = os.path.join(PDK_DIR, "nangate45.lib")
OUT_RAW_NETLIST = os.path.join(SYNTH_DIR, "accelerator_ternary_top.raw.v")
OUT_HFNS_NETLIST = os.path.join(SYNTH_DIR, "accelerator_ternary_top.final_hfns.v")

def run_synthesis():
    print("=" * 80)
    print("  PHASE 7 PHYSICAL: RUNNING LOGIC SYNTHESIS FOR accelerator_ternary_top")
    print("=" * 80)

    read_cmds = "\n".join([f"read_verilog -sv {f}" for f in RTL_FILES])

    ys_script = f"""
{read_cmds}
chparam -set BUFFER_VECS 16 -set OUT_BUF_DEPTH 64 accelerator_ternary_top
hierarchy -top accelerator_ternary_top
proc; opt; fsm; opt; memory; opt
techmap; opt
dfflibmap -liberty {LIB_FILE}
abc -liberty {LIB_FILE} -script +strash;map
clean
stat -liberty {LIB_FILE}
write_verilog -noattr {OUT_RAW_NETLIST}
"""

    print("Executing Yosys Logic Synthesis...")
    res = subprocess.run(["yosys", "-p", ys_script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
    out = res.stdout

    # Parse statistics
    area_matches = re.findall(r"Chip area for (?:top )?module [^\n:]*accelerator_ternary_top[^\n:]*:\s*([0-9\.]+)", out)
    if area_matches:
        non_zeros = [float(a) for a in area_matches if float(a) > 0.0]
        total_area = non_zeros[-1] if non_zeros else float(area_matches[-1])
        print(f"\n>>> Total Synthesized Standard Cell Area: {total_area:,.2f} µm²")

    cell_matches = re.findall(r"Number of cells:\s*([0-9]+)", out)
    if cell_matches:
        print(f">>> Total Cell Count: {int(cell_matches[-1]):,}")

    with open(os.path.join(SYNTH_DIR, "yosys_synth.log"), "w") as f:
        f.write(out)

    print(f"\nRaw synthesized netlist written to: {OUT_RAW_NETLIST}")

    # Strip 'signed' keywords from gate-level netlist for OpenROAD/OpenSTA compatibility
    with open(OUT_RAW_NETLIST, "r") as f:
        raw_content = f.read()
    raw_content = re.sub(r'\binput\s+signed\b', 'input', raw_content)
    raw_content = re.sub(r'\boutput\s+signed\b', 'output', raw_content)
    raw_content = re.sub(r'\bwire\s+signed\b', 'wire', raw_content)
    with open(OUT_RAW_NETLIST, "w") as f:
        f.write(raw_content)

    print("\nExecuting Hierarchical High-Fanout Net Synthesis (HFNS)...")
    hfns_script = os.path.join(SCRIPTS_DIR, "hierarchical_hfns.py")
    subprocess.run([
        sys.executable, hfns_script,
        OUT_RAW_NETLIST,
        OUT_HFNS_NETLIST,
        "16"
    ], check=True)

    print(f"\n>>> Final Buffered Gate-Level Netlist: {OUT_HFNS_NETLIST}")
    print("=" * 80)

if __name__ == "__main__":
    run_synthesis()
