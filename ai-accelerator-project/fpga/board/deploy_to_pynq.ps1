param (
    [string]$PynqIP = "192.168.2.99",
    [string]$BoardUser = "xilinx"
)

$ErrorActionPreference = "Stop"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  Deploying Ternary AI Accelerator Overlay to PYNQ-Z2" -ForegroundColor Cyan
Write-Host "  Target Host: ${BoardUser}@${PynqIP}" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$RequiredFiles = @(
    "ternary_pynq_soc.bit",
    "ternary_pynq_soc.hwh",
    "ternary_pynq_overlay.py",
    "benchmark_cpu_vs_fpga.py",
    "../driver/ternary_inference_engine.py"
)

foreach ($file in $RequiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Error "[ERROR] Required file missing: $file"
        exit 1
    }
}

Write-Host "[1/3] Copying FPGA Bitstream & Hardware Handoff via SCP..." -ForegroundColor Yellow
scp ternary_pynq_soc.bit "${BoardUser}@${PynqIP}:/home/${BoardUser}/ternary_pynq_soc.bit"
scp ternary_pynq_soc.hwh "${BoardUser}@${PynqIP}:/home/${BoardUser}/ternary_pynq_soc.hwh"

Write-Host "[2/3] Copying Host Runtime Drivers & Benchmarking Harness..." -ForegroundColor Yellow
scp ternary_pynq_overlay.py "${BoardUser}@${PynqIP}:/home/${BoardUser}/ternary_pynq_overlay.py"
scp benchmark_cpu_vs_fpga.py "${BoardUser}@${PynqIP}:/home/${BoardUser}/benchmark_cpu_vs_fpga.py"
scp ../driver/ternary_inference_engine.py "${BoardUser}@${PynqIP}:/home/${BoardUser}/ternary_inference_engine.py"

Write-Host "[3/3] Deployment complete!" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host "  To execute physical benchmarking on the PYNQ-Z2 board:" -ForegroundColor White
Write-Host "    ssh ${BoardUser}@${PynqIP}" -ForegroundColor Green
Write-Host "    cd /home/${BoardUser}" -ForegroundColor Green
Write-Host "    python3 benchmark_cpu_vs_fpga.py" -ForegroundColor Green
Write-Host "=================================================================" -ForegroundColor Cyan

