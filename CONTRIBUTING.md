# Contributing to smll

Thanks for considering a contribution. smll is small on purpose; this
guide explains what kinds of change fit and how to land them safely.

## Design principles

Before opening a PR, please make sure your change aligns with these.
They are the same principles documented in the README, restated here as
contributor-facing rules.

1. **Agent-first defaults.** The default mode runs every compression
   filter smll has. New filters ship enabled.
2. **Format-lossy, fact-preserving.** smll collapses padding, banners,
   progress chatter, and duplicate lines. It must keep every distinct
   *fact* a consumer might act on (failing test, error line, path,
   count, exit-status message). Dropping a fact is a bug.
3. **Actionable over minimal.** A change that wins the bytes benchmark
   but discards the next-step evidence is a regression even if tests
   pass.
4. **Small, no deps, no telemetry.** No new runtime dependencies. No
   network calls. The only file smll writes outside the working
   directory is `~/.smll/stats.json` (and, in the future, files under
   `~/.smll/tee/`).
5. **Lossless escape hatch is sacred.** `SMLL_LOSSLESS=1` is a contract:
   it must produce byte-identical passthrough for every supported
   command. Any change that breaks that is a bug.

If your change tension-tests one of these, call it out in the PR
description so reviewers can weigh in.

## Scope of accepted contributions

In scope:

- New filters for tools whose output is noisy and predictable, and where
  a realistic fixture shows ≥ ~50% byte reduction with no loss of
  actionable signal.
- Improvements to existing filters: tighter compaction, better edge-case
  handling, faster paths.
- Bug fixes (regressions, format-edge issues, exit-code mishandling).
- Test coverage gaps (snapshot/fixture additions, integration tests
  around the wrapper binary).
- Documentation: corrections, clarifications, missing supported-command
  rows.

Out of scope without a prior discussion issue:

- New runtime dependencies (`build.zig.zon` `.dependencies` must stay
  empty).
- Telemetry, analytics, or any network call.
- Daemon mode, IPC, or persistent background state beyond
  `~/.smll/stats.json`.
- Project-local filter overrides (e.g. loading a config file from the
  current working directory). smll's filter set is built-in by design.
- A plugin or extension system that allows loading filters from outside
  the binary at runtime.

If in doubt, open an issue first describing the change and the
motivating output sample.

## Development workflow

### Prerequisites

- Zig 0.16.0 (exact match required; CI fails on mismatch). Check with
  `zig version`. The `scripts/check-zig-version.sh` script is wired into
  CI.

### Build and test

```sh
zig build              # debug build
zig build test         # full test suite (~770 tests)
zig build release      # ReleaseSmall + strip, output at zig-out/release/smll
scripts/audit-fixtures.py           # fixture references + generated drift
python3 scripts/test_compare_rtk_metrics.py  # benchmark metric contract
scripts/smoke-supported-commands.py  # isolated wrapper dispatch smoke
```

`zig build test --summary all` is the verification command required
before opening or updating a PR. Both macOS and Linux runners must
remain green.

### Local benchmarks

```sh
scripts/measure.sh           # latency + compression ratio per fixture
scripts/generate_large_fixtures.sh   # regenerate large fixtures
scripts/audit-fixtures.py            # verify committed fixtures stay coherent
scripts/compare-rtk-container.sh     # Dockerized default agent-profile comparison vs rtk
scripts/compare-rtk-container.sh --profile rtk     # rtk-suite-inspired cases only
scripts/compare-rtk-container.sh --profile stress  # oversized coverage-gap probes
scripts/compare-rtk-container.sh --profile all     # every committed case
```

The large fixtures are committed and reproducible; regenerate them only
when adding a new one.

The rtk comparison is intentionally container-first so contributors do not need
rtk, Rust, Zig, or tokenizer packages installed locally. It pins rtk to
`v0.42.3` by default; set `RTK_REF=<tag-or-sha>` to compare another revision.
The headline comparison is exact tokenizer-counted stdout+stderr net savings;
native stats/gain estimates in the report are diagnostics, not the benchmark
score.
The default `agent` profile focuses on commands agent harnesses commonly run;
the `rtk` profile tracks cases inspired by rtk's own filter/test surface; and
`stress` keeps very large pass-through probes out of the default headline.
For local development, use `RTK_BIN=/path/to/rtk python3 scripts/compare-rtk.py`.

## Adding a filter

Each filter is a single `.zig` file under `src/filters/`. The contract
is uniform:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Return true when this filter recognises the given child output.
/// Cheap: read at most the first non-empty line or two.
pub fn matches(input: []const u8) bool { ... }

/// Compact `stdout` and `stderr` from the child process and write the
/// result to `writer`. Must preserve every actionable fact.
pub fn apply(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
) !void { ... }
```

Steps:

1. Add `src/filters/<name>.zig` with `matches` + `apply`.
2. Wire it into `build.zig` and `src/main.zig`'s dispatch (the comptime
   registry covers all three locations from one edit once that lands;
   until then, follow the pattern used by neighbouring filters).
3. Drop a realistic fixture into `tests/fixtures/<name>.txt`.
4. Add tests inside the filter file. Embed the fixture via
   `addAnonymousImport` in `build.zig`. Assert exact output with
   `expectEqualStrings` for the small-output case and assert byte-budget
   targets for large fixtures.
5. Document the command in `README.md`'s "Supported commands" table.

### Filter quality bar

- **Realistic fixture.** Synthetic happy-path output is not enough; use
  output from a real invocation when possible.
- **Tests for the error path.** What does the filter do on truncated,
  malformed, or empty input? At minimum, passing-through unchanged is
  acceptable.
- **No fact loss.** Every error line, failing test name, path, count,
  and summary line in the input must appear in the output (possibly
  reformatted).
- **No fabrication.** Never emit a line the child did not produce.
  Counts and summaries are allowed (e.g. `(+12 more)`), but they must
  reflect the real input.
- **Byte budget.** The compacted output should typically be ≤ 50% of
  raw input on realistic fixtures. Compaction that improves token
  density (digit normalization, padding collapse) is valuable even when
  byte count stays similar — document this in the PR.

## Pull request guidance

- Branch off `main`. Do not commit directly to `main`.
- Keep changes focused. One filter per PR, or one refactor per PR,
  rather than mixed.
- Run `zig build test --summary all` locally before opening the PR.
- If your change touches release/size behaviour, also run
  `zig build release` and note the resulting binary size in the PR
  description.
- PR descriptions should include: intent, key changes, verification
  run, and risk notes (what could regress, what's not covered).
- CI must be green before merge.

## Bug fixes

For any bug fix, write a failing test first, then fix. The test must
fail on `main` without the fix and pass with it. Mock only at system
boundaries (filesystem, clock, network — though smll has no network);
do not mock internal collaborators.

## Releasing

Releases are maintainer-only. The process:

1. Bump `.version` in `build.zig.zon`.
2. Append a section to `CHANGELOG.md` for the new version.
3. Tag the commit with an annotated, GitHub-signature-verified tag
   matching the regex `^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$`.
4. Push the tag. CI builds release artifacts, publishes the GitHub
   release, and (for non-rc tags) opens a Homebrew formula bump PR
   against the tap.

## Code of conduct

Be respectful, assume good faith, and stay focused on the technical
question. Personal attacks, harassment, or off-topic political
discussion will be moderated.

## Reporting security issues

Do not file public issues for security bugs. Follow the process in
[`SECURITY.md`](./SECURITY.md).
