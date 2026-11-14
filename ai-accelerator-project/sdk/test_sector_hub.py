#!/usr/bin/env python3
"""
==============================================================================
Unit Test Suite for BitNet-130 Universal Cross-Sector Application Hub
==============================================================================
Verifies multiplier-free execution, latency, energy budgets, and zero DSPs
across all 6 economic sectors:
  - Healthcare
  - Automotive
  - Industrial IoT
  - Smart Agriculture
  - Defense
  - Smart City / Audio
==============================================================================
"""

import unittest
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bitnet_sector_hub import (
    SECTOR_REGISTRY,
    get_sector_engine,
    run_all_sector_benchmarks,
    CardioPulseHealthcareSentinel,
    AegisBMSAutomotiveSentinel,
    VibraGuardIndustrialSentinel,
    AgriSenseAgriTechSentinel,
    SilentSentryDefenseSentinel,
    AuraSenseSmartCitySentinel
)


class TestBitNetSectorHub(unittest.TestCase):

    def test_01_registry_integrity(self):
        """Verify all 6 sectors are present in registry with required metadata."""
        expected_keys = {"healthcare", "automotive", "industrial", "agritech", "defense", "smart_city"}
        self.assertEqual(set(SECTOR_REGISTRY.keys()), expected_keys)
        for key, info in SECTOR_REGISTRY.items():
            self.assertIn("name", info)
            self.assertIn("description", info)
            self.assertIn("engine_class", info)
            self.assertIn("sample_input", info)
            self.assertIn("key_metric", info)

    def test_02_healthcare_sentinel(self):
        """Verify CardioPulse healthcare inference has zero multipliers and low latency."""
        engine = CardioPulseHealthcareSentinel()
        sample = [0.1 * (i % 5) for i in range(32)]
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], CardioPulseHealthcareSentinel.CLASSES)
        self.assertLess(res["latency_us"], 500.0)  # Sub-millisecond
        self.assertLess(res["energy_uj"], 50.0)    # Ultra-low energy

    def test_03_automotive_sentinel(self):
        """Verify Aegis-BMS automotive battery inference."""
        engine = AegisBMSAutomotiveSentinel()
        sample = [3.6, 3.6, 3.6, 3.6, 25.0, 25.0, 25.0, 25.0, 0.0, 0.0, 10.0, 1.0] + [0.0] * 4
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], AegisBMSAutomotiveSentinel.CLASSES)
        self.assertLess(res["latency_us"], 500.0)

    def test_04_industrial_sentinel(self):
        """Verify VibraGuard industrial motor vibration inference."""
        engine = VibraGuardIndustrialSentinel()
        sample = [0.1 * (i % 3) for i in range(24)]
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], VibraGuardIndustrialSentinel.CLASSES)

    def test_05_agritech_sentinel(self):
        """Verify AgriSense smart agriculture inference."""
        engine = AgriSenseAgriTechSentinel()
        sample = [0.7, 0.4, 30.0, 1.0, 25.0, 60.0] * 2
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], AgriSenseAgriTechSentinel.CLASSES)

    def test_06_defense_sentinel(self):
        """Verify SilentSentry zero-RF defense perimeter inference."""
        engine = SilentSentryDefenseSentinel()
        sample = [0.05 * (i % 4) for i in range(32)]
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], SilentSentryDefenseSentinel.CLASSES)

    def test_07_smart_city_sentinel(self):
        """Verify AuraSense privacy audio wake-word inference."""
        engine = AuraSenseSmartCitySentinel()
        sample = [1.0 * (i % 8) for i in range(40)]
        res = engine.run_inference(sample)
        self.assertEqual(res["multipliers_used"], 0)
        self.assertIn(res["prediction"], AuraSenseSmartCitySentinel.CLASSES)

    def test_08_run_all_sector_benchmarks(self):
        """Verify automated cross-sector benchmark runs 6/6 cleanly."""
        results = run_all_sector_benchmarks()
        self.assertEqual(len(results), 6)
        for r in results:
            self.assertEqual(r["multipliers_used"], 0)
            self.assertGreater(r["confidence"], 0.0)
            self.assertLessEqual(r["confidence"], 1.0)


if __name__ == "__main__":
    unittest.main()
