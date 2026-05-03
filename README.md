# smll

[![ci](https://github.com/nkootstra/smll/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nkootstra/smll/actions/workflows/ci.yml)

A tiny wrapper that compresses noisy command output before it lands in your
coding agent's context window. Drop-in — just prefix the command. Format-lossy,
fact-preserving by default; set `SMLL_LOSSLESS=1` to bypass all filters.

- ~220 KB release binary (Linux x86_64, `ReleaseSmall` + strip)
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

## Agent setup

smll can install or remove safe defaults for popular agent CLIs:

```sh
smll --setup claude
smll --setup opencode
smll --setup cursor
smll --unsetup claude
smll --unsetup opencode
smll --unsetup cursor
```

Use `--dry-run` to preview writes/deletes:

```sh
smll --setup claude --dry-run
smll --unsetup opencode --dry-run
```

What setup does:
- `claude`: writes `~/.claude/hooks/smll-pretooluse.sh` and adds a `PreToolUse`
  hook in `~/.claude/settings.json` that blocks noisy Bash commands unless they
  are prefixed with `smll`.
- `opencode`: writes `~/.config/opencode/plugins/smll-proxy.js` and enables it
  in `~/.config/opencode/opencode.json`; the plugin rewrites matching Bash
  commands to `smll <command>`.
- `cursor`: writes `~/.cursor/hooks.json` with a `preToolUse` hook and
  `~/.cursor/hooks/smll-pretooluse.sh`; blocks noisy Shell commands unless
  prefixed with `smll`.

Safety behavior:
- Existing files are backed up as `*.bak.smll` before changes.
- If existing RTK integration is detected, setup aborts and asks you to remove
  RTK first (to avoid conflicting double-proxy behavior).

## Token savings

smll tracks how many bytes it saves per wrapped command. View cumulative stats
with:

```sh
smll --stats
```

```
smll stats

  Commands wrapped:  142
  Input (raw):       2.8 MB
  Output (compact):  412.3 KB
  Saved:             2.4 MB (85%)
  Est. tokens saved: ~612.5K
```

Reset counters:

```sh
smll --stats --reset
```

Stats are stored locally in `~/.smll/stats.json` (~80 bytes). No network calls.
Best-effort — if the file can't be read or written, smll silently skips stats
and the wrapped command runs normally. Pipe mode (stdin) does not record stats.
Set `DO_NOT_TRACK=1` to skip local stats writes as well.

## Supported commands

| Category | Commands | Default behavior |
|---|---|---|
| file read | `cat` | keep imports, signatures, types; elide function bodies |
| git | `status`, `diff`, `log`, `show`, `add`, `commit`, `push`, `pull`, `fetch`, `merge`, `rebase`, `checkout`, `branch`, `stash`, `blame` | noise strip |
| search / listing | `rg`, `tree` | noise strip |
| filesystem walk | `find` / `find -ls` | strip metadata columns; collapse ≥3 paths/parent to count |
| columnar tables | `docker ps`, `kubectl get`, `gh pr/issue list`, `ps`, `ls -l`, `bun pm ls` | column/padding collapse |
| counts / environment | `wc`, `env` | collapse count padding; mask sensitive env values |
| disk usage | `du`, `du -sh` | 2-sig-fig round + sort |
| network probe | `curl -v` / `-vvv` | drop TLS handshake + PEM certs; preserve response bodies byte-for-byte |
| build drivers | `make`, `cargo build`, `go build`, `dotnet build`, `swift build`, `xcodebuild` | collapse progress, keep warnings/errors |
| test runners | `cargo test`, `pytest`, `jest` / `vitest`, `go test -v`, `dotnet test` | drop PASS/progress, keep FAIL + evidence |
| type checker / lint | `tsc`, `mypy`, `ruff` | preserve diagnostics and summaries |
| formatters | `prettier`, `dotnet format`, `ruff format` | keep files/summaries needing action |
| logs | `docker logs`, `kubectl logs` — consecutive-identical dedup | dedup + `(×N)` marker |
| package managers | `npm install` / `npm ci`, `pnpm`, `yarn`, `bun`, `pip list/outdated`, `uv`, `uvx` | drop noise, keep warnings/errors/summaries |
| GitHub CLI | `gh` | keep errors/statuses/URLs/help; table output still column-compacts |
| finite readers | `head`, `tail` | pass through exactly; follow/watch forms stream raw |
| fallback | unknown table/list-shaped output; large unknown stdout | safe table padding collapse; ANSI strip + blank-collapse + RLE |

Unknown output only compacts when the shape is high-confidence. Ambiguous short
output passes through untouched. `SMLL_LOSSLESS=1` bypasses every filter.

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

**Small, no deps, no telemetry.** The binary stays under 288 KB (Linux x86_64
release). No network calls, no analytics. The only file smll writes is
`~/.smll/stats.json` for local token-savings tracking (`--stats`).

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
zig build test              # ~600 unit + integration tests
zig build release           # produces zig-out/release/smll
```

Tested on Zig 0.16.0, macOS + Linux.
