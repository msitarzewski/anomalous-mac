# Network disclosure

Measurement, detection, baselines, and on-device explanations run on your Mac.
The app has no advertising trackers or analytics SDK. Optional contribution,
process discovery, and paid help do send data as described below.

| Destination | Purpose and data | When |
|---|---|---|
| anomalous.bot | Sparkle update feed and signed application downloads | Automatic update checks or Check for Updates |
| api.anomalous.bot | Signed process-identity feed; no process list in the request | Periodic refresh |
| api.anomalous.bot | Anomaly signature: process identity, versions, anomaly shape, hardware model identifier (for example Mac16,5) and timestamp | After explicit contribution consent; disable in Privacy settings |
| api.anomalous.bot | Unknown-process discovery: name, bundle ID, versions, install source, anomaly type | After discovery confirmation; disable automatic discovery in Privacy settings |
| api.anomalous.bot | Paid Get Help: bundle ID, app and OS versions, hardware model identifier, anomaly type, install source, an allowlisted diagnosis summary and metric curves, with account authentication | Explicit Get Help action |
| api.anomalous.bot | Account registration, authentication, balance and checkout creation | Account and billing actions |
| Apple | App Attest registration and request attestation for contribution and discovery | When these features require attestation |
| Stripe (browser) | Checkout and payment processing | When adding prepaid funds |

Contribution and discovery omit account tokens, paths, command-line arguments,
usernames, and hostnames. This does not hide the connection's IP address from
network infrastructure. Paid help is account-linked and uses a direct authenticated
request, not an oblivious relay. Server-side research and help use AI providers
and external cited websites.

Signature, discovery, and triage request bodies are written to the local send
log before transmission. Server JSON records can be compared by field; they are
not a guarantee of preserving byte order or whitespace from the original body.
Account credentials are not part of that diagnostic send log.

Private Cloud Compute integration is present but inactive in the direct-download
release. It sends no PCC requests. On-device explanations and explicit paid help
are the active explanation tiers.

Release builds constrain backend overrides to the production service or local
development hosts. Debug builds support custom HTTPS backends. See BUILD.md.
With contribution and discovery disabled and no account activity, the remaining
routine connections are software-update and signed corpus-feed checks.
