#!/usr/bin/env python3
"""
optimizer.py - Hardware-Aware AI Accelerator Architecture Search Engine.

Automatically searches the configuration space:
  - Dataflow: Weight-Stationary (WS) vs Output-Stationary (OS)
  - Tile dimensions: (T_M, T_K, T_N)
  - Buffering scheme: Single vs Double (Ping-Pong) Buffering
  - Physical constraint: Total Area <= 200,000 um^2 (0.20 mm^2)

Finds the Pareto-optimal configuration that minimizes total energy (pJ/MAC)
while satisfying strict silicon area and latency constraints.
"""

from typing import Dict, Any, List, Optional
from cost_model import HardwareCostModel, MAX_AREA_BUDGET_UM2

class ArchitectureOptimizer:
    def __init__(self, rows: int = 4, cols: int = 4, max_area_um2: float = MAX_AREA_BUDGET_UM2):
        self.rows = rows
        self.cols = cols
        self.cost_model = HardwareCostModel(rows, cols)
        self.max_area_um2 = max_area_um2

    def get_candidate_tiles(self, dim: int, max_val: int = 64) -> List[int]:
        """Generate valid tile candidates aligned to systolic array dimensions."""
        candidates = set()
        for base in [4, 8, 16, 32, 64]:
            if base <= max_val:
                candidates.add(base)
        # Also include exact dim if small or multiple
        if dim <= max_val and dim % 4 == 0:
            candidates.add(dim)
        elif dim < 4:
            candidates.add(4)
        return sorted([c for c in candidates if c <= max_val])

    def evaluate_fixed_ws(self, M: int, K: int, N: int) -> Dict[str, Any]:
        """Baseline 1: Fixed Weight-Stationary with default parameters."""
        T_M = min(32, max(4, ((M + 3) // 4) * 4))
        T_K = 4
        T_N = 4
        res = self.cost_model.evaluate(M, K, N, "WS", T_M, T_K, T_N, double_buffering=True)
        if res is None:
            # Fall back to single buffering if double buffering exceeded area
            res = self.cost_model.evaluate(M, K, N, "WS", T_M, T_K, T_N, double_buffering=False)
        assert res is not None, f"Fixed WS failed to fit for M={M}, K={K}, N={N}"
        res["strategy"] = "Fixed WS"
        return res

    def evaluate_fixed_os(self, M: int, K: int, N: int) -> Dict[str, Any]:
        """Baseline 2: Fixed Output-Stationary with default parameters."""
        T_M = 4
        T_K = min(64, max(4, ((K + 3) // 4) * 4))
        T_N = 4
        res = self.cost_model.evaluate(M, K, N, "OS", T_M, T_K, T_N, double_buffering=True)
        if res is None:
            res = self.cost_model.evaluate(M, K, N, "OS", T_M, T_K, T_N, double_buffering=False)
        assert res is not None, f"Fixed OS failed to fit for M={M}, K={K}, N={N}"
        res["strategy"] = "Fixed OS"
        return res

    def evaluate_heuristic_adaptive(self, M: int, K: int, N: int) -> Dict[str, Any]:
        """Baseline 3: Phase 12 Heuristic (K <= 4 or M >= 2*K => WS, else OS)."""
        if K <= 4 or (M >= 2 * K):
            res = self.evaluate_fixed_ws(M, K, N)
            res["strategy"] = "Heuristic (WS)"
        else:
            res = self.evaluate_fixed_os(M, K, N)
            res["strategy"] = "Heuristic (OS)"
        return res

    def optimize(self, M: int, K: int, N: int, latency_deadline_cycles: Optional[int] = None) -> Dict[str, Any]:
        """
        Global Search Engine:
        Evaluates full combinatorial search space:
          dataflows x T_M x T_K x T_N x buffering_modes
        Pruning any candidate that violates area budget or latency deadline.
        Returns the optimal configuration minimizing total energy.
        """
        best_cfg = None
        best_energy = float("inf")
        evaluated_candidates = 0
        valid_candidates = 0

        tm_candidates = self.get_candidate_tiles(M, max_val=64)
        tk_candidates = self.get_candidate_tiles(K, max_val=64)
        tn_candidates = self.get_candidate_tiles(N, max_val=64)

        for df in ["WS", "OS"]:
            for tm in tm_candidates:
                for tk in tk_candidates:
                    for tn in tn_candidates:
                        for db in [False, True]:
                            evaluated_candidates += 1
                            res = self.cost_model.evaluate(M, K, N, df, tm, tk, tn, double_buffering=db)
                            if res is None:
                                continue # Violated area budget (Area > 200,000 um^2)

                            if latency_deadline_cycles and res["total_cycles"] > latency_deadline_cycles:
                                continue # Violated latency deadline

                            valid_candidates += 1
                            if res["total_energy_uj"] < best_energy:
                                best_energy = res["total_energy_uj"]
                                best_cfg = res

        assert best_cfg is not None, f"Search engine found no valid configuration for M={M}, K={K}, N={N}"
        best_cfg["strategy"] = "Optimizer"
        best_cfg["evaluated_candidates"] = evaluated_candidates
        best_cfg["valid_candidates"] = valid_candidates
        return best_cfg
