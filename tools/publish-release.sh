#!/usr/bin/env bash
# Publish a release's DMG(s) + Sparkle appcast to production — the ONE command
# to run after building/signing/notarizing a release. No path decisions.
#
# WHY this destination (so it never drifts again): since the anomalous.bot →
# Laravel cutover, the `anomalous.bot` domain is served by Caddy with
#   root * /home/michael/Sites/api.anomalous.bot/public
# so EVERYTHING at anomalous.bot/* — the DMG, the appcast, the whole site —
# is served from that one public/ dir. Release artifacts are deploy-independent
# there (they're untracked/gitignored in the app repo, so `git reset --hard`
# during a deploy never touches them). The website's /download route resolves
# whichever Anomalous-X.Y.Z.dmg is present, so publishing a new one makes every
# link current with zero markup changes.
#
# Usage:
#   ./tools/publish-release.sh                 # publish dist/Anomalous-X.Y.Z.dmg + dist/appcast.xml
#   ./tools/publish-release.sh path/to/Anomalous-0.2.0.dmg [more.dmg ...] [appcast.xml]
set -euo pipefail

DEST_HOST="michael@umacbookpro"
DEST_DIR="/home/michael/Sites/api.anomalous.bot/public"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

# Collect what to publish. Default: semver-named DMGs in dist/ (NOT the
# -macOS-arm64 duplicates — /download and the appcast key on Anomalous-X.Y.Z.dmg)
# plus dist/appcast.xml if present.
FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  shopt -s nullglob
  for f in "$HERE"/dist/Anomalous-[0-9]*.[0-9]*.[0-9]*.dmg; do FILES+=("$f"); done
  [ -f "$HERE/dist/appcast.xml" ] && FILES+=("$HERE/dist/appcast.xml")
  shopt -u nullglob
fi

[ ${#FILES[@]} -gt 0 ] || { echo "✗ nothing to publish (no dist/Anomalous-X.Y.Z.dmg or appcast.xml, and no args)"; exit 1; }

echo "▸ publishing to ${DEST_HOST}:${DEST_DIR}"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "✗ not a file: $f"; exit 1; }
  base="$(basename "$f")"
  # Guard: reject the -macOS-arm64 variant — /download can't see it and the
  # appcast keys on the clean name; publishing it just clutters public/.
  if [[ "$base" == *-macOS-arm64.dmg ]]; then
    echo "  ⚠ skipping $base (use the Anomalous-X.Y.Z.dmg name — that's what /download and the appcast reference)"; continue
  fi
  echo "  → $base ($(du -h "$f" | cut -f1))"
  scp -q "$f" "${DEST_HOST}:${DEST_DIR}/${base}"
done

echo "▸ verifying on prod"
ssh "$DEST_HOST" 'cd ~/Sites/api.anomalous.bot && php artisan site:check-downloads'

echo "✓ published. https://anomalous.bot/download → the newest DMG; https://anomalous.bot/appcast.xml → the update feed."
