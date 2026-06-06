#!/usr/bin/env python3
"""Compare normal command output against smll and rtk for token savings."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import math
import os
import pathlib
import shlex
import statistics
import subprocess
import sys
import tempfile
import time
from typing import Iterable


@dataclasses.dataclass(frozen=True)
class ArgFixture:
    args: tuple[str, ...]
    fixture: str
    stderr_fixture: str | None = None
    stream: str = "stdout"
    exit_code: int | None = None


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    category: str
    command: tuple[str, ...]
    fixture: str
    profiles: tuple[str, ...] = ("agent",)
    stderr_fixture: str | None = None
    stream: str = "stdout"
    exit_code: int = 0
    signals: tuple[str, ...] = ()
    tool_signals: dict[str, tuple[str, ...]] = dataclasses.field(default_factory=dict)
    arg_fixtures: tuple[ArgFixture, ...] = ()
    git_porcelain: str | None = None
    git_stat: str | None = None


@dataclasses.dataclass
class ToolRun:
    stdout: bytes
    stderr: bytes
    exit_code: int
    median_ms: float

    @property
    def combined(self) -> bytes:
        return self.stdout + self.stderr


CASES_FILE = pathlib.Path("benchmarks/smll-vs-rtk/cases.json")
COMPARISON_BASIS = "tokenizer(stdout+stderr), net savings, unclamped"


class TokenCounter:
    def __init__(self, requested: str, require: bool):
        self.requested = requested
        self.actual = requested
        self._encoding = None
        if requested == "approx":
            return
        try:
            import tiktoken  # type: ignore

            self._encoding = tiktoken.get_encoding(requested)
        except Exception as exc:  # pragma: no cover - depends on local env
            if require:
                raise SystemExit(f"error: tokenizer {requested!r} unavailable: {exc}") from exc
            print(
                f"warning: tokenizer {requested!r} unavailable ({exc}); using approx bytes/4",
                file=sys.stderr,
            )
            self.actual = "approx"

    def count(self, data: bytes) -> int:
        if self._encoding is None:
            return math.ceil(len(data) / 4)
        return len(self._encoding.encode(data.decode("utf-8", errors="replace")))


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[1]


def load_cases(root: pathlib.Path, profile: str) -> tuple[Case, ...]:
    path = root / CASES_FILE
    data = json.loads(path.read_text(encoding="utf-8"))
    cases: list[Case] = []
    for item in data["cases"]:
        profiles = tuple(item.get("profiles", ("agent",)))
        if profile != "all" and profile not in profiles:
            continue
        cases.append(
            Case(
                name=item["name"],
                category=item["category"],
                command=tuple(item["command"]),
                fixture=item["fixture"],
                profiles=profiles,
                stderr_fixture=item.get("stderr_fixture"),
                stream=item.get("stream", "stdout"),
                exit_code=item.get("exit_code", 0),
                signals=tuple(item.get("signals", ())),
                tool_signals={
                    tool: tuple(signals)
                    for tool, signals in item.get("tool_signals", {}).items()
                },
                arg_fixtures=tuple(
                    ArgFixture(
                        args=tuple(variant["args"]),
                        fixture=variant["fixture"],
                        stderr_fixture=variant.get("stderr_fixture"),
                        stream=variant.get("stream", "stdout"),
                        exit_code=variant.get("exit_code"),
                    )
                    for variant in item.get("arg_fixtures", ())
                ),
                git_porcelain=item.get("git_porcelain"),
                git_stat=item.get("git_stat"),
            )
        )
    return tuple(cases)


def run_text(argv: list[str], cwd: pathlib.Path) -> str:
    try:
        out = subprocess.run(
            argv,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        ).stdout.strip()
    except OSError as exc:
        return f"unavailable: {exc}"
    return out or "unavailable"


def build_smll(root: pathlib.Path) -> pathlib.Path:
    print("Building smll release...", file=sys.stderr)
    subprocess.run(["zig", "build", "release"], cwd=root, check=True)
    return root / "zig-out" / "release" / "smll"


def isolated_env(base: dict[str, str], state_dir: pathlib.Path) -> dict[str, str]:
    env = dict(base)
    env.update(
        {
            "HOME": str(state_dir / "home"),
            "XDG_CONFIG_HOME": str(state_dir / "xdg-config"),
            "XDG_DATA_HOME": str(state_dir / "xdg-data"),
            "RTK_TELEMETRY_DISABLED": "1",
            "DO_NOT_TRACK": "1",
            "SMLL_TEE": "0",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "LC_ALL": "C",
            "LANG": "C",
        }
    )
    for key in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"):
        pathlib.Path(env[key]).mkdir(parents=True, exist_ok=True)
    return env


def shell_array(values: Iterable[str]) -> str:
    return " ".join(shlex.quote(v) for v in values)


def write_fake_tool(case: Case, bin_dir: pathlib.Path, root: pathlib.Path) -> None:
    tool = case.command[0]
    fixture_path = root / case.fixture
    stderr_fixture = shlex.quote(str(root / case.stderr_fixture)) if case.stderr_fixture else ""
    script = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        f"fixture={shlex.quote(str(fixture_path))}",
        f"stderr_fixture={stderr_fixture}",
        f"stream={shlex.quote(case.stream)}",
        f"exit_code={case.exit_code}",
        'if [ -n "${BENCH_INVOCATION_LOG:-}" ]; then',
        '  { printf "%s" "$#"; for arg in "$@"; do printf "\\t%s" "$arg"; done; printf "\\n"; } >> "$BENCH_INVOCATION_LOG"',
        "fi",
        "emit_fixture() {",
        '  if [ -n "$stderr_fixture" ]; then',
        '    cat "$fixture"',
        '    cat "$stderr_fixture" >&2',
        '  elif [ "$stream" = "stderr" ]; then',
        '    cat "$fixture" >&2',
        "  else",
        '    cat "$fixture"',
        "  fi",
        '  exit "$exit_code"',
        "}",
    ]

    if tool == "git" and case.command[1] == "status" and case.git_porcelain is not None:
        porcelain_path = bin_dir / "git-status-porcelain.txt"
        porcelain_path.write_text(case.git_porcelain, encoding="utf-8")
        script.extend(
            [
                'if [ "${1:-}" = "status" ]; then',
                '  for arg in "$@"; do',
                '    if [ "$arg" = "--porcelain" ]; then',
                f"      cat {shlex.quote(str(porcelain_path))}",
                '      exit "$exit_code"',
                "    fi",
                "  done",
                "fi",
            ]
        )

    if tool == "git" and case.command[1] == "diff" and case.git_stat is not None:
        stat_path = bin_dir / "git-diff-stat.txt"
        stat_path.write_text(case.git_stat, encoding="utf-8")
        script.extend(
            [
                'if [ "${1:-}" = "diff" ]; then',
                '  for arg in "$@"; do',
                '    if [ "$arg" = "--stat" ]; then',
                f"      cat {shlex.quote(str(stat_path))}",
                '      exit "$exit_code"',
                "    fi",
                "  done",
                "fi",
            ]
        )

    for variant in case.arg_fixtures:
        variant_fixture = root / variant.fixture
        variant_stderr = shlex.quote(str(root / variant.stderr_fixture)) if variant.stderr_fixture else ""
        condition = shell_args_condition(variant.args)
        script.extend(
            [
                f"if {condition}; then",
                f"  fixture={shlex.quote(str(variant_fixture))}",
                f"  stderr_fixture={variant_stderr}",
                f"  stream={shlex.quote(variant.stream)}",
                f"  exit_code={case.exit_code if variant.exit_code is None else variant.exit_code}",
                "  emit_fixture",
                "fi",
            ]
        )

    script.append("emit_fixture")

    path = bin_dir / tool
    path.write_text("\n".join(script) + "\n", encoding="utf-8")
    path.chmod(0o755)


def shell_args_condition(args: tuple[str, ...]) -> str:
    checks = [f'[ "$#" -eq {len(args)} ]']
    for idx, arg in enumerate(args, start=1):
        checks.append(f'[ "${{{idx}:-}}" = {shlex.quote(arg)} ]')
    return " && ".join(checks)


def expected_arg_variants(case: Case) -> tuple[tuple[str, ...], ...]:
    variants: list[tuple[str, ...]] = [case.command[1:]]
    variants.extend(variant.args for variant in case.arg_fixtures)
    return tuple(variants)


def args_allowed(case: Case, args: tuple[str, ...]) -> bool:
    if args in expected_arg_variants(case):
        return True

    # Some wrappers legitimately make extra fixture-backed probes to collect a
    # more compact summary. Keep these explicit so command rewrites remain
    # visible in the report.
    if case.command[0] == "git" and args:
        if case.git_porcelain is not None and args[0] == "status":
            return any(arg == "--porcelain" or arg.startswith("--porcelain=") for arg in args)
        if case.git_stat is not None and args[0] == "diff":
            return any(arg == "--stat" for arg in args)

    return False


def read_invocations(path: pathlib.Path) -> list[tuple[str, ...]]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return []

    invocations: list[tuple[str, ...]] = []
    for line in text.splitlines():
        if not line:
            continue
        fields = line.split("\t")
        try:
            argc = int(fields[0])
        except ValueError:
            continue
        args = tuple(fields[1:])
        if len(args) == argc:
            invocations.append(args)
    return invocations


def invocation_summary(case: Case, path: pathlib.Path) -> dict:
    invocations = read_invocations(path)
    unexpected = sorted({shell_array(args) for args in invocations if not args_allowed(case, args)})
    return {
        "invoked": bool(invocations),
        "count": len(invocations),
        "expected_arg_variants": [shell_array(args) for args in expected_arg_variants(case)],
        "unexpected_args": unexpected,
    }


def timed_run(
    argv: list[str],
    runs: int,
    warmup: int,
    cwd: pathlib.Path,
    env: dict[str, str],
    timeout_s: float,
) -> ToolRun:
    samples: list[float] = []
    last: subprocess.CompletedProcess[bytes] | None = None

    total = warmup + runs
    for idx in range(total):
        start = time.perf_counter()
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
            env=env,
            timeout=timeout_s,
            check=False,
        )
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        if idx >= warmup:
            samples.append(elapsed_ms)
            if last is None:
                last = proc

    if last is None:
        raise RuntimeError("runs must be at least 1")

    return ToolRun(
        stdout=last.stdout,
        stderr=last.stderr,
        exit_code=last.returncode,
        median_ms=statistics.median(samples),
    )


def missing_signals(data: bytes, signals: Iterable[str]) -> list[str]:
    text = data.decode("utf-8", errors="replace")
    return [signal for signal in signals if signal not in text]


def signals_for(case: Case, tool: str) -> tuple[str, ...]:
    return case.tool_signals.get(tool, case.signals)


def benchmark_saved_tokens(raw_tokens: int, tool_tokens: int) -> int:
    return raw_tokens - tool_tokens


def benchmark_savings_pct(raw_tokens: int, tool_tokens: int) -> float:
    if raw_tokens <= 0:
        return 0.0
    return 100.0 * benchmark_saved_tokens(raw_tokens, tool_tokens) / raw_tokens


def winner(smll_tokens: int, rtk_tokens: int) -> str:
    if smll_tokens < rtk_tokens:
        return "smll"
    if rtk_tokens < smll_tokens:
        return "rtk"
    return "tie"


def fmt_int(value: int) -> str:
    return f"{value:,}"


def count_run_tokens(counter: TokenCounter, run: ToolRun) -> int:
    return counter.count(run.stdout) + counter.count(run.stderr)


def div_ceil(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def build_stats_models(cases: list[dict], raw_tokens: int, smll_tokens: int, rtk_tokens: int) -> dict:
    raw_bytes = sum(row["raw"]["bytes"] for row in cases)
    raw_stderr_bytes = sum(row["raw"]["stderr_bytes"] for row in cases)
    smll_bytes = sum(row["smll"]["bytes"] for row in cases)
    smll_stderr_bytes = sum(row["smll"]["stderr_bytes"] for row in cases)
    smll_saved_bytes = max(raw_bytes - smll_bytes, 0)

    rtk_input_estimate = sum(div_ceil(row["raw"]["bytes"], 4) for row in cases)
    rtk_output_estimate = sum(div_ceil(row["rtk"]["bytes"], 4) for row in cases)
    rtk_saved_estimate = sum(
        max(
            div_ceil(row["raw"]["bytes"], 4) - div_ceil(row["rtk"]["bytes"], 4),
            0,
        )
        for row in cases
    )
    rtk_expansion_cases = [row["name"] for row in cases if row["rtk"]["tokens"] > row["raw"]["tokens"]]

    return {
        "smll_stats": {
            "role": "native_estimate_diagnostic",
            "basis": "agent-visible stdout+stderr bytes recorded by smll wrapper stats; displayed token savings are floor(saved_bytes / 4)",
            "input_bytes": raw_bytes,
            "output_bytes": smll_bytes,
            "saved_bytes": smll_saved_bytes,
            "estimated_tokens_saved": smll_saved_bytes // 4,
            "exact_benchmark_tokens_saved": benchmark_saved_tokens(raw_tokens, smll_tokens),
            "estimated_vs_exact_delta": (smll_saved_bytes // 4) - benchmark_saved_tokens(raw_tokens, smll_tokens),
            "included_raw_stderr_bytes": raw_stderr_bytes,
            "included_smll_stderr_bytes": smll_stderr_bytes,
            "factuality": "Factual for smll's recorded agent-visible byte totals; token savings remain an explicit bytes/4 estimate, not tokenizer-factual.",
        },
        "rtk_gain": {
            "role": "native_estimate_diagnostic",
            "basis": "ceil(combined stdout+stderr bytes / 4) token estimates, with per-command saved_tokens clamped at zero",
            "estimated_input_tokens": rtk_input_estimate,
            "estimated_output_tokens": rtk_output_estimate,
            "estimated_tokens_saved": rtk_saved_estimate,
            "exact_benchmark_tokens_saved": benchmark_saved_tokens(raw_tokens, rtk_tokens),
            "estimated_vs_exact_delta": rtk_saved_estimate - benchmark_saved_tokens(raw_tokens, rtk_tokens),
            "exact_positive_tokens_saved": sum(max(row["raw"]["tokens"] - row["rtk"]["tokens"], 0) for row in cases),
            "exact_expansion_tokens": sum(max(row["rtk"]["tokens"] - row["raw"]["tokens"], 0) for row in cases),
            "expansion_case_count": len(rtk_expansion_cases),
            "expansion_cases": rtk_expansion_cases,
            "factuality": "Factual for rtk's stored heuristic estimates; not factual for tokenizer tokens, and expansion cases do not reduce saved_tokens.",
        },
    }


def build_summary(case_count: int, raw_tokens: int, smll_tokens: int, rtk_tokens: int) -> dict:
    smll_saved = benchmark_saved_tokens(raw_tokens, smll_tokens)
    rtk_saved = benchmark_saved_tokens(raw_tokens, rtk_tokens)
    return {
        "winner": winner(smll_tokens, rtk_tokens),
        "case_count": case_count,
        "raw_tokens": raw_tokens,
        "smll_tokens": smll_tokens,
        "rtk_tokens": rtk_tokens,
        "smll_saved_tokens": smll_saved,
        "rtk_saved_tokens": rtk_saved,
        "smll_savings_pct": benchmark_savings_pct(raw_tokens, smll_tokens),
        "rtk_savings_pct": benchmark_savings_pct(raw_tokens, rtk_tokens),
        "smll_vs_rtk_delta_tokens": smll_tokens - rtk_tokens,
    }


def rel_link(path: pathlib.Path, base: pathlib.Path | None) -> str:
    if base is None:
        return str(path)
    try:
        return path.relative_to(base).as_posix()
    except ValueError:
        return str(path)


def render_markdown(result: dict, markdown_path: pathlib.Path | None) -> str:
    summary = result["summary"]
    settings = result["settings"]
    markdown_dir = markdown_path.parent if markdown_path else None
    lines = [
        "# smll vs rtk command token benchmark",
        "",
        f"- Profile: `{settings['profile']}` ({summary['case_count']} cases)",
        f"- Winner for this profile: **{summary['winner']}**",
        f"- Tokenizer: {result['tokenizer']['actual']} (requested: {result['tokenizer']['requested']})",
        f"- Comparison basis: `{settings['comparison_basis']}`",
        "",
        "Each row invokes the same top-level command three ways: the normal command, `smll <command>`, and `rtk <command>`. Full captured outputs are embedded below and written next to this report.",
        "",
        "The fixture tool records whether each wrapper called the committed fixture command as declared. Warnings show missing signals, exit-code mismatches, fixture bypasses, or wrapper-side argument rewrites; those rows still measure observed wrapper behavior, but they are not pure identical-child-invocation rows.",
        "",
        "## Same-Basis Benchmark Score",
        "",
        "Benchmark savings are exact tokenizer-counted stdout+stderr tokens. Expansions are not clamped; negative savings reduce totals.",
        "",
        "| output | tokens | saved vs raw | saved |",
        "|---|---:|---:|---:|",
        "| raw commands | {tokens} | - | - |".format(tokens=fmt_int(summary["raw_tokens"])),
        "| `smll` | {tokens} | {saved} | {pct:.1f}% |".format(
            tokens=fmt_int(summary["smll_tokens"]),
            saved=fmt_int(summary["smll_saved_tokens"]),
            pct=summary["smll_savings_pct"],
        ),
        "| `rtk` | {tokens} | {saved} | {pct:.1f}% |".format(
            tokens=fmt_int(summary["rtk_tokens"]),
            saved=fmt_int(summary["rtk_saved_tokens"]),
            pct=summary["rtk_savings_pct"],
        ),
        "",
        "## Native Product Estimates",
        "",
        "These rows model what each tool's own cumulative stats feature would report for this benchmark. They are not used for the winner; formulas differ by product and are not directly comparable to the tokenizer score.",
        "",
        "| native estimate | basis | product estimate | benchmark equivalent | gap | note |",
        "|---|---|---:|---:|---:|---|",
    ]
    stats_models = result["stats_models"]
    smll_stats = stats_models["smll_stats"]
    rtk_gain = stats_models["rtk_gain"]
    lines.extend(
        [
            "| `smll --stats` | stdout+stderr bytes, then saved bytes / 4 | {estimate} est. saved tokens | {exact} net saved tokens | {gap} | {note} |".format(
                estimate=fmt_int(smll_stats["estimated_tokens_saved"]),
                exact=fmt_int(smll_stats["exact_benchmark_tokens_saved"]),
                gap=fmt_int(smll_stats["estimated_vs_exact_delta"]),
                note=smll_stats["factuality"],
            ),
            "| `rtk gain` | combined bytes / 4, per-command saved tokens clamped at zero | {estimate} est. saved tokens | {exact} net saved tokens | {gap} | {note} |".format(
                estimate=fmt_int(rtk_gain["estimated_tokens_saved"]),
                exact=fmt_int(rtk_gain["exact_benchmark_tokens_saved"]),
                gap=fmt_int(rtk_gain["estimated_vs_exact_delta"]),
                note=rtk_gain["factuality"],
            ),
            "",
            "`smll --stats` includes {raw_stderr} raw stderr bytes in this benchmark's input accounting. `rtk gain` would hide {expansion_cases} expansion cases totaling {expansion_tokens} exact tokenizer tokens because its saved-token field saturates each command at zero.".format(
                raw_stderr=fmt_int(smll_stats["included_raw_stderr_bytes"]),
                expansion_cases=fmt_int(rtk_gain["expansion_case_count"]),
                expansion_tokens=fmt_int(rtk_gain["exact_expansion_tokens"]),
            ),
            "",
            "## Categories",
            "",
            "| category | raw | smll | rtk | winner | smll saved | rtk saved |",
            "|---|---:|---:|---:|---|---:|---:|",
        ]
    )
    for row in result["categories"]:
        lines.append(
            "| {category} | {raw} | {smll} | {rtk} | {winner} | {smll_pct:.1f}% | {rtk_pct:.1f}% |".format(
                category=row["category"],
                raw=fmt_int(row["raw_tokens"]),
                smll=fmt_int(row["smll_tokens"]),
                rtk=fmt_int(row["rtk_tokens"]),
                winner=row["winner"],
                smll_pct=row["smll_savings_pct"],
                rtk_pct=row["rtk_savings_pct"],
            )
        )

    lines.extend(
        [
            "",
            "## Commands",
            "",
            "| case | command | raw | smll | rtk | winner | delta | outputs | warnings |",
            "|---|---|---:|---:|---:|---|---:|---|---|",
        ]
    )
    for row in result["cases"]:
        warnings = []
        raw_exit = row["raw"]["exit_code"]
        for tool in ("smll", "rtk"):
            exit_code = row[tool]["exit_code"]
            if exit_code != raw_exit:
                warnings.append(f"{tool} exit {exit_code} != raw {raw_exit}")
        for tool in ("raw", "smll", "rtk"):
            missing = row[tool]["missing_signals"]
            if missing:
                warnings.append(f"{tool} missing {', '.join(missing)}")
            invocation = row[tool]["fixture_invocation"]
            if not invocation["invoked"]:
                warnings.append(f"{tool} did not invoke fixture tool")
            elif invocation["unexpected_args"]:
                shown_args = ", ".join(invocation["unexpected_args"][:3])
                suffix = "" if len(invocation["unexpected_args"]) <= 3 else ", ..."
                warnings.append(f"{tool} fixture args differed: {shown_args}{suffix}")
        outputs = " ".join(
            f"[{tool}]({rel_link(pathlib.Path(row[tool]['output_file']), markdown_dir)})"
            for tool in ("raw", "smll", "rtk")
        )
        lines.append(
            "| {name} | `{command}` | {raw} | {smll} | {rtk} | {winner} | {delta} | {outputs} | {warnings} |".format(
                name=row["name"],
                command=row["command"],
                raw=fmt_int(row["raw"]["tokens"]),
                smll=fmt_int(row["smll"]["tokens"]),
                rtk=fmt_int(row["rtk"]["tokens"]),
                winner=row["winner"],
                delta=fmt_int(abs(row["smll"]["tokens"] - row["rtk"]["tokens"])),
                outputs=outputs,
                warnings="<br>".join(warnings) if warnings else "",
            )
        )
    lines.append("")

    lines.extend(["## Captured Outputs", ""])
    for row in result["cases"]:
        lines.extend(
            [
                f"### {row['name']}",
                "",
                f"Command: `{row['command']}`",
                "",
            ]
        )
        for tool, title in (("raw", "Normal Output"), ("smll", "smll Output"), ("rtk", "rtk Output")):
            path = pathlib.Path(row[tool]["output_file"])
            try:
                output = path.read_text(encoding="utf-8", errors="replace")
            except OSError as exc:
                output = f"Unable to read output file {path}: {exc}\n"
            lines.extend(
                [
                    f"<details><summary>{title}</summary>",
                    "",
                    "```text",
                    output.rstrip("\n"),
                    "```",
                    "",
                    "</details>",
                    "",
                ]
            )
    return "\n".join(lines)


def render_console_summary(result: dict) -> str:
    summary = result["summary"]
    settings = result["settings"]
    lines = [
        "smll vs rtk command token benchmark",
        f"Profile: {settings['profile']} ({summary['case_count']} cases)",
        f"Winner for this profile: {summary['winner']}",
        f"Tokenizer: {result['tokenizer']['actual']} (requested: {result['tokenizer']['requested']})",
        f"Comparison basis: {settings['comparison_basis']}",
        "",
        "Same-basis benchmark score:",
        "- raw commands: {tokens} tokens".format(tokens=fmt_int(summary["raw_tokens"])),
        "- smll: {tokens} tokens; saved {saved} ({pct:.1f}%)".format(
            tokens=fmt_int(summary["smll_tokens"]),
            saved=fmt_int(summary["smll_saved_tokens"]),
            pct=summary["smll_savings_pct"],
        ),
        "- rtk: {tokens} tokens; saved {saved} ({pct:.1f}%)".format(
            tokens=fmt_int(summary["rtk_tokens"]),
            saved=fmt_int(summary["rtk_saved_tokens"]),
            pct=summary["rtk_savings_pct"],
        ),
        "",
        "Native product estimates (diagnostic; not used for winner):",
        "- smll --stats: ~{estimate} est. saved tokens; benchmark equivalent {exact}".format(
            estimate=fmt_int(result["stats_models"]["smll_stats"]["estimated_tokens_saved"]),
            exact=fmt_int(result["stats_models"]["smll_stats"]["exact_benchmark_tokens_saved"]),
        ),
        "- rtk gain: ~{estimate} est. saved tokens; benchmark equivalent {exact}".format(
            estimate=fmt_int(result["stats_models"]["rtk_gain"]["estimated_tokens_saved"]),
            exact=fmt_int(result["stats_models"]["rtk_gain"]["exact_benchmark_tokens_saved"]),
        ),
        "",
        "Categories:",
    ]
    for row in result["categories"]:
        lines.append(
            "- {category}: raw {raw}, smll {smll}, rtk {rtk}, winner {winner}".format(
                category=row["category"],
                raw=fmt_int(row["raw_tokens"]),
                smll=fmt_int(row["smll_tokens"]),
                rtk=fmt_int(row["rtk_tokens"]),
                winner=row["winner"],
            )
        )
    return "\n".join(lines)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rtk-bin", default=os.environ.get("RTK_BIN"), help="Path to rtk binary; defaults to RTK_BIN")
    parser.add_argument("--smll-bin", help="Path to smll binary; default builds zig-out/release/smll")
    parser.add_argument("--runs", type=int, default=20, help="Measured runs per tool/case")
    parser.add_argument("--warmup", type=int, default=3, help="Warmup runs per tool/case")
    parser.add_argument("--timeout", type=float, default=10.0, help="Per process timeout in seconds")
    parser.add_argument("--tokenizer", default="o200k_base", help="tiktoken encoding name, or 'approx'")
    parser.add_argument(
        "--require-tokenizer",
        action="store_true",
        help="Fail instead of using the approximate fallback if the requested tokenizer is unavailable",
    )
    parser.add_argument("--json", dest="json_path", help="Write machine-readable result JSON")
    parser.add_argument("--markdown", help="Write Markdown report")
    parser.add_argument("--outputs-dir", help="Directory for full raw/smll/rtk output files")
    parser.add_argument(
        "--profile",
        default="agent",
        help="Benchmark profile to run: agent, stress, rtk, or all",
    )
    parser.add_argument("--strict-signal", action="store_true", help="Exit non-zero if any signal check is missing")
    args = parser.parse_args()

    if not args.rtk_bin:
        parser.error("--rtk-bin or RTK_BIN is required")
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    if args.warmup < 0:
        parser.error("--warmup must be non-negative")
    return args


def default_outputs_dir(args: argparse.Namespace, root: pathlib.Path) -> pathlib.Path:
    if args.outputs_dir:
        return pathlib.Path(args.outputs_dir)
    for output_path in (args.markdown, args.json_path):
        if output_path:
            path = pathlib.Path(output_path)
            return path.with_suffix("").with_name(path.stem + "-outputs")
    return root / "zig-out" / "benchmarks" / "smll-vs-rtk-outputs"


def write_output_file(
    outputs_dir: pathlib.Path,
    case_name: str,
    tool: str,
    command: str,
    run: ToolRun,
) -> pathlib.Path:
    case_dir = outputs_dir / case_name
    case_dir.mkdir(parents=True, exist_ok=True)
    path = case_dir / f"{tool}.txt"
    with path.open("wb") as f:
        f.write(f"$ {command}\n".encode())
        f.write(f"# exit_code: {run.exit_code}\n".encode())
        f.write(f"# stdout_bytes: {len(run.stdout)}\n".encode())
        f.write(f"# stderr_bytes: {len(run.stderr)}\n".encode())
        f.write(b"\n## stdout\n")
        f.write(run.stdout)
        if run.stdout and not run.stdout.endswith(b"\n"):
            f.write(b"\n")
        f.write(b"\n## stderr\n")
        f.write(run.stderr)
        if run.stderr and not run.stderr.endswith(b"\n"):
            f.write(b"\n")
    return path


def main() -> int:
    args = parse_args()
    root = repo_root()
    cases = load_cases(root, args.profile)
    if not cases:
        raise SystemExit(f"error: no cases matched --profile {args.profile!r}")
    rtk_bin = pathlib.Path(args.rtk_bin).resolve()
    if not rtk_bin.exists():
        raise SystemExit(f"error: rtk binary not found: {rtk_bin}")

    smll_bin = pathlib.Path(args.smll_bin).resolve() if args.smll_bin else build_smll(root)
    if not smll_bin.exists():
        raise SystemExit(f"error: smll binary not found: {smll_bin}")

    outputs_dir = default_outputs_dir(args, root)
    outputs_dir.mkdir(parents=True, exist_ok=True)
    counter = TokenCounter(args.tokenizer, args.require_tokenizer)

    git_commit = run_text(["git", "rev-parse", "HEAD"], root)
    git_status = run_text(["git", "status", "--short"], root)
    tools = {
        "smll": {
            "path": str(smll_bin),
            "version": run_text([str(smll_bin), "--version"], root),
        },
        "rtk": {
            "path": str(rtk_bin),
            "version": run_text([str(rtk_bin), "--version"], root),
        },
    }

    cases_out: list[dict] = []
    strict_failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="smll-rtk-bench-") as tmp:
        tmp_path = pathlib.Path(tmp)
        env = isolated_env(os.environ, tmp_path)

        for case in cases:
            fake_bin = tmp_path / f"bin-{case.name}"
            fake_bin.mkdir()
            write_fake_tool(case, fake_bin, root)

            case_env = dict(env)
            case_env["PATH"] = str(fake_bin) + os.pathsep + case_env.get("PATH", "")
            raw_env = dict(case_env)
            smll_env = dict(case_env)
            rtk_env = dict(case_env)
            raw_invocation_log = fake_bin / "raw-invocations.tsv"
            smll_invocation_log = fake_bin / "smll-invocations.tsv"
            rtk_invocation_log = fake_bin / "rtk-invocations.tsv"
            raw_env["BENCH_INVOCATION_LOG"] = str(raw_invocation_log)
            smll_env["BENCH_INVOCATION_LOG"] = str(smll_invocation_log)
            rtk_env["BENCH_INVOCATION_LOG"] = str(rtk_invocation_log)

            raw_argv = list(case.command)
            smll_argv = [str(smll_bin), *case.command]
            rtk_argv = [str(rtk_bin), *case.command]
            command_display = shell_array(case.command)

            raw_run = timed_run(raw_argv, args.runs, args.warmup, root, raw_env, args.timeout)
            smll_run = timed_run(smll_argv, args.runs, args.warmup, root, smll_env, args.timeout)
            rtk_run = timed_run(rtk_argv, args.runs, args.warmup, root, rtk_env, args.timeout)
            raw_invocation = invocation_summary(case, raw_invocation_log)
            smll_invocation = invocation_summary(case, smll_invocation_log)
            rtk_invocation = invocation_summary(case, rtk_invocation_log)

            raw_tokens = count_run_tokens(counter, raw_run)
            smll_tokens = count_run_tokens(counter, smll_run)
            rtk_tokens = count_run_tokens(counter, rtk_run)
            raw_missing = missing_signals(raw_run.combined, signals_for(case, "raw"))
            smll_missing = missing_signals(smll_run.combined, signals_for(case, "smll"))
            rtk_missing = missing_signals(rtk_run.combined, signals_for(case, "rtk"))

            for tool, missing in (("raw", raw_missing), ("smll", smll_missing), ("rtk", rtk_missing)):
                if missing:
                    strict_failures.append(f"{case.name}: {tool} missing {', '.join(missing)}")

            raw_file = write_output_file(outputs_dir, case.name, "raw", command_display, raw_run)
            smll_file = write_output_file(
                outputs_dir,
                case.name,
                "smll",
                "smll " + command_display,
                smll_run,
            )
            rtk_file = write_output_file(
                outputs_dir,
                case.name,
                "rtk",
                "rtk " + command_display,
                rtk_run,
            )

            cases_out.append(
                {
                    "name": case.name,
                    "category": case.category,
                    "profiles": list(case.profiles),
                    "command": command_display,
                    "fixture": case.fixture,
                    "signals": {
                        "raw": list(signals_for(case, "raw")),
                        "smll": list(signals_for(case, "smll")),
                        "rtk": list(signals_for(case, "rtk")),
                    },
                    "winner": winner(smll_tokens, rtk_tokens),
                    "raw": {
                        "bytes": len(raw_run.combined),
                        "stdout_bytes": len(raw_run.stdout),
                        "stderr_bytes": len(raw_run.stderr),
                        "tokens": raw_tokens,
                        "median_ms": raw_run.median_ms,
                        "exit_code": raw_run.exit_code,
                        "missing_signals": raw_missing,
                        "fixture_invocation": raw_invocation,
                        "output_file": str(raw_file),
                    },
                    "smll": {
                        "bytes": len(smll_run.combined),
                        "stdout_bytes": len(smll_run.stdout),
                        "stderr_bytes": len(smll_run.stderr),
                        "tokens": smll_tokens,
                        "saved_tokens": benchmark_saved_tokens(raw_tokens, smll_tokens),
                        "savings_pct": benchmark_savings_pct(raw_tokens, smll_tokens),
                        "median_ms": smll_run.median_ms,
                        "exit_code": smll_run.exit_code,
                        "missing_signals": smll_missing,
                        "fixture_invocation": smll_invocation,
                        "output_file": str(smll_file),
                    },
                    "rtk": {
                        "bytes": len(rtk_run.combined),
                        "stdout_bytes": len(rtk_run.stdout),
                        "stderr_bytes": len(rtk_run.stderr),
                        "tokens": rtk_tokens,
                        "saved_tokens": benchmark_saved_tokens(raw_tokens, rtk_tokens),
                        "savings_pct": benchmark_savings_pct(raw_tokens, rtk_tokens),
                        "median_ms": rtk_run.median_ms,
                        "exit_code": rtk_run.exit_code,
                        "missing_signals": rtk_missing,
                        "fixture_invocation": rtk_invocation,
                        "output_file": str(rtk_file),
                    },
                }
            )

    raw_total = sum(row["raw"]["tokens"] for row in cases_out)
    smll_total = sum(row["smll"]["tokens"] for row in cases_out)
    rtk_total = sum(row["rtk"]["tokens"] for row in cases_out)

    categories = []
    for category in sorted({row["category"] for row in cases_out}):
        rows = [row for row in cases_out if row["category"] == category]
        raw = sum(row["raw"]["tokens"] for row in rows)
        smll = sum(row["smll"]["tokens"] for row in rows)
        rtk = sum(row["rtk"]["tokens"] for row in rows)
        categories.append(
            {
                "category": category,
                "raw_tokens": raw,
                "smll_tokens": smll,
                "rtk_tokens": rtk,
                "winner": winner(smll, rtk),
                "smll_saved_tokens": benchmark_saved_tokens(raw, smll),
                "rtk_saved_tokens": benchmark_saved_tokens(raw, rtk),
                "smll_savings_pct": benchmark_savings_pct(raw, smll),
                "rtk_savings_pct": benchmark_savings_pct(raw, rtk),
            }
        )

    result = {
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repo": {
            "root": str(root),
            "git_commit": git_commit,
            "git_dirty": bool(git_status),
        },
        "tools": tools,
        "tokenizer": {"requested": args.tokenizer, "actual": counter.actual},
        "settings": {
            "mode": "same-command",
            "cases_file": str(root / CASES_FILE),
            "profile": args.profile,
            "runs": args.runs,
            "warmup": args.warmup,
            "timeout_s": args.timeout,
            "outputs_dir": str(outputs_dir),
            "comparison_basis": COMPARISON_BASIS,
        },
        "summary": build_summary(len(cases_out), raw_total, smll_total, rtk_total),
        "categories": categories,
        "stats_models": build_stats_models(cases_out, raw_total, smll_total, rtk_total),
        "cases": cases_out,
    }

    markdown_path = pathlib.Path(args.markdown) if args.markdown else None
    markdown = render_markdown(result, markdown_path)
    if markdown_path:
        print(render_console_summary(result))
    else:
        print(markdown)

    if args.json_path:
        path = pathlib.Path(args.json_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if markdown_path:
        markdown_path.parent.mkdir(parents=True, exist_ok=True)
        markdown_path.write_text(markdown, encoding="utf-8")

    if strict_failures and args.strict_signal:
        print("\nSignal check failures:", file=sys.stderr)
        for failure in strict_failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
