#!/usr/bin/env bash
# Generate deterministic large fixtures for v0.3 pipe-mode benchmarks.
# Captures git status/diff/log/show outputs from a synthetic repo with
# enough breadth and history to produce 500-5000-word outputs each.
#
# Outputs:
#   tests/fixtures/large/git_status.txt
#   tests/fixtures/large/git_diff.txt
#   tests/fixtures/large/git_log.txt
#   tests/fixtures/large/git_show.txt
#
# Re-run is idempotent: same inputs produce the same files. Commit the
# resulting fixtures so benchmarks are reproducible across machines.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/tests/fixtures/large"
mkdir -p "$OUT_DIR"

SCRATCH=$(mktemp -d -t smll-large-fixtures)
trap 'rm -rf "$SCRATCH"' EXIT
cd "$SCRATCH"

git init -q
git config user.email alice@example.com
git config user.name "Alice Anderson"
git config commit.gpgsign false
# Pin author/committer dates so git_log output is byte-deterministic.
export GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"

# Build a base set of source-like files so diffs feel real (not byte spam).
make_base_file() {
    local path="$1" prefix="$2"
    {
        echo "// ${prefix} module — generated for benchmark fixture"
        echo "// Stable content; do not edit by hand."
        echo
        for i in $(seq 1 40); do
            printf 'fn %s_helper_%02d(input: i32) -> i32 {\n' "$prefix" "$i"
            printf '    let scaled = input * %d + %d;\n' "$((i + 1))" "$i"
            printf '    let shifted = scaled.wrapping_shl(%d);\n' "$((i % 8))"
            printf '    shifted ^ 0x%x\n' "$((i * 17))"
            printf '}\n\n'
        done
    } > "$path"
}

mkdir -p src
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    make_base_file "src/mod_${n}.rs" "mod_${n}"
done
git add src
git commit -q -m "feat(seed): bootstrap source tree

Twelve generated modules used as the baseline for benchmark fixtures.
Each module exposes 40 helper functions with deterministic arithmetic.
Fixture stability requires this commit be the first in the repo."

# Make 30 commits, each touching one or two files, with multi-line bodies.
adjectives=(amber azure brisk crimson dusky ember frosty golden hazy indigo
            jade keen lush mauve nimble obsidian pearl quartz russet silver
            teal umber vivid wisteria xenon yarrow zenith arcane bramble citrine)
nouns=(beacon cipher delta flux glade hollow inlet jetty knoll lattice meridian
       nimbus orchard plume quasar ridge sigil thorn umbra vista warden yonder
       zephyr arbor brink crest drift eddy fern grove)

for i in $(seq 1 30); do
    adj="${adjectives[$(( (i - 1) % ${#adjectives[@]} ))]}"
    noun="${nouns[$(( (i - 1) % ${#nouns[@]} ))]}"
    mod_idx=$(printf '%02d' $(( ((i - 1) % 12) + 1 )))
    target="src/mod_${mod_idx}.rs"

    # Append a deterministic block to the file.
    {
        printf '\n// commit-%02d: %s %s additions\n' "$i" "$adj" "$noun"
        for k in $(seq 1 5); do
            printf 'fn %s_%s_step_%d(seed: u64) -> u64 {\n' "$adj" "$noun" "$k"
            printf '    let mixed = seed.wrapping_mul(0x%x);\n' "$((i * 31 + k * 13))"
            printf '    mixed ^ 0x%x\n' "$((i * 257 + k))"
            printf '}\n\n'
        done
    } >> "$target"

    # Every fifth commit also touches a second module to make diffs richer.
    if [ $((i % 5)) -eq 0 ]; then
        second_idx=$(printf '%02d' $(( ((i - 1) % 12) + 2 > 12 ? 1 : ((i - 1) % 12) + 2 )))
        second="src/mod_${second_idx}.rs"
        {
            printf '\n// commit-%02d cross-ref to %s %s\n' "$i" "$adj" "$noun"
            printf 'const COMMIT_%02d_TAG: &str = "%s/%s";\n' "$i" "$adj" "$noun"
        } >> "$second"
        git add "$second"
    fi

    git add "$target"
    git commit -q -m "feat(${adj}): introduce ${adj} ${noun} step pipeline

Adds five stepwise helpers to mod_${mod_idx} that compose the ${adj}
${noun} transform. The pipeline mixes a wrapping multiply with an XOR
mask seeded from the commit ordinal, mirroring the shape of the real
transform we plan to land in production.

Refs: BENCH-${i}"
done

# Land one large feature commit that we can capture via 'git show'.
LARGE_COMMIT_FILE="src/mod_06.rs"
{
    printf '\n// finale-commit: stratified harness expansion\n'
    for k in $(seq 1 30); do
        printf 'pub fn stratified_harness_%02d(input: &[u64]) -> Vec<u64> {\n' "$k"
        printf '    let multiplier = 0x%x_u64;\n' "$((k * 1117))"
        printf '    let bias = 0x%x_u64;\n' "$((k * 31 + 7))"
        printf '    input.iter()\n'
        printf '        .map(|x| x.wrapping_mul(multiplier).wrapping_add(bias))\n'
        printf '        .map(|x| x ^ x.rotate_left(%d))\n' "$((k % 19 + 1))"
        printf '        .collect()\n'
        printf '}\n\n'
    done
} >> "$LARGE_COMMIT_FILE"
git add "$LARGE_COMMIT_FILE"
git commit -q -m "feat(harness): land stratified harness expansion

This commit introduces thirty stratified-harness helpers in mod_06.
Each helper applies a deterministic multiplier-and-bias transform
followed by a self-XOR rotation. The combination is intentionally
verbose so the resulting 'git show' output exercises a long unified
diff with realistic +/- density.

The harness is reused by the production pipeline on hot paths where
SIMD intrinsics are unavailable. We keep the loop body simple to let
the autovectorizer pick it up on platforms that support it.

Refs: BENCH-FINAL"

# Create dirty working state so 'git status' and 'git diff' are substantive.
# Modify every committed module to produce many "modified:" entries.
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    f="src/mod_${n}.rs"
    {
        printf '\n// uncommitted scratch: tuning notes for mod_%s\n' "$n"
        for k in 1 2 3 4 5; do
            printf 'fn dirty_tuning_%s_%d(value: i64) -> i64 {\n' "$n" "$k"
            printf '    value.wrapping_add(%d).rotate_right(%d)\n' "$((k * 17))" "$((k % 8))"
            printf '}\n\n'
        done
    } >> "$f"
done

# Build a large set of additional source files to stage, creating a
# "many staged new files" surface that compresses well (new file: path → A path).
mkdir -p src/components src/services src/utils
for n in $(seq 1 50); do
    f="src/components/comp_$(printf '%02d' "$n").rs"
    {
        printf '// component %02d — generated for large status fixture\n' "$n"
        for k in $(seq 1 8); do
            printf 'pub fn comp_%02d_render_%d(input: u32) -> u32 { input ^ 0x%x }\n' \
                "$n" "$k" "$((n * 13 + k * 7))"
        done
    } > "$f"
done
for n in $(seq 1 40); do
    f="src/services/svc_$(printf '%02d' "$n").rs"
    {
        printf '// service %02d — generated for large status fixture\n' "$n"
        for k in $(seq 1 6); do
            printf 'pub fn svc_%02d_handle_%d(req: u64) -> u64 { req.wrapping_add(0x%x) }\n' \
                "$n" "$k" "$((n * 31 + k * 11))"
        done
    } > "$f"
done
for n in $(seq 1 30); do
    f="src/utils/util_$(printf '%02d' "$n").rs"
    {
        printf '// util %02d — generated for large status fixture\n' "$n"
        for k in $(seq 1 5); do
            printf 'pub fn util_%02d_transform_%d(x: i64) -> i64 { x.wrapping_mul(%d) }\n' \
                "$n" "$k" "$((n * 17 + k))"
        done
    } > "$f"
done
git add src/components src/services src/utils

# Add a moderate untracked surface using default per-directory folding.
# With default git status (no --untracked-files=all), git shows the
# directory entry rather than each individual file — this is the realistic
# agent-facing scenario and compresses well vs the per-file listing.
mkdir -p docs/notes scripts/wip configs/staging
for n in $(seq 1 20); do
    {
        printf '# Untracked draft note %d\n\n' "$n"
        printf 'These notes describe pending work on the benchmark harness.\n'
    } > "docs/notes/draft-$(printf '%03d' "$n").md"
done
for n in $(seq 1 15); do
    printf '#!/usr/bin/env bash\n# WIP harness script %03d\nexit 0\n' "$n" \
        > "scripts/wip/harness_$(printf '%03d' "$n").sh"
done
for n in $(seq 1 10); do
    printf 'environment = staging\nslot = %03d\nseed = %d\n' "$n" "$((n * 17))" \
        > "configs/staging/slot_$(printf '%03d' "$n").cfg"
done

# Capture the four pipe-mode fixtures using default untracked mode.
# Default git status collapses untracked directories to a single entry
# each — realistic for agent use and avoids inflating byte-count with
# per-file TAB-prefixed entries that are already minimally encoded.
git status > "$OUT_DIR/git_status.txt"
git diff                          > "$OUT_DIR/git_diff.txt"
git log                           > "$OUT_DIR/git_log.txt"
git show                          > "$OUT_DIR/git_show.txt"

echo "Generated large fixtures in $OUT_DIR:"
for f in git_status git_diff git_log git_show; do
    bytes=$(wc -c < "$OUT_DIR/${f}.txt" | tr -d ' ')
    words=$(wc -w < "$OUT_DIR/${f}.txt" | tr -d ' ')
    printf '  %-12s  %8s bytes  %6s words\n' "${f}.txt" "$bytes" "$words"
done
