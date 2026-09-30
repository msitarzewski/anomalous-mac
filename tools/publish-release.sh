#!/usr/bin/env bash
# Publish an explicitly selected notarized DMG, then its matching Sparkle feed.
# Operator destinations belong in private environment configuration.
# Usage: ./tools/publish-release.sh [--verify-only] Release.dmg appcast.xml
set -euo pipefail

VERIFY_ONLY=false
if [ "${1:-}" = "--verify-only" ]; then VERIFY_ONLY=true; shift; fi
DMG="${1:?Pass the approved DMG}"
APPCAST="${2:?Pass its matching appcast.xml}"
[ "$#" -eq 2 ] || { echo "✗ expected one DMG and one appcast"; exit 1; }
[ -f "$DMG" ] && [ -f "$APPCAST" ] || { echo "✗ missing artifact"; exit 1; }
BASE="$(basename "$DMG")"
[[ "$BASE" =~ ^Anomalous-[0-9]+\.[0-9]+\.[0-9]+\.dmg$ ]] || { echo "✗ expected Anomalous-X.Y.Z.dmg"; exit 1; }
# Validate the signed/notarized container, its app, and the exact feed contract.
# Keep this validation inline: it belongs to this publication boundary.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
python3 -I - "$DMG" "$APPCAST" "$HERE" <<'PYCAST'
import base64, datetime, pathlib, plistlib, subprocess, sys, tempfile
import urllib.parse, xml.etree.ElementTree as ET

artifact = pathlib.Path(sys.argv[1]).resolve()
repo = pathlib.Path(sys.argv[3])
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(sys.argv[2]).findall('./channel/item')
assert len(items) == 1, 'Use an isolated appcast containing one release'
item = items[0]
e = item.find('enclosure')
assert e is not None, 'Missing enclosure'
u = urllib.parse.urlparse(e.attrib['url'])
assert u.scheme == 'https' and u.netloc == 'anomalous.bot'
assert u.path == '/' + artifact.name and not u.query and not u.fragment
assert int(e.attrib['length']) == artifact.stat().st_size
signature = e.attrib[ns + 'edSignature']
assert len(base64.b64decode(signature, validate=True)) == 64

def run(*args):
    return subprocess.check_output(args)

run('xcrun', 'stapler', 'validate', str(artifact))
requirement = 'anchor apple generic and certificate leaf[subject.OU] = "7JQGQ7CRH8" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
run('codesign', '--verify', '--strict', '-R', requirement, str(artifact))
with tempfile.TemporaryDirectory(prefix='anomalous-release-check-') as mount:
    mounted = False
    try:
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, str(artifact))
        mounted = True
        applications = pathlib.Path(mount) / 'Applications'
        assert applications.is_symlink() and str(applications.readlink()) == '/Applications', 'Missing Applications install target'
        app = pathlib.Path(mount) / 'Anomalous.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        assert info['CFBundleIdentifier'] == 'bot.anomalous.sensor'
        assert artifact.name == 'Anomalous-' + info['CFBundleShortVersionString'] + '.dmg'
        for field, key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString')]:
            value = e.attrib.get(ns + field) or item.findtext(ns + field)
            assert value == str(info[key]), 'Appcast/app mismatch: ' + field
        assert item.findtext(ns + 'minimumSystemVersion') == info['LSMinimumSystemVersion'], 'Minimum OS mismatch'
        run('codesign', '--verify', '--deep', '--strict', '-R', requirement, str(app))
        run('xcrun', 'stapler', 'validate', str(app))
        run('spctl', '--assess', '--type', 'execute', str(app))
        for binary, entitlement_file in [
            (app, 'App/Anomalous.entitlements'),
            (app / 'Contents/MacOS/AnomalousHelper', 'App/Helper.entitlements'),
            (app / 'Contents/Extensions/AnomalousWidget.appex', 'Widget/AnomalousWidget.entitlements'),
        ]:
            run('codesign', '--verify', '--strict', '-R', requirement, str(binary))
            executable = binary
            if binary.is_dir():
                binary_info = plistlib.loads((binary / 'Contents/Info.plist').read_bytes())
                executable = binary / 'Contents/MacOS' / binary_info['CFBundleExecutable']
            assert 'arm64' in run('lipo', '-archs', str(executable)).decode().split(), 'Missing Apple Silicon executable'
            details = subprocess.run(['codesign', '-dv', '--verbose=4', str(binary)], capture_output=True, check=True).stderr.decode()
            assert 'runtime' in details, 'Hardened runtime required: ' + str(binary)
            entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', str(binary)))
            expected = plistlib.loads((repo / entitlement_file).read_bytes())
            for key, value in expected.items():
                assert entitlements.get(key) == value, 'Entitlement mismatch: ' + key
            for key in ['com.apple.security.get-task-allow', 'get-task-allow', 'com.apple.security.cs.disable-library-validation', 'com.apple.security.cs.allow-dyld-environment-variables']:
                assert not entitlements.get(key), 'Unsafe release entitlement: ' + key
        profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')))
        assert profile['ExpirationDate'] > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired provisioning profile'
        assert '7JQGQ7CRH8' in profile['TeamIdentifier']
        assert profile['Entitlements'].get('com.apple.developer.usernotifications.time-sensitive') is True
        key = info['SUPublicEDKey']
        assert len(base64.b64decode(key, validate=True)) == 32
        # CryptoKit verifies the actual DMG bytes against the key sealed in the app.
        with tempfile.TemporaryDirectory(prefix='anomalous-swift-cache-') as compiler_cache:
            subprocess.run(['xcrun', 'swift', '-module-cache-path', compiler_cache, '-', str(artifact), key, signature], input=b"""
import Foundation
import CryptoKit
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[2])!)
let signature = Data(base64Encoded: args[3])!
let artifact = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: artifact) else {
    fputs("Invalid Sparkle artifact signature\\n", stderr)
    exit(1)
}
""", check=True)
    finally:
        if mounted:
            run('hdiutil', 'detach', mount)
PYCAST
if [ "$VERIFY_ONLY" = true ]; then
  echo "✓ artifact, app signatures, entitlements, notarization and appcast verified"
  exit 0
fi
: "${ANOMALOUS_RELEASE_HOST:?Set the SSH destination in private operator configuration}"
: "${ANOMALOUS_RELEASE_DIR:?Set the absolute public artifact directory}"
[[ "$ANOMALOUS_RELEASE_HOST" =~ ^[A-Za-z0-9_.@-]+$ && "$ANOMALOUS_RELEASE_HOST" != -* ]] || exit 1
[[ "$ANOMALOUS_RELEASE_DIR" =~ ^/[A-Za-z0-9_./-]+$ ]] || exit 1
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
# The operator must provision a directory writable by the SSH user and readable
# by the web server. New artifacts use 0644; directory ownership/ACLs stay intact.
DEST="$ANOMALOUS_RELEASE_HOST:$ANOMALOUS_RELEASE_DIR"
scp -q "$DMG" "$DEST/$BASE.uploading"
REMOTE_SHA="$(ssh "$ANOMALOUS_RELEASE_HOST" "sha256sum '$ANOMALOUS_RELEASE_DIR/$BASE.uploading'" | awk '{print $1}')"
[ "$SHA" = "$REMOTE_SHA" ] || { echo "✗ uploaded artifact checksum mismatch"; exit 1; }
ssh "$ANOMALOUS_RELEASE_HOST" "chmod 0644 '$ANOMALOUS_RELEASE_DIR/$BASE.uploading' && mv '$ANOMALOUS_RELEASE_DIR/$BASE.uploading' '$ANOMALOUS_RELEASE_DIR/$BASE'"
# Check public delivery before making the update discoverable.
PUBLIC_SHA="$(curl --fail --silent --show-error "https://anomalous.bot/$BASE" | shasum -a 256 | awk '{print $1}')"
[ "$SHA" = "$PUBLIC_SHA" ] || { echo "✗ public artifact checksum mismatch; feed unchanged"; exit 1; }
scp -q "$APPCAST" "$DEST/appcast.xml.uploading"
ssh "$ANOMALOUS_RELEASE_HOST" "chmod 0644 '$ANOMALOUS_RELEASE_DIR/appcast.xml.uploading' && mv '$ANOMALOUS_RELEASE_DIR/appcast.xml.uploading' '$ANOMALOUS_RELEASE_DIR/appcast.xml'"
echo "✓ published $BASE and its appcast"
