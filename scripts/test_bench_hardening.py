#!/usr/bin/env python3
"""Unit tests for the hardening benchmark's regression calculations."""

from __future__ import annotations

import importlib.util
import io
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock


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

    def test_state_writer_waits_for_every_child_before_raising(self) -> None:
        failed = mock.Mock()
        failed.wait.return_value = 1
        succeeded = mock.Mock()
        succeeded.wait.return_value = 0
        with mock.patch.object(bench.subprocess, "Popen", side_effect=[failed, succeeded]):
            with self.assertRaisesRegex(RuntimeError, "concurrent state writer failed"):
                bench.state_write_sample(pathlib.Path("/tmp/smll"), 2)
        failed.wait.assert_called_once_with()
        succeeded.wait.assert_called_once_with()

    def test_existing_non_executable_binary_is_reported_precisely(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            binary = pathlib.Path(root) / "smll"
            binary.write_text("not executable\n", encoding="utf-8")
            binary.chmod(0o600)
            argv = ["bench-hardening.py", "--baseline-bin", str(binary), "--candidate-bin", str(binary)]
            with mock.patch.object(sys, "argv", argv), self.assertRaises(SystemExit) as raised:
                bench.main()
        self.assertIn("not executable", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
