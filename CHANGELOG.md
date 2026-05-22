# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/).

Dates are in `YYYY-MM-DD`. Older release notes with worked numbers and
fixtures live under [`docs/releases/`](./docs/releases/).

## [Unreleased]

### Added

- `SECURITY.md` with a vulnerability-disclosure process and threat
  model.
- `CONTRIBUTING.md` covering design principles, filter-authoring
  guidance, and PR discipline.
- This changelog file, replacing scattered release notes as the
  single source of truth for what changed when.

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

[Unreleased]: https://github.com/nkootstra/smll/compare/v1.3.1...HEAD
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
[0.9.0]: https://github.com/nkootstra/smll/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/nkootstra/smll/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/nkootstra/smll/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/nkootstra/smll/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/nkootstra/smll/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/nkootstra/smll/releases/tag/v0.5.0
