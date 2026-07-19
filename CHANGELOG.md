# Changelog

All notable changes to the Anomalous macOS sensor. Dates are release dates;
`0.2.3` (`CFBundleVersion` 9) is the latest release.

## 0.2.3 *(2026-07-19)*

Free-tier discovery now works in production.

### Fixed
- **Anonymous discovery + contribution now use real App Attest.** Every
  anonymous request (identity discovery for an unknown process, and signature
  contribution) previously carried a placeholder attestation, which the
  fail-closed production API rejected — so free-tier discovery silently failed
  ("Couldn't reach the service") for every shipped build. The app now performs
  genuine `DCAppAttestService` attestation: it registers a Secure-Enclave key
  once, then signs each request with a per-request assertion the server
  verifies. No API posture was weakened to make this work.

## 0.2.2 *(2026-07-17)*

Crash fix + graceful degradation for Macs without Apple Intelligence.

### Fixed
- **Launch crash on some macOS 26.5.x Macs** ([#3](https://github.com/msitarzewski/anomalous-mac/issues/3)).
  The app strong‑linked a FoundationModels symbol present only in newer
  framework builds, so on 26.5.1/26.5.2 stable it aborted in dyld at launch
  ("Symbol not found") before any code ran. FoundationModels is now **weak‑
  linked**, so a missing symbol resolves to null at load instead of crashing;
  all on‑device‑AI use was already availability‑gated, so nothing calls it on
  an incapable Mac. Confirmed fixed on 26.5.1/26.5.2, no regression on macOS 27.

### Added
- **"Apple Intelligence recommended" notice.** When Apple Intelligence isn't
  available, the Welcome window now explains — honestly — that diagnosis cards
  come from the built‑in knowledge map and everything else works the same,
  instead of leaving you wondering why cards look generic.

## 0.2.1 *(2026-07-15)*

Post-`0.2.0` hardening and polish.

### Security
- **CSV export hardened against spreadsheet formula injection.** A field
  beginning with `=`, `+`, `-`, `@`, TAB, or CR is executed as a formula by
  Excel/Numbers/Sheets; the exported history carries untrusted values (a
  process's own name, an LLM‑written summary), so those fields are now
  neutralized (leading apostrophe) before RFC‑4180 escaping. A failed CSV
  save now surfaces an error instead of silently doing nothing.

### Changed
- **Larger default text in the history dashboards.** Primary reading content —
  process‑name identifiers, incident descriptions, and the By‑Process summary
  line — now renders at body size for readability. Secondary chrome
  (timestamps, counts, pills) is unchanged, and all text still scales with the
  system Accessibility Text Size setting.

## 0.2.0 — the "vibes" release *(2026-07-14)*

The jump from a CPU‑and‑RAM watcher to a Mac that can tell you **what's wrong,
what it is, and what to do** — and stay silent when nothing is. Everything below
is new since `0.1.3`.

### Sees your whole Mac, not just CPU & RAM
- Per process, every check: sustained **and** cumulative CPU, **physical‑footprint
  memory** (the honest number, not RSS), disk I/O, **energy** (nanojoules, P‑core
  vs E‑core split), **wakeups** (the real battery‑drain signal), **per‑process
  GPU** utilization & memory, **per‑process network** throughput, and
  Neural‑Engine memory — plus system context (memory pressure, swap, thermal,
  load). Most of it read from calls the OS was already making.

### Explains, in plain language, on‑device
- Diagnosis cards written by Apple's **Foundation Models**, grounded by a reviewed
  process corpus — *what it is · why it's probably hot · is this normal · what to
  do.* The classical detector decides; the model only phrases the verdict over
  the exact numbers, and never invents identities or facts.
- **Three‑tier escalation**, cheapest first: on‑device → Apple **Private Cloud
  Compute** → paid **Get Help** cloud triage with cited evidence (only on an
  explicit tap).
- **Discovery engine** — for an unknown process, an anonymous identity lookup that
  fails safe to "unknown" rather than guessing.
- **Signed corpus feed** (Ed25519), verified locally before it's trusted.

### A redesigned diagnosis card
- **Progressive disclosure** — the collapsed card is just the tier icon, process
  name, and a one‑line verdict; the plain‑English explanation and the action
  buttons live behind **Details**. The stack scrolls (and never runs off‑screen)
  when several fire at once.
- Tier shown as an **icon in front of the name** (tap for a popover with the
  tier + a plain description); **Get Help** as a glowing footer CTA; a **⋯ card
  menu** for *Normal for me*, *Snooze*, and *Check again*.
- **Check again (Verify)** — re‑checks the **live** metric so a card that's
  actually calmed down clears in about a second, instead of waiting ~45 minutes
  for the window/median to decay. Great right after you take the recommended
  action. Plus a **"first flagged" timestamp** on each card.

### Learns your normal
- Robust **median/MAD** baselines, **seasonal** hour‑of‑day / weekday buckets,
  cross‑dimension correlation (one insight, not five notifications), a warm‑up
  gate, and a per‑alert **confidence** score — only high‑confidence findings ever
  reach you.
- **"Normal for me"** *raises the envelope* for a process instead of muting it;
  **Snooze** for an hour or a day; and the **anti‑mute** guarantee — if something
  you accepted comes back materially worse, or misbehaves in a new way, you hear
  about it.
- **Card auto‑resolve + Journal** — a cleared card shows a brief "resolved" state,
  then files into a local incident history. A process that clears and re‑trips
  now reads its true saga from that history — **"first flagged … · returned N×"**
  — instead of resetting to a fresh one‑minute blip each time.

### Review what it's caught
- **Anomaly History window** (menu‑bar gear → *Anomaly History…*, or Settings) —
  a private, on‑device review of everything Anomalous has caught. **Overview**
  is a dashboard: how many incidents, what types happen most, how they resolved
  (most clear on their own), a trend over time, and your most‑flagged processes —
  over a **Day / Week / Month / Unlimited** range. **By Process** drills into any
  one process: a chart of its incidents over time and a timeline of every episode,
  so you can see whether something keeps misbehaving or whether a fix held.
- **You control the depth and the data** — keep the last 250 / 1,000 / 5,000 /
  25,000 / Unlimited incidents (default 1,000), **Export** the whole history to a
  CSV you choose, or **Clear** it. It never leaves your Mac; clearing the logbook
  doesn't touch detection or your learned baselines.

### Lives quietly in the OS
- **Ambient desktop widget** — "All systems nominal" at rest, comes to life only
  on a confirmed anomaly, with Snooze / Normal‑for‑me right in the tile.
- **Siri · Shortcuts · Control Center** via App Intents ("Is my Mac behaving
  normally?").
- **Notifications with discipline** — passive by default; a confirmed,
  high‑confidence anomaly posts **Time Sensitive** to break through Focus, with
  Investigate / Snooze / Normal‑for‑me inline. Recomposed to be scannable, not a
  wall of text.
- **Energy‑aware adaptive sampling** — the base cadence adapts to power (~60s on
  wall power, ~90s on battery) and backs off ×3 under thermal pressure or Low
  Power Mode. Measured **~0.4% CPU** on a busy Mac, **0% between checks**.

### Acts, conservatively
- Safety tiers gate the action: one‑click **Quit / Restart**, **Force Quit**
  behind an explicit confirmation, `brew services` stop/restart, root‑daemon
  termination via the helper, or an explain‑only card for things you must not
  touch.
- **Privileged root helper** — installed with one System Settings approval (never
  a password prompt) to watch and safely stop root daemons like dasd and
  WindowServer, where the worst runaways hide. Self‑heals across updates.
- **First‑run onboarding** — a brief, skippable setup that explains the helper
  and the two opt‑in flows (anonymous signatures, unknown‑process lookup) in
  plain language, each linking to its help page; informed defaults, not a gate.

### Accounts & paid triage
- Invite‑gated accounts, a prepaid balance, and **Stripe** top‑up. When Get Help
  needs balance, the card offers **Add credit** (→ Account), not a dead‑end retry.
  Every payload that leaves is allowlisted and logged locally byte‑for‑byte, and
  the server mirrors exactly what it received so you can diff the two.

### Privacy, transparency & updates
- Detection, judgment, baselines, acknowledgments, and the journal stay
  **on‑device**. Nothing identifiable leaves; the open‑source client plus a local
  send log let you verify exactly what's sent. Auto‑updates via **Sparkle**
  (EdDSA‑signed feed).

### Fixes & hardening
- **Get Help** now works for every anomaly kind — fixed the empty‑`metric_curves`
  422 (GPU / wakeups / disk anomalies) and the scalar‑baseline 422 (sustained‑CPU
  / leak anomalies); honest escalation errors instead of a catch‑all "couldn't
  reach the service."
- **Channel‑variant identity** — `dev.zed.Zed‑Preview` and friends reuse the base
  app's record instead of the model inventing "a preview tool."
- **Leak heal gate** — a process that ballooned then stabilized auto‑resolves
  instead of pinning a card for an hour.
- **Baseline‑poisoning fix** — catches chronically‑hot runaways (e.g.
  appstoreagent) that spike‑only rules and a poisoned baseline both miss.
- **Warm, plain voice** — user‑facing text says "quit it," not "kill"; "macOS
  starts it back up," not "respawns."
- **Duration grammar** — "for 1 hour," not "for 1 hours."
- Security: tested termination‑guard and server‑override policies, helper
  self‑heal, honest CPU‑cost documentation.

## 0.1.3 — 2026‑07‑04

- Fixed the detection→UI pipeline so genuinely‑detected anomalies actually
  surface (a five‑bug pile‑up, each masking the next). Live‑proven on real dasd
  and appstoreagent runaways.
- Settings **About** tab; a single‑image red active menu‑bar mark.

## 0.1.2 — 2026‑07‑04

- Installer polling fix; Liquid‑Glass‑era Settings; dropped the dev Server line.

## 0.1.1 — 2026‑07‑04

- Security hardening: hardened the root helper's XPC trust boundary; moved the
  account token to the Keychain; HTTPS‑only bearer.

## 0.1.0 — 2026‑07‑04

- Initial public release — the open‑source macOS sensor.
