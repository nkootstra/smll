# Autoresearch: RTK feature-parity under ZTK size cap

## Objective
Increase `smll` feature-parity with `rtk` across a representative command suite, while keeping the `smll` release binary **no larger than `ztk`**.

Parity here means: for each workload case, `smll` should produce output compression behavior close to `rtk` (without dropping critical failure/action signals), and remain fast.

## Metrics
- **Primary**: `parity_points` (higher is better)
  - Sum of per-case parity scores in `[0, 1]`, where parity is based on compression-distance to `rtk`.
  - Hard size gate: if `smll_bytes > ztk_bytes`, primary is forced to `0`.
- **Secondary**:
  - `size_cap_ok` (1/0)
  - `smll_bytes`, `ztk_bytes`, `rtk_bytes`
  - `cases`
  - `smll_avg_reduction_pct`, `rtk_avg_reduction_pct`
  - `smll_avg_latency_ms`, `rtk_avg_latency_ms`

## How to Run
`./autoresearch.sh`

The script prints structured `METRIC ...` lines.

## Files in Scope
- `src/main.zig` — dispatch/routing and mode guards
- `src/filters/*.zig` — command-specific compaction behavior
- `tests/fixtures/*.txt` — only when adding/adjusting realistic fixture coverage
- `benchmarks/results-head-to-head-fresh.md` — report updates when needed

## Off Limits
- No cheating by special-casing benchmark fixture file names/paths
- No fake outputs disconnected from command semantics
- No dependency additions that bloat binary beyond cap without strong reason

## Constraints
- Keep `smll` binary <= `ztk` binary size
- Preserve actionable debugging signal (errors/failures/locations)
- Keep behavior realistic for real command output, not overfit-only transforms
- No pushes

## What's Been Tried
- Recent wins before this session:
  - compact npm warnings/summaries
  - docker/kubectl logs timestamp removal
  - cargo test failure scaffolding compaction
  - docker logs stream-level ANSI fastpath
- Known dead ends:
  - overly aggressive pytest compaction regressed primary score
  - broad micro-optimizations without per-case impact
