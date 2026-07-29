# Security Policy

smll is a thin wrapper that executes shell commands on behalf of a user
or AI coding agent and compacts their output. Because the project sits in
the command-execution path, security issues can affect both the host
machine and any agent consuming smll's output.

## Reporting a vulnerability

Please report security issues privately via GitHub's [private
vulnerability reporting](https://github.com/nkootstra/smll/security/advisories/new)
("Security" tab → "Report a vulnerability"). Avoid opening a public issue
or pull request for anything you believe has security impact.

Include:

- The smll version (`smll --version`) and OS.
- Steps to reproduce, or a minimal proof-of-concept.
- Your assessment of the impact (e.g. command-result tampering, host
  file write, hook-config corruption).

You will receive an acknowledgement within 7 days. Fix timelines depend
on severity; a coordinated-disclosure window of up to 90 days applies
before any public write-up.

## Supported versions

Only the latest minor release on `main` receives security fixes.
Historical tags are left unchanged.

## Scope

In scope:

- The smll binary built from this repository.
- The release pipeline under `.github/workflows/`.
- The hook scripts and config templates embedded in `src/setup.zig`
  that smll writes when running `smll --setup ...`.
- The Homebrew formula bumped by `scripts/bump-formula.py`.

Out of scope:

- Vulnerabilities in third-party agents (Claude Code, OpenCode, Cursor)
  themselves.
- Vulnerabilities in tools whose output smll compacts (`git`, `docker`,
  `rg`, etc.). smll compacts their output but does not change their
  arguments or semantics.

## Threat model

smll's design constraints (a single static binary with no runtime
dependencies, no network calls, and no telemetry) intentionally narrow
the attack surface. The classes of issue we treat as security bugs:

- **Output tampering.** A filter that drops, fabricates, or rewrites an
  actionable fact (an error line, a path, a count, an exit-status
  message) in a way that could mislead the consumer. Format-lossy
  compaction is by design; fact loss is not.
- **Exit-code mishandling.** The wrapper must propagate the child's
  exit code unchanged. A bug that masks a non-zero exit is a security
  issue when the consumer is an agent acting on success/failure.
- **Hook / config corruption.** `smll --setup` patches agent
  configuration files. Failures must leave the original file recoverable
  via the `.bak.smll` backup. Silent partial writes or backup overwrites
  are in scope.
- **Argv / environment leakage.** New records written to `~/.smll/stats.json`
  or `~/.smll/history.jsonl` must not contain command arguments, environment
  values, URLs with embedded tokens, or similar secrets. Raw command output
  must not be persisted. History records written by releases before v1.9.1 are
  not rewritten; `smll --stats --reset` removes them.
- **Tag / formula spoofing.** The release workflow requires annotated,
  signature-verified tags and pins actions to commit SHAs. Bypasses of
  either gate are in scope.

Out of scope (not treated as security issues):

- Compaction reducing readable output below human expectation while
  keeping every actionable fact.
- Behavioural differences between `SMLL_LOSSLESS=1` and the default
  lossy mode where lossy mode loses non-actionable formatting.
- Bugs only reproducible with `SMLL_LOSSLESS=1` set, given that mode is
  documented as a byte-identical passthrough.

## Hardening already in place

- Single static binary, no runtime dependencies, no network calls.
- No telemetry; `~/.smll/stats.json` is local-only, ~80 bytes, and can
  be disabled with `DO_NOT_TRACK=1`.
- `SMLL_LOSSLESS=1` provides a byte-identical escape hatch.
- All GitHub Actions are pinned to commit SHAs.
- Release tags must be annotated and GitHub-signature-verified before
  any artifact is built or published.
- The Homebrew formula bumper validates SHA256 inputs as strict 64-char
  hex before writing.
- `smll --setup` backs up any pre-existing config file as
  `<file>.bak.smll` before modification and aborts when it detects a
  conflicting existing integration.

## Disclosure

After a fix ships, we will publish a GitHub Security Advisory with a
CVE if applicable, credit to the reporter (unless they prefer
anonymity), and a brief note in `CHANGELOG.md`.
