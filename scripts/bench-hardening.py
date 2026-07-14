#!/usr/bin/env python3
"""Same-host regression benchmark for smll's hardening contracts.

The benchmark measures a candidate and its pre-change binary in one
interleaved run. This avoids treating machine-specific absolute timings as a
portable baseline while still enforcing the 10% median/p95 regression budget.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import statistics
import subprocess
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOK_EVENT = b'{"tool_input":{"command":"git status"}}\n'
THROUGHPUT_FIXTURE = REPO_ROOT / "tests/fixtures/large/git_diff.txt"


@dataclass(frozen=True)
class Summary:
    median_ms: float
    p95_ms: float


def percentile_nearest_rank(samples: list[float], percentile: float) -> float:
    if not samples:
        raise ValueError("samples must not be empty")
    ordered = sorted(samples)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def summarize(samples: list[float]) -> Summary:
    return Summary(
        median_ms=statistics.median(samples),
        p95_ms=percentile_nearest_rank(samples, 0.95),
    )


def regression_pct(baseline: float, candidate: float) -> float:
    if baseline <= 0:
        return 0.0 if candidate <= baseline else math.inf
    return 100.0 * (candidate - baseline) / baseline


def regressed(baseline: Summary, candidate: Summary, threshold_pct: float) -> bool:
    return (
        regression_pct(baseline.median_ms, candidate.median_ms) > threshold_pct
        or regression_pct(baseline.p95_ms, candidate.p95_ms) > threshold_pct
    )


def clean_env() -> dict[str, str]:
    env = os.environ.copy()
    env["DO_NOT_TRACK"] = "1"
    env["SMLL_TEE"] = "0"
    env.pop("SMLL_LOSSLESS", None)
    env.pop("SMLL_STREAM", None)
    return env


def elapsed_ms(action: Callable[[], None]) -> float:
    start = time.perf_counter_ns()
    action()
    return (time.perf_counter_ns() - start) / 1_000_000


def run_checked(
    binary: pathlib.Path,
    args: tuple[str, ...],
    *,
    input_data: bytes | None = None,
    env: dict[str, str] | None = None,
) -> bytes:
    result = subprocess.run(
        (str(binary), *args),
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env or clean_env(),
        check=True,
    )
    return result.stdout


def startup_sample(binary: pathlib.Path) -> float:
    return elapsed_ms(lambda: run_checked(binary, ("--version",)))


def hook_sample(binary: pathlib.Path) -> float:
    output = b""

    def invoke() -> None:
        nonlocal output
        output = run_checked(binary, ("--hook-eval", "codex"), input_data=HOOK_EVENT)

    duration = elapsed_ms(invoke)
    if b'"permissionDecision":"deny"' not in output:
        raise RuntimeError(f"{binary}: hook benchmark did not produce a deny decision")
    return duration


def filter_sample(binary: pathlib.Path, fixture: bytes) -> float:
    return elapsed_ms(lambda: run_checked(binary, (), input_data=fixture))


def state_write_sample(binary: pathlib.Path, workers: int) -> float:
    with tempfile.TemporaryDirectory(prefix="smll-state-bench-") as root_text:
        root = pathlib.Path(root_text)
        bin_dir = root / "bin"
        home = root / "home"
        bin_dir.mkdir()
        home.mkdir()
        command = bin_dir / "state-writer"
        command.write_text("#!/bin/sh\nprintf 'state output\\n'\n", encoding="utf-8")
        command.chmod(0o700)

        env = os.environ.copy()
        env.pop("DO_NOT_TRACK", None)
        env.pop("SMLL_LOSSLESS", None)
        env.pop("SMLL_STREAM", None)
        env["SMLL_TEE"] = "0"
        env["HOME"] = str(home)
        env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"

        children: list[subprocess.Popen[bytes]] = []

        def invoke() -> None:
            for _ in range(workers):
                children.append(
                    subprocess.Popen(
                        (str(binary), "state-writer"),
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        env=env,
                    )
                )
            statuses = [child.wait() for child in children]
            if any(status != 0 for status in statuses):
                raise RuntimeError(f"{binary}: concurrent state writer failed")

        duration = elapsed_ms(invoke) / workers
        stats = json.loads((home / ".smll/stats.json").read_text(encoding="utf-8"))
        if stats.get("commands") != workers:
            raise RuntimeError(f"{binary}: concurrent stats lost updates")
        history = (home / ".smll/history.jsonl").read_text(encoding="utf-8")
        if history.count('"cmd":"state-writer"') != workers:
            raise RuntimeError(f"{binary}: concurrent history lost updates")
        return duration


def collect_pair(
    sample: Callable[[pathlib.Path], float],
    candidate: pathlib.Path,
    baseline: pathlib.Path,
    runs: int,
    warmup: int,
) -> tuple[Summary, Summary]:
    binaries = [baseline, candidate]
    for _ in range(warmup):
        for binary in binaries:
            sample(binary)

    candidate_samples: list[float] = []
    baseline_samples: list[float] = []
    for run_index in range(runs):
        ordered = binaries if run_index % 2 == 0 else list(reversed(binaries))
        for binary in ordered:
            value = sample(binary)
            if binary == baseline:
                baseline_samples.append(value)
            else:
                candidate_samples.append(value)
    return (
        summarize(baseline_samples),
        summarize(candidate_samples),
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-bin", type=pathlib.Path, default=REPO_ROOT / "zig-out/release/smll")
    parser.add_argument("--baseline-bin", type=pathlib.Path, required=True)
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--state-workers", type=int, default=8)
    parser.add_argument("--threshold-pct", type=float, default=10.0)
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    candidate = args.candidate_bin.resolve()
    baseline = args.baseline_bin.resolve()
    for binary in (candidate, baseline):
        if not binary.exists():
            raise SystemExit(f"error: executable not found: {binary}")
        if not os.access(binary, os.X_OK):
            raise SystemExit(f"error: file is not executable: {binary}")
    if args.runs < 2 or args.warmup < 0 or args.state_workers < 2:
        raise SystemExit("error: runs >= 2, warmup >= 0, and state-workers >= 2 are required")

    fixture = THROUGHPUT_FIXTURE.read_bytes()
    metrics: tuple[tuple[str, Callable[[pathlib.Path], float]], ...] = (
        ("warm startup", startup_sample),
        ("hook classification", hook_sample),
        ("pipe filter throughput", lambda binary: filter_sample(binary, fixture)),
        ("concurrent state write/op", lambda binary: state_write_sample(binary, args.state_workers)),
    )

    print("# smll hardening regression benchmark")
    print()
    print(f"runs: {args.runs}; warmup: {args.warmup}; threshold: {args.threshold_pct:.1f}%")
    print(f"candidate: `{candidate}`")
    print(f"baseline: `{baseline}`")
    print()
    print("| metric | baseline median | candidate median | delta | baseline p95 | candidate p95 | delta |")
    print("|---|---:|---:|---:|---:|---:|---:|")

    failures: list[str] = []
    for name, sample in metrics:
        baseline_summary, candidate_summary = collect_pair(
            sample, candidate, baseline, args.runs, args.warmup
        )
        median_delta = regression_pct(baseline_summary.median_ms, candidate_summary.median_ms)
        p95_delta = regression_pct(baseline_summary.p95_ms, candidate_summary.p95_ms)
        print(
            f"| {name} | {baseline_summary.median_ms:.3f} ms | {candidate_summary.median_ms:.3f} ms | "
            f"{median_delta:+.1f}% | {baseline_summary.p95_ms:.3f} ms | {candidate_summary.p95_ms:.3f} ms | {p95_delta:+.1f}% |"
        )
        if regressed(baseline_summary, candidate_summary, args.threshold_pct):
            failures.append(name)

    if failures:
        print()
        print(f"regressions above {args.threshold_pct:.1f}%: {', '.join(failures)}")
        return 1
    print()
    print(f"no median or p95 regression exceeded {args.threshold_pct:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
