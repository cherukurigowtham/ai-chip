#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"

mkdir -p "${REPO_ROOT}/ai-accelerator-project/ternary/physical/openroad_8x8_run"

echo "=== Running Phase 8 Genuine OpenROAD Physical Implementation Flow for 8x8 accelerator_ternary_top ==="
echo "Repository Root: ${REPO_ROOT}"
docker run --platform linux/amd64 --rm \
    -v "${REPO_ROOT}:/work" \
    -w /work \
    openroad/ubuntu22.04 \
    /OpenROAD/install/bin/openroad /work/ai-accelerator-project/ternary/physical/scripts/run_pnr_8x8.tcl | tee "${REPO_ROOT}/ai-accelerator-project/ternary/physical/openroad_8x8_run/pnr_8x8_run.log"
