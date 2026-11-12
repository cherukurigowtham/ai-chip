#!/usr/bin/env python3
"""
synth_runner.py - Automated Yosys Synthesis Runner against Nangate 45nm Library.

Synthesizes RTL modules and extracts:
- Total gate count
- DFF count & sequential area
- Combinational gate count & area
- Total silicon cell area (um^2)
"""

import os
import re
import subprocess
import tempfile
from typing import Dict, Any, Optional

DEFAULT_LIBERTY = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../phase9/synthesis/nangate45.lib"))

class SynthesisRunner:
    def __init__(self, liberty_path: str = DEFAULT_LIBERTY):
        assert os.path.exists(liberty_path), f"Liberty file not found: {liberty_path}"
        self.liberty_path = liberty_path

    def run_synthesis(self, verilog_files: list, top_module: str,
                      parameters: Optional[Dict[str, int]] = None) -> Dict[str, Any]:
        """
        Runs Yosys synthesis for given RTL files and top module.
        Returns parsed hardware statistics.
        """
        read_commands = "\n".join([f"read_verilog -sv {os.path.abspath(f)}" for f in verilog_files])
        param_cmd = ""
        if parameters:
            param_str = " ".join([f"-set {k} {v}" for k, v in parameters.items()])
            param_cmd = f"chparam {param_str} {top_module}"

        yosys_script = f"""
{read_commands}
{param_cmd}
hierarchy -top {top_module}
proc; opt; fsm; opt; memory; opt
techmap; opt
dfflibmap -liberty {self.liberty_path}
abc -liberty {self.liberty_path} -script +strash;map;print_stats
stat -liberty {self.liberty_path}
"""
        with tempfile.NamedTemporaryFile("w", suffix=".ys", delete=False) as f:
            script_path = f.name
            f.write(yosys_script)

        try:
            res = subprocess.run(["yosys", script_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=True)
            output = res.stdout
        finally:
            if os.path.exists(script_path):
                os.remove(script_path)

        stats = self._parse_yosys_output(output, top_module)
        return stats

    def _parse_yosys_output(self, output: str, top_module: str) -> Dict[str, Any]:
        """Parse Yosys stat report and ABC delay."""
        total_area = None
        seq_area = None
        dff_count = 0
        gate_count = 0
        abc_delay_ps = None

        # Extract ABC delay
        abc_delay_matches = re.findall(r"delay\s*=\s*([0-9\.]+)", output)
        if abc_delay_matches:
            # First match or PE match
            abc_delay_ps = float(abc_delay_matches[-1])

        # Extract total area (prefer non-zero top module total printed at end)
        area_matches = re.findall(r"Chip area for (?:top )?module [^\n:]*" + re.escape(top_module) + r"[^\n:]*:\s*([0-9\.]+)", output)
        if area_matches:
            non_zeros = [float(a) for a in area_matches if float(a) > 0.0]
            total_area = non_zeros[-1] if non_zeros else float(area_matches[-1])

        # Extract sequential area
        seq_match = re.search(r"of which used for sequential elements:\s*([0-9\.]+)", output)
        if seq_match:
            seq_area = float(seq_match.group(1))

        # Extract DFF count
        dff_matches = re.findall(r"^\s*([0-9]+)\s+[0-9\.\+E\-]+\s+DFF[A-Z0-9_]*", output, re.MULTILINE)
        dff_count = sum(int(m) for m in dff_matches)

        # Extract total cells
        cell_match = re.search(r"Number of cells:\s*([0-9]+)", output)
        if cell_match:
            gate_count = int(cell_match.group(1))

        comb_area = (total_area - seq_area) if (total_area is not None and seq_area is not None) else None

        return {
            "top_module": top_module,
            "total_area_um2": total_area,
            "sequential_area_um2": seq_area,
            "combinational_area_um2": comb_area,
            "dff_count": dff_count,
            "gate_count": gate_count,
            "abc_delay_ps": abc_delay_ps,
            "raw_output_snippet": output[-1200:]
        }

if __name__ == "__main__":
    runner = SynthesisRunner()
    files = [
        "ai-accelerator-project/phase14/rtl/pe_adaptive.sv"
    ]
    res = runner.run_synthesis(files, "pe_adaptive")
    print("PE Adaptive Synth Result:", res["total_area_um2"], "um^2, DFFs:", res["dff_count"], "Delay:", res["abc_delay_ps"], "ps")
