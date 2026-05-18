# smll Codebase Audit — 2026-05

A point-in-time audit of the entire `smll` codebase: structure, defects, refactor
opportunities, and expansion ideas. Companion to the refactor PR landed on
`claude/audit-refactor-codebase-xYOwr`.

## Scope

- 21,536 LOC of Zig across `src/`, plus 3,586 LOC of integration tests
- Build (`build.zig`, 1,150 LOC), CI (`.github/workflows/*.yml`), scripts, docs
- ~40 filter modules + 5 control-plane modules
- Verification entrypoint: `zig build test --summary all`
- Release size cap: 294,912 bytes (288 KiB) — baseline before this PR: 249,768 bytes

## Module inventory

| Module | LOC | Responsibility | Health |
|---|---:|---|---|
| `src/main.zig` | 1,557 | argv parsing, wrapper-mode subprocess, dispatch table | needs dedup |
| `src/setup.zig` | 1,066 | claude/opencode/cursor integration setup/unsetup, mini JSON | bug-fix landed |
| `src/stats.zig` | 434 | `~/.smll/stats.json` storage | atomic-write landed |
| `src/pipeline.zig` | 267 | stdin read + dispatch in pipe mode | cap landed |
| `src/util.zig` | 207 | shared git helpers | reusable; under-used by some filters |
| `src/filters/git_status.zig` | 849 | git status grammar v0.4 | could split |
| `src/filters/generic_compact.zig` | 743 | fallback noise stripper | could split |
| `src/filters/git_log.zig` | 526 | git log compaction | could split |
| `src/filters/git_diff.zig` | 491 | git diff hunk + summary | could split |
| `src/filters/rg.zig` | 468 | ripgrep output compaction | |
| `src/filters/cat_compact.zig` | 450 | function-body elision for `cat` | |
| `src/filters/git_blame.zig` | 448 | blame compaction | |
| `src/filters/du_compact.zig` | 445 | `du` sig-fig rounding + sort | |
| `src/filters/curl_compact.zig` | 434 | curl -v handshake/PEM stripping | |
| `src/filters/columnar.zig` | 375 | tabular output collapse (docker ps, etc.) | shared infra |
| `src/filters/cargo_test.zig` | 359 | cargo test output | |
| `src/filters/npm_install.zig` | 339 | js pkg manager installs | |
| `src/filters/go_test.zig` | 327 | go test -v | |
| `src/filters/git_branch.zig` | 303 | branch listing | |
| `src/filters/git_stash.zig` | 302 | stash output | |
| `src/filters/git_merge.zig` | 301 | merge output | |
| `src/filters/tree.zig` | 287 | tree(1) compaction | |
| `src/filters/build_compact.zig` | 286 | build progress collapse | |
| `src/filters/find_compact.zig` | 286 | find/find -ls | |
| `src/filters/build_output.zig` | 281 | js bundler/Vite/Next | |
| `src/filters/git_show.zig` | 253 | git show | |
| `src/filters/git_checkout.zig` | 221 | checkout | |
| `src/filters/pytest.zig` | 214 | pytest | |
| `src/filters/tool_compact.zig` | 212 | gh/apple-build/package helpers | |
| `src/filters/git_reflog.zig` | 207 | reflog | |
| `src/filters/docker_logs.zig` | 197 | docker/kubectl logs dedup | |
| `src/filters/detect.zig` | 195 | content shape detection helpers | shared infra |
| `src/filters/git_pull.zig` | 193 | pull | |
| `src/filters/jest.zig` | 192 | jest/vitest | |
| `src/filters/ls_compact.zig` | 183 | ls -l | |
| `src/filters/tsc.zig` | 163 | tsc errors | |
| `src/filters/git_fetch.zig` | 128 | fetch | |
| `src/filters/env_compact.zig` | 103 | env masking | |
| `src/filters/pip_compact.zig` | 89 | pip list/outdated | |
| `src/filters/prettier_compact.zig` | 65 | prettier | |
| `src/filters/ansi.zig` | (small) | ANSI escape stripping | shared infra |
| `src/filters/sigil_rle.zig` | (small) | sigil-prefix RLE | shared infra |
| `src/filters/ws_rle.zig` | (small) | whitespace-prefix RLE | shared infra |
| `src/filters/validator.zig` | (small) | line shape validators | shared infra |
| `tests/integration_test.zig` | 3,586 | end-to-end via `runSmll()` | should split by domain |

## Verified defects

### 1. `unsetupOpencode` leaves a dangling JSON entry — FIXED

Before this PR, `unsetupOpencode` (`src/setup.zig:390`) deleted the on-disk
plugin files (`index.ts`, `package.json`, legacy single-file) but never
unregistered the `smll-proxy` plugin path from
`~/.config/opencode/opencode.json`. Result: after `smll --unsetup opencode`,
opencode kept a dangling reference to a deleted plugin and would error on next
start. The reciprocal function `removeOpencodePluginEntry` existed at
`src/setup.zig:698` but was never invoked.

Compare with `unsetupClaude` (`src/setup.zig:341`) and `unsetupCursor` (`src/setup.zig:474`),
both of which correctly call their respective `remove…Hook` helpers.

**Fix:** `unsetupOpencode` now mirrors the unsetup pattern from claude/cursor —
loads the config, removes the plugin entry via `removeOpencodePluginEntry`,
writes a backup, and only then deletes the plugin files. Three new unit tests
in `src/setup.zig` lock the behavior.

### 2. `stats.zig` non-atomic write — FIXED

`saveJson` wrote directly to `~/.smll/stats.json`. If smll was killed
mid-write (or two smll instances raced), the file could be left half-written
and would fail every future `load()` until manually deleted. The error-swallow
in `load()` masked this as "stats look empty," silently dropping accumulated
counts.

**Fix:** `saveJson` now stages output to `stats.json.tmp` and then renames over
the live path. POSIX rename is atomic on the same filesystem, so either the
old or new file is always visible; on rename failure, the temp file is removed.
This doesn't add cross-process locking — concurrent writers still get
last-writer-wins on their state snapshots — but it eliminates the corrupted-
file failure mode.

### 3. `pipeline.zig` unbounded heap growth — FIXED

`pipeline.run` doubled its heap buffer indefinitely. The wrapper-mode path
guards stdout/stderr drains at 16 MiB (`src/main.zig:453` `MAX_OUTPUT_BYTES`),
but pipe mode had no such guard — a runaway stdin could exhaust memory.

**Fix:** A `MAX_PIPE_INPUT_BYTES` cap (16 MiB, matching wrapper-mode) returns
`error.StreamTooLong` if exceeded. The doubling step is also clamped to the
cap so we never over-allocate near the limit.

## Refactor (landed in this PR)

### `eqAny` helper for repeated `std.mem.eql` chains

`main.zig` had 79 occurrences of `std.mem.eql(u8, cmd_basename, "…")`. The
densest blocks (streaming detection, package-manager dispatch, columnar
dispatch, dotnet/swift/pip subcommand checks) read as long `or`-chains. A new
`eqAny(name, &.{ "a", "b", … })` helper compresses these into self-documenting
lookups. Cost: ~1.1 KB binary size (slice constants > inlined `or`s).
Trade-off accepted for readability — still 44 KB headroom under the cap.

## Recommendations not landed (rationale)

These would each grow this PR materially or duplicate work; deferred to
follow-ups.

### Filter dedup against `util.zig` and shared infra

`src/util.zig` exposes `isGitProgressLine`, `handleBracketRef`,
`processRefStderr`, `isHex40`, `sha7`, `isRefUpdateLine`,
`writeRefUpdateLine`, `writeStatLine`, `writeSummary`, `skipModeNum`, and
`conflictPath`, plus `src/filters/ansi.zig`, `columnar.zig`, `detect.zig`,
and `validator.zig` provide shared helpers. Several filter modules
re-implement adjacent patterns rather than calling these. A separate PR
should mechanically catalogue and substitute these, validated by the
existing test suite. Doing it inside this PR would obscure the bug-fix
diff.

### Split `integration_test.zig` (3,586 LOC)

Logical groupings (smoke, wrapper, dispatch, git_*, columnar, pipe-mode)
are clear from test prefixes. Splitting into per-domain files would
require touching `build.zig`'s fixture wiring and a careful audit to
ensure no test is silently dropped. Deferred to a focused follow-up PR.

### Split the largest filters

`git_status.zig` (849), `generic_compact.zig` (743), `git_log.zig` (526),
`git_diff.zig` (491) — each has internal phases that could become named
helpers. Internal-only refactor, no public-contract change. Deferred to
avoid stepping on the upcoming filter-dedup pass.

### `build.zig` filter-module helper

`build.zig` is 1,150 LOC with 373 `createModule`/`addImport`/`addAnonymousImport`
calls. Every filter follows the same pattern: create module, import `util`,
attach fixtures, register into main + release. A local
`addFilter(name, fixtures)` helper would collapse most of the file. Pure
mechanical, no behavior change. Deferred; this PR already touches many
files and a build.zig rewrite is large enough to merit its own review.

### Rewrite hand-rolled JSON parsers using `std.json`

Both `setup.zig` and `stats.zig` ship hand-rolled JSON readers/writers to
avoid pulling in `std.json` (binary-size concern). They are correct for the
controlled schemas they parse. Pulling in `std.json` would simplify the code
materially but risks pushing past the 288 KiB cap. Not changed.

### Hook script permissions

`writeFileEnsuringParent` (`src/setup.zig:750`) writes files with the
process umask. Hook scripts written under `~/.claude/hooks/` etc. could
land at `0o644` (non-executable) on systems with restrictive umask. Not a
real-world bug because the hook is invoked via `bash <path>` (see
`src/setup.zig:355, 435`) — `bash` reads the file, no execute bit needed.
Documented here so future readers don't re-flag.

## Test, CI, docs improvements (landed)

### `zig fmt --check` in CI

Added a `fmt-check` job to `.github/workflows/ci.yml` so style drift is
caught at PR time. Costs <30 s of CI; aligns the repo with Zig conventions.
The job runs `zig fmt --check src tests build.zig`; this PR also applies
formatting to existing files so the gate goes green from day one.

### Audit doc (this file)

### Notes on README accuracy (no changes needed)

Verified against current code: `cat` is correctly listed, `vitest` is
correctly listed (jest filter dispatch in `src/main.zig:824` handles
vitest), and `bun pm ls` is wired into the tree-routing branch
(`src/main.zig:792`). The README is accurate.

## Expansion ideas — sized for ≤ 44 KB headroom

| Idea | Sketch | Est. size | Priority |
|---|---|---:|---|
| `--explain` | Per-run report of which filter matched and bytes in/out. Reuses already-recorded stats. | 2–4 KB | high |
| `SMLL_DEBUG=1` env trace | Stderr trace of dispatch decisions. Behind comptime check could be ~0 KB when off. | 1–2 KB | high |
| `swift build` / `xcodebuild` filter | README lists; current `tool_compact.applyAppleBuild` is shared and adequate. Consider promoting to a dedicated filter only if existing coverage misses cases. | 4–8 KB | medium |
| `dotnet test` filter | Distinct grammar from `dotnet build`/`dotnet format`; currently routes through `dotnet_compact`. | 4–8 KB | medium |
| `vitest` dedicated filter | Likely covered by jest matcher; verify with fixture before adding. | 2–4 KB | low |
| Coding-agent integrations: `gemini-cli`, `aider`, `copilot-cli` | Each one's setup hook surface is a research task before code. | 4–8 KB each | medium |
| Packaging: APT/RPM/Nix/Scoop/Winget | Out-of-tree, no binary cost. | 0 KB | medium |
| Fuzzing on filter inputs | New CI job; corpus from `tests/fixtures/`. Catches panics on weird inputs. | 0 KB | high |
| Wrapper-mode integration shell tests | Today's tests are mostly stdin-pipe. A shell test that spawns `./smll <cmd>` against canned fixtures would catch dispatch regressions the unit tests miss. | 0 KB | high |

## Risk register

- **Binary size** — Each new filter or feature consumes 2–8 KB. With 44 KB
  headroom, the budget supports roughly 3–6 additions before the cap is at
  risk. CI gate will catch breaches.
- **AGENTS.md PR-size norm** — This PR is deliberately larger than the
  one-PR-one-concern norm, per explicit user direction. Future change sets
  should return to focused PRs.
- **JSON parser hardening** — Mini-parsers in `setup.zig` and `stats.zig`
  are correct for current schemas but assume well-formed input. A
  malicious or corrupted file could trigger unexpected paths; the
  best-effort error-swallow contains the blast radius.
