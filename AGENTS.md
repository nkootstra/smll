# smll — Agent Operating Guide

Agent-only instructions for safe, reviewable changes in this repo.

## Scope
- Applies to the entire repository.
- If a future subdirectory adds its own `AGENTS.md`, treat that as a scoped override for that area.

## Core Workflow (required)
1. Understand the task and constraints first.
2. Make minimal, targeted code changes.
3. Run required verification before finishing.
4. Keep PRs focused and reviewable.

Rationale: this keeps changes correct, debuggable, and easy to merge.

## Hard Safety Rules
- Never use benchmark-specific fixture/path special-casing.
- Preserve actionable signal in compact outputs (errors, failures, locations, counts).
- Do not add fake/synthetic output disconnected from command semantics.
- Do not modify CI/workflow semantics unless explicitly requested.

Rationale: avoid overfitting and behavior regressions.

## Branch + Merge Discipline
- Do all implementation work on a branch, never directly on `main`.
- Before opening/updating a PR, run full tests locally.
- Merge only after CI is green.
- Prefer squash merge for feature branches.

Rationale: prevents broken main and keeps history clean.

## Required Verification
Run before completion (and before PR updates):

```bash
zig build test --summary all
```

If release/size behavior is affected, also run:

```bash
zig build release
```

The size gate enforces a **360,448 byte (352 KiB)** cap on the Linux x86_64
release binary (`.github/workflows/ci.yml`). CI measures a **native** x86_64
build. Cross-compiling from another host (`zig build release
-Dtarget=x86_64-linux`) produces the right target but runs ~600–700 bytes
**smaller** than CI's native build — so a local cross figure that just squeaks
under the cap can still fail the gate. Treat the local cross size as a lower
bound (add ~700 bytes of margin), or rely on CI as the source of truth.

Rationale: local green should match CI expectations.

## Test and Bug-Fix Policy
- For bug fixes, write a failing test first, then fix.
- When useful, try parallel fix candidates and validate them against the same failing test.
- Mock only at system boundaries (external APIs, DB, clock, filesystem).
- Do not mock internal collaborators.

Rationale: test behavior, not implementation details.

## Editing Policy
- Keep changes small and localized.
- Prefer improving existing modules over adding new abstraction layers unless needed.
- Do not rename/move files unless required by the task.
- Keep comments high-signal; avoid narrating obvious code.

Rationale: reduces review risk and accidental breakage.

## PR Content Rules
- Include only task-relevant source changes.
- Exclude transient/autoresearch tracking artifacts unless explicitly requested.
- In PR description: include intent, key changes, verification run, and risk notes.

Rationale: fast reviewer comprehension and lower merge risk.

## Repo Notes (only what is non-inferrable)
- Primary verification entrypoint is `zig build test --summary all`.
- CI runs tests on macOS + Ubuntu and then a size gate.

Rationale: mirrors what actually gates merges.
