# ==============================================================================
# Dockerfile for Genuine OpenROAD Physical Implementation Flow
# Platform: Linux x86_64
# ==============================================================================

FROM openroad/flow-ubuntu22.04:latest

WORKDIR /work

# Copy project workspace
COPY . /work

# Set default command to run OpenROAD physical design flow
CMD ["openroad", "ai-accelerator-project/phase19/scripts/run_openroad.tcl"]
