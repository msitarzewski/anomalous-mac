# Changelog

All notable changes to the Anomalous macOS sensor. Dates are release dates;
`0.2.0` is the current unreleased build (`CFBundleVersion` 6).

## 0.2.0 — the "vibes" release *(unreleased)*

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
  then files into a local incident history.

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
