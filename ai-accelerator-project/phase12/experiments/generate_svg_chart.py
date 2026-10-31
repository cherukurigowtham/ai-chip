#!/usr/bin/env python3
"""
generate_svg_chart.py - Generates an SVG chart comparing WS vs OS and Adaptive benefits.
"""
import csv

def generate_svg():
    csv_file = "ai-accelerator-project/phase12/results/dataflow_comparison.csv"
    rows = []
    with open(csv_file, "r") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(r)

    svg_width = 1000
    svg_height = 650

    svg = []
    svg.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {svg_width} {svg_height}" width="{svg_width}" height="{svg_height}">')
    svg.append('<rect width="100%" height="100%" fill="#ffffff" />')

    # Title
    svg.append('<text x="500" y="40" font-family="Arial, sans-serif" font-size="22" font-weight="bold" text-anchor="middle" fill="#1e293b">Phase 12: Adaptive Dataflow Optimization (WS vs OS)</text>')
    svg.append('<text x="500" y="65" font-family="Arial, sans-serif" font-size="13" text-anchor="middle" fill="#64748b">Cross-Workload Energy, MAC Utilization, and Traffic Comparison (Nangate 45nm @ 500 MHz)</text>')

    # Panel 1: MAC Utilization Comparison (x: 60, y: 110, w: 420, h: 220)
    svg.append('<g id="panel1" transform="translate(60, 110)">')
    svg.append('<rect width="420" height="220" fill="#f8fafc" rx="8" stroke="#e2e8f0" stroke-width="1"/>')
    svg.append('<text x="210" y="25" font-family="Arial, sans-serif" font-size="14" font-weight="bold" text-anchor="middle" fill="#0f172a">MAC Utilization (%)</text>')

    # Y-axis ticks (0 to 80%)
    for p in [0, 20, 40, 60, 80]:
        y = 180 - (p / 80.0) * 140
        svg.append(f'<line x1="45" y1="{y}" x2="400" y2="{y}" stroke="#e2e8f0" stroke-dasharray="3,3" />')
        svg.append(f'<text x="40" y="{y+4}" font-family="Arial, sans-serif" font-size="10" text-anchor="end" fill="#94a3b8">{p}%</text>')

    for i, r in enumerate(rows):
        x = 55 + i * 70
        ws_u = float(r["WS_Util_%"])
        os_u = float(r["OS_Util_%"])
        h_ws = (ws_u / 80.0) * 140
        h_os = (os_u / 80.0) * 140

        svg.append(f'<rect x="{x}" y="{180-h_ws}" width="18" height="{h_ws}" fill="#3b82f6" rx="2"/>')
        svg.append(f'<rect x="{x+22}" y="{180-h_os}" width="18" height="{h_os}" fill="#f97316" rx="2"/>')

        name_short = r["Workload"].split()[0]
        svg.append(f'<text x="{x+20}" y="200" font-family="Arial, sans-serif" font-size="10" text-anchor="middle" fill="#475569">{name_short}</text>')

    # Legend
    svg.append('<rect x="130" y="40" width="12" height="12" fill="#3b82f6" rx="2"/>')
    svg.append('<text x="148" y="50" font-family="Arial, sans-serif" font-size="11" fill="#334155">Weight-Stationary</text>')
    svg.append('<rect x="260" y="40" width="12" height="12" fill="#f97316" rx="2"/>')
    svg.append('<text x="278" y="50" font-family="Arial, sans-serif" font-size="11" fill="#334155">Output-Stationary</text>')
    svg.append('</g>')

    # Panel 2: Total Energy Consumption (x: 520, y: 110, w: 420, h: 220)
    svg.append('<g id="panel2" transform="translate(520, 110)">')
    svg.append('<rect width="420" height="220" fill="#f8fafc" rx="8" stroke="#e2e8f0" stroke-width="1"/>')
    svg.append('<text x="210" y="25" font-family="Arial, sans-serif" font-size="14" font-weight="bold" text-anchor="middle" fill="#0f172a">Total Energy (uJ)</text>')

    for p, val in [(0, 0.0), (35, 0.5), (70, 1.0), (105, 1.5), (140, 2.0)]:
        y = 180 - p
        svg.append(f'<line x1="45" y1="{y}" x2="400" y2="{y}" stroke="#e2e8f0" stroke-dasharray="3,3" />')
        svg.append(f'<text x="40" y="{y+4}" font-family="Arial, sans-serif" font-size="10" text-anchor="end" fill="#94a3b8">{val:.1f}</text>')

    for i, r in enumerate(rows):
        x = 55 + i * 70
        ws_e = float(r["WS_Energy_uJ"])
        os_e = float(r["OS_Energy_uJ"])
        h_ws = min((ws_e / 2.0) * 140, 140)
        h_os = min((os_e / 2.0) * 140, 140)

        svg.append(f'<rect x="{x}" y="{180-h_ws}" width="18" height="{h_ws}" fill="#3b82f6" rx="2"/>')
        svg.append(f'<rect x="{x+22}" y="{180-h_os}" width="18" height="{h_os}" fill="#f97316" rx="2"/>')

        name_short = r["Workload"].split()[0]
        svg.append(f'<text x="{x+20}" y="200" font-family="Arial, sans-serif" font-size="10" text-anchor="middle" fill="#475569">{name_short}</text>')

    svg.append('</g>')

    # Panel 3: DRAM Memory Words Moved (x: 60, y: 360, w: 420, h: 250)
    svg.append('<g id="panel3" transform="translate(60, 360)">')
    svg.append('<rect width="420" height="250" fill="#f8fafc" rx="8" stroke="#e2e8f0" stroke-width="1"/>')
    svg.append('<text x="210" y="25" font-family="Arial, sans-serif" font-size="14" font-weight="bold" text-anchor="middle" fill="#0f172a">DRAM Memory Traffic (Words Moved)</text>')

    for p, val in [(0, "0"), (35, "3k"), (70, "6k"), (105, "9k"), (140, "12k")]:
        y = 200 - p
        svg.append(f'<line x1="45" y1="{y}" x2="400" y2="{y}" stroke="#e2e8f0" stroke-dasharray="3,3" />')
        svg.append(f'<text x="40" y="{y+4}" font-family="Arial, sans-serif" font-size="10" text-anchor="end" fill="#94a3b8">{val}</text>')

    for i, r in enumerate(rows):
        x = 55 + i * 70
        ws_w = float(r["WS_DRAM_Words"])
        os_w = float(r["OS_DRAM_Words"])
        h_ws = min((ws_w / 12500.0) * 140, 140)
        h_os = min((os_w / 12500.0) * 140, 140)

        svg.append(f'<rect x="{x}" y="{200-h_ws}" width="18" height="{h_ws}" fill="#3b82f6" rx="2"/>')
        svg.append(f'<rect x="{x+22}" y="{200-h_os}" width="18" height="{h_os}" fill="#f97316" rx="2"/>')

        name_short = r["Workload"].split()[0]
        svg.append(f'<text x="{x+20}" y="220" font-family="Arial, sans-serif" font-size="10" text-anchor="middle" fill="#475569">{name_short}</text>')
    svg.append('</g>')

    # Panel 4: Adaptive Optimization Advantage (% Energy Saved) (x: 520, y: 360, w: 420, h: 250)
    svg.append('<g id="panel4" transform="translate(520, 360)">')
    svg.append('<rect width="420" height="250" fill="#f8fafc" rx="8" stroke="#e2e8f0" stroke-width="1"/>')
    svg.append('<text x="210" y="25" font-family="Arial, sans-serif" font-size="14" font-weight="bold" text-anchor="middle" fill="#0f172a">Adaptive Benefit: Energy Saved (%)</text>')

    for p, val in [(0, 0), (35, 15), (70, 30), (105, 45), (140, 60)]:
        y = 200 - p
        svg.append(f'<line x1="45" y1="{y}" x2="400" y2="{y}" stroke="#e2e8f0" stroke-dasharray="3,3" />')
        svg.append(f'<text x="40" y="{y+4}" font-family="Arial, sans-serif" font-size="10" text-anchor="end" fill="#94a3b8">{val}%</text>')

    for i, r in enumerate(rows):
        x = 65 + i * 70
        sav = float(r["Energy_Savings_%"])
        choice = r["Adaptive_Choice"]
        h = (sav / 60.0) * 140

        color = "#10b981" if choice == "OS" else "#6366f1"
        svg.append(f'<rect x="{x}" y="{200-h}" width="35" height="{h}" fill="{color}" rx="3"/>')
        svg.append(f'<text x="{x+17}" y="{200-h-8}" font-family="Arial, sans-serif" font-size="10" font-weight="bold" text-anchor="middle" fill="#0f172a">{sav:.1f}%</text>')
        svg.append(f'<text x="{x+17}" y="{200-h-20}" font-family="Arial, sans-serif" font-size="9" text-anchor="middle" fill="#64748b">[{choice}]</text>')

        name_short = r["Workload"].split()[0]
        svg.append(f'<text x="{x+17}" y="220" font-family="Arial, sans-serif" font-size="10" text-anchor="middle" fill="#475569">{name_short}</text>')

    # Legend for Panel 4
    svg.append('<rect x="110" y="42" width="12" height="12" fill="#6366f1" rx="2"/>')
    svg.append('<text x="128" y="52" font-family="Arial, sans-serif" font-size="11" fill="#334155">Auto-Select WS</text>')
    svg.append('<rect x="250" y="42" width="12" height="12" fill="#10b981" rx="2"/>')
    svg.append('<text x="268" y="52" font-family="Arial, sans-serif" font-size="11" fill="#334155">Auto-Select OS</text>')
    svg.append('</g>')

    svg.append('</svg>')

    out_file = "ai-accelerator-project/phase12/results/dataflow_comparison.svg"
    with open(out_file, "w") as f:
        f.write("\n".join(svg))
    print(f"Generated clean SVG visualization: {out_file}")

if __name__ == "__main__":
    generate_svg()
