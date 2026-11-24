#!/usr/bin/env bash
# ==============================================================================
# Script: package_production_release.sh
# Description: Automated Commercial & Open-Source Silicon Release Packager
#              for the BitNet-130 Multiplier-Free Transformer ASIC & Frontier SDK.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

RELEASE_VERSION="v3.2.0"
DIST_DIR="dist"
PACKAGE_NAME="bitnet130_silicon_release_${RELEASE_VERSION}"
STAGE_DIR="${DIST_DIR}/${PACKAGE_NAME}"

echo -e "${BLUE}==========================================================================${NC}"
echo -e "${BLUE}  BITNET-130 SILICON & FRONTIER SDK RELEASE PACKAGER (${RELEASE_VERSION})    ${NC}"
echo -e "${BLUE}  Target Signoff: 500 MHz (2.0 ns) | Process: SkyWater Sky130 / Nangate 45nm${NC}"
echo -e "${BLUE}==========================================================================${NC}"

# 1. Run Verification Signoff across all 52 Tiers
echo -e "\n${YELLOW}>>> [STEP 1/6] Verifying Silicon Health across all 52 Industrial Tiers...${NC}"
./run_all_verifications.sh

# 2. Run Real-World Frontier Model & Application Benchmarks
echo -e "\n${YELLOW}>>> [STEP 2/6] Running Frontier Model & Cardiac Sentinel Benchmarks...${NC}"
python3 ai-accelerator-project/benchmarks/benchmark_frontier_models.py > /dev/null
python3 ai-accelerator-project/benchmarks/benchmark_frontier_fullstack.py > /dev/null
python3 ai-accelerator-project/applications/ecg_cardiac_sentinel/run_cardiac_arrhythmia_detector.py > /dev/null
echo -e "${GREEN}[OK] Benchmark Suite Signoff Passed!${NC}"

# 3. Build Standard PyPI Python Wheels & Source Tarball
echo -e "\n${YELLOW}>>> [STEP 3/6] Building PyPI Wheel & Source Distribution (setup.py)...${NC}"
python3 setup.py sdist bdist_wheel > /dev/null
echo -e "${GREEN}[OK] PyPI Distribution Built in dist/ (bitnet_accel-3.0.0-py3-none-any.whl)${NC}"

# 4. Create Clean Staging Directory
echo -e "\n${YELLOW}>>> [STEP 4/6] Assembling Staging Package in ${STAGE_DIR}...${NC}"
mkdir -p "${STAGE_DIR}/rtl"
mkdir -p "${STAGE_DIR}/verification"
mkdir -p "${STAGE_DIR}/sdk"
mkdir -p "${STAGE_DIR}/firmware"
mkdir -p "${STAGE_DIR}/hardware"
mkdir -p "${STAGE_DIR}/applications"
mkdir -p "${STAGE_DIR}/benchmarks"
mkdir -p "${STAGE_DIR}/synthesis"
mkdir -p "${STAGE_DIR}/openlane"
mkdir -p "${STAGE_DIR}/scripts"
mkdir -p "${STAGE_DIR}/src"
mkdir -p "${STAGE_DIR}/docs"
mkdir -p "${STAGE_DIR}/dashboard"
mkdir -p "${STAGE_DIR}/python_dist"

# Copy RTL modules
cp ai-accelerator-project/ternary/rtl/*.sv "${STAGE_DIR}/rtl/"

# Copy Verification modules & scripts
cp ai-accelerator-project/verification/deep_testing/*.sv "${STAGE_DIR}/verification/" 2>/dev/null || true
cp ai-accelerator-project/verification/deep_testing/*.py "${STAGE_DIR}/verification/" 2>/dev/null || true
cp run_all_verifications.sh "${STAGE_DIR}/"

# Copy Python SDK
cp ai-accelerator-project/sdk/*.py "${STAGE_DIR}/sdk/"
cp dist/*.whl "${STAGE_DIR}/python_dist/" 2>/dev/null || true
cp dist/*.tar.gz "${STAGE_DIR}/python_dist/" 2>/dev/null || true

# Copy Embedded C Firmware
cp hardware/carrier_board/firmware/* "${STAGE_DIR}/firmware/"

# Copy Hardware Carrier Board Design & JLCPCB Manufacturing Package
cp -r hardware/carrier_board/*.kicad* "${STAGE_DIR}/hardware/" 2>/dev/null || true
cp -r hardware/carrier_board/*.csv "${STAGE_DIR}/hardware/" 2>/dev/null || true
cp -r hardware/carrier_board/*.md "${STAGE_DIR}/hardware/" 2>/dev/null || true
cp -r hardware/carrier_board/gerbers "${STAGE_DIR}/hardware/" 2>/dev/null || true

# Copy Real-World Applications
cp -r ai-accelerator-project/applications/* "${STAGE_DIR}/applications/"

# Copy Benchmarks
cp -r ai-accelerator-project/benchmarks/* "${STAGE_DIR}/benchmarks/"

# Copy Gate-Level Synthesis Profiler & Report
cp ai-accelerator-project/ternary/synthesis/*.py "${STAGE_DIR}/synthesis/" 2>/dev/null || true
cp ai-accelerator-project/ternary/synthesis/*.json "${STAGE_DIR}/synthesis/" 2>/dev/null || true

# Copy OpenLane 2 Physical Layout Configurations
cp -r openlane/* "${STAGE_DIR}/openlane/" 2>/dev/null || true

# Copy Tapeout Manifests & Scripts
cp -r scripts/* "${STAGE_DIR}/scripts/" 2>/dev/null || true
cp -r src/* "${STAGE_DIR}/src/" 2>/dev/null || true
cp info.yaml "${STAGE_DIR}/" 2>/dev/null || true

# Copy Documentation, Whitepaper & Datasheet
cp docs/BITNET130_ARCHITECTURE_WHITEPAPER.md "${STAGE_DIR}/docs/"
cp docs/BITNET130_DATASHEET.md "${STAGE_DIR}/docs/"
cp ai-accelerator-project/docs/BITNET_UNIVERSAL_PROCESSOR_DATASHEET.md "${STAGE_DIR}/docs/" 2>/dev/null || true
cp docs/FRONTIER_MODELS_SILICON_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/FRONTIER_FULLSTACK_EXECUTION_REPORT.md "${STAGE_DIR}/docs/" 2>/dev/null || true
cp docs/FPGA_PHYSICAL_BOARD_BRINGUP_REPORT.md "${STAGE_DIR}/docs/" 2>/dev/null || true
cp docs/DISTRIBUTED_CHIPLET_ALLREDUCE_REPORT.md "${STAGE_DIR}/docs/" 2>/dev/null || true
cp docs/MANUFACTURING_AND_COMMERCIAL_DOSSIER.md "${STAGE_DIR}/docs/" 2>/dev/null || true
cp docs/AI_CHIP_VS_INDUSTRY_GIANTS_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/REAL_WORLD_PROBLEM_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/MLPERF_TINY_OPEN_SOURCE_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/TINY_TAPEOUT_SKY130_PHYSICAL_SIGNOFF.md "${STAGE_DIR}/docs/"
cp docs/MULTITILE_2X2_PHYSICAL_SCALING.md "${STAGE_DIR}/docs/"
cp docs/crowdsupply_qa_response.md "${STAGE_DIR}/docs/"
cp docs/index.html "${STAGE_DIR}/docs/"
cp docs/interactive_demo.html "${STAGE_DIR}/docs/"
cp -r ai-accelerator-project/dashboard/* "${STAGE_DIR}/dashboard/" 2>/dev/null || true

# 5. Generate Cryptographic Checksums
echo -e "\n${YELLOW}>>> [STEP 5/6] Generating SHA-256 Cryptographic Checksums...${NC}"
cd "${STAGE_DIR}"
find . -type f ! -name "SHA256SUMS.txt" -exec shasum -a 256 {} + > SHA256SUMS.txt
cd ../..

# 6. Build Distribution Tarball
echo -e "\n${YELLOW}>>> [STEP 6/6] Creating Production Release Archive...${NC}"
cd "${DIST_DIR}"
tar -czf "${PACKAGE_NAME}.tar.gz" "${PACKAGE_NAME}"
cd ..

TAR_SIZE=$(ls -lh "${DIST_DIR}/${PACKAGE_NAME}.tar.gz" | awk '{print $5}')
TAR_SHA=$(shasum -a 256 "${DIST_DIR}/${PACKAGE_NAME}.tar.gz" | awk '{print $1}')

echo -e "\n${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  PRODUCTION RELEASE PACKAGE CREATED SUCCESSFULLY!                        ${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo -e "  Version:  ${RELEASE_VERSION}"
echo -e "  Archive:  ${DIST_DIR}/${PACKAGE_NAME}.tar.gz"
echo -e "  Size:     ${TAR_SIZE}"
echo -e "  SHA-256:  ${TAR_SHA}"
echo -e "  PyPI Whl: dist/bitnet_accel-3.0.0-py3-none-any.whl"
echo -e "${GREEN}==========================================================================${NC}\n"
