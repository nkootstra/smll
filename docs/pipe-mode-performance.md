# smll Pipe-Mode Performance — Design, Non-Goals & Findings — 2026-06

Reference notes for the pipe-mode single-pass pre-classifier (`src/signals.zig`,
wired through `src/pipeline.zig`) and the performance decisions around it.
Captures why it exists, what it deliberately does *not* do, the measured wins,
and one optimization that was measured and abandoned so nobody re-attempts it.

Companion to PRs #64 (pre-classifier), #63 (generic compactor allocation fixes),
and #65 (pipe-throughput regression guard).

## What the pre-classifier does

The pipe dispatcher runs each filter's `matches()` in order until one claims the
input. Six filters — `cargo_test`, `jest`/`vitest`, `tsc`, `go_test`, `pytest`,
and `npm_install` (npm/pnpm/bun/yarn/composer) — each probe several substrings.
On a large *unrelated* stream (a 500 KiB `journalctl` dump, say) those probes
used to run many full `std.mem.find` scans before the input fell through to the
generic compactor.

The pre-classifier collapses all of those probes into **one** pass. It scans the
whole input once, records which of a fixed set of needles are present in a `u32`
bitset (`signals.Signals`), and each expensive filter gates on that bitset via a
`sigGate` before its `matches()` is even called.

## Safety invariant (why routing is provably unchanged)

Every needle in the table is a **necessary substring** of at least one of its
filter's `matches()` paths: if that path returns true, the needle is guaranteed
present. A filter's gate is the OR of its needles' presence bits, so
`matches(input) ⟹ gate(input)` — the gate is a **superset** of `matches`. The
dispatcher only *skips* a filter when its gate is false, and a false gate means
every match-path's necessary needle is absent, so `matches()` could not have
returned true. Selection is therefore identical to the ungated dispatcher.

The invariant is pinned by a property test in `src/main.zig` that runs every
gated filter's `matches()` and `sigGate()` against 15 real captured fixtures and
asserts `matches(data) ⟹ sigGate(data)` for each.

## Non-goals (deliberate constraints)

These are choices the design rules *out*, on purpose:

- **No windowed / prefix-only scan.** The scan covers the **entire** input, not
  a fixed prefix. A test summary that appears only after megabytes of preamble
  must still be detected; a windowed classifier would silently misroute such
  output, violating smll's fact-preserving contract. The whole-input cost is
  accepted as the price of correctness. (`signals.compute` has a `found == all`
  saturating early-exit, but it triggers only when *every* tool family's needle
  is already present — vanishingly rare on real single-tool output — so the
  negative hot path always scans to the end.)
- **Not a classifier, only a pruner.** A gate never changes which filter wins;
  it only lets the dispatcher *skip* work it can prove is wasted. The gate is
  allowed to be a loose superset (false positives are fine — the filter's real
  `matches()` still runs); it must never be a subset (a false negative would
  drop a real match). When in doubt, a needle is omitted, not added.
- **No per-filter heuristics or scoring.** No "this looks 70% like pytest"
  fuzziness. Presence/absence of literal necessary substrings only — that is
  what keeps the superset proof mechanical and auditable.
- **No lazy/partial materialization of the bitset.** `compute()` is all-or-
  nothing per dispatch: it runs at most once, only when the first gated filter
  is reached. Inputs claimed by an earlier ungated filter (the wrapper hot
  path's `git_*` family at dispatch indices 0–8) never pay for it.
- **No widening past 32 needles without a deliberate change.** The tag is `u5`
  and presence packs into a `u32`. A 33rd needle requires widening both (and the
  shift casts) to `u6`/`u64`; a `comptime` assert guards the ceiling rather than
  letting it overflow silently.

## Measured findings

### Runtime (the headline win)

Piping a large unrelated stream through smll, the six substring-probing filters
collapse from many full scans to a single shared scan plus six near-free bitset
checks. On the 559 KiB `generic_journalctl.txt` fixture, end-to-end pipe latency
dropped from **~16 ms to ~7 ms** (median, native arm64, `subprocess.run` +
`monotonic_ns` driver). The remaining ~7 ms is dominated by process startup
(~3.5 ms fixed) plus two unavoidable whole-input passes (the classifier scan and
the generic compactor's own scan).

### Size (the cost)

Verified on the CI-gated **x86_64-linux** release build (cross-compiled),
parent `5a99340` → pre-classifier merge `485eb8d`:

| Build | Size (B) | Δ |
|---|---:|---:|
| Pre (`5a99340`) | 328,440 | — |
| Post (`485eb8d`) | 330,376 | **+1,936** |

Net cost is small because `signals` is **one** shared module in the `build.zig`
registry, imported by all six filters (`extra_deps`) plus the exe/release
top-level — the needle table and scanner are compiled once, not duplicated
seven times. Against the 344,064 B (336 KiB) cap, CI native (≈ cross + ~656 B
padding ≈ 331,032 B) leaves **~13 KB headroom**.

> Note: a macOS arm64 *native* release build is a poor size oracle for changes
> this small — segment/page-alignment quantization absorbs ±2 KB of code into
> existing padding (the same change showed a far smaller native delta). Always
> measure size against the cross-compiled x86_64-linux target the CI gate uses.

## Abandoned experiment: `generic_compact` → `.ReleaseFast`

`generic_compact` is the pipe-mode fallback for every unknown command, so it
runs on the largest unclassified streams and was a candidate to promote from the
size-first `.ReleaseSmall` default to `.ReleaseFast` (trading a few KiB of code
for speed). It was implemented (a per-module `optimize` field in `build.zig`'s
`ModuleEntry`) and **measured**, then reverted:

| Input | ReleaseSmall | ReleaseFast | Δ |
|---|---:|---:|---:|
| journalctl (559 KiB) | 6.87 ms | 6.94 ms | +1.1% (slower) |
| ps_auxww (175 KiB) | 7.55 ms | 8.27 ms | +9.4% (slower) |
| whole corpus | 54.7 MB/s | 53.8 MB/s | −1.6% |
| size (x86_64-linux) | — | — | **+1,768 B** |

**Why it doesn't help:** the compactor's work is whole-buffer scanning and
run-length collapsing — **memory-bandwidth-bound**, not compute-bound.
`.ReleaseFast`'s instruction-level optimizations (inlining, unrolling) don't move
a workload already waiting on memory. All deltas are noise-to-slightly-worse, so
spending ~1.8 KiB of scarce size headroom bought nothing. **Lesson:** measure
before promoting a module's optimize mode; a "hot" filter is only worth
`.ReleaseFast` if it is CPU-bound, and smll's scan-heavy filters generally are
not.

## Other documented non-goals

Decisions intentionally *not* pursued in this performance pass:

- **Wrapper-mode ~6 ms overhead.** Wrapper-mode latency is dominated by process
  spawn plus concurrent stdout/stderr drain, not by smll's own work. Running
  with `DO_NOT_TRACK=1` showed no measurable delta, so the stats I/O is not the
  bottleneck. Not worth chasing below ~5 ms.
- **`×` → `x` in `docker_logs`.** Saves one byte per marker — not worth the
  churn in that filter. The ASCII `x` multiplier is kept only in
  `git_commit` / `git_merge` for cross-filter consistency, not as a general
  rule.

## Regression guard

`scripts/bench-pipe.sh` and the non-blocking `pipe-bench` CI job (PR #65) stream
the whole `tests/fixtures/large/` corpus through the release binary as a single
concatenated input and report MB/s. Concatenation amortizes process startup over
~1.2 MB so the number reflects scan throughput. A generous floor (default
10 MB/s; CI measured ~49 MB/s) surfaces a `::error::` annotation on an egregious
regression — exactly the O(n²) failure mode a future change to the classifier or
compactor could introduce — without blocking merges.

## What did not change

- No filter behavior or output bytes. Routing is identical to the ungated
  dispatcher (proven by the superset invariant, pinned by the property test).
- No new runtime dependencies; still a single static binary.
- The wrapper-mode (`git_*`) hot path pays nothing — it is claimed before any
  gated filter, so the classifier scan never runs for it.
