# Anomalous Wire Protocol

Platform-neutral from day one: the macOS sensor is the first implementation; the Windows sensor (ETW/perf counters) is a later sibling **speaking these same schemas**. `platform` fields everywhere; process identity is abstract (pid + start-time is the macOS *implementation*, never the schema).

| Schema | Flow | Notes |
|---|---|---|
| [anomaly-signature.schema.json](anomaly-signature.schema.json) | **Anonymous** (free tier's only transmission) | Structurally anonymous — no user/path/hostname/cmdline fields exist. App Attest attests the *sensor build*, never the user. |
| [known-issues-feed.schema.json](known-issues-feed.schema.json) | Public pull | Whole-feed pull, match locally. Never per-incident lookup. |
| [partner-manifest.schema.json](partner-manifest.schema.json) | Public registry | "We measure; you annotate." Modes raise thresholds, never exempt. |
| [triage-payload.schema.json](triage-payload.schema.json) | **Account-linked** (paid) | Composed on-device; byte-logged client-side; mirrored server-side; OHTTP relay transport. |

Versioning: every schema carries `schema_version` (currently `0.1.0`). Breaking changes bump minor pre-1.0; the server accepts N and N-1.

Not yet specified (deliberately — design exists in `../memory-bank/seed.md`): the local partner **state channel** (XPC + localhost transports, `setMode` protocol), the OHTTP relay envelope, and the DiagnosisCard JSON shape (currently authoritative as the `@Generable` Swift struct in `../sensor`; extract to JSON Schema when the backend provider lands).
