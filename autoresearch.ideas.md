# Future improvement ideas

## From RTK issue analysis (2026-04-23)

- **Force LC_ALL=C when spawning ls subprocess** — The ParsedNothing safety net
  catches the failure, but proactively forcing the locale on the spawned `ls`
  process would let the parser work correctly in the first place. Requires
  modifying the process spawn in main.zig to set env vars on the child process.
  RTK #1475 fix includes this.

- **Detect eza/exa/lsd and adjust field count** — eza uses different field layouts
  (e.g. no link count, day-first dates). Could detect via binary name inspection
  or output heuristics and switch to eza-specific parsing. RTK #1454 just falls
  back; we could do better by actually parsing eza output.

- **Add `rg` pattern-mode compression** — Currently only `rg --files` is compressed.
  Could add grouped-by-file compression for `rg <pattern>` output to reduce
  repetitive path prefixes. RTK #1452/#1456 show the pitfalls of flag handling.

- **Support `go test -bench` better** — Currently benchmark lines are preserved
  but not further compressed (e.g. could strip goos/goarch metadata lines,
  compress repeated benchmark prefixes). Low priority since benchmarks are
  usually small.
