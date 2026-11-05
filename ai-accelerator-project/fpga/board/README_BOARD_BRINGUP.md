# Physical FPGA Board Bring-Up Guide (PYNQ-Z2 / ZedBoard)

This guide details the procedure to implement, flash, and physically benchmark the 8×8 Ternary AI Accelerator on a **PYNQ-Z2** (or ZedBoard) featuring the Xilinx Zynq-7000 (`xc7z020clg400-1`).

---

## Prerequisites

1. **Hardware**:
   - PYNQ-Z2 Development Board (or ZedBoard).
   - Micro-USB cable (for JTAG/UART and power).
   - Ethernet cable (connected to local router or host computer).
   - MicroSD card flashed with PYNQ v2.7 or v3.0 image.
2. **Software (on Host PC with Vivado)**:
   - Xilinx Vivado ML Standard / Enterprise (version 2022.1 or newer).
   - Python 3 with `numpy`.

---

## Step 1: Generate Bitstream and Hardware Handoff (`.bit` and `.hwh`)

On the machine where Vivado is installed:

```bash
cd ai-accelerator-project/fpga/board
vivado -mode batch -source bd_pynq_z2.tcl
```

This automated script performs:
1. RTL elaboration and packaging of `accelerator_ternary_axi_top`.
2. Zynq-7000 PS7 instantiation with 100 MHz `FCLK_CLK0`.
3. AXI DMA instantiation and memory-mapped interconnect wiring.
4. Logic synthesis, placement, routing, and timing signoff at 100 MHz.
5. Bitstream generation (`ternary_pynq_soc.bit`) and hardware handoff extraction (`ternary_pynq_soc.hwh`).

---

## Step 2: Deploy to the PYNQ-Z2 Board

Transfer the generated bitstream, hardware handoff, and benchmarking scripts to the board:

```bash
# Set PYNQ board IP address (default is 192.168.2.99 or pynq.local)
export PYNQ_IP="192.168.2.99"

# Copy deployment package
scp ternary_pynq_soc.bit xilinx@${PYNQ_IP}:/home/xilinx/ternary_pynq_soc.bit
scp ternary_pynq_soc.hwh xilinx@${PYNQ_IP}:/home/xilinx/ternary_pynq_soc.hwh
scp ternary_pynq_overlay.py benchmark_cpu_vs_fpga.py xilinx@${PYNQ_IP}:/home/xilinx/
scp ../driver/ternary_inference_engine.py xilinx@${PYNQ_IP}:/home/xilinx/
```

---

## Step 3: Run Hardware Verification and Benchmarking on Board

SSH into the PYNQ board and run the comparative benchmark:

```bash
ssh xilinx@${PYNQ_IP}
# Default password: xilinx

cd /home/xilinx
python3 benchmark_cpu_vs_fpga.py
```

The script will:
1. Program the FPGA fabric using `pynq.Overlay('ternary_pynq_soc.bit')`.
2. Benchmark the dual-core ARM Cortex-A9 host CPU.
3. Stream BitNet b1.58 quantized tensors via physical AXI DMA to the 8×8 ternary array.
4. Verify bit-exact equivalence between CPU and FPGA outputs.
5. Print real hardware latency, throughput, and speedup.

---

## Step 4: Measure Live Electrical Board Power

To measure true electrical power rather than relying on architectural toggle estimates:

1. **Via On-Board PMBus / Sysfs Sensors**:
   On PYNQ-Z2, read power rail voltage and current from the on-board regulators:
   ```bash
   cat /sys/class/hwmon/hwmon*/in1_input  # VCCINT voltage
   cat /sys/class/hwmon/hwmon*/curr1_input # VCCINT current
   ```
2. **Via External Current Shunt / Multimeter**:
   - Place a digital multimeter (in DC current mode) across the **JP1 (Power jumper)** or inline with the 12V DC barrel jack.
   - Measure idle power ($P_{\text{idle}}$) before running inference.
   - Measure active power ($P_{\text{active}}$) while looping inference.
   - Dynamic PL Power: $P_{\text{dynamic}} = P_{\text{active}} - P_{\text{idle}}$.

---

## Step 5: Archive & Reproducibility Package

To ensure full reproducibility of the physical implementation, preserve the complete project, logs, and raw reports alongside the bitstream:

```bash
tar -czvf phase11_implementation_archive.tar.gz \
    ternary_pynq_soc.bit \
    ternary_pynq_soc.hwh \
    reports/ \
    phase11_vivado.log \
    phase11_vivado.jou \
    bd_pynq_z2.tcl
```
