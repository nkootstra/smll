#!/usr/bin/env python3
"""Unit tests for the hardening benchmark's regression calculations."""

from __future__ import annotations

import importlib.util
import io
import pathlib
import sys
import unittest
from contextlib import redirect_stderr


MODULE_PATH = pathlib.Path(__file__).with_name("bench-hardening.py")
SPEC = importlib.util.spec_from_file_location("bench_hardening", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
bench = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bench
SPEC.loader.exec_module(bench)


class HardeningBenchmarkTests(unittest.TestCase):
    def test_regression_gate_requires_a_baseline(self) -> None:
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            bench.parse_args([])
        self.assertEqual(raised.exception.code, 2)

    def test_nearest_rank_p95(self) -> None:
        self.assertEqual(bench.percentile_nearest_rank(list(range(1, 21)), 0.95), 19)

    def test_regression_percentage_preserves_improvements(self) -> None:
        self.assertEqual(bench.regression_pct(10.0, 9.0), -10.0)

    def test_either_median_or_p95_can_fail_budget(self) -> None:
        baseline = bench.Summary(median_ms=10.0, p95_ms=20.0)
        self.assertTrue(bench.regressed(baseline, bench.Summary(11.1, 20.0), 10.0))
        self.assertTrue(bench.regressed(baseline, bench.Summary(10.0, 22.1), 10.0))
        self.assertFalse(bench.regressed(baseline, bench.Summary(11.0, 22.0), 10.0))


if __name__ == "__main__":
    unittest.main()
