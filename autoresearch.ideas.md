# Future improvement ideas

## Pending

- **Force LC_ALL=C when spawning ls subprocess** — The ParsedNothing safety net
  catches failures, but proactively setting the locale on the spawned `ls` child
  would let the parser succeed in the first place. Requires modifying process
  spawn in main.zig to inject env vars. Zig 0.16 spawn API needs investigation.

- **Detect eza/exa/lsd and adjust field count** — eza uses different field layouts
  (no link count, day-first dates). Could detect via binary name inspection or
  output heuristics and switch to eza-specific parsing. Currently falls back via
  ParsedNothing — good enough but not optimal.

## Done / pruned

- ~~Add rg pattern-mode compression~~ — Done (commit 1eef6bf, +15% savings)
- ~~go test -bench better~~ — Done (commit 4fc1621, benchmark lines preserved)
