#!/usr/bin/env bash
# Generate / append the Sparkle appcast (appcast.xml) for Anomalous.
#
# Sparkle ships two CLI tools we need. This wraps `generate_appcast`, which
# scans a folder of signed+notarized DMGs, EdDSA-signs each one with the
# PRIVATE key from your login Keychain (created once by `generate_keys`), and
# writes/updates appcast.xml alongside them.
#
#   • The PRIVATE key lives ONLY in the login Keychain — never in the repo.
#   • The PUBLIC key goes into Info.plist as SUPublicEDKey (project.yml), and is
#     what the shipped app uses to verify downloads.
#
# One-time setup (per signing machine), do this BEFORE the first release:
#   $(tools/sparkle-appcast.sh --tool generate_keys)
#   → prints the public key. Paste it into project.yml → target Anomalous →
#     info.properties → SUPublicEDKey, then `xcodegen generate` and rebuild.
#     To move the key to another machine: `generate_keys -x key.priv` on the
#     old one, `generate_keys -f key.priv` on the new one, then `rm key.priv`.
#
# Per release:
#   1. Build Release, then tools/sign.sh + tools/notarize.sh + tools/make-dmg.sh
#      so ./dist holds the signed+notarized DMG(s).
#   2. ./tools/sparkle-appcast.sh                 # signs DMGs, writes dist/appcast.xml
#   3. Publish dist/appcast.xml + the .dmg to anomalous.bot
#      (copy them to the host serving anomalous.bot; NOT auto-deployed).
#
# Usage:
#   ./tools/sparkle-appcast.sh [dist_dir]           # default: ./dist
#   ./tools/sparkle-appcast.sh --tool generate_keys # locate + run generate_keys
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Find a Sparkle CLI tool ($1). Prefer the copy SPM already downloaded into
# DerivedData; fall back to a Homebrew install (`brew install --cask sparkle`).
find_sparkle_tool() {
  local tool="$1" hit
  hit="$(ls -t "$HOME"/Library/Developer/Xcode/DerivedData/Anomalous-*/SourcePackages/artifacts/sparkle/Sparkle/bin/"$tool" 2>/dev/null | head -1 || true)"
  [ -x "$hit" ] && { echo "$hit"; return 0; }
  hit="$(command -v "$tool" 2>/dev/null || true)"
  [ -x "$hit" ] && { echo "$hit"; return 0; }
  for c in "/opt/homebrew/Caskroom/sparkle"/*/bin/"$tool" "/usr/local/Caskroom/sparkle"/*/bin/"$tool"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

if [ "${1:-}" = "--tool" ]; then
  TOOL="${2:?usage: --tool <generate_keys|generate_appcast>}"
  BIN="$(find_sparkle_tool "$TOOL")" || {
    echo "✗ $TOOL not found. Build the app once (SPM fetches Sparkle) or: brew install --cask sparkle" >&2
    exit 1
  }
  shift 2
  echo "▸ $BIN" >&2
  exec "$BIN" "$@"
fi

DIST="${1:-$HERE/dist}"
[ -d "$DIST" ] || { echo "✗ dist dir not found: $DIST (run make-dmg.sh first)"; exit 1; }
ls "$DIST"/*.dmg >/dev/null 2>&1 || { echo "✗ no .dmg files in $DIST — build+sign+notarize a DMG first"; exit 1; }

GEN="$(find_sparkle_tool generate_appcast)" || {
  echo "✗ generate_appcast not found. Build the app once (SPM fetches Sparkle) or: brew install --cask sparkle" >&2
  exit 1
}

echo "▸ generate_appcast over $DIST"
echo "  (EdDSA-signs each DMG with the private key from your login Keychain)"
"$GEN" "$DIST"

echo "✓ appcast written: $DIST/appcast.xml"
echo "  Next: publish $DIST/appcast.xml + the .dmg to anomalous.bot"
echo "        (copy them to the host serving anomalous.bot manually)."
