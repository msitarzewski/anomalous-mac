#!/usr/bin/env bash
# Sign the built Anomalous.app + embedded root helper with Developer ID and
# the hardened runtime (inside-out: helper before app). This is what makes
# SMAppService.daemon registration work — ad-hoc builds can't register a
# system daemon.
#
# Usage:  ./tools/sign.sh [path/to/Anomalous.app]
#         (defaults to the latest DerivedData Debug build)
set -euo pipefail

TEAM_ID="7JQGQ7CRH8"
DEV_ID="Developer ID Application: Michael Sitarzewski (${TEAM_ID})"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Anomalous-*/Build/Products/Debug/Anomalous.app | head -1)}"
[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }

HELPER="$APP/Contents/MacOS/AnomalousHelper"
[ -f "$HELPER" ] || { echo "✗ embedded helper not found: $HELPER"; exit 1; }

SIGN=(codesign --force --options runtime --timestamp --sign "$DEV_ID")

echo "▸ signing helper (inside-out first)"
"${SIGN[@]}" --entitlements "$HERE/App/Helper.entitlements" \
  --identifier "bot.anomalous.helper" "$HELPER"

echo "▸ signing app"
"${SIGN[@]}" --entitlements "$HERE/App/Anomalous.entitlements" \
  --identifier "bot.anomalous.sensor" "$APP"

echo "▸ verify"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|Identifier=" | head -6

echo "✓ signed: $APP"
echo "  Team: $TEAM_ID"
echo "  Next: launch it, click 'Enable system-wide monitoring' → approve in System Settings."
echo "  For distribution: notarize a zip of the app (see build-deployment.md)."
