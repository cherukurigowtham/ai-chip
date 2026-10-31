#!/usr/bin/env python3
"""
hfns_optimizer.py - High Fanout Net Synthesis (HFNS) Buffer Tree Insertion Tool
Author: AI Accelerator Physical Design Team
Target: Nangate 45nm Open Cell Library (BUF_X4, BUF_X8, BUF_X16)
Constraint: Maximum fanout <= 16 for all non-clock signals.
"""

import re
import sys
import os
from collections import defaultdict

def run_hfns(input_netlist, output_netlist, max_fanout=16, exclude_nets=('clk', 'vss', 'vdd')):
    print("=" * 80)
    print(f"  HIGH FANOUT NET SYNTHESIS (HFNS) OPTIMIZER (MAX_FANOUT = {max_fanout})")
    print(f"  Input:  {input_netlist}")
    print(f"  Output: {output_netlist}")
    print("=" * 80)

    with open(input_netlist, 'r') as f:
        text = f.read()

    # Find the top module definition
    # Pattern to match: module accelerator_top (...); ... endmodule
    module_match = re.search(r'module\s+(\w+)\s*\((.*?)\);(.*?)endmodule', text, re.DOTALL)
    if not module_match:
        raise ValueError("Could not find module definition in netlist")

    mod_name, mod_ports, mod_body = module_match.groups()

    # Parse all cell instantiations in mod_body
    # Cell instantiation pattern: CELL_TYPE INST_NAME ( .PORT(NET), ... );
    inst_pattern = re.compile(r'(\w+)\s+(\S+)\s*\((.*?)\);', re.DOTALL)
    port_pattern = re.compile(r'\.(\w+)\s*\(\s*(\S+?)\s*\)')

    # We want to identify for each net:
    # 1. Driver pin (output of a cell or input port of module)
    # 2. Sink pins: list of (inst_name, port_name, full_port_text_slice)
    
    # Store instances and their connections
    instances = []
    net_sinks = defaultdict(list)
    net_drivers = defaultdict(list)

    # Clean comments inside mod_body
    clean_body = re.sub(r'//.*', '', mod_body)
    clean_body = re.sub(r'/\*.*?\*/', '', clean_body, flags=re.DOTALL)

    # Extract all wire/reg declarations
    wire_decls = []
    non_inst_statements = []

    pos = 0
    parsed_insts = []
    
    # Output pins in Nangate 45nm
    OUT_PINS = {'Z', 'ZN', 'Q', 'QN', 'CO', 'S'}

    for match in inst_pattern.finditer(clean_body):
        cell_type, inst_name, ports_str = match.groups()
        start_idx, end_idx = match.span()

        # Check if this is a wire or reg or assign statement rather than cell instantiation
        if cell_type in ['input', 'output', 'inout', 'wire', 'reg', 'assign']:
            continue

        port_conns = {}
        for pm in port_pattern.finditer(ports_str):
            pname, netname = pm.groups()
            port_conns[pname] = netname
            if pname in OUT_PINS:
                net_drivers[netname].append((inst_name, cell_type, pname))
            else:
                net_sinks[netname].append((inst_name, pname))

        parsed_insts.append({
            'cell_type': cell_type,
            'inst_name': inst_name,
            'ports': port_conns,
            'span': (start_idx, end_idx),
            'raw': match.group(0)
        })

    print(f"Total standard cell instances parsed: {len(parsed_insts):,}")

    # Identify nets exceeding max_fanout
    high_fanout_nets = {}
    for net, sinks in net_sinks.items():
        if net in exclude_nets:
            continue
        if len(sinks) > max_fanout:
            high_fanout_nets[net] = sinks

    print(f"Identified {len(high_fanout_nets)} nets with fanout > {max_fanout}")
    print(f"Top 10 highest fanout nets:")
    sorted_hf = sorted(high_fanout_nets.items(), key=lambda x: len(x[1]), reverse=True)
    for net, sinks in sorted_hf[:10]:
        print(f"  {net:<30}: {len(sinks):>5} loads")

    # Generate buffer trees for high fanout nets
    # We will build a replacement mapping for sink connections
    # (inst_name, port_name) -> new_net_name
    sink_replacement = {}
    new_buffers = []
    new_wires = []

    buffer_count = 0
    
    for net, sinks in sorted_hf:
        sanitized_net = re.sub(r'[^a-zA-Z0-9_]', '_', net)
        num_sinks = len(sinks)

        # Build multi-level buffer tree if needed
        # Level 1: Leaf buffers driving up to max_fanout sinks
        leaf_chunks = [sinks[i:i + max_fanout] for i in range(0, num_sinks, max_fanout)]
        num_leaf_buffers = len(leaf_chunks)

        leaf_net_names = []
        for g_idx, chunk in enumerate(leaf_chunks):
            leaf_buf_name = f"hfns_l1_{sanitized_net}_{g_idx}"
            leaf_out_net = f"hfns_n1_{sanitized_net}_{g_idx}"
            leaf_in_net = None # to be wired to level 2 or root driver

            new_wires.append(leaf_out_net)
            leaf_net_names.append((leaf_buf_name, leaf_out_net))

            for (inst, port) in chunk:
                sink_replacement[(inst, port)] = leaf_out_net

        # If number of leaf buffers <= max_fanout, connect them directly to root driver via BUF_X16 root buffer
        if num_leaf_buffers <= max_fanout:
            # We can have a single root buffer BUF_X16 driving all leaf buffers
            root_buf_name = f"hfns_root_{sanitized_net}"
            root_out_net = f"hfns_nroot_{sanitized_net}"
            new_wires.append(root_out_net)

            # Root buffer: input is original net, output is root_out_net
            # Use BUF_X16 if > 8 leaves, BUF_X8 if > 4, BUF_X4 otherwise
            root_cell = "BUF_X16" if num_leaf_buffers > 8 else ("BUF_X8" if num_leaf_buffers > 4 else "BUF_X4")
            new_buffers.append(f"  {root_cell} {root_buf_name} ( .A({net}), .Z({root_out_net}) );")
            buffer_count += 1

            # Each leaf buffer has input root_out_net, output leaf_out_net
            for leaf_buf_name, leaf_out_net in leaf_net_names:
                new_buffers.append(f"  BUF_X4 {leaf_buf_name} ( .A({root_out_net}), .Z({leaf_out_net}) );")
                buffer_count += 1
        else:
            # 2-level tree: Level 2 buffers driving groups of leaf buffers
            l2_chunks = [leaf_net_names[i:i + max_fanout] for i in range(0, num_leaf_buffers, max_fanout)]
            l2_net_names = []

            for l2_idx, l2_chunk in enumerate(l2_chunks):
                l2_buf_name = f"hfns_l2_{sanitized_net}_{l2_idx}"
                l2_out_net = f"hfns_n2_{sanitized_net}_{l2_idx}"
                new_wires.append(l2_out_net)
                l2_net_names.append((l2_buf_name, l2_out_net))

                # Each leaf buffer in this chunk connects its .A to l2_out_net
                for leaf_buf_name, leaf_out_net in l2_chunk:
                    new_buffers.append(f"  BUF_X4 {leaf_buf_name} ( .A({l2_out_net}), .Z({leaf_out_net}) );")
                    buffer_count += 1

            # Root buffer drives the Level 2 buffers
            root_buf_name = f"hfns_root_{sanitized_net}"
            root_out_net = f"hfns_nroot_{sanitized_net}"
            new_wires.append(root_out_net)

            root_cell = "BUF_X16" if len(l2_net_names) > 8 else ("BUF_X8" if len(l2_net_names) > 4 else "BUF_X4")
            new_buffers.append(f"  {root_cell} {root_buf_name} ( .A({net}), .Z({root_out_net}) );")
            buffer_count += 1

            for l2_buf_name, l2_out_net in l2_net_names:
                new_buffers.append(f"  BUF_X8 {l2_buf_name} ( .A({root_out_net}), .Z({l2_out_net}) );")
                buffer_count += 1

    print(f"\nHFNS Buffer Tree Generation Summary:")
    print(f"  Inserted Buffer Cells: {buffer_count:,}")
    print(f"  Created Internal Wires: {len(new_wires):,}")
    print(f"  Re-routed Sinks:        {len(sink_replacement):,}")

    # Reconstruct the structural netlist
    # In each cell instantiation, update modified sink ports
    print("\nReconstructing Verilog structural netlist...")
    out_lines = []
    
    # Header: module declaration
    out_lines.append(f"module {mod_name} ({mod_ports});\n")

    # Wire declarations: collect existing and add new
    existing_wires = re.findall(r'(?:input|output|inout|wire|reg)\s+[^;]+;', mod_body)
    for ew in existing_wires:
        out_lines.append(f"  {ew.strip()}\n")

    # Chunk new wires in groups of 10 for clean Verilog
    for i in range(0, len(new_wires), 10):
        chunk = new_wires[i:i + 10]
        out_lines.append(f"  wire {', '.join(chunk)};\n")

    out_lines.append("\n  // =========================================================================\n")
    out_lines.append("  // High Fanout Net Synthesis (HFNS) Buffer Trees\n")
    out_lines.append("  // =========================================================================\n")
    for buf_stmt in new_buffers:
        out_lines.append(f"{buf_stmt}\n")

    out_lines.append("\n  // =========================================================================\n")
    out_lines.append("  // Standard Cell Gate Netlist (With Buffer Tree Connections)\n")
    out_lines.append("  // =========================================================================\n")

    for inst in parsed_insts:
        c_type = inst['cell_type']
        i_name = inst['inst_name']
        p_dict = inst['ports']

        # Check if any port needs replacement
        port_strings = []
        for pname, netname in p_dict.items():
            rep = sink_replacement.get((i_name, pname), netname)
            port_strings.append(f".{pname}({rep})")

        out_lines.append(f"  {c_type} {i_name} ( {', '.join(port_strings)} );\n")

    out_lines.append("endmodule\n")

    with open(output_netlist, 'w') as f:
        f.writelines(out_lines)

    print(f"Successfully generated optimized netlist: {output_netlist}")
    print(f"File size: {os.path.getsize(output_netlist):,} bytes")
    print("=" * 80 + "\n")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 hfns_optimizer.py <input.netlist.v> <output.netlist.v> [max_fanout]")
        sys.exit(1)
    
    mf = int(sys.argv[3]) if len(sys.argv) > 3 else 16
    run_hfns(sys.argv[1], sys.argv[2], max_fanout=mf)
EOF