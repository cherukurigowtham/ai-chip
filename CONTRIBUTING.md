# Contributing to BitNet-130

Thank you for your interest in contributing to the BitNet-130 open-source silicon and AI accelerator project!

## 1. Development Principles
- **Multiplier-Free Arithmetic:** All tensor compute paths must use conditional ternary sign inversion $\{-1, 0, +1\}$ with 0 hardware multipliers (0 DSP slices).
- **Bit-Exact Parity:** New RTL additions must match double-precision software models with 0 mismatches across all corner cases.
- **Clock-Gating & Energy Efficiency:** New processing elements must incorporate dynamic zero-skipping clock gating.

## 2. Pull Request Guidelines
1. Fork the repository and create a feature branch (`git checkout -b feat/your-feature`).
2. Run the 14-stage full system test suite before submitting:
   ```bash
   ./run_full_system_test.sh
   ```
3. Ensure all tests pass with 0 errors.
4. Run Verilator lint checks on modified SystemVerilog modules:
   ```bash
   verilator --lint-only -Wall ai-accelerator-project/ternary/rtl/your_module.sv
   ```
5. Submit a pull request with a detailed description of PPA (Power, Performance, Area) impact.

## 3. Reporting Issues
Please report bugs or feature suggestions on the GitHub Issues page with reproduction steps and simulator logs.
