# Future improvement ideas

## Pending

- **Detect eza/exa/lsd and adjust field count** — eza uses different field layouts
  (no link count, day-first dates). Currently falls back via ParsedNothing + proactive
  LC_ALL=C forces POSIX ls, but if the *binary itself* is eza (aliased to `ls`), the
  output shape differs enough that parsing fails. Could detect eza by inspecting PATH
  or binary name and applying a different field-count parser.

- **rg -N (no line numbers) passthrough guard** — `rg -N` output is `path:content`
  (no `:digit:` pattern). matchesPattern correctly rejects it. However, rg.matches()
  (--files dirname RLE) may accept it if content doesn't start with a digit, leading
  to incorrect compression. Fix: in main.zig, only route `rg` to the --files filter
  when `--files`/`-l` flag is present in argv OR output contains no `:` at all.

## Done / pruned

- ~~Add rg pattern-mode compression~~ — Done (commit 1eef6bf, +15% savings)
- ~~go test -bench better~~ — Done (commit 4fc1621, benchmark lines preserved)
- ~~Force LC_ALL=C when spawning ls subprocess~~ — Done (commit 79ff39c)
- ~~Route git grep -n through pattern filter~~ — Done (commit 9c6d83e)
