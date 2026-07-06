# Network disclosure — every URL the app contacts

Anomalous is quiet on the network by design. **Measurement, detection, judgment,
and the on-device AI all run entirely on your Mac** — the app reaches out only
for the few things below, and **never to any third party: no analytics, no
telemetry, no trackers.**

Nothing identifiable ever leaves the machine. Every payload that *does* leave is
composed on-device from an **allowlist** and written to the app's **local send
log** first, so you can diff the exact bytes against what the server received.

| Host | What for | When |
|------|----------|------|
| **anomalous.bot** | **Software updates** (Sparkle) — fetches `appcast.xml` and downloads the signed `.dmg` if you update. Update payloads are **EdDSA-signed and verified** before install. | Periodic automatic check, and when you pick "Check for Updates…". |
| **api.anomalous.bot** | **Process-identity corpus** (grounding feed) — periodically fetches the reviewed known-process feed that grounds diagnosis cards. The feed is **Ed25519-signed and verified locally** before it's trusted; a tampered or unsigned feed is rejected and the last verified copy (or the shipped corpus) stands. This is a plain download — **no data about you is sent**, just the request. | Roughly once a day, in the background. |
| **api.anomalous.bot** | **Anonymous signature contribution** — an attested, never-account-linked signature (process name, version, OS, anomaly shape). Never paths, arguments, ownership, or anything identifiable; every send is in the local send log. | Only if contribution is enabled. |
| **api.anomalous.bot** | **Get Help — cloud triage** (tier 3, paid) — sends an allowlisted diagnosis payload for a hard-to-judge process and returns an expert card with cited evidence. The exact bytes are logged locally first (diffable against the server's payload mirror). | Only when you're signed in **and** tap "Get Help". Never automatic. |
| **api.anomalous.bot** | **Account & billing** — opens Stripe Checkout for a prepaid top-up and reads your balance. Payment happens in your browser via Stripe; the app never sees card details. | Only when you add funds or view your account. |
| **Apple — Private Cloud Compute** | **Escalated reasoning** (tier 2) — for a hard or novel anomaly the on-device model can't confidently ground, the *same* allowlisted, on-device-composed reasoning is sent to Apple's Private Cloud Compute for a stronger answer. **Key-less, no account, and covered by Apple's verifiable no-storage privacy guarantees.** Engages only when the build carries Apple's PCC entitlement; otherwise escalation stays on-device or waits for an explicit Get Help tap. | Automatically, only for low-confidence / novel cards, only when enabled. |
| **Apple** | **App Attest** — device attestation that keeps anonymous contribution sybil-resistant without identifying you. On-device **Apple Intelligence** (tier 1) needs **no network** for the free judgment tier. | Attestation accompanies contribution. |

The backend host is configurable via `ANOMALOUS_SERVER` — point it at your own
server and the app talks only to you.

**The quietest possible posture:** with contribution off, no account, and the
Private Cloud Compute tier disabled, the app's only outbound connections are the
signed software-update check and the signed grounding-feed pull — both to
`anomalous.bot` infrastructure, both verified before use, neither carrying
anything about you.
