#!/usr/bin/env python3
"""Bump Formula/smll.rb to a new version + per-platform sha256 values.

Invoked by the release.yml bump-tap job. Uses anchor comments in the formula
(`# Anchor: <name>`) to locate the exact lines to rewrite; fails loudly if any
anchor goes missing (formula was hand-edited, for example).

Env:
  VERSION           e.g. 0.5.0
  SHA_SOURCE        64-char hex for the GitHub source archive
  SHA_MACOS_ARM64   64-char hex for the macOS arm64 release tarball
  SHA_LINUX_X64     64-char hex for the Linux x86_64 release tarball
  SHA_LINUX_ARM64   64-char hex for the Linux arm64 release tarball
  FORMULA_PATH      path to Formula/smll.rb (default: homebrew-smll/Formula/smll.rb)
"""
from __future__ import annotations

import os
import pathlib
import re
import sys

VERSION_RE = re.compile(r'^(\s*version\s+")([^"]+)(")\s*$', re.MULTILINE)
URL_RE = re.compile(r'^(\s*url\s+")([^"]+)(")\s*$', re.MULTILINE)
SHA_RE = re.compile(r'^(\s*sha256\s+")([a-f0-9]{64})(")\s*$', re.MULTILINE)


def die(msg: str) -> "None":
    print(f"bump-formula: error: {msg}", file=sys.stderr)
    sys.exit(1)


def require_env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        die(f"{name} not set")
    return v


def sub_after_anchor(text: str, anchor: str, line_re: re.Pattern, new_line_value: str) -> str:
    """Replace the captured group 2 of line_re on the next matching line after anchor.

    Requires the anchor comment on one line and the target line immediately after
    (same indentation level). Fails loudly on mismatch.
    """
    marker = f"# Anchor: {anchor}"
    idx = text.find(marker)
    if idx < 0:
        die(f"anchor not found: {anchor}")

    tail = text[idx:]
    # Skip past the anchor line itself.
    nl = tail.find("\n")
    if nl < 0:
        die(f"anchor {anchor} has no following line")
    search_from = idx + nl + 1

    m = line_re.search(text, search_from)
    if not m:
        die(f"anchor {anchor} not followed by a matching line")

    # Verify the match is the immediate next line (no intervening blanks).
    between = text[search_from:m.start()]
    if between.strip():
        die(f"anchor {anchor}: intervening content before target line")

    return text[: m.start(2)] + new_line_value + text[m.end(2) :]


def main() -> "None":
    version = require_env("VERSION")
    sha_src = require_env("SHA_SOURCE").lower()
    sha_mac = require_env("SHA_MACOS_ARM64").lower()
    sha_lx = require_env("SHA_LINUX_X64").lower()
    sha_la = require_env("SHA_LINUX_ARM64").lower()

    for name, val in [
        ("SHA_SOURCE", sha_src),
        ("SHA_MACOS_ARM64", sha_mac),
        ("SHA_LINUX_X64", sha_lx),
        ("SHA_LINUX_ARM64", sha_la),
    ]:
        if not re.fullmatch(r"[a-f0-9]{64}", val):
            die(f"{name} is not a 64-char hex string: {val!r}")

    path = pathlib.Path(os.environ.get("FORMULA_PATH", "homebrew-smll/Formula/smll.rb"))
    if not path.is_file():
        die(f"formula not found: {path}")

    text = path.read_text()

    # Version
    text = sub_after_anchor(text, "version", VERSION_RE, version)

    # URLs: source archive + three binary releases. All share the version substring.
    source_url = f"https://github.com/nkootstra/smll/archive/refs/tags/v{version}.tar.gz"
    text = sub_after_anchor(text, "source-url", URL_RE, source_url)

    def rel_url(triple: str) -> str:
        return f"https://github.com/nkootstra/smll/releases/download/v{version}/smll-{version}-{triple}.tar.gz"

    text = sub_after_anchor(text, "macos-arm64-url", URL_RE, rel_url("aarch64-apple-darwin"))
    text = sub_after_anchor(text, "linux-x86_64-url", URL_RE, rel_url("x86_64-linux-gnu"))
    text = sub_after_anchor(text, "linux-arm64-url", URL_RE, rel_url("aarch64-linux-gnu"))

    # sha256 values — per-platform binary hashes plus the GitHub source archive hash
    # (source-fallback path for macOS Intel and any other unsupported platform).
    text = sub_after_anchor(text, "source-sha256", SHA_RE, sha_src)
    text = sub_after_anchor(text, "macos-arm64-sha256", SHA_RE, sha_mac)
    text = sub_after_anchor(text, "linux-x86_64-sha256", SHA_RE, sha_lx)
    text = sub_after_anchor(text, "linux-arm64-sha256", SHA_RE, sha_la)

    path.write_text(text)
    print(f"bump-formula: updated {path} to {version}")


if __name__ == "__main__":
    main()
