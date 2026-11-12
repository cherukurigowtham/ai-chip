#!/usr/bin/env bash
# ==============================================================================
# Script: package_production_release.sh
# Description: Automated Commercial & Open-Source Silicon Release Packager
#              for the BitNet-130 Multiplier-Free Transformer ASIC.
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

RELEASE_VERSION="v2.1"
DIST_DIR="dist"
PACKAGE_NAME="bitnet130_silicon_release_${RELEASE_VERSION}"
STAGE_DIR="${DIST_DIR}/${PACKAGE_NAME}"

echo -e "${BLUE}==========================================================================${NC}"
echo -e "${BLUE}  BITNET-130 SILICON COMMERCIAL RELEASE PACKAGER (${RELEASE_VERSION})           ${NC}"
echo -e "${BLUE}==========================================================================${NC}"

# 1. Run Verification Signoff
echo -e "\n${YELLOW}>>> [STEP 1/5] Verifying Silicon Health across all 19 Tiers...${NC}"
./run_all_verifications.sh

# 2. Run Real-World Application Benchmark
echo -e "\n${YELLOW}>>> [STEP 2/5] Running Real-World Cardiac Sentinel Benchmark...${NC}"
python3 ai-accelerator-project/applications/ecg_cardiac_sentinel/run_cardiac_arrhythmia_detector.py > /dev/null
echo -e "${GREEN}[OK] Cardiac Sentinel Benchmark Signoff Passed!${NC}"

# 3. Create Clean Staging Directory
echo -e "\n${YELLOW}>>> [STEP 3/5] Assembling Staging Package in ${STAGE_DIR}...${NC}"
rm -rf "${DIST_DIR}"
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

# Copy RTL modules
cp ai-accelerator-project/ternary/rtl/*.sv "${STAGE_DIR}/rtl/"

# Copy Verification modules & scripts
cp ai-accelerator-project/verification/deep_testing/*.sv "${STAGE_DIR}/verification/" 2>/dev/null || true
cp ai-accelerator-project/verification/deep_testing/*.py "${STAGE_DIR}/verification/" 2>/dev/null || true
cp run_all_verifications.sh "${STAGE_DIR}/"

# Copy Python SDK
cp ai-accelerator-project/sdk/*.py "${STAGE_DIR}/sdk/"

# Copy Embedded C Firmware
cp hardware/carrier_board/firmware/* "${STAGE_DIR}/firmware/"

# Copy Hardware Carrier Board Design
cp -r hardware/carrier_board/*.kicad* "${STAGE_DIR}/hardware/" 2>/dev/null || true
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
cp docs/AI_CHIP_VS_INDUSTRY_GIANTS_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/REAL_WORLD_PROBLEM_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/MLPERF_TINY_OPEN_SOURCE_BENCHMARK.md "${STAGE_DIR}/docs/"
cp docs/TINY_TAPEOUT_SKY130_PHYSICAL_SIGNOFF.md "${STAGE_DIR}/docs/"
cp docs/MULTITILE_2X2_PHYSICAL_SCALING.md "${STAGE_DIR}/docs/"
cp docs/crowdsupply_qa_response.md "${STAGE_DIR}/docs/"
cp docs/interactive_demo.html "${STAGE_DIR}/docs/"

# 4. Generate Cryptographic Checksums
echo -e "\n${YELLOW}>>> [STEP 4/5] Generating SHA-256 Cryptographic Checksums...${NC}"
cd "${STAGE_DIR}"
find . -type f ! -name "SHA256SUMS.txt" -exec shasum -a 256 {} + > SHA256SUMS.txt
cd ../..

# 5. Build Distribution Tarball
echo -e "\n${YELLOW}>>> [STEP 5/5] Creating Production Release Archive...${NC}"
cd "${DIST_DIR}"
tar -czf "${PACKAGE_NAME}.tar.gz" "${PACKAGE_NAME}"
cd ..

TAR_SIZE=$(ls -lh "${DIST_DIR}/${PACKAGE_NAME}.tar.gz" | awk '{print $5}')
TAR_SHA=$(shasum -a 256 "${DIST_DIR}/${PACKAGE_NAME}.tar.gz" | awk '{print $1}')

echo -e "\n${GREEN}==========================================================================${NC}"
echo -e "${GREEN}  PRODUCTION RELEASE PACKAGE CREATED SUCCESSFULLY!                        ${NC}"
echo -e "${GREEN}==========================================================================${NC}"
echo -e "  Archive:  ${DIST_DIR}/${PACKAGE_NAME}.tar.gz"
echo -e "  Size:     ${TAR_SIZE}"
echo -e "  SHA-256:  ${TAR_SHA}"
echo -e "${GREEN}==========================================================================${NC}\n"
