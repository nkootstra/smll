#!/usr/bin/env python3
"""Smoke-test supported wrapper command families with isolated fake tools.

This is a dispatch smoke test, not a replacement for fixture-level semantic
tests. It verifies that each supported command family can be launched through
the smll binary, runs under isolated HOME/XDG state, and preserves the child
exit code. Filter-specific signal preservation remains covered by Zig fixture
tests and the comparison benchmark's strict signal checks.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


@dataclasses.dataclass(frozen=True)
class Payload:
    value: str
    is_fixture: bool = False

    def read(self, root: pathlib.Path) -> bytes:
        if self.is_fixture:
            return (root / self.value).read_bytes()
        return self.value.encode("utf-8")


@dataclasses.dataclass(frozen=True)
class Case:
    name: str
    argv: tuple[str, ...]
    stdout: Payload
    stderr: Payload
    exit_code: int = 0


def literal(value: str) -> Payload:
    return Payload(value)


def fixture(path: str) -> Payload:
    return Payload(path, is_fixture=True)


def build_cases() -> list[Case]:
    cases: list[Case] = []

    def add(
        name: str,
        argv: tuple[str, ...],
        stdout: Payload | None = None,
        stderr: Payload | None = None,
        exit_code: int = 0,
    ) -> None:
        cases.append(
            Case(
                name=name,
                argv=argv,
                stdout=stdout or literal(""),
                stderr=stderr or literal(""),
                exit_code=exit_code,
            )
        )

    add("git-status", ("git", "status"), fixture("tests/fixtures/git_status_dirty.txt"))
    add("git-diff", ("git", "diff"), fixture("tests/fixtures/git_diff_simple.txt"))
    add("git-log", ("git", "log"), fixture("tests/fixtures/git_log_linear.txt"))
    add("git-show", ("git", "show"), fixture("tests/fixtures/git_show_body.txt"))
    add(
        "git-add-error",
        ("git", "add", "missing.txt"),
        fixture("tests/fixtures/git_add_error.stdout.txt"),
        fixture("tests/fixtures/git_add_error.stderr.txt"),
        128,
    )
    add("git-commit", ("git", "commit"), fixture("tests/fixtures/git_commit_simple.txt"))
    add(
        "git-push",
        ("git", "push"),
        fixture("tests/fixtures/git_push_simple.stdout.txt"),
        fixture("tests/fixtures/git_push_simple.stderr.txt"),
    )
    add(
        "git-pull",
        ("git", "pull"),
        fixture("tests/fixtures/git_pull_ff.stdout.txt"),
        fixture("tests/fixtures/git_pull_ff.stderr.txt"),
    )
    add(
        "git-fetch",
        ("git", "fetch"),
        fixture("tests/fixtures/git_fetch_simple.stdout.txt"),
        fixture("tests/fixtures/git_fetch_simple.stderr.txt"),
    )
    add(
        "git-merge",
        ("git", "merge", "feature"),
        fixture("tests/fixtures/git_merge_conflict.stdout.txt"),
        fixture("tests/fixtures/git_merge_conflict.stderr.txt"),
        1,
    )
    add("git-rebase", ("git", "rebase", "main"), fixture("tests/fixtures/git_rebase_simple.txt"))
    add(
        "git-checkout",
        ("git", "checkout", "feature"),
        fixture("tests/fixtures/git_checkout_switch.stdout.txt"),
        fixture("tests/fixtures/git_checkout_switch.stderr.txt"),
    )
    add("git-branch", ("git", "branch"), fixture("tests/fixtures/git_branch_list.txt"))
    add("git-stash", ("git", "stash", "list"), fixture("tests/fixtures/git_stash_list.txt"))
    add("git-blame", ("git", "blame", "src/main.zig"), fixture("tests/fixtures/git_blame_simple.txt"))
    add(
        "git-grep",
        ("git", "grep", "-n", "TODO"),
        literal("src/main.zig:10:// TODO: tighten parser\nsrc/util.zig:4:// TODO: share helper\n"),
    )
    add("git-reflog", ("git", "reflog"), fixture("tests/fixtures/git_reflog.txt"))

    add("rg-files", ("rg", "--files"), fixture("tests/fixtures/rg_files.txt"))
    add("tree-src", ("tree", "src"), fixture("tests/fixtures/tree_src.txt"))
    add("find-ls", ("find", ".", "-ls"), fixture("tests/fixtures/find_ls.txt"))
    add("ls-la", ("ls", "-la"), fixture("tests/fixtures/ls_la.txt"))
    add("ls-recursive", ("ls", "-R", "src"), fixture("tests/fixtures/ls_R.txt"))
    add("head", ("head", "file.txt"), literal("alpha\nbeta\n"))
    add("tail", ("tail", "file.txt"), literal("omega\n"))
    add(
        "cat-code",
        ("cat", "main.zig"),
        literal('const std = @import("std");\nfn main() void { doThing(); }\n'),
    )

    add("docker-ps", ("docker", "ps"), fixture("tests/fixtures/docker_ps.txt"))
    add("docker-logs", ("docker", "logs", "app"), fixture("tests/fixtures/docker_logs.txt"))
    add("kubectl-get", ("kubectl", "get", "pods"), fixture("tests/fixtures/kubectl_pods.txt"))
    add("kubectl-logs", ("kubectl", "logs", "app"), fixture("tests/fixtures/docker_logs.txt"))
    add("gh-pr-list", ("gh", "pr", "list"), fixture("tests/fixtures/gh_pr_list.txt"))
    add("gh-run-list", ("gh", "run", "list"), fixture("tests/fixtures/gh_run_list.txt"))
    add(
        "acli-jira-workitem-search",
        ("acli", "jira", "workitem", "search", "--jql", "project = EXAMPLE"),
        fixture("tests/fixtures/acli_jira_workitem_search.txt"),
    )
    add(
        "acli-confluence-page-view",
        ("acli", "confluence", "page", "view", "--id", "100000001"),
        fixture("tests/fixtures/acli_confluence_page_view.txt"),
    )
    add("ps-aux", ("ps", "aux"), fixture("tests/fixtures/ps_aux.txt"))
    add(
        "df-h",
        ("df", "-h"),
        literal("Filesystem Size Used Avail Use% Mounted on\n/dev/disk1s1 100G 70G 30G 70% /\n"),
    )
    add(
        "psql",
        ("psql", "-c", "select 1"),
        literal(" id | name\n----+------\n  1 | app\n(1 row)\n"),
    )
    add(
        "systemctl",
        ("systemctl", "status"),
        literal("UNIT LOAD ACTIVE SUB DESCRIPTION\napp.service loaded active running App\n"),
    )
    add(
        "lsof",
        ("lsof", "-i"),
        literal("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnode 123 user 10u IPv4 0 0t0 TCP *:3000 (LISTEN)\n"),
    )
    add("brew", ("brew", "outdated"), literal("node 22.1.0 < 22.2.0\nzig 0.15.0 < 0.16.0\n"))
    add("bun-pm-ls", ("bun", "pm", "ls"), fixture("tests/fixtures/bun_pm_ls.txt"))

    add("wc", ("wc", "-l", "file.txt"), literal("     42 file.txt\n"))
    add("env", ("env",), literal("PATH=/tmp/bin\nAPI_TOKEN=secret-value\nNORMAL=value\n"))
    add("du", ("du", "-sh", "."), fixture("tests/fixtures/du_sh.txt"))
    add(
        "curl-v",
        ("curl", "-v", "https://example.com"),
        fixture("tests/fixtures/curl_v_example.stdout.txt"),
        fixture("tests/fixtures/curl_v_example.stderr.txt"),
    )

    add("make", ("make",), fixture("tests/fixtures/make_build.txt"))
    add("cargo-build", ("cargo", "build"), fixture("tests/fixtures/cargo_build.txt"))
    add("cargo-test", ("cargo", "test"), fixture("tests/fixtures/cargo_test_failing.txt"), exit_code=1)
    add("zig-build", ("zig", "build"), literal("info: compiling app\nerror: expected type bool\n"), exit_code=1)
    add("go-build", ("go", "build", "./..."), fixture("tests/fixtures/go_build.txt"), exit_code=1)
    add("go-test", ("go", "test", "-v"), fixture("tests/fixtures/go_test_v.txt"), exit_code=1)
    add(
        "dotnet-build",
        ("dotnet", "build"),
        fixture("benchmarks/smll-vs-rtk/fixtures/dotnet_build_failed.txt"),
        exit_code=1,
    )
    add(
        "dotnet-test",
        ("dotnet", "test"),
        fixture("benchmarks/smll-vs-rtk/fixtures/dotnet_test_failed.txt"),
        exit_code=1,
    )
    add(
        "dotnet-format",
        ("dotnet", "format"),
        literal("Formatting code files in workspace\nWarnings were encountered while loading the workspace.\n"),
    )
    add(
        "dotnet-restore",
        ("dotnet", "restore"),
        literal("Determining projects to restore...\nRestored app.csproj (in 1.2 sec).\n"),
    )
    add("swift-build", ("swift", "build"), literal("Compile Swift Module App\nBuild complete!\n"))
    add("xcodebuild", ("xcodebuild",), literal("CompileSwiftSources normal arm64\n** BUILD FAILED **\n"), exit_code=65)
    add(
        "gradle-build",
        ("gradle", "build"),
        fixture("benchmarks/smll-vs-rtk/fixtures/gradle_build_failed.txt"),
        exit_code=1,
    )
    add(
        "gradlew-test",
        ("gradlew", "test"),
        fixture("benchmarks/smll-vs-rtk/fixtures/gradle_test_failed.txt"),
        exit_code=1,
    )
    add(
        "mvn-package",
        ("mvn", "package"),
        fixture("benchmarks/smll-vs-rtk/fixtures/mvn_build_failed.txt"),
        exit_code=1,
    )
    add(
        "mvnw-package",
        ("mvnw", "package"),
        fixture("benchmarks/smll-vs-rtk/fixtures/mvn_build_failed.txt"),
        exit_code=1,
    )
    add("pytest", ("pytest", "-v"), fixture("tests/fixtures/pytest_failing.txt"), exit_code=1)
    add("jest", ("jest",), fixture("tests/fixtures/jest_failing.txt"), exit_code=1)
    add("vitest", ("vitest",), fixture("tests/fixtures/jest_failing.txt"), exit_code=1)
    add("tsc", ("tsc", "--noEmit"), fixture("tests/fixtures/tsc_errors.txt"), exit_code=2)
    add(
        "mypy",
        ("mypy", "src"),
        literal("src/app.py:10: error: Incompatible return value type\nFound 1 error in 1 file\n"),
        exit_code=1,
    )
    add(
        "ruff",
        ("ruff", "check", "."),
        literal("src/app.py:1:1: F401 `os` imported but unused\nFound 1 error.\n"),
        exit_code=1,
    )
    add(
        "eslint",
        ("eslint", "."),
        literal("/repo/src/app.ts\n  1:7  error  x is assigned a value but never used  no-unused-vars\n\n1 problem (1 error, 0 warnings)\n"),
        exit_code=1,
    )
    add(
        "biome",
        ("biome", "check", "."),
        literal("src/app.ts:1:7 lint/correctness/noUnusedVariables\n  This variable is unused.\nChecked 1 file.\n"),
        exit_code=1,
    )
    add(
        "prettier",
        ("prettier", "--check", "."),
        literal("Checking formatting...\n[warn] src/app.ts\n[warn] Code style issues found in the above file.\n"),
        exit_code=1,
    )

    add("npm-install", ("npm", "install"), fixture("tests/fixtures/npm_install.txt"))
    add("npm-build", ("npm", "run", "build"), fixture("tests/fixtures/vite_build.txt"))
    add("pnpm-install", ("pnpm", "install"), fixture("tests/fixtures/pnpm_install.txt"))
    add("yarn-add", ("yarn", "add", "react"), fixture("tests/fixtures/yarn_install.txt"))
    add("bun-add", ("bun", "add", "react"), fixture("tests/fixtures/bun_install.txt"))
    add("pip-install", ("pip", "install", "-r", "requirements.txt"), fixture("tests/fixtures/large/generic_pip_install.txt"))
    add("pip3-list", ("pip3", "list"), literal("Package    Version\n---------- -------\nrequests   2.34.2\n"))
    add(
        "uv-pip-install",
        ("uv", "pip", "install", "-r", "requirements.txt"),
        fixture("benchmarks/smll-vs-rtk/fixtures/uv_pip_install.txt"),
    )
    add("uvx", ("uvx", "ruff", "check"), literal("Installed 1 package in 9ms\nAll checks passed!\n"))
    add("composer-require", ("composer", "require", "guzzlehttp/guzzle"), fixture("tests/fixtures/composer_require.txt"))

    add("next-build", ("next", "build"), fixture("tests/fixtures/next_build.txt"))
    add("terraform-plan", ("terraform", "plan"), fixture("benchmarks/smll-vs-rtk/fixtures/terraform_plan.txt"))
    add("tofu-plan", ("tofu", "plan"), fixture("benchmarks/smll-vs-rtk/fixtures/terraform_plan.txt"))
    add(
        "aws-json",
        ("aws", "sts", "get-caller-identity"),
        literal('{\n  "Account": "123456789012",\n  "Arn": "arn:aws:iam::123456789012:user/test"\n}\n'),
    )
    add("jq-json", ("jq", "."), literal('{\n  "ok": true,\n  "items": [1, 2, 3]\n}\n'))
    add(
        "pre-commit",
        ("pre-commit", "run", "--all-files"),
        fixture("benchmarks/smll-vs-rtk/fixtures/pre_commit_failed.txt"),
        exit_code=1,
    )

    return cases


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--smll-bin", help="Path to smll binary; default is zig-out/release/smll")
    parser.add_argument("--no-build", action="store_true", help="Do not run `zig build release` before smoke tests")
    parser.add_argument("--case", action="append", dest="case_names", help="Run only the named smoke case; may be repeated")
    parser.add_argument("--list", action="store_true", help="List smoke case names and exit")
    parser.add_argument("--timeout", type=float, default=10.0, help="Per-case timeout in seconds")
    return parser.parse_args()


def build_smll(root: pathlib.Path) -> pathlib.Path:
    subprocess.run(["zig", "build", "release"], cwd=root, check=True)
    return root / "zig-out" / "release" / "smll"


def resolve_smll(args: argparse.Namespace, root: pathlib.Path) -> pathlib.Path:
    if args.smll_bin:
        path = pathlib.Path(args.smll_bin)
        return path if path.is_absolute() else root / path
    if args.no_build:
        return root / "zig-out" / "release" / "smll"
    return build_smll(root)


def write_fake_tool(case_dir: pathlib.Path, case: Case, root: pathlib.Path) -> pathlib.Path:
    stdout_path = case_dir / "stdout.bin"
    stderr_path = case_dir / "stderr.bin"
    stdout_path.write_bytes(case.stdout.read(root))
    stderr_path.write_bytes(case.stderr.read(root))

    script_path = case_dir / case.argv[0]
    script_path.write_text(
        "\n".join(
            [
                "#!/usr/bin/env bash",
                "set -euo pipefail",
                f"/bin/cat {shlex.quote(str(stdout_path))}",
                f"if [ -s {shlex.quote(str(stderr_path))} ]; then",
                f"  /bin/cat {shlex.quote(str(stderr_path))} >&2",
                "fi",
                f"exit {case.exit_code}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    script_path.chmod(0o755)
    return script_path


def isolated_env(base: dict[str, str], temp_root: pathlib.Path, bin_dir: pathlib.Path) -> dict[str, str]:
    env = dict(base)
    env.update(
        {
            "PATH": str(bin_dir) + os.pathsep + env.get("PATH", ""),
            "HOME": str(temp_root / "home"),
            "XDG_CONFIG_HOME": str(temp_root / "xdg-config"),
            "XDG_DATA_HOME": str(temp_root / "xdg-data"),
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
    env.pop("SMLL_LOSSLESS", None)
    return env


def preview(data: bytes) -> str:
    text = data.decode("utf-8", errors="replace").replace("\n", "\\n")
    if len(text) > 180:
        return text[:177] + "..."
    return text


def main() -> int:
    args = parse_args()
    root = REPO_ROOT
    cases = build_cases()

    if args.list:
        for case in cases:
            print(case.name)
        return 0

    if args.case_names:
        requested = set(args.case_names)
        known = {case.name for case in cases}
        missing = sorted(requested - known)
        if missing:
            print(f"unknown smoke case(s): {', '.join(missing)}", file=sys.stderr)
            return 2
        cases = [case for case in cases if case.name in requested]

    smll = resolve_smll(args, root)
    if not smll.exists():
        print(f"smll binary not found: {smll}", file=sys.stderr)
        print("run without --no-build or pass --smll-bin", file=sys.stderr)
        return 2

    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="smll-supported-smoke-") as temp:
        temp_root = pathlib.Path(temp)
        for case in cases:
            case_dir = temp_root / case.name
            bin_dir = case_dir / "bin"
            bin_dir.mkdir(parents=True)
            write_fake_tool(bin_dir, case, root)

            env = isolated_env(os.environ, temp_root, bin_dir)
            argv = [str(smll), *case.argv]
            try:
                proc = subprocess.run(
                    argv,
                    cwd=root,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=args.timeout,
                    check=False,
                )
            except subprocess.TimeoutExpired:
                failures.append(f"{case.name}: timed out after {args.timeout:g}s")
                continue

            if proc.returncode != case.exit_code:
                failures.append(
                    "{name}: exit {got} != {want}; stdout={stdout!r}; stderr={stderr!r}".format(
                        name=case.name,
                        got=proc.returncode,
                        want=case.exit_code,
                        stdout=preview(proc.stdout),
                        stderr=preview(proc.stderr),
                    )
                )

    print(f"supported command smoke cases: {len(cases)}")
    if failures:
        print("FAILURES:")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("all supported command smoke cases passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
