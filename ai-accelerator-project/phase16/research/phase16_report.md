# Phase 16: Real EDA Toolchain Validation & Static Timing Sign-Off

**Date:** October 31, 2026  
**Platform:** Nangate 45nm Open Cell Library (FreePDK45, Typical Corner: 1.10V, 25°C)  
**EDA Binary:** OpenSTA v3.1.0 (Built natively for Darwin `arm64` via AppleClang, Tcl 8.6, Bison 3.8.2, Flex 2.6.4, CUDD 3.0.0, Eigen 5.0.1)  
**Design Target:** `accelerator_top` (4×4 Systolic Array, Weight-Stationary & Output-Stationary Adaptive Dataflow, 16-entry SRAM vector buffers, 64-entry drain buffer)  
**Netlist:** Structural Gate-Level Verilog (`accelerator_top.netlist.v`, 24,388 cells, 11,588 DFF bits / 6,634 sequential instances, 152,087.63 µm²)  
**Timing Constraints:** Synopsys Design Constraints (`accelerator_top.sdc`, Target Clock = 500 MHz, Period = 2.000 ns)

---

## 1. Executive Summary

In Phase 15, physical design stages (floorplan, placement, clock tree synthesis, routing, and post-route STA) were evaluated using custom Python-based topological estimators. While that provided architectural insight, it did not execute a production static timing analysis (STA) engine.

In **Phase 16**, we transition entirely to **genuine, independently reproducible EDA software execution**:
1. **Toolchain Compilation**: We compiled **OpenSTA v3.1.0** natively on Apple Silicon (`Darwin arm64`), integrating Homebrew's modern Bison, Flex, CUDD BDD engine, and Tcl 8.6 runtime.
2. **Standard Cell Characterization**: We ran full Non-Linear Delay Model (NLDM) 2D table lookups and state-dependent power characterization using the industrial-standard **Nangate 45nm Open Cell Library** (`nangate45.lib`).
3. **Formal Timing Sign-Off**: We applied an industry-standard SDC constraint targeting 500 MHz ($T = 2.000\text{ ns}$), with 50 ps clock uncertainty, 20 ps clock transition, 400 ps I/O delays, `INV_X2` input driving cell, and 10 fF pin capacitance loads.

### Key Silicon-Level Findings

| Analysis Metric | Phase 15 Python Estimate | Phase 16 OpenSTA Sign-Off | Discrepancy / Delta | Engineering Finding |
| :--- | :---: | :---: | :---: | :--- |
| **Analysis Engine** | Python Topological Estimator | **OpenSTA v3.1.0** (C++/Tcl) | Real EDA Binary | Independently verifiable tool reports |
| **Delay Calculation** | Nominal Intrinsic Delay | **NLDM 2D LUT (Slew × Cap)** | Physical RC Model | Full slew degradation & capacitive load |
| **Target Clock** | 500.0 MHz ($T = 2.00\text{ ns}$) | **500.0 MHz ($T = 2.00\text{ ns}$)** | 0.0% | Identical timing constraint |
| **Critical Path Delay** | $1.363\text{ ns}$ | **$44.350\text{ ns}$** | **$+42.987\text{ ns}$ (+3,154%)** | **Severe timing violation** |
| **Max Frequency ($F_{\max}$)** | $733.7\text{ MHz}$ | **$22.55\text{ MHz}$** | **$-711.15\text{ MHz}$ (-96.9%)** | Unbuffered broadcast nets limit speed |
| **Worst Setup Slack (WNS)** | $+0.637\text{ ns}$ (MET) | **$-42.3502\text{ ns}$ (VIOLATED)** | $-42.987\text{ ns}$ | Requires High Fanout Net Synthesis |
| **Worst Hold Slack (min)** | Not Modeled | **$+0.0236\text{ ns}$ (+23.6 ps)** | N/A | **MET** (No race conditions detected) |
| **Total Negative Slack (TNS)**| $0.000\text{ ns}$ | **$-114,481.29\text{ ns}$** | $-114,481.29\text{ ns}$ | Widespread violations on control nets |
| **Dynamic Power** | $68.40\text{ mW}$ | **$24.37\text{ mW}$** | $-44.03\text{ mW}$ (-64.4%) | Python model assumed 50% toggles everywhere |
| **Leakage Power** | $3.12\text{ mW}$ | **$3.59\text{ mW}$** | $+0.47\text{ mW}$ (+15.1%) | **Excellent model agreement** |
| **Total Silicon Power** | $71.52\text{ mW}$ | **$27.96\text{ mW}$** | $-43.56\text{ mW}$ (-60.9%) | OpenSTA state-dependent power calculation |

```
                                  CRITICAL PATH COMPARISON
      Phase 15 Python Model [======] 1.36 ns (733.7 MHz)
      Phase 16 OpenSTA Real [========================================================================] 44.35 ns (22.55 MHz)
      Target Clock Period   [========] 2.00 ns (500.0 MHz)
```

---

## 2. Root Cause Analysis: Why Did Real STA Disagree with the Model?

The massive discrepancy between the Phase 15 model ($1.363\text{ ns}$) and OpenSTA sign-off ($44.350\text{ ns}$) is rooted in **unbuffered high-fanout nets (HFNS)**:

### 1. The Anatomy of the 44.35 ns Critical Path
In `accelerator_top.netlist.v`, the critical path originates at `u_controller/_76090_/Q` (`stream_counter[0]`) and terminates at `u_controller/u_systolic_core/gen_row[0].gen_col[0].u_pe/_11382_/D`:

```
+--------------------------------------------------------------------------------------------------------------------+
| Instance Name                                | Cell Type | Fanout | Load Cap (fF) | Slew (ns) | Stage Delay (ns)   |
+--------------------------------------------------------------------------------------------------------------------+
| u_controller/_76090_/Q (stream_counter[0])   | DFF_X1    | 1,033  | 1,821.11 fF   | 4.158 ns  | 4.4431 ns          |
| u_controller/_68619_/ZN                      | INV_X1    |   519  |   793.09 fF   | 7.530 ns  | 17.2192 ns (!!)    |
| u_controller/_69730_/ZN                      | NOR2_X1   |     1  |     1.71 fF   | 0.910 ns  | 1.8405 ns          |
| u_controller/_39151_/ZN                      | NOR2_X1   |   513  |   786.07 fF   | 2.322 ns  | 6.2868 ns (!!)     |
| u_controller/_41373_/ZN                      | INV_X1    |   512  |   825.70 fF   | 0.000 ns  | 9.7379 ns (!!)     |
| Subtotal (4 High-Fanout Broadcast Gates)     | -         | -      | -             | -         | 39.5276 ns (89.3%) |
+--------------------------------------------------------------------------------------------------------------------+
| Downstream PE Arithmetic Logic (38 gates)    | Standard  | 1 - 21 | 1.1 - 31.9 fF | 0.01-0.2ns|  4.7310 ns (10.7%) |
+--------------------------------------------------------------------------------------------------------------------+
| TOTAL DATA ARRIVAL TIME                      | -         | -      | -             | -         | 44.2586 ns         |
+--------------------------------------------------------------------------------------------------------------------+
```

### 2. Physical Design Insight
- **The Phase 15 Python Estimator Flaw**: The Python model treated cells as if they were driving ideal nominal loads (~2 to 5 fF), estimating each gate transition at 40 to 80 ps.
- **The Physical Reality**: In the raw netlist emitted by Yosys, global control signals like `stream_counter[0]`, `drain_counter`, and `dataflow_mode` were mapped to minimum-size 1X inverters (`INV_X1`) driving **over 500 to 1,000 gates directly**.
- **NLDM Slew Degradation**: In Nangate 45nm, an `INV_X1` has a maximum recommended load capacitance of ~10 fF. When loaded with 793 fF (79× over limit), the transition slew degrades to **7.53 nanoseconds**, causing the inverter propagation delay to balloon to **17.22 nanoseconds for a single gate**!
- **Conclusion**: **39.53 ns out of the 44.26 ns path delay (89.3%) is pure unbuffered fanout RC penalty.** The true intrinsic datapath logic through the PE multiplier and accumulator chain requires only **4.73 ns**.

---

## 3. Power Analysis Breakdown

OpenSTA evaluated the power dissipation across all 24,388 cells and interconnects under Nangate 45nm characterization:

```
Group                  Internal  Switching    Leakage      Total
                          Power      Power      Power      Power (Watts)
------------------------------------------------------------------------
Sequential           2.2978e-02 1.5854e-05 5.0526e-04 2.3499e-02  84.0%
Combinational        3.8911e-04 9.8674e-04 3.0860e-03 4.4619e-03  16.0%
Clock                0.0000e+00 0.0000e+00 0.0000e+00 0.0000e+00   0.0%
Macro                0.0000e+00 0.0000e+00 0.0000e+00 0.0000e+00   0.0%
------------------------------------------------------------------------
Total                2.3367e-02 1.0026e-03 3.5911e-03 2.7961e-02 100.0%
                          83.6%       3.6%      12.8%
```

- **Leakage Power**: **$3.591\text{ mW}$**. The Phase 15 analytical model predicted $3.120\text{ mW}$ (+15.1% discrepancy). This confirms the leakage model was remarkably accurate.
- **Sequential Internal Power**: **$22.98\text{ mW}$ (82.2% of total)**. The 11,588 flip-flops in the SRAM buffer memories and PE accumulators dominate dynamic consumption due to internal clock pin switching.
- **Dynamic Switching Power**: **$1.00\text{ mW}$**. Actual net switching is relatively small because not all 11,588 DFFs toggle simultaneously on every cycle. Phase 15 assumed a 50% activity factor across all registers, which inflated estimated dynamic power to $68.4\text{ mW}$.

---

## 4. Hold Timing Sign-Off

- **Worst Hold Slack**: **$+0.0236\text{ ns}$ (+23.6 ps) [MET]**
- **Analysis**:
  - OpenSTA verified min-delay paths from inputs and between sequential elements.
  - Even with a 50 ps clock uncertainty margin, data arrival times exceed library hold requirements across all 6,634 sequential instances.
  - Zero hold violations exist in the structural netlist.

---

## 5. Engineering Roadmap to Achieve 500 MHz Silicon Convergence

To close the gap from 22.55 MHz to the target 500 MHz ($2.0\text{ ns}$), the following physical design steps must be incorporated:

1. **High Fanout Net Synthesis (HFNS)**:
   - Insert balanced buffer trees (`BUF_X4`, `BUF_X8`, `BUF_X16`) on all broadcast control lines (`stream_counter`, `drain_counter`, `pe_enable`, `dataflow_mode`).
   - Capping maximum fanout to 16 loads per driver will immediately recover ~37 ns of delay, bringing path delay from 44.35 ns down to ~7.2 ns.
2. **Pipelining Broadcast Control Signals**:
   - Register the `stream_counter` and `drain_counter` decode signals at the boundary of each PE row/column.
3. **Register-Retiming & Arithmetic Restructuring**:
   - The remaining ~4.7 ns logic path consists of 38 gates traversing the 16-bit MAC multiplier and accumulator adders.
   - Inserting an execution pipeline register between the multiplier stage and accumulator stage will reduce logic depth to <1.5 ns, comfortably achieving >650 MHz.

---

## 6. Deliverable Files in Phase 16

1. **OpenSTA Binary**: `ai_chip/bin/sta` (OpenSTA v3.1.0, native Darwin `arm64`)
2. **Sign-Off SDC Constraints**: `ai-accelerator-project/phase16/sdc/accelerator_top.sdc`
3. **OpenSTA Execution Script**: `ai-accelerator-project/phase16/scripts/run_opensta.tcl`
4. **Tool-Generated Reports** (`ai-accelerator-project/phase16/sta_reports/`):
   - `timing_checks.rpt`: Min/max timing checks with slew, cap, and fanout details
   - `top20_setup_paths.rpt`: Complete gate-by-gate trace of the 20 worst setup paths
   - `top20_hold_paths.rpt`: Gate trace of the 20 worst hold paths (+23.6 ps slack)
   - `setup_worst_slack.rpt`: Worst Negative Slack (-42.3502 ns)
   - `hold_worst_slack.rpt`: Hold slack (+0.0236 ns)
   - `clock_min_period.rpt`: Minimum period (44.35 ns) and $F_{\max}$ (22.55 MHz)
   - `power.rpt`: Sequential, combinational, internal, switching, and leakage power
   - `units.rpt` & `clocks.rpt`: Verification of design units and clock definitions
5. **Comparison Matrix**: `ai-accelerator-project/phase16/comparison/real_tool_vs_model.csv`
6. **Comparison Chart**: `ai-accelerator-project/phase16/comparison/eda_vs_modeled_comparison.png`
