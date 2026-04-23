# smll

[![ci](https://github.com/nkootstra/smll/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nkootstra/smll/actions/workflows/ci.yml)

A tiny wrapper that compresses noisy command output before it lands in your
coding agent's context window. Drop-in — just prefix the command. Format-lossy,
fact-preserving by default; set `SMLL_LOSSLESS=1` to bypass all filters.

- ~240 KB release binary (Linux x86_64, `ReleaseSmall` + strip)
- Single-file Zig, zero runtime dependencies, no telemetry

## Install

```sh
brew install nkootstra/smll/smll
```

Or two-step:

```sh
brew tap nkootstra/smll
brew install smll
```

Prebuilt bottles ship for `aarch64-apple-darwin`, `x86_64-linux-gnu`, and
`aarch64-linux-gnu`. On any other platform (notably macOS Intel), Homebrew
builds from source via `zig` — the formula declares it as a `:build`
dependency. See [Build from source](#build-from-source) for the manual path.

## Usage

**Wrapper mode.** Prefix any supported command with `smll`:

```sh
smll git status
smll git log --oneline -20
smll rg TODO
smll tree src
```

Every distinct fact in the raw output is recoverable from the compacted stream
— smll collapses format (padding, banners, progress chatter, duplicate lines)
but preserves the actionable payload (failures, errors, paths, counts).

**Lossless escape hatch.** Set `SMLL_LOSSLESS=1` to bypass every filter and
pass the raw output through byte-identically:

```sh
SMLL_LOSSLESS=1 smll jest           # raw jest output, no compaction
SMLL_LOSSLESS=1 smll docker ps      # full columnar table preserved
```

## Supported commands

| Category | Commands | Default behavior |
|---|---|---|
| git | `status`, `diff`, `log`, `show`, `add`, `commit`, `push`, `pull`, `fetch`, `merge`, `rebase`, `checkout`, `branch`, `stash`, `blame` | noise strip |
| search / listing | `rg`, `tree` | noise strip |
| filesystem walk | `find` / `find -ls` | strip metadata columns; collapse ≥3 paths/parent to count |
| columnar tables | `docker ps`, `kubectl get`, `gh pr/issue list`, `ps`, `ls -l`, `bun pm ls` | column/padding collapse |
| disk usage | `du`, `du -sh` | 2-sig-fig round + sort |
| network probe | `curl -v` / `-vvv` | drop TLS handshake + PEM certs |
| build drivers | `make`, `cargo build`, `go build` | collapse progress, keep warnings/errors |
| test runners | `cargo test`, `pytest`, `jest` / `vitest`, `go test -v` | drop PASS, keep FAIL + evidence |
| type checker | `tsc` — compresses each error to `path:L:C TSnnnn` | locations-only |
| logs | `docker logs`, `kubectl logs` — consecutive-identical dedup | dedup + `(×N)` marker |
| package managers | `npm install` / `npm ci` — keep WARN + summary, drop notice/funding | drop noise, keep actionable |
| fallback | any unknown command whose stdout exceeds 64 KiB | ANSI strip + blank-collapse + RLE |

Anything short and unknown passes through untouched. `SMLL_LOSSLESS=1`
bypasses every filter.

## Design principles

**Agent-first defaults.** Without any env var, smll runs every compression
filter it has. The default is the densest supported output that preserves every
actionable fact an agent's next step could depend on. `SMLL_LOSSLESS=1` opts
out and restores byte-identical pass-through.

**Format-lossy, fact-preserving.** smll collapses format (padding, banners,
passing-case chatter) but keeps every distinct fact the agent might act on.
Safe to alias over raw tools for agent workflows.

**Actionable over minimal.** A 6-token "2 errors" wins a bytes benchmark but
loses the use case. smll preserves failure evidence (`--- FAIL:` lines with
their `t.Errorf` context, `npm WARN deprecated: Use X instead`) even when a
smaller competitor collapses to a count.

**Small, no deps, no telemetry.** The binary stays under 256 KB (Linux x86_64
release). No network calls, no analytics, no config files.

## Migrating from v0.5

v0.6 inverts the env-var posture. Previously `SMLL_COMPACT=1` opted *in* to
lossy compaction; now lossy is the default.

- Remove `SMLL_COMPACT=1` from your shell rc — it is silently ignored.
- If you relied on byte-identical output (`SMLL_COMPACT` unset), set
  `SMLL_LOSSLESS=1` instead.
- If you were already setting `SMLL_COMPACT=1` everywhere, you can delete it
  and get the same behavior.

## Build from source

Required for contributors and for platforms without a prebuilt bottle.

```sh
git clone https://github.com/nkootstra/smll.git
cd smll
zig build release           # zig 0.16.0+
cp zig-out/release/smll /usr/local/bin/
```

## Development

```sh
zig build test              # ~560 unit + integration tests
zig build release           # produces zig-out/release/smll
```

Tested on Zig 0.16.0, macOS + Linux.
