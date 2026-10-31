#!/usr/bin/env bash
# ==============================================================================
# Shell Script to Execute Genuine OpenROAD PnR via Docker / Podman / Native Host
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo "================================================================================"
echo "  PHASE 19: PHYSICAL DESIGN IMPLEMENTATION RUNNER"
echo "================================================================================"

if command -v openroad &> /dev/null; then
    echo "[INFO] Found native OpenROAD executable: $(which openroad)"
    cd "$PROJECT_ROOT"
    openroad ai-accelerator-project/phase19/scripts/run_openroad.tcl
elif command -v docker &> /dev/null; then
    echo "[INFO] Running OpenROAD via Docker container (openroad/flow-ubuntu22.04:latest)..."
    docker run --rm -v "$PROJECT_ROOT":/work -w /work openroad/flow-ubuntu22.04:latest \
        openroad ai-accelerator-project/phase19/scripts/run_openroad.tcl
elif command -v podman &> /dev/null; then
    echo "[INFO] Running OpenROAD via Podman container..."
    podman run --rm -v "$PROJECT_ROOT":/work -w /work docker.io/openroad/flow-ubuntu22.04:latest \
        openroad ai-accelerator-project/phase19/scripts/run_openroad.tcl
else
    echo "[ERROR] Neither OpenROAD, Docker, nor Podman was found in PATH."
    echo "[INFO] Current host environment: $(uname -s) $(uname -m)"
    echo "[INFO] To run physical place-and-route:"
    echo "       1. Install Docker Desktop or Podman on macOS, OR"
    echo "       2. Execute this script on a Linux x86_64 server with OpenROAD installed."
    exit 1
fi
