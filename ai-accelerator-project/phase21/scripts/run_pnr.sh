#!/usr/bin/env bash
set -e

echo "=== Running Phase 21 Genuine OpenROAD Physical Implementation Flow ==="
docker run --platform linux/amd64 --rm \
    -v "$(pwd):/work" \
    -w /work \
    openroad/ubuntu22.04 \
    /OpenROAD/install/bin/openroad /work/ai-accelerator-project/phase21/scripts/run_pnr.tcl | tee ai-accelerator-project/phase21/openroad_run/pnr_run.log
