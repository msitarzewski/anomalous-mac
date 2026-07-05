# Anomalous — macOS sensor

**[anomalous.bot](https://anomalous.bot)** · **[Download](https://anomalous.bot/Anomalous-0.1.0.dmg)** · **[Sponsor ♥](https://github.com/sponsors/msitarzewski)**

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-1b1113) ![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-1b1113) ![License](https://img.shields.io/badge/license-Apache--2.0-c1121f)

**Activity Monitor with a "So what?" and "Now what?" layer.**

<p align="center">
  <img src="media/diagnosis-cards.png" width="460"
       alt="Anomalous menu-bar popover: two detected anomalies — appstoreagent (~76% CPU for hours) and dasd (100% for hours) — each with a plain-language diagnosis card, safety tier, and a Quit action.">
</p>

macOS shows you *what* is using CPU and memory. It never tells you whether that's
*normal*, what the process actually *is*, or what to *do* about it. Anomalous is
that judgment layer: a quiet menu-bar app that watches your Mac, stays silent when
nothing is wrong, and surfaces a plain-language diagnosis card when something
genuinely is — with a safe action to take.

This repository is the **macOS sensor** — the on-device client. It is open source
on purpose (see *Why this is open* below). The recon/triage backend and the
aggregate signal network are **separate services and are not part of this
repository**; the sensor is useful entirely on its own, offline, with no account.

---

## What it does

- **Detects** runaway processes with rolling per-process baselines — sustained CPU
  over long windows, monotonic memory growth, cumulative-time ratios — the
  signatures that snapshot tools like Activity Monitor miss.
- **Judges** each anomaly on-device with Apple's Foundation Models framework,
  grounded by a curated knowledge map of macOS daemons, producing a typed
  diagnosis card: *what it is · why it's probably hot · is this normal · what to do*.
- **Acts**, conservatively and with safety tiers: Quit / Force Quit user processes,
  `brew services` stop/restart, or an explain-only card for things you shouldn't kill.
- **Sees root daemons** (dasd, WindowServer, …) via an optional privileged helper —
  the place the worst runaways hide — installed with one System Settings approval,
  never a password prompt.
- **Escalates** (optional, account-based) to a cloud triage service for novel issues
  the on-device stack can't ground. Every payload is composed on-device, allowlisted,
  and **logged locally byte-for-byte** before it leaves.

## Why this is open

The sensor is open source because **trust is the product**. Anyone can read exactly
what is collected and what is transmitted; the send log in the app is diffable
against this source. Nothing identifiable ever leaves the machine, and you don't
have to take our word for it — you can read the code that composes every payload.

The value of the wider product lives *upstream* (curated diagnosis, the aggregate
observatory, the reviewed known-issues feed), so the client is free, inspectable,
and embeddable. Partners are welcome to build on it under the Apache-2.0 license.

## Architecture

```
Collector (always on, cheap)  →  Detection rules  →  Judgment (on-device LLM + knowledge map)
      libproc sampling                baselines            @Generable diagnosis card
                                                                   │
   Privileged helper (root)  ─ fills root-owned gaps ──────────────┤
      XPC, Team-ID-pinned                                          │
                                                          Action layer (safety tiers)
                                                                   │
                                              Escalation client → (separate backend)
                                                 allowlisted payload + local send log
```

- `AnomalousCore/` — the portable engine: collector, detection, knowledge map,
  judgment, escalation/ingest clients, the helper XPC protocol. Platform-neutral
  where it can be; the wire protocol lives in [`protocol/`](protocol/).
- `App/` — the SwiftUI menu-bar app (`MenuBarExtra`, `LSUIElement`), Settings,
  history, and the privileged-helper client.
- `AnomalousCore/Sources/AnomalousHelper/` — the root helper (runs as a
  `SMAppService.daemon`; samples and terminates root-owned processes only).

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon.
- Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- Foundation Models (Apple Intelligence) for the on-device judgment layer;
  degrades to knowledge-map-only cards where unavailable.

## Building from source

Developer setup, the build/sign/notarize pipeline, and backend configuration
are in **[BUILD.md](BUILD.md)** — end users don't need any of it, just the
[download](https://anomalous.bot).

## Support

Anomalous is free and open source. If it saves you a debugging session, consider
**[sponsoring on GitHub](https://github.com/sponsors/msitarzewski)** — sponsorship
funds the curation (the daemon knowledge map, the reviewed known-issues feed) that
makes the free tier better for everyone.

More native macOS tools from the same workshop — small, fast, open, no telemetry:
**[Brew Browser](https://brew-browser.zerologic.com)** (a GUI for Homebrew) ·
**[Agency Agents](https://agencyagents.app)** (a control surface for AI agent personas).

## Network disclosure — every URL the app contacts

Anomalous is quiet on the network by design. Detection, judgment, and actions
run entirely on-device; the app reaches out only for the few things below, and
**never to any third party — no analytics, no telemetry, no trackers.**

| Host | What for | When |
|------|----------|------|
| **anomalous.bot** | **Software updates** (Sparkle) — fetches `appcast.xml`, and downloads the signed `.dmg` if you update. Update payloads are **EdDSA-signed and verified** before install. | Periodic automatic check, and when you pick "Check for Updates…". |
| **api.anomalous.bot** | **Anonymous signature contribution** — an attested, never-account-linked signature (process name, version, OS, anomaly shape). Never paths, arguments, or anything identifiable; every send is written to the app's local send log. | Only if contribution is enabled. |
| **api.anomalous.bot** | **Cloud triage ("Get expert help")** — sends an allowlisted diagnosis payload for a hard-to-judge process and returns an expert card. The exact bytes are logged locally first (diffable against the server mirror). | Only when you're signed in **and** tap "Get expert help". |
| **api.anomalous.bot** | **Account & billing** — opens Stripe Checkout for a prepaid top-up and reads your balance. Payment happens in your browser via Stripe; the app never sees card details. | Only when you add funds or view your account. |
| **Apple** | **App Attest** (device attestation for anonymous contribution). On-device **Apple Intelligence** needs no network for the free judgment tier. | Attestation accompanies contribution. |

The backend host is configurable via `ANOMALOUS_SERVER` — point it at your own and
the app talks only to you. With contribution off and no account, the app's only
outbound connection is the signed software-update check to `anomalous.bot`.

## Security

Anomalous runs a **root helper** that can sample and terminate processes, and it composes payloads that leave the machine — so security reports are genuinely welcome. See **[SECURITY.md](SECURITY.md)** for scope and the coordinated-disclosure process, and email **msitarzewski@gmail.com** (please don't open a public issue for vulnerabilities).

## License

[Apache License 2.0](LICENSE) — © 2026 Michael Sitarzewski.

*"Anomalous" and the Anomalous mark are trademarks; the license grants no trademark
rights (see LICENSE §6). Fork the code freely; ship your fork under its own name.*
