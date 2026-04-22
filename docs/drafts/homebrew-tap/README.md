# homebrew-smll

Homebrew tap for [smll](https://github.com/nkootstra/smll), a tiny wrapper
that compresses noisy command output for coding agents.

## Install

```sh
brew install nkootstra/smll/smll
```

Or two-step:

```sh
brew tap nkootstra/smll
brew install smll
```

## Supported platforms (prebuilt bottles)

- macOS Apple Silicon (`aarch64-apple-darwin`)
- Linux x86_64 (`x86_64-linux-gnu`)
- Linux arm64 (`aarch64-linux-gnu`)

On any other platform (notably macOS Intel), the formula builds from source
via `zig` (declared as a `:build` dependency).

## Trust model

Formula `sha256` values pin each prebuilt tarball. Anyone verifying manually
can cross-check with `shasum -a 256 smll-<ver>-<triple>.tar.gz` against the
hash in this formula. The `SHA256SUMS`-style aggregate files on the smll
GitHub Releases page are convenience artifacts, not trust anchors — the
formula is what protects end users.

## Formula updates

Formula bumps are opened automatically by the smll repo's release workflow
(`peter-evans/create-pull-request`) on each tag push. Merges go through this
tap's CI (`test-formula.yml`) which runs:

- `brew audit --strict --online`
- `brew install --build-from-source`
- `brew test`

on both macOS and Linux runners before any user sees a change.

## Rotation

The PAT that the smll release workflow uses to open bump PRs
(`HOMEBREW_TAP_TOKEN`) is scoped to `contents: write` on this repo only.
Audit and rotate quarterly in the smll repo's Settings → Secrets UI.
