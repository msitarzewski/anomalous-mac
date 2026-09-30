# Building Anomalous

Developer notes for building the macOS sensor from source. End users don't need
any of this — just [download the DMG](https://anomalous.bot).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Foundation Models (Apple Intelligence) for the on-device judgment layer; it
  degrades to knowledge-map-only cards where unavailable.

Validation toolchain: Xcode 27.2 (`27B5019j`), Swift 6.4. The core test suite and
Release compilation pass with this toolchain; an opt-in replay of private local
history runs only when `ANOMALOUS_PRIVATE_REPLAY_DIR` is set.
This does not replace signed runtime checks on macOS 26 and 27. The deployment
target remains macOS 26; compiling the current source requires the newer SDK.
CI uses GitHub's `xcode-27` preview runner, generates the ignored Xcode project,
and records the resolved dependency lockfile with coverage artifacts. Preview
runner availability and SDK revisions can change; inspect the recorded build
number when comparing CI and local results.

## Build & run

```bash
# 1. Generate the Xcode project from project.yml
xcodegen generate

# 2. Fast core sanity check
swift build --package-path AnomalousCore
swift test  --package-path AnomalousCore

# 3. Build/run the app in Xcode (scheme: Anomalous), or from the CLI:
xcodebuild -project Anomalous.xcodeproj -scheme Anomalous -configuration Release build
```

The privileged helper requires a Developer ID signature to register as a system
daemon; the reference signing + notarization + DMG pipeline is in [`tools/`](tools/)
(secrets are read from the environment, never committed).

## Cutting a release

End-to-end checklist. Signing secrets come from `~/.config/anomalous/signing.env`
(never committed); the EdDSA appcast key lives only in the login Keychain.

1. **Bump the version** — `CFBundleShortVersionString` + `CFBundleVersion` in
   `project.yml` (**both** the app and widget targets), then `xcodegen generate`.
   Add a `CHANGELOG.md` entry.
2. **Build → sign → notarize → DMG:**
   ```
   xcodebuild -project Anomalous.xcodeproj -scheme Anomalous -configuration Release clean build
   source ~/.config/anomalous/signing.env
   ./tools/sign.sh <Release/Anomalous.app>     # Developer ID (helper first, inside-out)
   ./tools/notarize.sh <app>                   # notarytool + staple
   ./tools/make-dmg.sh <app> dist/rel-X.Y.Z    # isolated dir → one clean appcast entry
   ```
3. **Appcast + publish to prod:**
   ```
   ./tools/sparkle-appcast.sh dist/rel-X.Y.Z   # EdDSA-signs the DMG
   ./tools/publish-release.sh --verify-only dist/rel-X.Y.Z/Anomalous-X.Y.Z.dmg dist/rel-X.Y.Z/appcast.xml
   # Load ANOMALOUS_RELEASE_HOST and ANOMALOUS_RELEASE_DIR from private operator configuration.
   ./tools/publish-release.sh dist/rel-X.Y.Z/Anomalous-X.Y.Z.dmg dist/rel-X.Y.Z/appcast.xml
   ```
4. **Cut the GitHub release** — users expect the Releases tab:
   ```
   gh release create vX.Y.Z --title "Anomalous X.Y.Z" --latest \
     --notes-file <changelog-section> dist/rel-X.Y.Z/Anomalous-X.Y.Z.dmg
   ```
5. **Bump the Homebrew cask** in [`msitarzewski/homebrew-tap`](https://github.com/msitarzewski/homebrew-tap):
   set `version` + `sha256` (`shasum -a 256 dist/rel-X.Y.Z/Anomalous-X.Y.Z.dmg`) in
   `Casks/anomalous.rb` and push. Installs as `brew install --cask msitarzewski/tap/anomalous`.

Before publication, verify fresh installation and an upgrade from the previous
release on supported macOS versions. Keep the prior signed artifacts and feed
available for rollback. Signing and notarization alone do not establish runtime
compatibility.

## Backend server (optional)

Cloud triage, anonymous contribution, and account/billing talk to a backend —
but the sensor is fully useful without one: local detection, judgment, and
actions need no server. Release builds restrict backend overrides to the production
service and localhost. Debug builds accept custom HTTPS backends through
`ANOMALOUS_SERVER`. The wire contract is published in [`protocol/`](protocol/).

Release tools require an explicit `Release/Anomalous.app` path and signing fails
if its required provisioning profile is missing. Keep operator destinations and
credentials outside this public repository. Publishing checks the uploaded and
publicly downloaded DMG checksum before replacing the appcast. `--verify-only`
runs local signature, notarization, entitlement and appcast checks without a
destination or network publication. The operator must provision destination
ownership/ACLs for upload and web access; new published files use mode 0644.
