# Contributing to Anomalous

Thanks for considering a contribution. This project is small, opinionated, and deliberately open. The bar for landing changes is "does it match the patterns already here, keep the trust model intact, and not break anything" — not "have you signed paperwork."

This repo is the **macOS sensor** (the on-device client). The recon/triage backend and the aggregate network are separate, closed services — changes here should assume the backend is a black box reached over the published [`protocol/`](protocol/).

## TL;DR

1. Fork the repo, create a topic branch off `main`.
2. Make your change. Keep it small and focused.
3. Run the checks (below).
4. Open a PR with a short description of what changed and why.

**No CLA. No rights assignment.** Your contributions remain yours, licensed under [Apache-2.0](./LICENSE) to match the project. By opening a PR you confirm you wrote the change or have the right to contribute it under that license.

## Dev setup

Prereqs:

- **macOS 26 (Tahoe)** or later, **Apple Silicon**
- **Xcode 26+** (`xcode-select -p` should point at `Xcode.app`, not just Command Line Tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

Loop:

```sh
git clone https://github.com/<your-fork>/anomalous-mac
cd anomalous-mac
xcodegen generate                        # regenerate Anomalous.xcodeproj from project.yml
swift build --package-path AnomalousCore  # fast core compile
swift test  --package-path AnomalousCore  # unit tests (Swift Testing)
xcodebuild -project Anomalous.xcodeproj -scheme Anomalous -configuration Release build
```

Run the app in Xcode (scheme **Anomalous**). It's a menu-bar app (`LSUIElement`) — no Dock icon; look in the menu bar. Local detection, judgment, and actions work with no server and no account.

## Project structure

```text
anomalous-mac/
├── App/                          the SwiftUI menu-bar app
│   ├── Sources/                  AnomalousApp, AppState, AnomalyListView, Settings, HelperClient
│   ├── Resources/AppIcon.icon    Liquid Glass app icon (Icon Composer)
│   ├── Resources/Assets.xcassets menu-bar template marks
│   ├── LaunchDaemons/            the privileged helper's LaunchDaemon plist
│   └── *.entitlements
├── AnomalousCore/                the portable engine (Swift Package)
│   └── Sources/
│       ├── AnomalousCore/        Collector, Detection, KnowledgeMap, Judgment, Escalation, Helper protocol
│       └── AnomalousHelper/      the root helper (runs as an SMAppService.daemon)
├── protocol/                     the published wire schemas (client ⇄ backend)
├── tools/                        sign / notarize / make-dmg / make-pkg
├── landing/                      the anomalous.bot marketing site
└── project.yml                   XcodeGen source of truth (the .xcodeproj is generated)
```

## How to add behavior

The pipeline is **collector → detection → judgment → action**. Extend the stage that fits:

1. **Detection rule** — add to the rules in `AnomalousCore/Sources/AnomalousCore/Detection/`. Rules must be conservative (long windows, high thresholds) — a false positive gets the app deleted.
2. **Daemon knowledge** — extend the curated map in `AnomalousCore/Sources/AnomalousCore/KnowledgeMap/knowledge-map.json`. Only add an entry you can ground honestly (identity, safety tier, what-hot-implies). Never guess.
3. **Judgment** — the on-device model fills a typed `@Generable` diagnosis card; ground it with tools/map entries, never free-form assertions.
4. **Action** — new actions go through the safety-tiered `ProcessActuator`. A confident wrong action is worse than none.

Add focused tests alongside (mirror the existing `AnomalousCoreTests`).

## The trust model — do not weaken it

These are load-bearing. Changes that touch them need explicit discussion:

- **The root helper** pins XPC clients to the app's Team ID and enforces a **pid-reuse guard** before terminating. Don't loosen `shouldAcceptNewConnection`, and never remove the start-time re-check.
- **Nothing identifiable leaves the machine.** Payloads are composed on-device from an allowlist — no paths, arguments, command lines, usernames, or hostnames. If you add a transmitted field, it must be allowlisted and reflected in `protocol/` and the local send log.
- **The send log** records every transmission byte-for-byte before it's sent. Keep logged == sent.
- Telemetry signatures are **anonymous by schema** and never account-linked.

## Tests

```sh
swift test --package-path AnomalousCore
```

## Code style

- Swift: match the surrounding code (naming, comment density, idiom). `@MainActor`/`@Observable` for UI state; keep XPC reply/error handlers off the main actor.
- Prefer extending existing types over new abstractions.
- Keep UI copy plain and operational — the audience includes non-technical users. Layer geeky detail *and* a plain-language summary; never one at the expense of the other.

## PR guidance

Include: what changed, why, screenshots for UI changes, the test commands you ran, and any platform verification you couldn't do.

**Easy PRs:** docs fixes, tests for existing behavior, accessibility fixes, focused bug fixes with a reproduction, conservative knowledge-map additions.

**Discuss first:** anything touching the **privileged helper or XPC boundary**, **entitlements**, **what leaves the machine** (payload/telemetry fields), **signing / notarization / release**, new network hosts, or new dependencies.

## Security

Found a vulnerability? **Do not open a public issue.** See [SECURITY.md](SECURITY.md) and email msitarzewski@gmail.com.

## Code of conduct

Be direct, kind, and specific. Disagree about the work, not the person.
