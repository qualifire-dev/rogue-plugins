#!/usr/bin/env bash
set -euo pipefail
# Build per-OS release tarballs for rogue-plugin-claude.
# Output: dist/rogue-plugin-claude-<os>.tar.gz
# Filename does NOT include version so GitHub Releases /latest/ asset URL is stable.
#
# Env:
#   OS_MATRIX  — space-separated list of OS targets. Default: "darwin".
#                Future: "darwin linux windows".

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OS_MATRIX="${OS_MATRIX:-darwin}"
DIST="$ROOT/dist"
PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('plugins/rogue/.claude-plugin/plugin.json'))['version'])" 2>/dev/null || echo "unknown")

echo "→ plugin version: $PLUGIN_VERSION"
echo "→ target OSes:    $OS_MATRIX"

rm -rf "$DIST"
mkdir -p "$DIST"

# Files shared by every OS today. (When a Windows tarball lands, filter the
# scripts/hooks per OS via a per-os manifest.)
COMMON_FILES=(
  ".claude-plugin"
  "plugins"
  "README.md"
  "LICENSE"
)

for OS in $OS_MATRIX; do
  STAGE=$(mktemp -d)
  trap 'rm -rf "$STAGE"' EXIT
  TOPDIR="$STAGE/rogue-plugin-claude"
  mkdir -p "$TOPDIR"

  for f in "${COMMON_FILES[@]}"; do
    [ -e "$f" ] || { echo "✗ missing: $f" >&2; exit 1; }
    cp -R "$f" "$TOPDIR/"
  done

  # Future OS-specific filtering hook (no-op today).
  # case "$OS" in
  #   darwin) rm -f "$TOPDIR/plugins/rogue/scripts/security-alert.ps1" ;;
  #   windows) rm -f "$TOPDIR/plugins/rogue/scripts/security-alert.sh" ;;
  # esac

  OUT="$DIST/rogue-plugin-claude-${OS}.tar.gz"
  tar -czf "$OUT" -C "$STAGE" "rogue-plugin-claude"
  SIZE=$(wc -c < "$OUT" | awk '{print $1}')
  echo "✓ $OUT  ($SIZE bytes, version $PLUGIN_VERSION)"

  rm -rf "$STAGE"
  trap - EXIT
done

# ── Codex plugin tarball ────────────────────────────────────────────────────
# Primary Codex install path is `codex plugin marketplace add <repo>` (git), but
# we also ship a versionless tarball so /releases/latest/download URLs are stable
# (used by compiled-key MDM bundles and any download-based install).
if [ -d "plugins/codex" ]; then
  CODEX_VERSION=$(python3 -c "import json; print(json.load(open('plugins/codex/.codex-plugin/plugin.json'))['version'])" 2>/dev/null || echo "unknown")
  echo "→ codex plugin version: $CODEX_VERSION"
  for OS in $OS_MATRIX; do
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    TOPDIR="$STAGE/rogue-plugin-codex"
    mkdir -p "$TOPDIR/plugins" "$TOPDIR/.agents/plugins"
    cp .agents/plugins/marketplace.json "$TOPDIR/.agents/plugins/"
    cp -R plugins/codex "$TOPDIR/plugins/"
    cp README.md LICENSE "$TOPDIR/" 2>/dev/null || true
    OUT="$DIST/rogue-plugin-codex-${OS}.tar.gz"
    tar -czf "$OUT" -C "$STAGE" "rogue-plugin-codex"
    SIZE=$(wc -c < "$OUT" | awk '{print $1}')
    echo "✓ $OUT  ($SIZE bytes, version $CODEX_VERSION)"
    rm -rf "$STAGE"; trap - EXIT
  done
fi

echo ""
echo "dist/:"
ls -la "$DIST"
