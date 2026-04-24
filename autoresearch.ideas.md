# Future improvement ideas

## Pending

- **Detect eza/exa/lsd and adjust field count** — eza uses different field layouts
  (no link count, day-first dates). Currently falls back via ParsedNothing + proactive
  LC_ALL=C forces POSIX ls, but if the *binary itself* is eza (aliased to `ls`), the
  output shape differs enough that parsing fails. Could detect eza by inspecting PATH
  or binary name and applying a different field-count parser. Low priority.

## Done / pruned

- ~~Add rg pattern-mode compression~~ — Done (commit 1eef6bf)
- ~~go test -bench preserve~~ — Done (commit 4fc1621)
- ~~LC_ALL=C for ls spawn~~ — Done (commit 79ff39c)
- ~~git grep -n through pattern filter~~ — Done (commit 9c6d83e)
- ~~rg -N passthrough guard~~ — Done (commit 7bbf67b)
- ~~cargo test --bench results~~ — Done (commit 6c214d4)
- ~~git diff --stat silent drop~~ — Done (commit 096c766)
- ~~git show --stat~~ — Done (commit 8db07c1)
- ~~git log --oneline/--format~~ — Done (commit c7b3596)
- ~~single_threaded=true~~ — Done (commit d5cb450, -15KB)
- ~~f64 float libs in du_compact~~ — Done (commit 35a59b3, -30KB)
- ~~pdqsort → insertion sort~~ — Done (commit d6dcded, -8.5KB)
