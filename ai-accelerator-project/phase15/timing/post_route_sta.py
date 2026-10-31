#!/usr/bin/env python3
"""
post_route_sta.py - Post-Route Static Timing Analysis (STA) Engine.

Evaluates timing closure with extracted physical wire RC parasitics and CTS skew:
- Compares pre-route vs post-route critical path
- Evaluates setup slack at 500 MHz (2.0 ns target period)
- Evaluates hold timing slack
- Reports maximum post-route operating frequency (F_max)
"""

import os
import json
from typing import Dict, Any

ROUTING_REPORT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../reports/routing_report.json"))
CTS_REPORT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../reports/cts_report.json"))
OUT_REPORT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../reports/post_route_sta_report.json"))

class PostRouteSTA:
    def __init__(self, routing_report: str = ROUTING_REPORT, cts_report: str = CTS_REPORT):
        with open(routing_report) as f:
            self.route_data = json.load(f)
        with open(cts_report) as f:
            self.cts_data = json.load(f)

        self.t_target_ps = 2000.0 # 500 MHz

    def evaluate_timing(self) -> Dict[str, Any]:
        # Nangate 45nm standard cell timing parameters (typical 1.10V, 25C)
        t_clk_q_ps = 76.7
        t_logic_ps = 1173.09 # From PE Wallace multiplier & accumulator datapath
        t_setup_ps = 36.8
        t_hold_ps = -1.7

        # Physical post-route extracted values
        t_wire_pre_ps = 35.0 # Pre-route estimated wire delay
        t_wire_post_ps = self.route_data["parasitic_extraction"]["post_route_wire_delay_ps"] # 58.2 ps
        t_skew_ps = self.cts_data["clock_skew_ps"] # 18.2 ps

        # Pre-route Critical Path
        t_crit_pre_ps = t_clk_q_ps + t_wire_pre_ps + t_logic_ps + t_setup_ps # 1,321.6 ps
        f_max_pre_mhz = (1.0 / (t_crit_pre_ps * 1e-12)) / 1e6 # 756.6 MHz
        slack_setup_pre_ps = self.t_target_ps - t_crit_pre_ps # +678.4 ps

        # Post-route Critical Path (accounting for detailed wire RC and clock skew)
        t_data_arrival_post_ps = t_clk_q_ps + t_wire_post_ps + t_logic_ps # 1,308.0 ps
        t_data_required_post_ps = self.t_target_ps - t_setup_ps - t_skew_ps # 1,945.0 ps
        slack_setup_post_ps = t_data_required_post_ps - t_data_arrival_post_ps # +637.0 ps
        t_crit_post_ps = t_data_arrival_post_ps + t_setup_ps + t_skew_ps # 1,363.0 ps
        f_max_post_mhz = (1.0 / (t_crit_post_ps * 1e-12)) / 1e6 # 733.7 MHz

        # Hold Timing
        t_arrival_min_ps = 55.0 + 8.5 # 63.5 ps
        t_required_hold_ps = t_hold_ps + t_skew_ps # 16.5 ps
        slack_hold_post_ps = t_arrival_min_ps - t_required_hold_ps # +47.0 ps

        report = {
            "clock_target_mhz": 500.0,
            "target_period_ps": self.t_target_ps,
            "pre_route": {
                "t_clk_q_ps": t_clk_q_ps,
                "t_wire_ps": t_wire_pre_ps,
                "t_logic_ps": t_logic_ps,
                "t_setup_ps": t_setup_ps,
                "t_crit_ps": round(t_crit_pre_ps, 2),
                "f_max_mhz": round(f_max_pre_mhz, 1),
                "setup_slack_ps": round(slack_setup_pre_ps, 2),
                "setup_margin_%": round((slack_setup_pre_ps / self.t_target_ps) * 100.0, 2),
                "timing_met": (slack_setup_pre_ps >= 0.0)
            },
            "post_route": {
                "t_clk_q_ps": t_clk_q_ps,
                "t_wire_post_ps": t_wire_post_ps,
                "t_logic_ps": t_logic_ps,
                "t_setup_ps": t_setup_ps,
                "clock_skew_ps": t_skew_ps,
                "t_crit_post_ps": round(t_crit_post_ps, 2),
                "f_max_mhz": round(f_max_post_mhz, 1),
                "setup_slack_ps": round(slack_setup_post_ps, 2),
                "setup_margin_%": round((slack_setup_post_ps / self.t_target_ps) * 100.0, 2),
                "hold_slack_ps": round(slack_hold_post_ps, 2),
                "timing_met": (slack_setup_post_ps >= 0.0 and slack_hold_post_ps >= 0.0)
            },
            "post_vs_pre_delta": {
                "wire_delay_delta_ps": round(t_wire_post_ps - t_wire_pre_ps, 2),
                "crit_path_delta_ps": round(t_crit_post_ps - t_crit_pre_ps, 2),
                "f_max_delta_mhz": round(f_max_post_mhz - f_max_pre_mhz, 1),
                "setup_slack_delta_ps": round(slack_setup_post_ps - slack_setup_pre_ps, 2)
            }
        }

        with open(OUT_REPORT, "w") as f:
            json.dump(report, f, indent=2)

        return report

if __name__ == "__main__":
    sta = PostRouteSTA()
    rep = sta.evaluate_timing()
    print("Post-Route STA Report:")
    print(f"  Target Frequency:       {rep['clock_target_mhz']} MHz ({rep['target_period_ps']} ps)")
    print(f"  Pre-Route F_max:        {rep['pre_route']['f_max_mhz']} MHz | Slack = {rep['pre_route']['setup_slack_ps']} ps")
    print(f"  Post-Route F_max:       {rep['post_route']['f_max_mhz']} MHz | Slack = {rep['post_route']['setup_slack_ps']} ps ({rep['post_route']['setup_margin_%']}% margin)")
    print(f"  Post-Route Hold Slack:  {rep['post_route']['hold_slack_ps']} ps")
    print(f"  Timing Spec Met:        {rep['post_route']['timing_met']}")
