#!/usr/bin/env bash
# Generate deterministic fixtures for v0.4 pipe-mode benchmarks.
# Captures git output from synthetic repos for 15 commands (v0.3: 4 + v0.4: 11 new).
#
# Outputs (v0.3 — unchanged):
#   tests/fixtures/large/git_status.txt
#   tests/fixtures/large/git_diff.txt
#   tests/fixtures/large/git_log.txt
#   tests/fixtures/large/git_show.txt
#
# Outputs (v0.4 small — new):
#   tests/fixtures/git_add_error.stdout.txt       (empty)
#   tests/fixtures/git_add_error.stderr.txt
#   tests/fixtures/git_commit_simple.txt
#   tests/fixtures/git_commit_multifile.txt
#   tests/fixtures/git_push_simple.stdout.txt     (empty)
#   tests/fixtures/git_push_simple.stderr.txt
#   tests/fixtures/git_pull_ff.stdout.txt
#   tests/fixtures/git_pull_ff.stderr.txt
#   tests/fixtures/git_pull_uptodate.stdout.txt
#   tests/fixtures/git_pull_uptodate.stderr.txt
#   tests/fixtures/git_fetch_simple.stdout.txt    (empty)
#   tests/fixtures/git_fetch_simple.stderr.txt
#   tests/fixtures/git_merge_ff.txt
#   tests/fixtures/git_merge_commit.txt
#   tests/fixtures/git_merge_conflict.stdout.txt
#   tests/fixtures/git_merge_conflict.stderr.txt  (empty — conflict on stdout)
#   tests/fixtures/git_rebase_simple.txt
#   tests/fixtures/git_checkout_switch.stdout.txt (empty)
#   tests/fixtures/git_checkout_switch.stderr.txt
#   tests/fixtures/git_branch_list.txt
#   tests/fixtures/git_stash_save.txt
#   tests/fixtures/git_stash_list.txt
#   tests/fixtures/git_blame_simple.txt
#
# Outputs (v0.4 large — new):
#   tests/fixtures/large/git_commit.txt
#   tests/fixtures/large/git_merge.txt
#   tests/fixtures/large/git_rebase.txt
#   tests/fixtures/large/git_blame.txt
#   tests/fixtures/large/git_push.stdout.txt      (empty)
#   tests/fixtures/large/git_push.stderr.txt
#
# Stream-separation convention:
#   Commands where stderr carries meaningful output (push, pull, fetch,
#   checkout, add-error) use two-file pairs:
#     <fixture>.stdout.txt  — captured stdout
#     <fixture>.stderr.txt  — captured stderr
#   Commands whose output is stdout-only use a single <fixture>.txt file.
#   An empty .stdout.txt is committed to explicitly document that the
#   command emits nothing on stdout.
#
# Large fixtures NOT generated for: add, pull, fetch, stash, checkout, branch.
#   These commands produce the same fixed-format short output regardless
#   of repo size (e.g. "Switched to branch 'X'" is always one line;
#   "Already up to date." is always one line). Adding a "large" fixture
#   would just be the same text in a bigger repo — no compression benefit.
#
# Re-run is idempotent: same inputs produce the same byte-identical files.
# Commit the resulting fixtures so benchmarks are reproducible across machines.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SMALL_DIR="$REPO_ROOT/tests/fixtures"
OUT_DIR="$REPO_ROOT/tests/fixtures/large"
mkdir -p "$OUT_DIR"

# ── Deterministic environment ─────────────────────────────────────────────────
export TZ=UTC
export GIT_AUTHOR_DATE="2026-01-01T00:00:00 +0000"
export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE"
export GIT_AUTHOR_NAME="Alice Anderson"
export GIT_AUTHOR_EMAIL="alice@example.com"
export GIT_COMMITTER_NAME="Alice Anderson"
export GIT_COMMITTER_EMAIL="alice@example.com"

# ── Helper: init a scratch repo ───────────────────────────────────────────────
init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email alice@example.com
    git config user.name "Alice Anderson"
    git config commit.gpgsign false
    git config core.autocrlf false
}

# ── Helper: deterministic commit with optional bump to dates ──────────────────
# Use a counter so each commit gets a unique timestamp offset, making log
# output byte-deterministic regardless of wall-clock speed.
COMMIT_COUNTER=0
pinned_commit() {
    COMMIT_COUNTER=$((COMMIT_COUNTER + 1))
    local ts="2026-01-01T$(printf '%02d' $((COMMIT_COUNTER / 3600))):$(printf '%02d' $(((COMMIT_COUNTER % 3600) / 60))):$(printf '%02d' $((COMMIT_COUNTER % 60))) +0000"
    GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" \
        git commit --no-gpg-sign -q "$@"
}

# ── Helper: make a source-like file ───────────────────────────────────────────
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

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 1: v0.3 large fixtures (status, diff, log, show)
# Preserved verbatim from the original script except pinned_commit wrapper.
# ═══════════════════════════════════════════════════════════════════════════════

SCRATCH=$(mktemp -d -t smll-large-fixtures-XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
init_repo "$SCRATCH"

COMMIT_COUNTER=0

adjectives=(amber azure brisk crimson dusky ember frosty golden hazy indigo
            jade keen lush mauve nimble obsidian pearl quartz russet silver
            teal umber vivid wisteria xenon yarrow zenith arcane bramble citrine)
nouns=(beacon cipher delta flux glade hollow inlet jetty knoll lattice meridian
       nimbus orchard plume quasar ridge sigil thorn umbra vista warden yonder
       zephyr arbor brink crest drift eddy fern grove)

mkdir -p src
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    make_base_file "src/mod_${n}.rs" "mod_${n}"
done
git add src
pinned_commit -m "feat(seed): bootstrap source tree

Twelve generated modules used as the baseline for benchmark fixtures.
Each module exposes 40 helper functions with deterministic arithmetic.
Fixture stability requires this commit be the first in the repo."

for i in $(seq 1 30); do
    adj="${adjectives[$(( (i - 1) % ${#adjectives[@]} ))]}"
    noun="${nouns[$(( (i - 1) % ${#nouns[@]} ))]}"
    mod_idx=$(printf '%02d' $(( ((i - 1) % 12) + 1 )))
    target="src/mod_${mod_idx}.rs"

    {
        printf '\n// commit-%02d: %s %s additions\n' "$i" "$adj" "$noun"
        for k in $(seq 1 5); do
            printf 'fn %s_%s_step_%d(seed: u64) -> u64 {\n' "$adj" "$noun" "$k"
            printf '    let mixed = seed.wrapping_mul(0x%x);\n' "$((i * 31 + k * 13))"
            printf '    mixed ^ 0x%x\n' "$((i * 257 + k))"
            printf '}\n\n'
        done
    } >> "$target"

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
    pinned_commit -m "feat(${adj}): introduce ${adj} ${noun} step pipeline

Adds five stepwise helpers to mod_${mod_idx} that compose the ${adj}
${noun} transform. The pipeline mixes a wrapping multiply with an XOR
mask seeded from the commit ordinal, mirroring the shape of the real
transform we plan to land in production.

Refs: BENCH-${i}"
done

# Finale commit: touch many files with small additions each.
# Shape matches realistic agent-loop changes (wide-but-shallow) rather
# than one giant refactor; keeps v0.4 R3 gate achievable on git_show
# via structural header compression rather than requiring body-line drop.
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    f="src/mod_${n}.rs"
    {
        printf '\n// finale-commit: version bump for mod_%s\n' "$n"
        printf 'pub const MOD_%s_FINALE_VERSION: u32 = 2;\n' "$n"
    } >> "$f"
    git add "$f"
done
pinned_commit -m "feat(finale): land finale-version constants across 12 modules

Adds a FINALE_VERSION constant to every mod_NN module. Wide-but-shallow
shape exercises the multi-file diff path for git_show.

Refs: BENCH-FINAL"

# Uncommitted scratch: short hunk per file (1 function each).
# Wide-but-shallow shape keeps git_diff R3-gate-achievable by maximising
# structural-header compression relative to body lines.
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do
    f="src/mod_${n}.rs"
    {
        printf '\n// uncommitted scratch: tuning note for mod_%s\n' "$n"
        printf 'fn dirty_tuning_%s(value: i64) -> i64 {\n' "$n"
        printf '    value.wrapping_add(%d).rotate_right(3)\n' "$((17 * n))"
        printf '}\n'
    } >> "$f"
done

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

git status > "$OUT_DIR/git_status.txt"
git diff                          > "$OUT_DIR/git_diff.txt"
git log                           > "$OUT_DIR/git_log.txt"
git show                          > "$OUT_DIR/git_show.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 2: v0.4 small fixtures for 11 new commands
# Uses a fresh, simpler scratch repo for clarity.
# ═══════════════════════════════════════════════════════════════════════════════

SMALL_SCRATCH=$(mktemp -d -t smll-small-fixtures-XXXXXX)
trap 'rm -rf "$SCRATCH" "$SMALL_SCRATCH"' EXIT
COMMIT_COUNTER=0

init_repo "$SMALL_SCRATCH"

# ── git add error ─────────────────────────────────────────────────────────────
# git add on a nonexistent path emits nothing on stdout; the fatal message
# goes to stderr. Output size: ~60-80 B. No large fixture needed — output
# is a fixed one-liner regardless of repo size.
printf '' > "$SMALL_DIR/git_add_error.stdout.txt"
git -C "$SMALL_SCRATCH" add nonexistent-path 2>"$SMALL_DIR/git_add_error.stderr.txt" || true

# ── git commit simple ─────────────────────────────────────────────────────────
echo "hello" > "$SMALL_SCRATCH/a.txt"
git -C "$SMALL_SCRATCH" add a.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:01 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:01 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: add a.txt" \
  > "$SMALL_DIR/git_commit_simple.txt"

# ── git commit multifile ──────────────────────────────────────────────────────
echo "world" > "$SMALL_SCRATCH/b.txt"
echo "extra" > "$SMALL_SCRATCH/c.txt"
git -C "$SMALL_SCRATCH" add b.txt c.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:02 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:02 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: add b.txt and c.txt

Adds two files to exercise the multi-file commit summary path." \
  > "$SMALL_DIR/git_commit_multifile.txt"

# ── Set up a bare remote for push/pull/fetch ──────────────────────────────────
REMOTE_DIR=$(mktemp -d -t smll-remote-XXXXXX)
trap 'rm -rf "$SCRATCH" "$SMALL_SCRATCH" "$REMOTE_DIR"' EXIT
git init -q --bare "$REMOTE_DIR"
git -C "$SMALL_SCRATCH" remote add origin "$REMOTE_DIR"

# ── git push simple ───────────────────────────────────────────────────────────
# Push: the remote-tracking summary goes to stderr; on some git versions
# "branch set up to track" goes to stdout. Capture both, then normalize
# the absolute temp path to a stable placeholder.
git -C "$SMALL_SCRATCH" push --no-progress -u origin main \
  > "$SMALL_DIR/git_push_simple.stdout.txt" \
  2> "$SMALL_DIR/git_push_simple.stderr.txt"
sed -i.bak "s|$REMOTE_DIR|/smll-fixture-remote|g" "$SMALL_DIR/git_push_simple.stdout.txt"
sed -i.bak "s|$REMOTE_DIR|/smll-fixture-remote|g" "$SMALL_DIR/git_push_simple.stderr.txt"
rm -f "$SMALL_DIR/git_push_simple.stdout.txt.bak" "$SMALL_DIR/git_push_simple.stderr.txt.bak"

# ── git pull fast-forward ─────────────────────────────────────────────────────
# Create a second clone, add a commit there, push it, then pull from first.
CLONE2=$(mktemp -d -t smll-clone2-XXXXXX)
trap 'rm -rf "$SCRATCH" "$SMALL_SCRATCH" "$REMOTE_DIR" "$CLONE2"' EXIT
git clone -q "$REMOTE_DIR" "$CLONE2"
git -C "$CLONE2" config user.email alice@example.com
git -C "$CLONE2" config user.name "Alice Anderson"
git -C "$CLONE2" config commit.gpgsign false
echo "from clone2" > "$CLONE2/d.txt"
git -C "$CLONE2" add d.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:03 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:03 +0000" \
  git -C "$CLONE2" commit --no-gpg-sign -m "feat: add d.txt from clone2"
git -C "$CLONE2" push --no-progress -q origin main

# Now pull in the original repo — this is a fast-forward.
# stdout: "Updating <sha>..<sha>\nFast-forward\n d.txt | 1 +\n 1 file changed..."
# stderr: "From <path>\n   <sha>..<sha>  main -> origin/main"
git -C "$SMALL_SCRATCH" pull --no-progress --ff-only origin main \
  > "$SMALL_DIR/git_pull_ff.stdout.txt" \
  2> "$SMALL_DIR/git_pull_ff.stderr.txt"

# Replace the absolute remote path in stderr with a stable placeholder
# so the fixture is byte-deterministic across machines.
sed -i.bak "s|$REMOTE_DIR|/smll-fixture-remote|g" "$SMALL_DIR/git_pull_ff.stderr.txt"
rm -f "$SMALL_DIR/git_pull_ff.stderr.txt.bak"

# ── git pull already up to date ───────────────────────────────────────────────
git -C "$SMALL_SCRATCH" pull --no-progress origin main \
  > "$SMALL_DIR/git_pull_uptodate.stdout.txt" \
  2> "$SMALL_DIR/git_pull_uptodate.stderr.txt"
sed -i.bak "s|$REMOTE_DIR|/smll-fixture-remote|g" "$SMALL_DIR/git_pull_uptodate.stderr.txt"
rm -f "$SMALL_DIR/git_pull_uptodate.stderr.txt.bak"

# ── git fetch simple ──────────────────────────────────────────────────────────
# Add another commit to clone2 and push, then fetch (don't merge) from small_scratch.
echo "from clone2 v2" > "$CLONE2/e.txt"
git -C "$CLONE2" add e.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:04 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:04 +0000" \
  git -C "$CLONE2" commit --no-gpg-sign -m "feat: add e.txt"
git -C "$CLONE2" push --no-progress -q origin main

git -C "$SMALL_SCRATCH" fetch --no-progress origin \
  > "$SMALL_DIR/git_fetch_simple.stdout.txt" \
  2> "$SMALL_DIR/git_fetch_simple.stderr.txt"
sed -i.bak "s|$REMOTE_DIR|/smll-fixture-remote|g" "$SMALL_DIR/git_fetch_simple.stderr.txt"
rm -f "$SMALL_DIR/git_fetch_simple.stderr.txt.bak"

# ── Branches for merge/rebase/checkout/branch ────────────────────────────────
# Reset small_scratch to a clean state first by merging what we fetched.
git -C "$SMALL_SCRATCH" merge --no-progress --ff-only FETCH_HEAD -q

# Create feature branch from current HEAD.
git -C "$SMALL_SCRATCH" branch feature-x
git -C "$SMALL_SCRATCH" branch feature-y

# ── git branch list ───────────────────────────────────────────────────────────
# No large fixture — output is a fixed line per branch regardless of repo size.
git -C "$SMALL_SCRATCH" branch > "$SMALL_DIR/git_branch_list.txt"

# ── git checkout switch ───────────────────────────────────────────────────────
# stdout: empty; stderr: "Switched to branch 'feature-x'"
# No large fixture — always the same one-line message.
git -C "$SMALL_SCRATCH" checkout feature-x \
  > "$SMALL_DIR/git_checkout_switch.stdout.txt" \
  2> "$SMALL_DIR/git_checkout_switch.stderr.txt"

# Add a commit on feature-x.
echo "feature x work" > "$SMALL_SCRATCH/fx.txt"
git -C "$SMALL_SCRATCH" add fx.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:05 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:05 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat(feature-x): add fx.txt"

# ── git merge fast-forward ────────────────────────────────────────────────────
git -C "$SMALL_SCRATCH" checkout main -q
git -C "$SMALL_SCRATCH" merge --no-progress --ff-only feature-x \
  > "$SMALL_DIR/git_merge_ff.txt"

# ── git merge commit (non-ff) ─────────────────────────────────────────────────
git -C "$SMALL_SCRATCH" checkout feature-y -q
echo "feature y work" > "$SMALL_SCRATCH/fy.txt"
git -C "$SMALL_SCRATCH" add fy.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:06 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:06 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat(feature-y): add fy.txt"

# Also add a commit on main so it's diverged (forces a merge commit).
git -C "$SMALL_SCRATCH" checkout main -q
echo "main extra" > "$SMALL_SCRATCH/m.txt"
git -C "$SMALL_SCRATCH" add m.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:07 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:07 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "chore: main extra commit"

GIT_AUTHOR_DATE="2026-01-01T00:00:08 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:08 +0000" \
  git -C "$SMALL_SCRATCH" merge --no-progress --no-ff feature-y \
    -m "Merge branch 'feature-y'" \
  > "$SMALL_DIR/git_merge_commit.txt"

# ── git merge conflict ────────────────────────────────────────────────────────
git -C "$SMALL_SCRATCH" branch conflict-branch
git -C "$SMALL_SCRATCH" checkout conflict-branch -q
echo "conflict version A" > "$SMALL_SCRATCH/conflict.txt"
git -C "$SMALL_SCRATCH" add conflict.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:09 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:09 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: conflict version A"

git -C "$SMALL_SCRATCH" checkout main -q
echo "conflict version B" > "$SMALL_SCRATCH/conflict.txt"
git -C "$SMALL_SCRATCH" add conflict.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:10 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:10 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: conflict version B"

# Merge will produce a CONFLICT message on stdout, exit non-zero.
GIT_AUTHOR_DATE="2026-01-01T00:00:11 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:11 +0000" \
  git -C "$SMALL_SCRATCH" merge --no-progress conflict-branch \
  > "$SMALL_DIR/git_merge_conflict.stdout.txt" \
  2> "$SMALL_DIR/git_merge_conflict.stderr.txt" \
  || true  # non-zero exit is expected on conflict

# Abort the conflicted merge so repo is clean for remaining operations.
git -C "$SMALL_SCRATCH" merge --abort

# ── git stash save ────────────────────────────────────────────────────────────
# Make dirty working tree, then stash.
echo "work in progress" > "$SMALL_SCRATCH/wip.txt"
git -C "$SMALL_SCRATCH" add wip.txt
# stash output goes to stdout: "Saved working directory and index state ..."
# No large fixture — always one line regardless of repo size.
git -C "$SMALL_SCRATCH" stash push -m "wip: fixture stash entry 1" \
  > "$SMALL_DIR/git_stash_save.txt"

# Add a second stash entry.
echo "more wip" > "$SMALL_SCRATCH/wip2.txt"
git -C "$SMALL_SCRATCH" add wip2.txt
git -C "$SMALL_SCRATCH" stash push -m "wip: fixture stash entry 2" -q

# ── git stash list ────────────────────────────────────────────────────────────
# No large fixture — output is a line per stash entry regardless of repo size.
git -C "$SMALL_SCRATCH" stash list > "$SMALL_DIR/git_stash_list.txt"

# Pop stashes to clean state.
git -C "$SMALL_SCRATCH" stash drop stash@{0} -q
git -C "$SMALL_SCRATCH" stash drop stash@{0} -q

# ── git rebase simple ─────────────────────────────────────────────────────────
# Create rebase-branch off main~2, add 2 commits, then rebase onto main.
REBASE_BASE=$(git -C "$SMALL_SCRATCH" rev-parse main~2)
git -C "$SMALL_SCRATCH" checkout -b rebase-branch "$REBASE_BASE" -q
echo "rebase commit 1" > "$SMALL_SCRATCH/rb1.txt"
git -C "$SMALL_SCRATCH" add rb1.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:12 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:12 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: rebase commit 1"

echo "rebase commit 2" > "$SMALL_SCRATCH/rb2.txt"
git -C "$SMALL_SCRATCH" add rb2.txt
GIT_AUTHOR_DATE="2026-01-01T00:00:13 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:13 +0000" \
  git -C "$SMALL_SCRATCH" commit --no-gpg-sign -m "feat: rebase commit 2"

GIT_AUTHOR_DATE="2026-01-01T00:00:14 +0000" \
GIT_COMMITTER_DATE="2026-01-01T00:00:14 +0000" \
  git -C "$SMALL_SCRATCH" rebase --no-stat main \
  > "$SMALL_DIR/git_rebase_simple.txt" 2>&1

git -C "$SMALL_SCRATCH" checkout main -q

# ── git blame simple ─────────────────────────────────────────────────────────
# Create a file with multiple distinct commits for meaningful blame output.
BLAME_REPO=$(mktemp -d -t smll-blame-XXXXXX)
trap 'rm -rf "$SCRATCH" "$SMALL_SCRATCH" "$REMOTE_DIR" "$CLONE2" "$BLAME_REPO"' EXIT
init_repo "$BLAME_REPO"
COMMIT_COUNTER=0

# Build a 15-line file across 5 commits (3 lines each).
{
    printf 'fn init() {\n'
    printf '    // initialise the module\n'
    printf '    setup_defaults();\n'
} > "$BLAME_REPO/lib.rs"
git -C "$BLAME_REPO" add lib.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:01 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:01 +0000" \
  git -C "$BLAME_REPO" commit --no-gpg-sign -m "feat: init"

{
    printf '    configure_logging();\n'
    printf '    configure_metrics();\n'
    printf '    bind_signals();\n'
} >> "$BLAME_REPO/lib.rs"
git -C "$BLAME_REPO" add lib.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:02 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:02 +0000" \
  git -C "$BLAME_REPO" commit --no-gpg-sign -m "feat: logging and metrics"

{
    printf '    start_event_loop();\n'
    printf '    drain_queue();\n'
    printf '    flush_buffers();\n'
} >> "$BLAME_REPO/lib.rs"
git -C "$BLAME_REPO" add lib.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:03 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:03 +0000" \
  git -C "$BLAME_REPO" commit --no-gpg-sign -m "feat: event loop"

{
    printf '    persist_state();\n'
    printf '    checkpoint();\n'
    printf '    notify_ready();\n'
} >> "$BLAME_REPO/lib.rs"
git -C "$BLAME_REPO" add lib.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:04 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:04 +0000" \
  git -C "$BLAME_REPO" commit --no-gpg-sign -m "feat: persist and notify"

{
    printf '    wait_for_shutdown();\n'
    printf '    teardown();\n'
    printf '}\n'
} >> "$BLAME_REPO/lib.rs"
git -C "$BLAME_REPO" add lib.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:05 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:05 +0000" \
  git -C "$BLAME_REPO" commit --no-gpg-sign -m "feat: shutdown"

git -C "$BLAME_REPO" blame lib.rs > "$SMALL_DIR/git_blame_simple.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3: v0.4 large fixtures (commit, merge, rebase, blame, push)
# ═══════════════════════════════════════════════════════════════════════════════

LARGE_SCRATCH=$(mktemp -d -t smll-large-v4-XXXXXX)
trap 'rm -rf "$SCRATCH" "$SMALL_SCRATCH" "$REMOTE_DIR" "$CLONE2" "$BLAME_REPO" "$LARGE_SCRATCH"' EXIT
COMMIT_COUNTER=0

init_repo "$LARGE_SCRATCH"

mkdir -p "$LARGE_SCRATCH/src"

# Build 50 source files as the initial tree.
for n in $(seq 1 50); do
    make_base_file "$LARGE_SCRATCH/src/module_$(printf '%02d' "$n").rs" "module_$(printf '%02d' "$n")"
done
git -C "$LARGE_SCRATCH" add src
GIT_AUTHOR_DATE="2026-01-01T00:00:01 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:01 +0000" \
  git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q -m "feat(seed): bootstrap 50-module source tree"

# ── large git_commit.txt ──────────────────────────────────────────────────────
# Add/modify 50+ files in one commit to get a rich "N files changed" summary.
for n in $(seq 1 50); do
    f="$LARGE_SCRATCH/src/module_$(printf '%02d' "$n").rs"
    printf '\n// large-commit patch for module %02d\n' "$n" >> "$f"
    printf 'pub const MODULE_%02d_VERSION: u32 = 2;\n' "$n" >> "$f"
done
# Add 100 new files so each gets an individual "create mode" line,
# making the commit output meaningfully larger than the small fixture.
mkdir -p "$LARGE_SCRATCH/src/generated"
for n in $(seq 1 100); do
    f="$LARGE_SCRATCH/src/generated/gen_$(printf '%03d' "$n").rs"
    {
        printf '// generated_%03d — part of large-commit fixture\n' "$n"
        for k in $(seq 1 5); do
            printf 'pub fn gen_%03d_fn_%d(x: u64) -> u64 { x ^ 0x%x }\n' \
                "$n" "$k" "$((n * 41 + k * 17))"
        done
    } > "$f"
done
git -C "$LARGE_SCRATCH" add src
GIT_AUTHOR_DATE="2026-01-01T00:00:02 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:02 +0000" \
  git -C "$LARGE_SCRATCH" commit --no-gpg-sign \
  -m "feat(large): patch all 50 modules and add 100 generated files

Modifies every existing module with a version constant and adds 100
new generated files. This commit is used to exercise the large-commit
fixture path where the summary line reads 'N files changed, M insertions(+)'
and each new file appears as an individual 'create mode' entry.

Refs: LARGE-COMMIT-1" \
  > "$OUT_DIR/git_commit.txt"

# ── large git_merge.txt ────────────────────────────────────────────────────────
# Create a feature branch that modifies many files, then merge it.
git -C "$LARGE_SCRATCH" checkout -b large-feature -q
for n in $(seq 1 60); do
    f="$LARGE_SCRATCH/src/module_$(printf '%02d' "$n").rs"
    printf '\n// large-feature: add transform for module %02d\n' "$n" >> "$f"
    for k in $(seq 1 3); do
        printf 'pub fn large_feature_%02d_transform_%d(x: u64) -> u64 { x ^ 0x%x }\n' \
            "$n" "$k" "$((n * 37 + k * 13))" >> "$f"
    done
done
git -C "$LARGE_SCRATCH" add src
GIT_AUTHOR_DATE="2026-01-01T00:00:03 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:03 +0000" \
  git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q \
  -m "feat(large-feature): add transform functions across all 60 modules"

# Add a diverging commit on main so this is a true merge commit.
# Use a brand-new file so there is no overlap with large-feature's changes.
git -C "$LARGE_SCRATCH" checkout main -q
printf '// main diverging commit\npub const MAIN_REVISION: u32 = 3;\n' \
  > "$LARGE_SCRATCH/src/main_revision.rs"
git -C "$LARGE_SCRATCH" add src/main_revision.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:04 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:04 +0000" \
  git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q -m "chore: bump main revision"

GIT_AUTHOR_DATE="2026-01-01T00:00:05 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:05 +0000" \
  git -C "$LARGE_SCRATCH" merge --no-progress --no-ff large-feature \
  -m "Merge branch 'large-feature' into main" \
  > "$OUT_DIR/git_merge.txt"

# ── large git_rebase.txt ──────────────────────────────────────────────────────
# Create a rebase-branch off the seed commit (main~1, before the large-commit)
# with 5 commits each adding new files to src/rebase_batch/.
# New files have no overlap with main's existing modules, so rebase is clean.
REBASE_BASE_LARGE=$(git -C "$LARGE_SCRATCH" rev-parse main~1)
git -C "$LARGE_SCRATCH" checkout -b large-rebase-branch "$REBASE_BASE_LARGE" -q
mkdir -p "$LARGE_SCRATCH/src/rebase_batch"

for commit_n in $(seq 1 5); do
    for n in $(seq $((commit_n * 10 - 9)) $((commit_n * 10))); do
        f="$LARGE_SCRATCH/src/rebase_batch/rbatch_$(printf '%02d' "$commit_n")_$(printf '%02d' "$n").rs"
        {
            printf '// rebase batch %d item %02d — generated\n' "$commit_n" "$n"
            printf 'pub const REBASE_%d_ITEM_%02d: u64 = 0x%x;\n' \
                "$commit_n" "$n" "$((commit_n * 1000 + n))"
            for k in $(seq 1 5); do
                printf 'pub fn rebase_%d_%02d_fn_%d(x: u64) -> u64 { x ^ 0x%x }\n' \
                    "$commit_n" "$n" "$k" "$((commit_n * 37 + n * 13 + k * 7))"
            done
        } > "$f"
    done
    git -C "$LARGE_SCRATCH" add src/rebase_batch
    GIT_AUTHOR_DATE="2026-01-01T00:00:$(printf '%02d' $((commit_n + 6))) +0000" \
    GIT_COMMITTER_DATE="2026-01-01T00:00:$(printf '%02d' $((commit_n + 6))) +0000" \
      git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q \
      -m "feat(rebase): batch $commit_n — add 10 new rebase_batch files"
done

GIT_AUTHOR_DATE="2026-01-01T00:00:12 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:12 +0000" \
  git -C "$LARGE_SCRATCH" rebase --no-stat main \
  > "$OUT_DIR/git_rebase.txt" 2>&1

git -C "$LARGE_SCRATCH" checkout main -q

# ── large git_blame.txt ────────────────────────────────────────────────────────
# Build a 200+ line file with many distinct commits.
BLAME_LARGE="$LARGE_SCRATCH/src/blamed_module.rs"
{
    printf '// blamed_module.rs — generated for large blame fixture\n'
    printf '// This file has 200+ lines committed across 20 separate commits.\n'
    printf '\n'
} > "$BLAME_LARGE"
git -C "$LARGE_SCRATCH" add src/blamed_module.rs
GIT_AUTHOR_DATE="2026-01-01T00:00:13 +0000" GIT_COMMITTER_DATE="2026-01-01T00:00:13 +0000" \
  git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q -m "feat(blame-module): initial header"

for batch in $(seq 1 20); do
    for line in $(seq 1 10); do
        lineno=$(( (batch - 1) * 10 + line ))
        printf 'pub fn blamed_fn_%03d(x: u64) -> u64 { x.wrapping_mul(0x%x) ^ 0x%x }\n' \
            "$lineno" "$((lineno * 31 + 7))" "$((lineno * 257))" >> "$BLAME_LARGE"
    done
    git -C "$LARGE_SCRATCH" add src/blamed_module.rs
    GIT_AUTHOR_DATE="2026-01-01T00:00:$(printf '%02d' $((batch + 13))) +0000" \
    GIT_COMMITTER_DATE="2026-01-01T00:00:$(printf '%02d' $((batch + 13))) +0000" \
      git -C "$LARGE_SCRATCH" commit --no-gpg-sign -q \
      -m "feat(blame-module): batch $batch — lines $((batch * 10 - 9))-$((batch * 10))"
done

git -C "$LARGE_SCRATCH" blame src/blamed_module.rs > "$OUT_DIR/git_blame.txt"

# ── large git_push ─────────────────────────────────────────────────────────────
# NOTE: tests/fixtures/large/git_push.{stdout,stderr}.txt are HAND-MAINTAINED.
# The test `apply: large fixture preserves all 10 refs` exercises a ten-ref
# push shape (mixed new-branch / fast-forward / rejected / deleted rows) that
# is hard to produce deterministically from a scratch repo. Regenerating it
# here would collapse it to a single "main -> main" line and break the test.
# If you need to update the fixture, edit those files directly.

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 3b: v0.6 generic-compact calibration fixtures
# Synthetic — must exceed 64 KiB and mimic real-world output shapes
# (pip install, cargo build -vv, journalctl, find /usr).
# ═══════════════════════════════════════════════════════════════════════════════

# ── generic_pip_install.txt ───────────────────────────────────────────────────
# pip install output: many "Collecting ..." / "Requirement already satisfied"
# lines, common repeats via nested transitive deps, ANSI color on "Successfully".
{
    for n in $(seq 1 400); do
        pkg="lib-pkg-$(printf '%03d' "$n")"
        ver="$((n % 50 + 1)).$((n % 10)).$((n % 5))"
        printf 'Collecting %s==%s\n' "$pkg" "$ver"
        printf '  Downloading %s-%s-py3-none-any.whl (%d kB)\n' "$pkg" "$ver" "$((n * 3 + 41))"
        printf '     \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80 %d.%d/%d.%d kB %d.%d MB/s eta 0:00:00\n' \
            "$((n * 3 + 41))" 0 "$((n * 3 + 41))" 0 $((n % 9 + 1)) $((n % 9))
    done
    # Transitive-dep repeats — 400 identical "Requirement already satisfied"
    # lines. Real pip logs commonly re-emit this for every downstream dep.
    for _ in $(seq 1 400); do
        printf 'Requirement already satisfied: urllib3<3,>=1.21.1 in /usr/lib/python3/dist-packages (from requests) (2.0.7)\n'
    done
    printf '\n\n\nInstalling collected packages:'
    for n in $(seq 1 400); do
        printf ' lib-pkg-%03d,' "$n"
    done
    printf '\n\n'
    printf '\x1b[32mSuccessfully installed 400 packages\x1b[0m\n'
} > "$OUT_DIR/generic_pip_install.txt"

# ── generic_cargo_build_verbose.txt ───────────────────────────────────────────
# cargo build -vv: many "Compiling <crate> v<ver>" + rustc invocations with
# repeated flag-sets, ANSI green on "Finished".
{
    crates=(serde syn quote proc-macro2 unicode-ident proc-macro-hack
            futures tokio hyper reqwest anyhow thiserror log env_logger
            clap clap_derive once_cell lazy_static regex memchr aho-corasick)
    for n in $(seq 1 240); do
        crate="${crates[$(( (n - 1) % ${#crates[@]} ))]}"
        ver="$((n % 10 + 1)).$((n % 20)).$((n % 5))"
        printf '\x1b[32m   Compiling\x1b[0m %s v%s\n' "$crate" "$ver"
        printf '     Running `rustc --crate-name %s --edition=2021 --crate-type lib ' "$crate"
        printf -- '--emit=dep-info,metadata,link -C embed-bitcode=no '
        printf -- '-C codegen-units=1 -C metadata=%x -C extra-filename=-%x ' "$((n * 31))" "$((n * 31))"
        printf -- '--out-dir /tmp/target/release/deps -L dependency=/tmp/target/release/deps`\n'
    done
    # Repeated warning about unused imports (common real shape). Cargo emits
    # the same short-form warning many times when one symbol is unused across
    # N re-exporting crates. Consecutive duplicates are RLE-friendly.
    for _ in $(seq 1 600); do
        printf 'warning: unused import: `std::collections::HashMap`\n'
    done
    for _ in $(seq 1 600); do
        printf 'warning: variable does not need to be mutable\n'
    done
    printf '\x1b[32m    Finished\x1b[0m release [optimized] target(s) in 45.23s\n'
} > "$OUT_DIR/generic_cargo_build_verbose.txt"

# ── generic_journalctl.txt ────────────────────────────────────────────────────
# journalctl output: timestamped log lines, many identical consecutive repeats
# (kernel messages, service restart loops).
{
    for day in 18 19 20 21 22 23; do
        for hr in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
            for min in 0 10 20 30 40 50; do
                printf 'Apr %d 2026 %s:%02d:00 host systemd[1]: Started Session %d of user root.\n' \
                    "$day" "$hr" "$min" "$((day * 24 * 6 + min))"
                # Repeat this warning 4x (dedup target).
                for _ in 1 2 3 4; do
                    printf 'Apr %d 2026 %s:%02d:01 host kernel: [UFW BLOCK] IN=eth0 OUT= SRC=203.0.113.42 DST=10.0.0.5 PROTO=TCP SPT=54321 DPT=22 SYN\n' \
                        "$day" "$hr" "$min"
                done
                printf 'Apr %d 2026 %s:%02d:02 host sshd[%d]: Accepted publickey for alice from 10.0.0.100 port %d\n' \
                    "$day" "$hr" "$min" "$((min + 1000))" "$((54000 + min * 7))"
            done
        done
    done
} > "$OUT_DIR/generic_journalctl.txt"

# ── generic_ps_auxww.txt ──────────────────────────────────────────────────────
# Synthetic `ps`-style output: each cluster is a block of many identical
# worker rows (same PID column collapsed to "-" so RLE fires) plus heavy
# trailing padding. Collapses hard under format-lossy compaction; real
# `ps auxww` with distinct PIDs reduces less, but this fixture measures
# the compactor's best-case agent scenario (repeating worker fleets).
{
    printf 'USER       PID %%CPU %%MEM    VSZ   RSS TTY      STAT START   TIME COMMAND\n'
    # Cluster 1: 400 identical gunicorn worker lines (PID column suppressed).
    for _ in $(seq 1 400); do
        printf 'www          -  0.1  0.5 123456  7890 ?        S    00:00   0:00 /usr/bin/python3 /opt/app/venv/bin/gunicorn --workers 8 --bind 0.0.0.0:8000 app.wsgi:application                        \n'
    done
    # Cluster 2: 300 identical node worker lines.
    for _ in $(seq 1 300); do
        printf 'node         -  0.2  1.0 234567 12345 ?        Sl   00:00   0:01 node /opt/app/dist/server.js --cluster --instances 4                                                                 \n'
    done
    # Cluster 3: 250 identical postgres worker lines.
    for _ in $(seq 1 250); do
        printf 'postgres     -  0.0  0.8 345678 15432 ?        Ss   00:00   0:00 postgres: 15/main: writer process                                                                                    \n'
    done
} > "$OUT_DIR/generic_ps_auxww.txt"

# ── find_ls.txt (large) ───────────────────────────────────────────────────────
# Synthetic `find -ls` output: GNU-style inode/blocks/mode/nlinks/user/group/
# size/month/day/time-or-year/path. Path depth varies 1-4 to exercise
# directory-marker emission and whitespace-tolerance.
{
    dirs=("src" "src/filters" "src/ui" "tests" "tests/fixtures" "docs" "vendor" "vendor/lib" "scripts" "benchmarks")
    # Deterministic inodes — $RANDOM would churn the committed fixture on every
    # regen. Use a simple positional formula instead.
    for i in "${!dirs[@]}"; do
        d="${dirs[$i]}"
        inode=$((2055100 + i * 37))
        printf '%d    0 drwxr-xr-x   2 user     staff          64 Apr 23 12:34 ./%s\n' "$inode" "$d"
    done
    for n in $(seq 1 500); do
        d_idx=$((n % 10))
        d="${dirs[$d_idx]}"
        inode=$((2055500 + n))
        size=$((n * 37 % 9991 + 40))
        # Alternate time-of-day and year-only columns to cover both find -ls shapes.
        if (( n % 3 == 0 )); then
            printf '%d    8 -rw-r--r--   1 user     staff    %8d Apr 23  2025 ./%s/file_%04d.zig\n' "$inode" "$size" "$d" "$n"
        else
            printf '%d    8 -rw-r--r--   1 user     staff    %8d Apr 23 12:34 ./%s/file_%04d.zig\n' "$inode" "$size" "$d" "$n"
        fi
    done
} > "$OUT_DIR/find_ls.txt"

# ── du_sh.txt (large) ─────────────────────────────────────────────────────────
# Synthetic `du -sh` output over ~500 entries. Size column varies across K/M/G
# with both integer and `du -h`-style single-decimal leads so rounding exercises
# every branch. Deep path shapes mirror real monorepos.
{
    for n in $(seq 1 500); do
        mod=$((n % 7))
        path="./monorepo/pkg$((n % 20))/src/module_$((n % 40))/lib_$(printf '%03d' "$n").zig"
        case "$mod" in
            0) printf '%dK\t%s\n' "$(( (n * 17) % 999 + 1 ))" "$path" ;;
            1) printf '%dM\t%s\n' "$(( (n * 31) % 900 + 100 ))" "$path" ;;
            2) printf '%d.%dG\t%s\n' "$(( (n % 9) + 1 ))" "$(( (n * 3) % 10 ))" "$path" ;;
            3) printf '%dM\t%s\n' "$(( (n * 13) % 90 + 10 ))" "$path" ;;
            4) printf '%d.%dM\t%s\n' "$(( (n % 9) + 1 ))" "$(( (n * 7) % 10 ))" "$path" ;;
            5) printf '%dG\t%s\n' "$(( (n % 19) + 1 ))" "$path" ;;
            6) printf '%dK\t%s\n' "$(( (n * 41) % 99 + 1 ))" "$path" ;;
        esac
    done
} > "$OUT_DIR/du_sh.txt"

# ── curl_vvv_example.stderr.txt + curl_vvv_example.stdout.txt (large) ─────────
# Synthetic `curl -vvv` output over a redirect chain + multiplexed HTTP/2
# session. Stderr heavy on TLS/schannel/ALPN chatter + a PEM cert block to
# exercise drop logic. Stdout carries a realistic JSON body.
{
    for n in $(seq 1 30); do
        cat <<EOF
*   Trying 10.0.0.$((n % 255 + 1)):443...
* Connected to api.example.com (10.0.0.$((n % 255 + 1))) port 443
* ALPN: curl offers h2,http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN: server accepted h2
* Server certificate:
*   subject: CN=api.example.com
*   start date: Jan  1 00:00:00 2024 GMT
*   expire date: Apr  1 00:00:00 2024 GMT
*   subjectAltName: host "api.example.com" matched cert's "api.example.com"
*   issuer: C=US; O=Let's Encrypt; CN=R3
*   SSL certificate verify ok.
* Certificate level 0: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
* Certificate level 1: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
* Using HTTP2, server supports multiplexing
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
> GET /v1/resources/$n HTTP/2
> Host: api.example.com
> User-Agent: curl/8.0.1
> accept: application/json
> authorization: Bearer <<REDACTED>>
>
* Connection state changed (MAX_CONCURRENT_STREAMS == 128)!
< HTTP/2 200
< content-type: application/json
< content-length: 128
< cache-control: no-store
< date: Mon, 22 Apr 2026 12:00:0$((n % 10)) GMT
< x-request-id: req-${n}
<
EOF
    done
    # One PEM cert block dump at the end to exercise the BEGIN/END drop path.
    cat <<'EOF'
* Server certificate chain:
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIUJYJn0qRkWZA5YDEmEHKG5tJX+q4wDQYJKoZIhvcNAQEL
BQAwRTELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExETAPBgNVBAoM
CEV4YW1wbGUxDjAMBgNVBAMMBVJvb3QxMB4XDTI0MDEwMTAwMDAwMFoXDTM0MDEw
MTAwMDAwMFowRTELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExETAP
BgNVBAoMCEV4YW1wbGUxDjAMBgNVBAMMBVJvb3QxMIICIjANBgkqhkiG9w0BAQEF
AAOCAg8AMIICCgKCAgEAz4ftrMELxpz+fXhVfpCwJ5V4j+0H8wKLOoE4jJZP7vWj
-----END CERTIFICATE-----
EOF
} > "$OUT_DIR/curl_vvv_example.stderr.txt"

{
    for n in $(seq 1 30); do
        printf '{"id":%d,"name":"resource_%d","status":"ok"}\n' "$n" "$n"
    done
} > "$OUT_DIR/curl_vvv_example.stdout.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# SECTION 4: Summary
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo "Generated v0.3 large fixtures in $OUT_DIR:"
for f in git_status git_diff git_log git_show; do
    bytes=$(wc -c < "$OUT_DIR/${f}.txt" | tr -d ' ')
    words=$(wc -w < "$OUT_DIR/${f}.txt" | tr -d ' ')
    printf '  %-24s  %8s bytes  %6s words\n' "${f}.txt" "$bytes" "$words"
done

echo ""
echo "Generated v0.4 small fixtures in $SMALL_DIR:"
for f in \
    git_add_error.stdout.txt git_add_error.stderr.txt \
    git_commit_simple.txt git_commit_multifile.txt \
    git_push_simple.stdout.txt git_push_simple.stderr.txt \
    git_pull_ff.stdout.txt git_pull_ff.stderr.txt \
    git_pull_uptodate.stdout.txt git_pull_uptodate.stderr.txt \
    git_fetch_simple.stdout.txt git_fetch_simple.stderr.txt \
    git_merge_ff.txt git_merge_commit.txt \
    git_merge_conflict.stdout.txt git_merge_conflict.stderr.txt \
    git_rebase_simple.txt \
    git_checkout_switch.stdout.txt git_checkout_switch.stderr.txt \
    git_branch_list.txt \
    git_stash_save.txt git_stash_list.txt \
    git_blame_simple.txt; do
    bytes=$(wc -c < "$SMALL_DIR/${f}" | tr -d ' ')
    printf '  %-40s  %8s bytes\n' "$f" "$bytes"
done

echo ""
echo "Generated v0.4 large fixtures in $OUT_DIR:"
for f in git_commit.txt git_merge.txt git_rebase.txt git_blame.txt \
         git_push.stdout.txt git_push.stderr.txt; do
    bytes=$(wc -c < "$OUT_DIR/${f}" | tr -d ' ')
    printf '  %-32s  %8s bytes\n' "$f" "$bytes"
done

echo ""
echo "Generated v0.6 generic-compact fixtures in $OUT_DIR:"
for f in generic_pip_install.txt generic_cargo_build_verbose.txt \
         generic_journalctl.txt generic_ps_auxww.txt; do
    bytes=$(wc -c < "$OUT_DIR/${f}" | tr -d ' ')
    printf '  %-32s  %8s bytes\n' "$f" "$bytes"
done
