#!/usr/bin/env python3
"""
hierarchical_hfns.py - Hierarchical High Fanout Net Synthesis (HFNS) Buffer Tree Optimizer
Target: Nangate 45nm Open Cell Library (BUF_X4, BUF_X8, BUF_X16)
Constraint: Maximum fanout <= 16 for all non-clock signals across all hierarchical modules.
"""

import re
import sys
import os
from collections import defaultdict

def is_output_pin(cell_type, pin_name):
    if pin_name in ['Z', 'ZN', 'Q', 'QN', 'CO']:
        return True
    if pin_name == 'S' and ('FA_' in cell_type or 'HA_' in cell_type):
        return True
    return False

def parse_ports_balanced(s):
    ports = {}
    i = 0
    while i < len(s):
        m = re.search(r'\.([a-zA-Z0-9_$]+)\s*\(', s[i:])
        if not m:
            break
        pname = m.group(1)
        start_expr = i + m.end()
        depth = 1
        j = start_expr
        while j < len(s) and depth > 0:
            if s[j] == '(':
                depth += 1
            elif s[j] == ')':
                depth -= 1
            j += 1
        expr = s[start_expr:j-1].strip()
        ports[pname] = expr
        i = j
    return ports

def optimize_module(mod_name, mod_ports, mod_body, max_fanout=16, exclude_nets=('clk', 'vss', 'vdd')):
    print(f"\nProcessing module: {mod_name}")
    
    # 1. Parse wire/reg/input/output declarations
    decl_pattern = re.compile(r'^\s*(input|output|inout|wire|reg)\s+([^;]+);', re.MULTILINE)
    declarations = []
    for m in decl_pattern.finditer(mod_body):
        declarations.append(m.group(0))

    # 2. Extract assign statements
    assign_pattern = re.compile(r'assign\s+([^;]+);')
    assign_stmts = []
    for m in assign_pattern.finditer(mod_body):
        assign_stmts.append(m.group(0))

    # Remove wire/input/output declarations and assigns to isolate instances
    cleaned_body = decl_pattern.sub('', mod_body)
    cleaned_body = assign_pattern.sub('', cleaned_body)

    # 3. Parse cell instantiations
    inst_pattern = re.compile(r'(\S+)\s+(\S+)\s*\((.*?)\);', re.DOTALL)

    parsed_insts = []
    net_sinks = defaultdict(list)
    net_drivers = defaultdict(list)

    for match in inst_pattern.finditer(cleaned_body):
        cell_type, inst_name, ports_str = match.groups()
        if cell_type in ['input', 'output', 'inout', 'wire', 'reg', 'assign', 'module', 'endmodule']:
            continue
        
        port_conns = parse_ports_balanced(ports_str)
        for pname, netname in port_conns.items():
            if is_output_pin(cell_type, pname):
                net_drivers[netname].append((inst_name, cell_type, pname))
            else:
                # Only record as sink if it is a simple net identifier or bit select
                if not (netname.startswith('{') or netname.endswith('}')):
                    net_sinks[netname].append((inst_name, pname))

        parsed_insts.append({
            'cell_type': cell_type,
            'inst_name': inst_name,
            'ports': port_conns
        })

    print(f"  Parsed {len(parsed_insts):,} cell instances")

    # 4. Identify high-fanout nets
    high_fanout_nets = {}
    for net, sinks in net_sinks.items():
        if net in exclude_nets:
            continue
        if len(sinks) > max_fanout:
            high_fanout_nets[net] = sinks

    print(f"  Found {len(high_fanout_nets)} nets exceeding max fanout {max_fanout}")

    if not high_fanout_nets:
        return f"module {mod_name} ({mod_ports});\n{mod_body}\nendmodule\n"

    # 5. Generate buffer trees
    sink_replacement = {}
    new_buffers = []
    new_wires = []
    buf_id = 0

    sorted_hf = sorted(high_fanout_nets.items(), key=lambda x: len(x[1]), reverse=True)

    def fmt_net(n_str):
        return f"{n_str} " if n_str.startswith('\\') else n_str

    for net, sinks in sorted_hf:
        sanitized = re.sub(r'[^a-zA-Z0-9_]', '_', net)
        num_sinks = len(sinks)
        net_in = fmt_net(net)

        # Level 1 (leaf) buffers driving at most max_fanout sinks
        leaf_chunks = [sinks[i:i + max_fanout] for i in range(0, num_sinks, max_fanout)]
        num_leaf_buffers = len(leaf_chunks)

        leaf_net_info = []
        for g_idx, chunk in enumerate(leaf_chunks):
            leaf_buf = f"hfns_l1_{sanitized}_{g_idx}_{buf_id}"
            leaf_wire = f"hfns_w1_{sanitized}_{g_idx}_{buf_id}"
            new_wires.append(leaf_wire)
            leaf_net_info.append((leaf_buf, leaf_wire))

            for (inst, port) in chunk:
                sink_replacement[(inst, port)] = leaf_wire

        # Connect leaves to root or level 2 buffers
        if num_leaf_buffers <= max_fanout:
            # Single root buffer
            root_buf = f"hfns_root_{sanitized}_{buf_id}"
            root_wire = f"hfns_wroot_{sanitized}_{buf_id}"
            new_wires.append(root_wire)

            root_cell = "BUF_X16" if num_leaf_buffers > 8 else ("BUF_X8" if num_leaf_buffers > 4 else "BUF_X4")
            new_buffers.append(f"  {root_cell} {root_buf} ( .A({net_in}), .Z({root_wire}) );")

            for leaf_buf, leaf_wire in leaf_net_info:
                new_buffers.append(f"  BUF_X4 {leaf_buf} ( .A({root_wire}), .Z({leaf_wire}) );")
        else:
            # 2-level buffer tree
            l2_chunks = [leaf_net_info[i:i + max_fanout] for i in range(0, num_leaf_buffers, max_fanout)]
            l2_wires = []

            for l2_idx, l2_chunk in enumerate(l2_chunks):
                l2_buf = f"hfns_l2_{sanitized}_{l2_idx}_{buf_id}"
                l2_wire = f"hfns_w2_{sanitized}_{l2_idx}_{buf_id}"
                new_wires.append(l2_wire)
                l2_wires.append((l2_buf, l2_wire))

                for leaf_buf, leaf_wire in l2_chunk:
                    new_buffers.append(f"  BUF_X4 {leaf_buf} ( .A({l2_wire}), .Z({leaf_wire}) );")

            # Root buffer driving level 2 buffers
            root_buf = f"hfns_root_{sanitized}_{buf_id}"
            root_wire = f"hfns_wroot_{sanitized}_{buf_id}"
            new_wires.append(root_wire)

            root_cell = "BUF_X16" if len(l2_wires) > 8 else ("BUF_X8" if len(l2_wires) > 4 else "BUF_X4")
            new_buffers.append(f"  {root_cell} {root_buf} ( .A({net_in}), .Z({root_wire}) );")

            for l2_buf, l2_wire in l2_wires:
                new_buffers.append(f"  BUF_X8 {l2_buf} ( .A({root_wire}), .Z({l2_wire}) );")

        buf_id += 1

    print(f"  Inserted {len(new_buffers):,} buffer cells, {len(new_wires):,} internal wires")

    # 6. Rebuild module code
    out = []
    out.append(f"module {mod_name} ({mod_ports});\n")

    for d in declarations:
        out.append(f"  {d.strip()}\n")

    for a in assign_stmts:
        out.append(f"  {a.strip()}\n")

    # New wires
    for i in range(0, len(new_wires), 10):
        chunk = new_wires[i:i + 10]
        out.append(f"  wire {', '.join(chunk)};\n")

    out.append("\n  // --- HFNS Buffer Cells ---\n")
    for b in new_buffers:
        out.append(f"{b}\n")

    out.append("\n  // --- Standard Cells (Rerouted Sinks) ---\n")
    for inst in parsed_insts:
        ctype = inst['cell_type']
        iname = inst['inst_name']
        pconns = inst['ports']

        p_strs = []
        for p, n in pconns.items():
            rep = sink_replacement.get((iname, p), n)
            rep_str = f"{rep} " if rep.startswith('\\') else rep
            p_strs.append(f".{p}({rep_str})")

        out.append(f"  {ctype} {iname} ( {', '.join(p_strs)} );\n")

    out.append("endmodule\n")
    return "".join(out)

def run_hierarchical_hfns(input_netlist, output_netlist, max_fanout=16):
    print("=" * 80)
    print(f"  HIERARCHICAL HIGH FANOUT NET SYNTHESIS (HFNS)")
    print(f"  Input:      {input_netlist}")
    print(f"  Output:     {output_netlist}")
    print(f"  Max Fanout: {max_fanout}")
    print("=" * 80)

    with open(input_netlist, 'r') as f:
        content = f.read()

    # Split into modules
    mod_pattern = re.compile(r'module\s+(\S+)\s*\((.*?)\);(.*?)endmodule', re.DOTALL)
    
    optimized_modules = []
    mod_matches = list(mod_pattern.finditer(content))
    print(f"Found {len(mod_matches)} modules in netlist.\n")

    for m in mod_matches:
        mname, mports, mbody = m.groups()
        opt_mod = optimize_module(mname, mports, mbody, max_fanout=max_fanout)
        optimized_modules.append(opt_mod)

    with open(output_netlist, 'w') as f:
        for opt_m in optimized_modules:
            f.write(opt_m)
            f.write("\n")

    print("\n" + "=" * 80)
    print(f"Hierarchical HFNS Completed Successfully!")
    print(f"Output written to: {output_netlist} ({os.path.getsize(output_netlist):,} bytes)")
    print("=" * 80 + "\n")

if __name__ == "__main__":
    in_netlist = sys.argv[1] if len(sys.argv) > 1 else "ai-accelerator-project/phase16/netlist/accelerator_top.netlist.v"
    out_netlist = sys.argv[2] if len(sys.argv) > 2 else "ai-accelerator-project/phase17/synthesis/accelerator_top.hfns.v"
    mf = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    run_hierarchical_hfns(in_netlist, out_netlist, max_fanout=mf)
