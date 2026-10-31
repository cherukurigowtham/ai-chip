#!/usr/bin/env python3
"""
calibrated_optimizer.py - Silicon-Calibrated Architecture Search Engine.

Searches the architecture configuration space under empirical post-synthesis
silicon constraints (A <= 200,000 um^2, S_SRAM <= 1,082 Bytes).
"""

from typing import Dict, Any, List, Optional
from calibrated_cost_model import CalibratedCostModel, MAX_AREA_BUDGET_UM2

class CalibratedOptimizer:
    def __init__(self, rows: int = 4, cols: int = 4):
        self.rows = rows
        self.cols = cols
        self.cost_model = CalibratedCostModel(rows, cols)

    def get_candidate_tiles(self, dim: int, max_val: int = 32) -> List[int]:
        candidates = set()
        for base in [4, 8, 16, 24, 32]:
            if base <= max_val:
                candidates.add(base)
        if dim <= max_val and dim % 4 == 0:
            candidates.add(dim)
        elif dim < 4:
            candidates.add(4)
        return sorted([c for c in candidates if c <= max_val])

    def evaluate_fixed_ws(self, M: int, K: int, N: int) -> Dict[str, Any]:
        T_M = min(16, max(4, ((M + 3) // 4) * 4))
        T_K = 4
        T_N = 4
        res = self.cost_model.evaluate(M, K, N, "WS", T_M, T_K, T_N, double_buffering=True)
        if res is None:
            res = self.cost_model.evaluate(M, K, N, "WS", T_M, T_K, T_N, double_buffering=False)
        assert res is not None, f"Fixed WS failed for M={M}, K={K}, N={N}"
        res["strategy"] = "Fixed WS (Calibrated)"
        return res

    def evaluate_fixed_os(self, M: int, K: int, N: int) -> Dict[str, Any]:
        T_M = 4
        T_K = min(16, max(4, ((K + 3) // 4) * 4))
        T_N = 4
        res = self.cost_model.evaluate(M, K, N, "OS", T_M, T_K, T_N, double_buffering=True)
        if res is None:
            res = self.cost_model.evaluate(M, K, N, "OS", T_M, T_K, T_N, double_buffering=False)
        assert res is not None, f"Fixed OS failed for M={M}, K={K}, N={N}"
        res["strategy"] = "Fixed OS (Calibrated)"
        return res

    def evaluate_heuristic_adaptive(self, M: int, K: int, N: int) -> Dict[str, Any]:
        if K <= 4 or (M >= 2 * K):
            res = self.evaluate_fixed_ws(M, K, N)
            res["strategy"] = "Heuristic WS (Calibrated)"
        else:
            res = self.evaluate_fixed_os(M, K, N)
            res["strategy"] = "Heuristic OS (Calibrated)"
        return res

    def optimize(self, M: int, K: int, N: int) -> Dict[str, Any]:
        best_cfg = None
        best_energy = float("inf")
        evaluated_candidates = 0
        valid_candidates = 0

        tm_candidates = self.get_candidate_tiles(M, max_val=32)
        tk_candidates = self.get_candidate_tiles(K, max_val=32)
        tn_candidates = self.get_candidate_tiles(N, max_val=32)

        for df in ["WS", "OS"]:
            for tm in tm_candidates:
                for tk in tk_candidates:
                    for tn in tn_candidates:
                        for db in [False, True]:
                            evaluated_candidates += 1
                            res = self.cost_model.evaluate(M, K, N, df, tm, tk, tn, double_buffering=db)
                            if res is None:
                                continue # Violated physical silicon budget or capacity!

                            valid_candidates += 1
                            if res["total_energy_uj"] < best_energy:
                                best_energy = res["total_energy_uj"]
                                best_cfg = res

        assert best_cfg is not None, f"Calibrated optimizer found no valid configuration for M={M}, K={K}, N={N}"
        best_cfg["strategy"] = "Calibrated Optimizer"
        best_cfg["evaluated_candidates"] = evaluated_candidates
        best_cfg["valid_candidates"] = valid_candidates
        return best_cfg
