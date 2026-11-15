#!/usr/bin/env python3
"""
Unit Test Suite for BitNet-130 Developer CLI (bitnet_cli.py)
============================================================
Tests all primary commands and argument paths:
1. bitnet info
2. bitnet compile (with Hugging Face repo & custom model)
3. bitnet convert (backward compatibility alias)
4. bitnet chat (single-turn prompt with device selection)
5. bitnet flash (mock firmware validation)
6. bitnet benchmark (suite execution)
"""

import unittest
import os
import sys
import subprocess
import tempfile

SDK_DIR = os.path.dirname(os.path.abspath(__file__))
CLI_SCRIPT = os.path.join(SDK_DIR, "bitnet_cli.py")


class TestBitNetCLI(unittest.TestCase):
    """Test case suite for BitNet-130 command line interface."""

    def _run_cli(self, args: list) -> subprocess.CompletedProcess:
        cmd = [sys.executable, CLI_SCRIPT] + args
        env = os.environ.copy()
        env["PYTHONPATH"] = SDK_DIR
        return subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def test_01_info_command(self):
        """Verify 'bitnet info' displays silicon specs and zero multipliers."""
        res = self._run_cli(["info"])
        self.assertEqual(res.returncode, 0, f"bitnet info failed: {res.stderr}")
        self.assertIn("BITNET-130 HARDWARE ARCHITECTURE", res.stdout)
        self.assertIn("Hardware Multipliers: ZERO", res.stdout)
        self.assertIn("Llama 3", res.stdout)
        self.assertIn("DeepSeek", res.stdout)

    def test_02_compile_huggingface(self):
        """Verify 'bitnet compile --hf' ingests repo and outputs .bitnet package."""
        with tempfile.NamedTemporaryFile(suffix=".bitnet", delete=False) as f:
            out_file = f.name

        try:
            res = self._run_cli(["compile", "--hf", "meta-llama/Llama-3.2-1B", "--output", out_file])
            self.assertEqual(res.returncode, 0, f"bitnet compile failed: {res.stderr}")
            self.assertIn("Hugging Face Source    : meta-llama/Llama-3.2-1B", res.stdout)
            self.assertIn("Hardware Multipliers   : ZERO", res.stdout)
            self.assertTrue(os.path.exists(out_file))
            self.assertGreater(os.path.getsize(out_file), 1000)
        finally:
            if os.path.exists(out_file):
                os.remove(out_file)

    def test_03_convert_alias(self):
        """Verify 'bitnet convert' backward compatibility alias."""
        with tempfile.NamedTemporaryFile(suffix=".bitnet", delete=False) as f:
            out_file = f.name

        try:
            res = self._run_cli(["convert", "--model", "qwen-2.5", "--output", out_file])
            self.assertEqual(res.returncode, 0, f"bitnet convert failed: {res.stderr}")
            self.assertIn("Target Architecture", res.stdout)
            self.assertIn("QWEN", res.stdout)
            self.assertIn("Zero-Skip Sparsity", res.stdout)
            self.assertTrue(os.path.exists(out_file))
        finally:
            if os.path.exists(out_file):
                os.remove(out_file)

    def test_04_chat_single_turn(self):
        """Verify 'bitnet chat' single turn execution with live telemetry."""
        res = self._run_cli(["chat", "--model", "llama-3", "--prompt", "Hello BitNet", "--max-tokens", "5", "--device", "sim"])
        self.assertEqual(res.returncode, 0, f"bitnet chat failed: {res.stderr}")
        self.assertIn("BITNET-130 HARDWARE INTERACTIVE CONVERSATIONAL TERMINAL", res.stdout)
        self.assertIn("Multipliers: 0", res.stdout)
        self.assertIn("tok/s", res.stdout)

    def test_05_flash_firmware(self):
        """Verify 'bitnet flash' binary integrity checking and mock upload."""
        with tempfile.NamedTemporaryFile(suffix=".uf2", delete=False) as f:
            f.write(b"UF2\n" + b"\x00" * 512)
            fw_file = f.name

        try:
            res = self._run_cli(["flash", "--firmware", fw_file, "--mock"])
            self.assertEqual(res.returncode, 0, f"bitnet flash failed: {res.stderr}")
            self.assertIn("FIRMWARE FLASH SUCCESSFUL", res.stdout)
            self.assertIn("RP2040 Bootloader Detected", res.stdout)
        finally:
            if os.path.exists(fw_file):
                os.remove(fw_file)

    def test_06_benchmark_suite(self):
        """Verify 'bitnet benchmark --suite frontier' throughput & energy profiling."""
        res = self._run_cli(["benchmark", "--model", "mistral", "--suite", "frontier"])
        self.assertEqual(res.returncode, 0, f"bitnet benchmark failed: {res.stderr}")
        self.assertIn("TARGET [MISTRAL] SUMMARY:", res.stdout)
        self.assertIn("Active Compute Power : 49.20 mW", res.stdout)
        self.assertIn("Hardware Multipliers : ZERO", res.stdout)

    def test_07_perf_command(self):
        """Verify 'bitnet perf' roofline and waterfall acceleration profiling."""
        res_roofline = self._run_cli(["perf", "--model", "llama3", "--mode", "roofline"])
        self.assertEqual(res_roofline.returncode, 0, f"bitnet perf failed: {res_roofline.stderr}")
        self.assertIn("ROOFLINE ANALYSIS", res_roofline.stdout)
        self.assertIn("BitNet-X16", res_roofline.stdout)

        res_waterfall = self._run_cli(["perf", "--model", "llama3", "--mode", "waterfall"])
        self.assertEqual(res_waterfall.returncode, 0, f"bitnet perf failed: {res_waterfall.stderr}")
        self.assertIn("OPTIMIZATION WATERFALL", res_waterfall.stdout)
        self.assertIn("NET SILICON ACCELERATION", res_waterfall.stdout)


if __name__ == "__main__":
    unittest.main()
