#!/usr/bin/env python3
"""Unit tests for same-basis benchmark comparison metrics."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "scripts/compare-rtk.py"


def load_compare_module():
    spec = importlib.util.spec_from_file_location("compare_rtk", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


compare = load_compare_module()


def row(
    name: str,
    raw_tokens: int,
    smll_tokens: int,
    rtk_tokens: int,
    raw_bytes: int,
    smll_bytes: int,
    rtk_bytes: int,
) -> dict:
    return {
        "name": name,
        "raw": {"tokens": raw_tokens, "bytes": raw_bytes, "stderr_bytes": 0},
        "smll": {"tokens": smll_tokens, "bytes": smll_bytes, "stderr_bytes": 0},
        "rtk": {"tokens": rtk_tokens, "bytes": rtk_bytes, "stderr_bytes": 0},
    }


class CompareRtkMetricTests(unittest.TestCase):
    def test_declared_omission_recognizes_only_smll_marker_lines(self) -> None:
        self.assertTrue(
            compare.has_declared_omission(
                b"(smll: omitted 5 relevant lines; rerun with smll --raw)\n"
            )
        )
        self.assertTrue(
            compare.has_declared_omission(
                b"src/ (4 entries: a, b, c; 1 omitted; --raw for all)\n"
            )
        )
        self.assertFalse(compare.has_declared_omission(b"--raw flag was omitted\n"))
        self.assertFalse(
            compare.has_declared_omission(b"child; 1 omitted; --raw for all)\n")
        )
        self.assertFalse(
            compare.has_declared_omission(
                b"(smll: omitted many relevant lines; rerun with smll --raw)\n"
            )
        )

    def test_benchmark_savings_are_unclamped(self) -> None:
        self.assertEqual(compare.benchmark_saved_tokens(100, 125), -25)
        self.assertEqual(compare.benchmark_savings_pct(100, 125), -25.0)

    def test_expansion_cases_reduce_net_saved_tokens(self) -> None:
        summary = compare.build_summary(2, raw_tokens=200, smll_tokens=80, rtk_tokens=200)
        self.assertEqual(summary["rtk_saved_tokens"], 0)
        self.assertEqual(summary["rtk_savings_pct"], 0.0)

        stats = compare.build_stats_models(
            [
                row("positive", 100, 40, 80, 400, 160, 320),
                row("expansion", 100, 40, 120, 400, 160, 480),
            ],
            raw_tokens=200,
            smll_tokens=80,
            rtk_tokens=200,
        )
        self.assertEqual(stats["rtk_gain"]["exact_benchmark_tokens_saved"], 0)
        self.assertEqual(stats["rtk_gain"]["exact_expansion_tokens"], 20)
        self.assertEqual(stats["rtk_gain"]["expansion_case_count"], 1)

    def test_winner_uses_benchmark_tokens(self) -> None:
        summary = compare.build_summary(1, raw_tokens=1000, smll_tokens=400, rtk_tokens=700)
        self.assertEqual(summary["winner"], "smll")
        self.assertEqual(summary["smll_saved_tokens"], 600)
        self.assertEqual(summary["rtk_saved_tokens"], 300)

    def test_native_estimates_do_not_drive_winner(self) -> None:
        summary = compare.build_summary(1, raw_tokens=1000, smll_tokens=100, rtk_tokens=900)
        stats = compare.build_stats_models(
            [row("bytes-favor-rtk", 1000, 100, 900, 4000, 3900, 1000)],
            raw_tokens=1000,
            smll_tokens=100,
            rtk_tokens=900,
        )

        self.assertEqual(summary["winner"], "smll")
        self.assertGreater(
            stats["rtk_gain"]["estimated_tokens_saved"],
            stats["smll_stats"]["estimated_tokens_saved"],
        )
        self.assertEqual(stats["smll_stats"]["role"], "native_estimate_diagnostic")
        self.assertEqual(stats["rtk_gain"]["role"], "native_estimate_diagnostic")

    def test_smll_native_estimate_excludes_declared_omissions(self) -> None:
        cases = [
            {
                "name": "declared",
                "raw": {"bytes": 100, "stderr_bytes": 0, "tokens": 25},
                "smll": {"bytes": 20, "stderr_bytes": 0, "tokens": 5, "declared_omission": True},
                "rtk": {"bytes": 20, "tokens": 5},
            },
            {
                "name": "formatted",
                "raw": {"bytes": 100, "stderr_bytes": 0, "tokens": 25},
                "smll": {"bytes": 40, "stderr_bytes": 0, "tokens": 10, "declared_omission": False},
                "rtk": {"bytes": 40, "tokens": 10},
            },
        ]
        stats = compare.build_stats_models(cases, raw_tokens=50, smll_tokens=20, rtk_tokens=20)
        self.assertEqual(stats["smll_stats"]["omitted_bytes"], 80)
        self.assertEqual(stats["smll_stats"]["saved_bytes"], 60)
        self.assertEqual(stats["smll_stats"]["estimated_tokens_saved"], 15)


if __name__ == "__main__":
    unittest.main()
