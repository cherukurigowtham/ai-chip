#!/usr/bin/env python3
"""
sta_engine.py - Static Timing Analysis (STA) Engine for Nangate 45nm AI Accelerator.

Computes exact timing metrics across synthesized configurations:
- Clock-to-Q delay (T_clk_q)
- Metal interconnect RC wire delay (T_wire)
- Combinational logic propagation delay (T_logic)
- Flip-flop setup time (T_setup)
- Total Critical Path Delay (T_crit)
- Maximum Operating Frequency (F_max)
- Setup Timing Slack at 500 MHz (2.0 ns target)
"""

from typing import Dict, Any

# Nangate 45nm Typical Corner (1.10V, 25C)
T_CLK_Q_PS = 76.7      # DFF_X1 CK -> Q delay
T_SETUP_PS = 36.8      # DFF_X1 Data setup time
T_HOLD_PS = -1.7       # DFF_X1 Data hold time
T_WIRE_RC_PS = 35.0    # Neighbor PE Metal 3 local routing RC delay

TARGET_PERIOD_PS = 2000.0 # 500 MHz

class TimingAnalyzer:
    def __init__(self, target_clk_period_ps: float = TARGET_PERIOD_PS):
        self.target_clk_period_ps = target_clk_period_ps

    def analyze_timing(self, logic_delay_ps: float, custom_wire_ps: float = T_WIRE_RC_PS) -> Dict[str, Any]:
        """
        Calculates complete clock path timing margins and setup/hold slacks.
        """
        # Critical path: DFF(launch) -> Wire -> Logic tree -> DFF(capture)
        t_data_arrival_ps = T_CLK_Q_PS + custom_wire_ps + logic_delay_ps
        t_crit_ps = t_data_arrival_ps + T_SETUP_PS

        f_max_mhz = (1.0 / (t_crit_ps * 1e-12)) / 1e6
        setup_slack_ps = self.target_clk_period_ps - t_crit_ps
        setup_margin_pct = (setup_slack_ps / self.target_clk_period_ps) * 100.0

        timing_met = (setup_slack_ps >= 0.0)
        hold_margin_ps = T_CLK_Q_PS - T_HOLD_PS # Positive means no hold violation possible

        return {
            "t_clk_q_ps": T_CLK_Q_PS,
            "t_wire_ps": custom_wire_ps,
            "t_logic_ps": round(logic_delay_ps, 2),
            "t_setup_ps": T_SETUP_PS,
            "t_crit_ps": round(t_crit_ps, 2),
            "t_crit_ns": round(t_crit_ps / 1000.0, 3),
            "f_max_mhz": round(f_max_mhz, 1),
            "target_period_ps": self.target_clk_period_ps,
            "setup_slack_ps": round(setup_slack_ps, 2),
            "setup_margin_%": round(setup_margin_pct, 2),
            "hold_margin_ps": round(hold_margin_ps, 2),
            "timing_met": timing_met
        }

if __name__ == "__main__":
    sta = TimingAnalyzer()
    res = sta.analyze_timing(1173.09)
    print(f"STA Report: Critical Path = {res['t_crit_ps']} ps ({res['t_crit_ns']} ns)")
    print(f"F_max = {res['f_max_mhz']} MHz | Setup Slack @ 500 MHz = {res['setup_slack_ps']} ps (Met: {res['timing_met']})")
