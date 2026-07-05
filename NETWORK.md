# Network disclosure — every URL the app contacts

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
