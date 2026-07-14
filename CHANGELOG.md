# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/).

Dates are in `YYYY-MM-DD`. Older release notes with worked numbers and
fixtures live under [`docs/releases/`](./docs/releases/).

## [Unreleased]

## [1.9.0] - 2026-07-14

### Added

- `smll --raw <command...>` and `<command> | smll --raw` provide discoverable
  aliases for byte-identical lossless output.
- Semantic regression coverage now spans explicit wrapping, pipe mode,
  installed hooks, streaming, lossless output, exit/signal propagation,
  truncation, UTF-8 boundaries, Git patches, repository states, and capture
  limits.
- Repeatable hardening benchmarks compare median and p95 warm startup, hook
  classification, filter throughput, and concurrent state writes against an
  explicit baseline.

### Changed

- Transparent runners such as `uv run`, `uvx`, `poetry run`, `pnpm exec`, and
  `npx` are normalized without changing argv boundaries, while version, help,
  query, structured, patch, NUL-delimited, and custom-format output stays raw.
- Bounded filters retain deterministic head-and-tail output with exact omission
  counts and a `--raw` recovery instruction; unique long lines and invalid byte
  sequences are preserved.
- Stats and history use a versioned schema that separates raw, displayed,
  explicitly omitted, diagnostic, and verified formatting-saved bytes.

### Fixed

- Installed hooks no longer grant command authority or rewrite compound shell
  commands. Simple supported commands are blocked with a suggestion to rerun
  through smll; ambiguous commands leave normal agent permissions untouched.
- Nonzero commands cannot produce synthetic success, and unrecognized failures
  fall back to raw output instead of an empty summary.
- Child exit codes, Unix signals, oversized captures/stdin, descendant-held
  pipes, stream draining, and stdout/stderr ownership now behave consistently.
- Git patches, merge/rebase/cherry-pick/revert/bisect state, intent-to-add,
  listing hierarchy, parent paths, and requested file metadata retain their
  semantic information.
- Local state uses private permissions, serialized atomic writes, redacted tee
  headers, collision-resistant filenames, and complete `--stats --reset --all`
  cleanup.
- Hook setup validates before writing, records ownership, preserves config
  permissions, rolls back transactionally, and never reports success after a
  partial or no-op unsetup.

## [1.8.2] - 2026-06-30

### Fixed

- `gh api graphql --paginate --jq .data` and related `gh` data-query commands
  now pass through unchanged instead of being mistaken for compactable `gh`
  output.

## [1.8.1] - 2026-06-25

### Added

- `dotnet` MSBuild query invocations now pass through unchanged so commands such
  as `dotnet msbuild -getProperty:TargetFramework` preserve machine-readable
  output.

### Changed

- Build and process-output compaction received performance and size
  improvements.

## [1.8.0] — 2026-06-16

### Changed

- Bumped package version to `1.8.0`.

## [1.7.0] — 2026-06-13

### Added

- `cargo check` and `cargo clippy` now use the existing build-output compactor in
  wrapper mode. Cargo `Checking` progress collapses to `Checked N (cargo)`,
  while clippy/rustc diagnostics and final `Finished ...` lines are preserved.
- Mocha and Node's built-in `node --test` output now compact in wrapper and pipe
  mode. Passing cases are dropped, failure blocks stay intact, and count trailers
  such as `1 failing` / `# fail 1` are preserved. Script runners
  (`npm/pnpm/yarn/bun test`) try this shape after Jest/Vitest detection.
- `docker compose ps` / `docker-compose ps` now reuse the Docker container
  summary (`dNup name(image,status)`), and `docker compose logs` /
  `docker-compose logs` normalize `service | payload` prefixes before
  consecutive duplicate collapse.
- `docker images` now emits an argv-gated summary
  (`images N: repo:tag(size) ... dangling xK (+M)`) instead of generic column
  compaction.
- `ninja` build progress now collapses `[N/M] ...` rows to `built N (ninja)`
  using the completed step count while preserving compiler warnings/errors, and
  direct `webpack` builds now
  reuse the JS build-output compactor for asset summaries and compiled banners.
- `SMLL_STREAM=1` now enables opt-in streaming compaction for follow-mode logs:
  `docker logs -f`, `docker compose logs -f`, `kubectl logs -f`, `tail -f`,
  and `journalctl -f`. First occurrences are emitted immediately, repeated
  payloads are summarized on flush, default streaming behavior remains raw
  unless explicitly enabled, and space-separated `YYYY-MM-DD HH:MM:SS`
  timestamps now dedupe correctly.
- `SMLL_STREAM=1` also supports `tsc --watch`: repeated watch banners and code
  frames are suppressed, diagnostics stream as `path:L:C TSnnnn: message`, and
  clean recompiles emit `clean (0 errors)` once per transition.
- `SMLL_STREAM=1` now supports direct `jest --watch` / `vitest -w` runs:
  clear-screen render frames are compacted with the existing Jest/Vitest
  failure filter, identical re-renders are suppressed, and passing transitions
  emit `all tests passed`.
- `SMLL_STREAM=1` now supports `gh run watch`: repeated job table redraws are
  reduced to job state transitions such as `build: queued->running`, while
  already-completed run messages pass through raw.
- Datadog `pup` is now an auto-wrap target. Wrapper mode minifies clean JSON
  output and strips box framing/padding from `-o table` output while preserving
  lossless mode.
- The package-dependency-tree compaction (`src/filters/package_tree.zig`) now
  covers `npm ls`/`npm list`, `pnpm ls`/`pnpm list`, and `yarn list` in addition
  to `bun pm ls` (argv-gated dispatch in wrapper mode). It emits the same
  grammar — root context, `deps +N: …` for direct dependencies, and a
  `nested rows xM` transitive count. npm/yarn/bun direct deps are detected by a
  column-0 box connector (yarn v1's two-char `├─`/`└─` are handled alongside the
  three-char `├──`/`└──`/`├─┬`/`└─┬`), so indented transitive rows are never
  miscounted as direct. pnpm's flat `dependencies:` list is parsed as direct
  deps (`name version` → `name@version`) with every box-drawn row treated as
  transitive. `SMLL_LOSSLESS=1` bypasses it.
- Plain `ls` (no `-l`) now gets argv-gated normalization in wrapper mode
  (`src/filters/ls_compact.zig` `applyPlain`). `-C`/`-x`/`-m` column and comma
  layouts are split back to one name per line and re-sorted, so the result is
  the same listing plain `ls` would have printed; `.`/`..` are dropped. A
  single-directory listing is never collapsed — every name is shown. Only
  multi-directory output (`ls a b`, `ls -R`) collapses each sub-listing of ≥3
  entries to `dir/ (N entries: a, b, c)`, keeping the headerless top block of
  `ls -R` in full. Fails safe: a blocked listing that parses to nothing passes
  through raw, and `SMLL_LOSSLESS=1` bypasses it.
- `gh pr view`, `gh pr checks`, and `gh run view` get purpose-built compaction
  in wrapper mode (new `src/filters/gh_compact.zig`, dispatched by argv so the
  shape is never guessed). `gh pr view` folds the `number`/`state`/`title`
  metadata block into a one-line header, keeps the remaining non-empty fields,
  and prints the body verbatim (the generic keep-filter used to drop the title,
  state, and number entirely). `gh pr checks` collapses passing checks into a
  count and keeps every non-passing row so the failure URL stays clickable.
  `gh run view` collapses passing jobs to a count, keeps failing jobs with their
  failing steps, and de-duplicates the ANNOTATIONS section — GitHub repeats the
  same multi-hundred-byte Node-deprecation warning once per job, which now
  collapses to a single line that keeps the full message and lists every
  affected job. Errors are never dropped — identical error text across N jobs
  collapses the same way, preserving the message and all N locations. Every
  handler fails safe: any input that does not match the
  expected non-TTY `gh` grammar passes through raw, and `SMLL_LOSSLESS=1`
  bypasses all three.
- `smll sh -c "<cmd>"` (and `bash`/`zsh`) now route the wrapped command's
  captured stdout through the pipe-mode content-detection chain — the same
  first-match-wins dispatcher stdin uses — so a shell-wrapped `git status`,
  `ls`, test run, etc. gets the same compaction it would as a direct wrapper or
  pipe. A content filter only fires when the combined output still matches its
  grammar, so mixed `cmd1 && cmd2` output falls through to the generic
  compactor. Interactive/login shells (`-i`/`-l`) and `SMLL_LOSSLESS=1` are left
  untouched. (The pipe filter chain moved to `src/pipe_filters.zig` so pipe mode
  and the shell re-dispatch share one definition.)
- `scripts/bench-pipe.sh` and a non-blocking `pipe-bench` CI job measure pipe
  throughput (MB/s) over the whole `tests/fixtures/large/` corpus as a single
  concatenated stream, so the number reflects scan speed rather than process
  startup. A generous floor surfaces a CI annotation on an egregious regression
  (e.g. an accidental O(n²) scan) without blocking merges.

### Changed

- Pipe-mode dispatch now runs a single-pass pre-classifier before the
  test-runner and package-manager filters (`cargo test`, `jest`/`vitest`,
  `tsc`, `go test`, `pytest`, npm/pnpm/bun/yarn/composer). Each of those filters
  probes several substrings, so an unrelated large stream (e.g. a 500 KiB
  `journalctl` dump) used to pay for many full scans before falling through to
  the generic compactor. The classifier scans the whole input once, records
  which needles are present, and lets each filter skip its `matches()` when its
  needles are absent. Routing is provably unchanged — every gate is a superset
  of its filter's `matches()`, pinned by a property test over real fixtures —
  and the scan covers the entire input, so a summary line appearing late in a
  large output is still detected.
- Generic compactor no longer allocates a per-line copy for every output line:
  unique (non-repeated) lines are now emitted as borrowed slices, and only the
  collapsed `×N` run lines are allocated. Output is byte-for-byte unchanged; the
  hot path for unknown commands over 4 KiB just does far less heap work.
- Columnar tables now mark a repeated column value with a `~` sigil instead of a
  bare blank gap, so an agent can tell "same as the row above" apart from a
  genuinely empty field (and a trailing repeated column no longer leaves a
  dangling space).
- Raised the CI release size cap from 320 KiB to 360 KiB (368,640 bytes) to
  make room for the in-progress runner/test output compaction work. Documented
  that the gate measures a native x86_64 build, which runs slightly larger than
  a cross-compiled one.

## [1.6.0] — 2026-06-07

### Added

- Directory-aware readable compaction for `git log --stat` and
  `git show --stat`, preserving commit identity, subjects, trailers, file
  paths, and summary lines while trimming noisy stat details.
- ASCII `tree` output detection and summarization, with integration
  fixtures and benchmark coverage for larger tree outputs.
- Plain `find` output grouping for repeated directory-heavy listings.

### Changed

- Wrapper routing now recognizes the new readable `git` stat and `tree`
  compaction paths.
- Release binary size guidance and CI size cap now reflect the expanded
  compaction coverage.

### Fixed

- Help output remains under the release size cap.
- `git` stat ordering and plain `find` grouping now produce stable sorted
  summaries.

## [1.5.1] — 2026-06-06

### Added

- `-h` / `--help` with a full CLI usage reference covering wrapper mode,
  pipe mode, stats/discovery, agent setup, diagnostics, and environment
  overrides.

### Changed

- Running `smll` with no arguments from an interactive terminal now prints
  help instead of waiting on stdin. Piped stdin (`cmd | smll`) still uses
  pipe-filter mode.

## [1.5.0] — 2026-06-06

### Added

- Codex agent setup/unsetup, installing a `PreToolUse` hook under
  `~/.codex/hooks.json` that rewrites noisy Bash commands through `smll`.
- `--filters` to list supported filters and agent auto-wrap commands.
- Compact filters for ESLint/Biome diagnostics, `next build`,
  Terraform/OpenTofu plans, and clean JSON output from `aws`/`jq`.
- Agent setup auto-wrap coverage for additional build, lint, infra, JSON,
  table, and package-manager commands.
- Append-only local command history in `~/.smll/history.jsonl`, keeping
  per-command labels, project key, filter name, exit code, byte counts, and
  duration without storing full argv.
- Token-first `--stats` output with `--verbose`, `--since`, `--project`, and
  `--by-command` views, plus `--discover` for low-savings, passthrough, and
  top raw-output command labels.
- `--explain`, `--rewrite`, `--err`, and `--test` flag-style wrapper commands.
- Successful `zig build --summary all` compaction that keeps the summary line
  while dropping the successful step tree.

### Changed

- `find -ls` directory-collapsed output now keeps representative example paths
  in aggregate lines.

## [1.4.0] — 2026-06-04

### Added

- `SECURITY.md` with a vulnerability-disclosure process and threat
  model.
- `CONTRIBUTING.md` covering design principles, filter-authoring
  guidance, and PR discipline.
- This changelog file, replacing scattered release notes as the
  single source of truth for what changed when.
- MIT license.
- Raw-output tee logs for failed wrapped commands, with opt-outs via
  `SMLL_TEE=0` and `DO_NOT_TRACK=1`.
- Containerized comparison benchmark tooling and expanded agent-oriented
  fixtures.

### Changed

- Wrapper, setup, pipe-filter, and git wrapper code split into focused
  modules.
- Build configuration now uses a declarative module registry with a
  compile-time duplicate-name check.
- Several command compactors gained broader coverage for build, package
  manager, and tool outputs.

### Fixed

- OpenCode unsetup now removes the `smll-proxy` plugin entry before
  deleting plugin files.
- Stats writes are atomic to avoid corrupting `~/.smll/stats.json` on
  interrupted or racing writes.
- Pipe-mode input buffering is capped to avoid unbounded heap growth.
- Tee rotation order is deterministic when multiple logs share the same
  mtime.

### Documentation

- Added a codebase audit with follow-up refactor and hardening notes.

## [1.3.1] — 2026-05-17

### Changed

- Wrapper-mode passthrough behaviour is now covered by characterisation
  tests, locking in the contract for future refactors.

## [1.3.0] — 2026-05-14

### Added

- Experimental filter improvements: `git reflog`, build-output (Vite /
  Next.js / Nuxt.js), and broader install/package-manager
  generalisation.

### Changed

- Generic command output compaction tuned for higher token density on
  unknown-tool outputs.

### Security

- All GitHub Actions pinned to commit SHAs.
- Tag-derived version interpolation hardened in the release workflow.

## [1.2.5] — 2026-05-03

### Added

- `--version` flag.

## [1.2.4] — 2026-05-03

### Fixed

- Agent retry loops on commands that legitimately produced no output —
  smll now surfaces an unambiguous "no output" hint instead of an
  ambiguous empty buffer.

### Changed

- Further release-binary size reductions.

## [1.2.3] — 2026-04-29

### Added

- Hardened wrapper output safety; additional bespoke filters for common
  tools.

### Changed

- Debug/test builds link libc explicitly so they match the release
  module's linkage assumptions.

## [1.2.2] — 2026-04-28

### Changed

- Release binary shrunk from ~316 KB to ~204 KB (~35% smaller) via
  Mach-O symbol-table stripping, JSON-writer compaction, and other
  micro-optimisations.

### Fixed

- Post-build `strip` step is now skipped on non-macOS targets where it
  was a no-op (or worse).

### Documentation

- README binary-size figure updated to ~220 KB.

## [1.2.1] — 2026-04-27

### Fixed

- Wrapper-mode dispatch: `generic_compact` is now correctly used as the
  fallback for every bespoke block instead of being silently skipped on
  some branches.

## [1.2.0] — 2026-04-27

### Added

- Broader coverage of the wrapper-mode dispatch surface.

## [1.1.2] — 2026-04-26

### Added

- Before/after context lines around `cargo test` compiler errors so
  agents see the failing source location, not just the error message.

## [1.1.1] — 2026-04-26

### Added

- Regression test for ANSI-coloured `cargo test` compiler-error
  context.

## [1.1.0] — 2026-04-26

### Added

- ANSI-aware `cargo test` filter improvements.

## [1.0.7] – [1.0.0] — 2026-04-26

A burst of polish following the 1.0.0 cut. Highlights:

### Added

- Cursor agent setup (`smll --setup cursor`) with hook script and
  `~/.cursor/hooks.json` integration.
- `cat` / file-read compression (keeps imports, signatures, types;
  elides function bodies).
- `--stats` flag for local token-savings tracking, stored at
  `~/.smll/stats.json`. `DO_NOT_TRACK=1` skips writes.
- README documentation for Cursor setup and the `cat` row in the
  supported-commands table.

## [0.9.0] — 2026-04-26

### Changed

- Filter throughput optimisations: streaming `git status`, early
  dispatch in `git diff`, batched writes, larger pipe-mode buffers.

## [0.8.0] — 2026-04-25

### Added

- Agent setup/unsetup for Claude Code and OpenCode, with backup-before-
  write safety and a conflict guard that aborts when an existing
  third-party proxy integration is detected.
- `AGENTS.md` and `CLAUDE.md` guardrails to encode branch discipline and
  CI-safety policy for both human and agent contributors.

## [0.7.1] — 2026-04-24

### Fixed

- Follow-up patches to the v0.7.0 compression work.

## [0.7.0] — 2026-04-23

Comprehensive token compression across all supported commands. See
[`docs/releases/v0.7.0.md`](./docs/releases/v0.7.0.md) for the full
worked numbers.

### Added

- Generic compactor with global non-consecutive dedup, block-pattern
  collapse, line truncation, and high-repeat truncation. Threshold
  lowered from 64 KB to 16 KB.
- Directory grouping in `git status`, `git commit`, and `git merge`.
- Compact pipe-mode formats for `git log` and `git show`.
- `git blame` truncation: one source line per commit block plus a
  `(+N)` summary.
- Diff-context drop with function-aware hunk headers.
- `curl`: header dedup after first request, body truncation,
  5-request cap.
- `du`: top-10 entries plus tail summary with common path-prefix
  stripping.
- `docker logs`: timestamps abbreviated to `HH:MM:SS`.
- Columnar improvements: repeated column values shown as empty fields;
  last-field absolute paths truncated to basename.

## [0.6.0] — 2026-04-23

**Breaking change.** smll is now lossy by default. See
[`docs/releases/v0.6.0.md`](./docs/releases/v0.6.0.md) for the full
migration notes.

### Changed

- Env-var posture inverted: `SMLL_COMPACT=1` removed; `SMLL_LOSSLESS=1`
  added as the global opt-out for byte-identical passthrough.

### Added

- 64 KiB-gated generic compactor for unknown commands.
- `find_compact` filter for `find` and `find -ls`.
- `du_compact` filter for `du` and `du -sh`.
- `curl_compact` filter for `curl -v` / `-vvv` (stderr-aware).
- `build_compact` filter for `make`, `cargo build`, `go build`.

### Removed

- `SMLL_COMPACT` environment variable (silently ignored if still set).

## [0.5.0] — 2026-04-22

First tagged public release. Earlier development history is preserved
in the git log.

[Unreleased]: https://github.com/nkootstra/smll/compare/v1.9.0...HEAD
[1.9.0]: https://github.com/nkootstra/smll/compare/v1.8.2...v1.9.0
[1.8.2]: https://github.com/nkootstra/smll/compare/v1.8.1...v1.8.2
[1.8.1]: https://github.com/nkootstra/smll/compare/v1.8.0...v1.8.1
[1.8.0]: https://github.com/nkootstra/smll/compare/v1.7.0...v1.8.0
[1.7.0]: https://github.com/nkootstra/smll/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/nkootstra/smll/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/nkootstra/smll/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/nkootstra/smll/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/nkootstra/smll/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/nkootstra/smll/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/nkootstra/smll/compare/v1.2.5...v1.3.0
[1.2.5]: https://github.com/nkootstra/smll/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/nkootstra/smll/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/nkootstra/smll/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/nkootstra/smll/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/nkootstra/smll/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/nkootstra/smll/compare/v1.1.2...v1.2.0
[1.1.2]: https://github.com/nkootstra/smll/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/nkootstra/smll/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/nkootstra/smll/compare/v1.0.7...v1.1.0
[1.0.7]: https://github.com/nkootstra/smll/compare/v1.0.0...v1.0.7
[1.0.0]: https://github.com/nkootstra/smll/releases/tag/v1.0.0
[0.9.0]: https://github.com/nkootstra/smll/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/nkootstra/smll/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/nkootstra/smll/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/nkootstra/smll/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nkootstra/smll/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nkootstra/smll/releases/tag/v0.5.0
