#!/usr/bin/env bash
# Vendor the latest released Rogue plugin into a PRIVATE org marketplace repo,
# baking in the org API key. This is the update engine for the Desktop / Cowork
# track: the claude.ai org dashboard auto-syncs a connected GitHub marketplace
# "whenever a PR is merged to that repo", so committing the refreshed plugin
# here propagates the new version to every org member — no zip re-upload, no
# per-user action.
#
# Why vendor (relative-path source) instead of pointing at our public repo?
# Org marketplaces MUST be private/internal, and GitHub-synced marketplaces only
# support a narrow set of marketplace.json source types — relative paths are the
# reliable one. Anthropic's own guidance is to copy plugin folders into the
# marketplace repo. So we copy our released plugin tree into ./plugins/rogue and
# the marketplace.json references it with "source": "./plugins/rogue".
#
# The baked env sets ROGUE_AUTO_UPDATE=0 on purpose: on Desktop/Cowork the
# PLATFORM owns updates (this sync + the dashboard), and Cowork doesn't fire the
# SessionStart hook our CLI updater needs (anthropics/claude-code#47993). The
# update path here is "merge to this repo", not the in-plugin updater.
#
# Usage (local / manual):
#   scripts/sync-org-marketplace.sh --repo-dir ./my-org-marketplace --key rsk_xxx
#
# Usage (CI / GitHub Action): see templates/org-marketplace/.github/workflows/sync-rogue.yml
#
# Flags:
#   --repo-dir DIR   marketplace repo working copy to vendor into (default: cwd)
#   --key KEY        org ROGUE_API_KEY to bake (required)
#   --mode ask|block PreToolUse enforcement mode (default: ask)
#   --from vX.Y.Z    source release tag (default: latest GitHub release)
#   --base-url URL   override ROGUE_BASE_URL (rare)
#   --repo OWNER/REPO source plugin repo (default: qualifire-dev/rogue-plugin-claude)
#   --commit         git add+commit in --repo-dir after vendoring (off by default;
#                    the Action commits itself)
#   -h | --help      print this and exit
#
# Output: writes <repo-dir>/.claude-plugin/marketplace.json (if missing) and
# <repo-dir>/plugins/rogue/** (vendored tree + baked env). Does not push.

set -euo pipefail

SRC_REPO="qualifire-dev/rogue-plugin-claude"
REPO_DIR="$PWD"
KEY=""; MODE=""; FROM=""; BASE_URL=""; DO_COMMIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --key)      KEY="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --from)     FROM="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --repo)     SRC_REPO="$2"; shift 2 ;;
    --commit)   DO_COMMIT=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0" 2>/dev/null; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$KEY" ] || { echo "--key (org ROGUE_API_KEY) required" >&2; exit 2; }
case "$MODE" in ""|ask|block) ;; *) echo "Bad --mode: $MODE (expected ask|block)" >&2; exit 2 ;; esac
MODE="${MODE:-ask}"
[ -d "$REPO_DIR" ] || { echo "--repo-dir '$REPO_DIR' is not a directory" >&2; exit 2; }

for tool in curl tar python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool" >&2; exit 1; }
done

# Resolve release tag.
if [ -z "$FROM" ]; then
  echo "-> resolving latest release tag of $SRC_REPO..."
  FROM=$(curl -fsSL "https://api.github.com/repos/${SRC_REPO}/releases/latest" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')
  [ -n "$FROM" ] || { echo "could not resolve latest tag" >&2; exit 1; }
fi
echo "-> source release: $FROM"

TARBALL_URL="https://github.com/${SRC_REPO}/releases/download/${FROM}/rogue-plugin-claude.tar.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "-> downloading $TARBALL_URL"
# Release artifact filename was historically -darwin; try both for old tags.
if ! curl -fsSL "$TARBALL_URL" -o "$WORK/src.tar.gz" 2>/dev/null; then
  curl -fsSL "https://github.com/${SRC_REPO}/releases/download/${FROM}/rogue-plugin-claude-darwin.tar.gz" \
    -o "$WORK/src.tar.gz"
fi
tar -xzf "$WORK/src.tar.gz" -C "$WORK"

SRC="$WORK/rogue-plugin-claude/plugins/rogue"
[ -d "$SRC/.claude-plugin" ] || { echo "unexpected tarball layout at $SRC" >&2; exit 1; }

# ── Vendor the plugin tree into <repo-dir>/plugins/rogue ──────────────────────
DEST="$REPO_DIR/plugins/rogue"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC"/. "$DEST"/
echo "-> vendored plugin into $DEST"

# ── Strip Cowork-unsupported hook events (same allow-list as compile) ─────────
python3 - "$DEST" <<'PY'
import json, os, sys
dest = sys.argv[1]
COWORK_ALLOW = {
    "PreToolUse", "PostToolUse", "Stop", "SubagentStop",
    "SessionStart", "SessionEnd", "UserPromptSubmit",
    "PreCompact", "Notification",
}
hp = os.path.join(dest, "hooks", "hooks.json")
with open(hp) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
kept = {k: v for k, v in hooks.items() if k in COWORK_ALLOW}
dropped = sorted(set(hooks) - set(kept))
data["hooks"] = kept
with open(hp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
if dropped:
    print("-> stripped unsupported hook events: " + ", ".join(dropped), file=sys.stderr)
PY

# ── Bake the org key into <repo-dir>/plugins/rogue/env ────────────────────────
# ROGUE_AUTO_UPDATE=0: Desktop/Cowork updates are platform-managed (this sync +
# dashboard), so the in-plugin SessionStart updater must stand down.
{
  echo "# Vendored by sync-org-marketplace.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# Source release: ${FROM}"
  printf 'export ROGUE_API_KEY=%q\n'            "$KEY"
  printf 'export ROGUE_PRETOOLUSE_ON_BLOCK=%q\n' "$MODE"
  [ -n "$BASE_URL" ] && printf 'export ROGUE_BASE_URL=%q\n' "$BASE_URL"
  echo 'export ROGUE_AUTO_UPDATE=0'
  cat <<'ACTOR'

# Best-effort actor identity from git config. If empty at hook-fire time the
# hooks fall back to hostname/whoami (see scripts/actor.sh). Per-user
# ~/.rogue-env still overrides everything here.
: "${ROGUE_ACTOR_EMAIL:=$(git config --global user.email 2>/dev/null)}"
: "${ROGUE_ACTOR_NAME:=$(git config --global user.name 2>/dev/null)}"
export ROGUE_ACTOR_EMAIL ROGUE_ACTOR_NAME
ACTOR
} > "$DEST/env"
chmod 600 "$DEST/env"
echo "-> baked org key into $DEST/env (mode 600)  key=...${KEY: -4}"

# ── Ensure a marketplace.json exists (seed from template on first run) ────────
MJ="$REPO_DIR/.claude-plugin/marketplace.json"
if [ ! -f "$MJ" ]; then
  mkdir -p "$REPO_DIR/.claude-plugin"
  cat > "$MJ" <<'JSON'
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "CHANGE-ME-org-security",
  "description": "Internal Rogue Security AIDR distribution",
  "owner": { "name": "Security Team", "email": "security@your-org.example" },
  "plugins": [
    {
      "name": "rogue",
      "description": "Rogue Security AIDR — real-time AI agent detection and response for Claude Code",
      "category": "security",
      "source": "./plugins/rogue"
    }
  ]
}
JSON
  echo "-> seeded $MJ — EDIT the marketplace 'name' + owner before connecting it to the dashboard."
fi

VER=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9][^"]*"' \
        "$DEST/.claude-plugin/plugin.json" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")

if [ "$DO_COMMIT" = "1" ] && command -v git >/dev/null 2>&1 && git -C "$REPO_DIR" rev-parse >/dev/null 2>&1; then
  if [ -n "$(git -C "$REPO_DIR" status --porcelain)" ]; then
    git -C "$REPO_DIR" add -A
    git -C "$REPO_DIR" commit -m "chore: sync Rogue AIDR plugin to v${VER}" >/dev/null
    echo "-> committed v${VER} in $REPO_DIR (push to trigger the dashboard sync)"
  else
    echo "-> no changes to commit (already at v${VER})"
  fi
fi

cat <<EOF

OK  vendored Rogue AIDR v${VER} into $REPO_DIR

  Next:
    1. (first run) edit .claude-plugin/marketplace.json — set a unique 'name'
       and your org owner, then connect this PRIVATE repo to the claude.ai org
       dashboard as a GitHub-synced marketplace with "Sync automatically" ON.
    2. Commit + push (or merge a PR). The dashboard re-syncs on merge and every
       org member's Claude Desktop / Cowork gets v${VER} on next session.

!!  plugins/rogue/env embeds ROGUE_API_KEY in plaintext. This repo MUST stay
    private/internal. To rotate: revoke the old key in the dashboard, re-run
    with the new --key, commit.
EOF
