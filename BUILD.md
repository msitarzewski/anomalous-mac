# Building Anomalous

Developer notes for building the macOS sensor from source. End users don't need
any of this — just [download the DMG](https://anomalous.bot).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Foundation Models (Apple Intelligence) for the on-device judgment layer; it
  degrades to knowledge-map-only cards where unavailable.

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

> Steps 4–5 are the easy ones to forget — they were missing through 0.2.1.

## Backend server (optional)

Cloud triage, anonymous contribution, and account/billing talk to a backend —
but the sensor is fully useful without one: local detection, judgment, and
actions need no server. Set the backend host with the `ANOMALOUS_SERVER`
environment variable (default `https://api.anomalous.bot`) to point the app at
your own self-hosted backend. The wire contract every backend must speak is
published in [`protocol/`](protocol/).
