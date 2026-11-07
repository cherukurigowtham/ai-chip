#!/usr/bin/env bash
# ==============================================================================
# Script: deploy_to_pynq.sh
# Description: Automated deployment script to flash and benchmark the 8x8 Ternary
#              AI Accelerator SoC on a physical PYNQ-Z2 board.
# Usage: ./deploy_to_pynq.sh [PYNQ_IP] (defaults to 192.168.2.99)
# ==============================================================================

set -euo pipefail

PYNQ_IP="${1:-192.168.2.99}"
BOARD_USER="xilinx"
DEST_DIR="/home/${BOARD_USER}"

echo "================================================================="
echo "  Deploying Ternary AI Accelerator Overlay to PYNQ-Z2"
echo "  Target Host: ${BOARD_USER}@${PYNQ_IP}"
echo "================================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# 1. Validate required build deliverables
for file in "ternary_pynq_soc.bit" "ternary_pynq_soc.hwh" "ternary_pynq_overlay.py" "benchmark_cpu_vs_fpga.py" "../driver/ternary_inference_engine.py"; do
    if [ ! -f "${file}" ]; then
        echo "[ERROR] Required file missing: ${file}"
        exit 1
    fi
done

echo "[1/3] Copying FPGA Bitstream & Hardware Handoff..."
scp ternary_pynq_soc.bit "${BOARD_USER}@${PYNQ_IP}:${DEST_DIR}/ternary_pynq_soc.bit"
scp ternary_pynq_soc.hwh "${BOARD_USER}@${PYNQ_IP}:${DEST_DIR}/ternary_pynq_soc.hwh"

echo "[2/3] Copying Host Runtime Drivers & Benchmarking Harness..."
scp ternary_pynq_overlay.py "${BOARD_USER}@${PYNQ_IP}:${DEST_DIR}/ternary_pynq_overlay.py"
scp benchmark_cpu_vs_fpga.py "${BOARD_USER}@${PYNQ_IP}:${DEST_DIR}/benchmark_cpu_vs_fpga.py"
scp ../driver/ternary_inference_engine.py "${BOARD_USER}@${PYNQ_IP}:${DEST_DIR}/ternary_inference_engine.py"

echo "[3/3] Deployment complete!"
echo "================================================================="
echo "  To execute physical benchmarking on the PYNQ-Z2 board:"
echo "    ssh ${BOARD_USER}@${PYNQ_IP}"
echo "    cd ${DEST_DIR}"
echo "    python3 benchmark_cpu_vs_fpga.py"
echo "================================================================="

