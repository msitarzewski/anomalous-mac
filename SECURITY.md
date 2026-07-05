# Security Policy

Thanks for taking the time to look. Anomalous ships a **privileged helper that runs as root** and can **terminate processes**, and it composes **payloads that leave the machine**. Security is core to the product — the sensor is open source precisely so this can be audited. Reports, large or small, are very welcome.

## Supported versions

| Version | Supported |
|---------|-----------|
| `0.1.x` | Yes       |

Pre-1.0 project on macOS 26 (Apple Silicon). The latest released line receives security fixes.

## Reporting a vulnerability

Email **msitarzewski@gmail.com** with:

- A clear description of the issue and the impact you believe it has
- Steps to reproduce, or a proof-of-concept
- The version / commit you tested against
- Your name or handle if you'd like credit (optional)

Please do **not** open a public GitHub issue for security reports.

## Response time

Best-effort (this is an independent project):

- **Acknowledgement:** within 7 days
- **Initial assessment:** within 14 days
- **Fix or mitigation plan:** within 30 days for high/critical findings

## Scope

The interesting attack surface is the **privileged helper** and the **data that leaves the machine**. In scope:

**Privileged helper (`bot.anomalous.helper`, runs as root):**
- Driving the helper's XPC interface (root-wide sampling or **process termination**) from a process that is **not** the genuine, Team-ID-`7JQGQ7CRH8`-signed app — i.e., bypassing `setCodeSigningRequirement` client pinning.
- Causing the helper to terminate an **unintended** process — e.g., defeating the **pid-reuse guard** (the helper re-reads the live start time and must refuse on mismatch) to kill a process that reused a pid.
- Any privilege escalation to root through the helper, its LaunchDaemon plist, or the `SMAppService` registration/approval flow.
- Getting the app or helper to run code from an attacker-controlled path (embedded-helper path substitution, plist tampering).

**Data leaving the machine:**
- Any **identifiable** data (filesystem paths, process arguments, command lines, hostnames, usernames) escaping in an **escalation/triage payload** or an **anomaly signature** beyond the documented allowlist and published [`protocol/`](protocol/) schemas. Command lines in particular must never leave — they carry credentials.
- A divergence between what the app **sends** and what it records in the local **send log** (the auditability guarantee).
- De-anonymization of telemetry, or any path that links an anonymous anomaly signature to an account.
- Leakage of the triage **bearer token** / account credentials out of their storage.
- SSRF or unexpected outbound requests from the app.

**Updates (once shipped):**
- Acceptance of a **tampered or unsigned in-app update** (Sparkle EdDSA verification bypass).

**General:** remote code execution in the app or helper; memory-safety issues reachable across the XPC boundary.

### Out of scope

- Vulnerabilities in **macOS**, the **Foundation Models** framework, `libproc`, `SMAppService`, or other Apple/system components — report those to Apple.
- Actions a **same-UID** process performs with the **user's own** privileges (a process already running as you can do what you can do). **Note:** escalating from user to **root** via the helper is explicitly *in* scope — that's the line that matters here.
- The behavior of processes Anomalous merely *observes* (a real runaway daemon is not our vulnerability).
- The closed recon/triage **backend** — it is a separate service; report backend issues to the same address but they are not part of this repository.
- Attacks requiring physical access to an unlocked machine, or social engineering.

## Disclosure policy

Coordinated disclosure, **90-day** default. If a fix needs longer, the reporter and maintainer can agree on an extension before the embargo expires. Once a fix ships, the report can be cross-linked from the changelog.

## Security posture

- The root helper vends **only** a Mach XPC service and pins clients to Team ID `7JQGQ7CRH8` (`NSXPCConnection` `setCodeSigningRequirement`) — no local process except the genuine signed app can drive it.
- Termination enforces a **pid-reuse guard**: the helper re-reads the target's start time and refuses if it doesn't match the caller's expectation — a confident wrong kill is worse than no kill.
- The app degrades gracefully without the helper (unprivileged, user-only sampling); root is never *required*.
- Escalation payloads are **composed on-device**, allowlisted by construction, and **logged byte-for-byte** locally before sending; command lines and paths never leave.
- Telemetry is **anonymous by schema** (published in `protocol/`), never account-linked; the send log is diffable against this source.
- Developer ID signed, hardened runtime, notarized; the helper is embedded and signed inside-out.

## Hall of Fame

Reporters who have responsibly disclosed security issues:

<!-- Add as: Name (handle) — short description, fix in commit/PR link -->

*(empty — be the first)*
