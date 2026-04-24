# Future improvement ideas

## Pending

- **Detect eza/exa/lsd and adjust field count** — eza uses different field layouts
  (no link count, day-first dates). Currently falls back via ParsedNothing + proactive
  LC_ALL=C forces POSIX ls, but if the *binary itself* is eza (aliased to `ls`), the
  output shape differs enough that parsing fails. Could detect eza by inspecting PATH
  or binary name and applying a different field-count parser.

- **git log --oneline / --format edge cases** — Check whether git_log.applyCompact
  handles --oneline and custom --format= output without corrupting it. Parallel to
  the git diff --stat bug we just fixed.

- **git show --stat** — Similar to git diff --stat: `git show --stat` output has
  space-leading stat lines that might also be dropped by git_show's filter.

## Done / pruned

- ~~Add rg pattern-mode compression~~ — Done (commit 1eef6bf, +15% savings)
- ~~go test -bench better~~ — Done (commit 4fc1621, benchmark lines preserved)
- ~~Force LC_ALL=C when spawning ls subprocess~~ — Done (commit 79ff39c)
- ~~Route git grep -n through pattern filter~~ — Done (commit 9c6d83e)
- ~~rg -N passthrough guard~~ — Done (commit 7bbf67b)
- ~~cargo test --bench results silently dropped~~ — Done (commit 6c214d4)
- ~~git diff --stat output silently dropped~~ — Done (commit 096c766)
