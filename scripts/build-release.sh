#!/usr/bin/env bash
set -euo pipefail
# Build the release tarball for rogue-plugin-claude.
# Output: dist/rogue-plugin-claude.tar.gz
#
# The package is cross-platform by content: it ships BOTH the POSIX-sh scripts
# (hook.sh, heartbeat.sh, …) and their PowerShell siblings (hook.ps1, …), and
# hooks.json registers an `sh` entry and a PowerShell entry for every event.
# There is therefore nothing OS-specific to split — one tarball serves macOS,
# Linux, and Windows. The filename has NO version and NO OS suffix so the
# GitHub Releases /latest/download/ asset URL stays stable.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
# Read the plugin version WITHOUT python3 (absent on a fresh macOS — same reason
# the runtime scripts avoid it). grep/sed are always present.
PLUGIN_VERSION=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
  plugins/rogue/.claude-plugin/plugin.json | head -1 \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")

echo "→ plugin version: $PLUGIN_VERSION"

rm -rf "$DIST"
mkdir -p "$DIST"

COMMON_FILES=(
  ".claude-plugin"
  "plugins"
  "README.md"
  "LICENSE"
)

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
TOPDIR="$STAGE/rogue-plugin-claude"
mkdir -p "$TOPDIR"

for f in "${COMMON_FILES[@]}"; do
  [ -e "$f" ] || { echo "✗ missing: $f" >&2; exit 1; }
  cp -R "$f" "$TOPDIR/"
done

OUT="$DIST/rogue-plugin-claude.tar.gz"
tar -czf "$OUT" -C "$STAGE" "rogue-plugin-claude"
SIZE=$(wc -c < "$OUT" | awk '{print $1}')
echo "✓ $OUT  ($SIZE bytes, version $PLUGIN_VERSION)"

echo ""
echo "dist/:"
ls -la "$DIST"
