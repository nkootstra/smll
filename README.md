# smll

[![ci](https://github.com/nkootstra/smll/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nkootstra/smll/actions/workflows/ci.yml)

A tiny wrapper that compresses noisy command output before it lands in your
coding agent's context window. Drop-in — just prefix the command. Lossless by
default, opt-in lossy filters when you're willing to trade detail for tokens.

- 145 KB release binary
- Single-file Zig, zero runtime dependencies, no telemetry

## Install

```sh
git clone https://github.com/nielskootstra/smll.git
cd smll
zig build release           # zig 0.15.2+
cp zig-out/release/smll /usr/local/bin/
```

## Usage

**Wrapper mode.** Prefix any supported command with `smll`:

```sh
smll git status
smll git log --oneline -20
smll rg TODO
smll tree src
```

Output stays byte-for-byte lossless by default — smll only strips predictable
noise (progress chatter, trailing blank lines). Every token saved is one an
agent doesn't waste.

**Opt-in lossy compaction.** Set `SMLL_COMPACT=1` to enable filters that drop
content the agent doesn't usually need:

```sh
SMLL_COMPACT=1 smll jest
SMLL_COMPACT=1 smll tsc
SMLL_COMPACT=1 smll docker logs myapp
```

## Supported commands

| Category | Commands | Mode |
|---|---|---|
| git | `status`, `diff`, `log`, `show`, `add`, `commit`, `push`, `pull`, `fetch`, `merge`, `rebase`, `checkout`, `branch`, `stash`, `blame` | lossless |
| search / listing | `rg`, `tree` | lossless |
| columnar tables | `docker ps`, `kubectl get`, `gh pr/issue list`, `ps`, `ls -l`, `bun pm ls` | opt-in lossy |
| test runners | `cargo test`, `pytest`, `jest` / `vitest`, `go test -v` | opt-in lossy |
| type checker | `tsc` — compresses each error to `path:L:C TSnnnn` | opt-in lossy |
| logs | `docker logs`, `kubectl logs` — consecutive-identical dedup | opt-in lossy |
| package managers | `npm install` / `npm ci` — keep WARN + summary, drop notice/funding | opt-in lossy |

Anything not in the list passes through untouched.

## Design principles

**R3 — lossless by default.** Without `SMLL_COMPACT=1`, smll never drops
content that changes meaning. The default dispatch is safe to alias over raw
tools.

**Actionable over minimal.** A 6-token "2 errors" wins a bytes benchmark but
loses the use case. smll preserves failure evidence (`--- FAIL:` lines with
their `t.Errorf` context, `npm WARN deprecated: Use X instead`) even when a
smaller competitor collapses to a count.

**Small, no deps, no telemetry.** The binary stays under 150 KB. No network
calls, no analytics, no config files.

## Development

```sh
zig build test              # runs ~260 unit + 90 integration tests
zig build release           # produces zig-out/release/smll
```

Tested on Zig 0.15.2, macOS + Linux.
