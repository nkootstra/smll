#!/usr/bin/env python3
"""Audit committed fixtures for factual consistency.

The checks here avoid live network or host-command dependencies. Fixtures should
be deterministic artifacts, so this validates internal consistency: references,
required benchmark signals, generated fixture reproducibility, and HTTP metadata.
"""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
CASES_PATH = REPO_ROOT / "benchmarks/smll-vs-rtk/cases.json"
FIXTURE_ROOTS = (
    REPO_ROOT / "tests/fixtures",
    REPO_ROOT / "benchmarks/smll-vs-rtk/fixtures",
)
EXPECTED_EMPTY_FIXTURES = {
    "tests/fixtures/git_add_error.stdout.txt",
    "tests/fixtures/git_checkout_switch.stdout.txt",
    "tests/fixtures/git_fetch_simple.stdout.txt",
    "tests/fixtures/git_merge_conflict.stderr.txt",
    "tests/fixtures/pipe_inputs/git_add.txt",
    "tests/fixtures/pipe_inputs/git_checkout.txt",
    "tests/fixtures/pipe_inputs/git_fetch.txt",
}
PLACEHOLDER_PATTERNS = (
    b"Lorem ipsum",
    b"PLACEHOLDER",
    b"TODO_PLACEHOLDER",
)


def rel(path: pathlib.Path) -> str:
    return path.relative_to(REPO_ROOT).as_posix()


def add_error(errors: list[str], message: str) -> None:
    errors.append(message)


def fixture_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in FIXTURE_ROOTS:
        files.extend(path for path in root.rglob("*") if path.is_file())
    return sorted(files)


def check_fixture_file_sanity(errors: list[str]) -> None:
    empty_files: set[str] = set()
    for path in fixture_files():
        data = path.read_bytes()
        path_rel = rel(path)
        if not data:
            empty_files.add(path_rel)
        if b"\x00" in data:
            add_error(errors, f"{path_rel}: contains NUL bytes")
        if b"\r\n" in data:
            add_error(errors, f"{path_rel}: contains CRLF line endings")
        for pattern in PLACEHOLDER_PATTERNS:
            if pattern in data:
                add_error(errors, f"{path_rel}: contains placeholder marker {pattern!r}")

    if empty_files != EXPECTED_EMPTY_FIXTURES:
        unexpected = sorted(empty_files - EXPECTED_EMPTY_FIXTURES)
        missing = sorted(EXPECTED_EMPTY_FIXTURES - empty_files)
        if unexpected:
            add_error(errors, "unexpected empty fixtures: " + ", ".join(unexpected))
        if missing:
            add_error(errors, "expected empty fixtures are non-empty: " + ", ".join(missing))


def referenced_fixtures(case: dict[str, object]) -> list[str]:
    refs: list[str] = []
    for key in ("fixture", "stderr_fixture"):
        value = case.get(key)
        if isinstance(value, str):
            refs.append(value)

    arg_fixtures = case.get("arg_fixtures")
    if isinstance(arg_fixtures, list):
        for entry in arg_fixtures:
            if isinstance(entry, dict) and isinstance(entry.get("fixture"), str):
                refs.append(entry["fixture"])

    return refs


def check_benchmark_cases(errors: list[str]) -> None:
    payload = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    cases = payload.get("cases", [])
    if not isinstance(cases, list):
        add_error(errors, f"{rel(CASES_PATH)}: expected top-level cases list")
        return

    for case in cases:
        if not isinstance(case, dict):
            add_error(errors, f"{rel(CASES_PATH)}: found non-object case")
            continue

        case_name = str(case.get("name", "<unnamed>"))
        refs = referenced_fixtures(case)
        raw = b""
        for fixture_ref in refs:
            fixture_path = REPO_ROOT / fixture_ref
            if not fixture_path.is_file():
                add_error(errors, f"{case_name}: missing fixture {fixture_ref}")
                continue
            raw += fixture_path.read_bytes()

        signals = case.get("signals", [])
        if isinstance(signals, list):
            for signal in signals:
                if isinstance(signal, str) and signal.encode("utf-8") not in raw:
                    add_error(errors, f"{case_name}: signal not present in raw fixtures: {signal!r}")


def parse_cert_date(value: str) -> dt.datetime:
    normalized = " ".join(value.split())
    parsed = dt.datetime.strptime(normalized, "%b %d %H:%M:%S %Y GMT")
    return parsed.replace(tzinfo=dt.timezone.utc)


def parse_http_date(value: str) -> dt.datetime:
    parsed = email.utils.parsedate_to_datetime(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    parsed = parsed.astimezone(dt.timezone.utc)

    match = re.match(r"^(?P<weekday>[A-Z][a-z]{2}), ", value)
    if match and match.group("weekday") != parsed.strftime("%a"):
        raise ValueError(f"weekday {match.group('weekday')} does not match {parsed.strftime('%a')}")
    return parsed


def parse_curl_metadata(stderr_text: str) -> tuple[list[int], list[dt.datetime], list[tuple[dt.datetime, dt.datetime]]]:
    content_lengths: list[int] = []
    http_dates: list[dt.datetime] = []
    cert_windows: list[tuple[dt.datetime, dt.datetime]] = []
    current_start: dt.datetime | None = None

    for line in stderr_text.splitlines():
        if line.startswith("*   start date: "):
            current_start = parse_cert_date(line.removeprefix("*   start date: "))
        elif line.startswith("*   expire date: "):
            if current_start is None:
                raise ValueError("certificate expire date appeared before start date")
            cert_windows.append((current_start, parse_cert_date(line.removeprefix("*   expire date: "))))
            current_start = None
        elif line.startswith("< content-length: "):
            content_lengths.append(int(line.removeprefix("< content-length: ")))
        elif line.startswith("< date: "):
            http_dates.append(parse_http_date(line.removeprefix("< date: ")))

    return content_lengths, http_dates, cert_windows


def check_curl_fixture_pair(
    errors: list[str],
    stdout_path: pathlib.Path,
    stderr_path: pathlib.Path,
    *,
    split_stdout_lines: bool,
) -> None:
    stdout = stdout_path.read_bytes()
    stderr_text = stderr_path.read_text(encoding="utf-8")
    try:
        content_lengths, http_dates, cert_windows = parse_curl_metadata(stderr_text)
    except ValueError as exc:
        add_error(errors, f"{rel(stderr_path)}: invalid curl metadata: {exc}")
        return

    if len(content_lengths) != len(http_dates):
        add_error(errors, f"{rel(stderr_path)}: content-length/date count mismatch")
    if len(cert_windows) != len(http_dates):
        add_error(errors, f"{rel(stderr_path)}: certificate/date count mismatch")

    for index, (start, expires) in enumerate(cert_windows[: len(http_dates)]):
        response_date = http_dates[index]
        if not start <= response_date <= expires:
            add_error(
                errors,
                f"{rel(stderr_path)}: response {index + 1} date is outside certificate validity",
            )

    if split_stdout_lines:
        bodies = stdout.splitlines(keepends=True)
        if len(bodies) != len(content_lengths):
            add_error(errors, f"{rel(stdout_path)}: body/content-length count mismatch")
            return
        for index, (body, content_length) in enumerate(zip(bodies, content_lengths, strict=True)):
            if len(body) != content_length:
                add_error(
                    errors,
                    f"{rel(stderr_path)}: response {index + 1} content-length {content_length} "
                    f"does not match body bytes {len(body)}",
                )
    elif content_lengths and content_lengths[0] != len(stdout):
        add_error(
            errors,
            f"{rel(stderr_path)}: content-length {content_lengths[0]} does not match body bytes {len(stdout)}",
        )


def check_curl_fixtures(errors: list[str]) -> None:
    check_curl_fixture_pair(
        errors,
        REPO_ROOT / "tests/fixtures/curl_v_example.stdout.txt",
        REPO_ROOT / "tests/fixtures/curl_v_example.stderr.txt",
        split_stdout_lines=False,
    )
    check_curl_fixture_pair(
        errors,
        REPO_ROOT / "tests/fixtures/large/curl_vvv_example.stdout.txt",
        REPO_ROOT / "tests/fixtures/large/curl_vvv_example.stderr.txt",
        split_stdout_lines=True,
    )


def generated_fixture_paths(root: pathlib.Path) -> set[pathlib.Path]:
    fixture_root = root / "tests/fixtures"
    return {path.relative_to(fixture_root) for path in fixture_root.rglob("*") if path.is_file()}


def check_generated_reproducibility(errors: list[str]) -> None:
    with tempfile.TemporaryDirectory(prefix="smll-fixture-audit-") as temp_dir:
        temp_repo = pathlib.Path(temp_dir) / "repo"
        ignore = shutil.ignore_patterns(".git", ".zig-cache", "zig-out", "__pycache__")
        shutil.copytree(REPO_ROOT, temp_repo, ignore=ignore)

        result = subprocess.run(
            ["bash", "scripts/generate_large_fixtures.sh"],
            cwd=temp_repo,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            add_error(errors, "fixture generator failed during audit:\n" + result.stdout[-4000:])
            return

        current_paths = generated_fixture_paths(REPO_ROOT)
        regenerated_paths = generated_fixture_paths(temp_repo)
        for missing in sorted(current_paths - regenerated_paths):
            add_error(errors, f"regenerated fixtures missing committed file: tests/fixtures/{missing.as_posix()}")
        for unexpected in sorted(regenerated_paths - current_paths):
            add_error(errors, f"regenerated fixtures created uncommitted file: tests/fixtures/{unexpected.as_posix()}")

        for path in sorted(current_paths & regenerated_paths):
            current = REPO_ROOT / "tests/fixtures" / path
            regenerated = temp_repo / "tests/fixtures" / path
            if current.read_bytes() != regenerated.read_bytes():
                add_error(errors, f"generated fixture drift: tests/fixtures/{path.as_posix()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-generated",
        action="store_true",
        help="skip byte-for-byte fixture regeneration",
    )
    args = parser.parse_args()

    errors: list[str] = []
    check_fixture_file_sanity(errors)
    check_benchmark_cases(errors)
    check_curl_fixtures(errors)
    if not args.skip_generated:
        check_generated_reproducibility(errors)

    if errors:
        print("fixture audit failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(f"fixture audit passed ({len(fixture_files())} fixture files checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
