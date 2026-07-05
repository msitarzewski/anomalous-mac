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

## Backend server (optional)

Cloud triage, anonymous contribution, and account/billing talk to a backend —
but the sensor is fully useful without one: local detection, judgment, and
actions need no server. Set the backend host with the `ANOMALOUS_SERVER`
environment variable (default `https://api.anomalous.bot`) to point the app at
your own self-hosted backend. The wire contract every backend must speak is
published in [`protocol/`](protocol/).
