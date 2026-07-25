---
name: zona-review
description: Review a Zona diff or PR with the project's load-bearing invariants front-loaded — the ZonaKit/app-target split, power-meter expiry, HR-zone classification, ERG/HR design, and concurrency rules. Use before pushing a branch or when reviewing Zona code.
allowed-tools: Read, Grep, Bash
---

Review the code under discussion (the current diff, a named branch, or a PR) as a
Zona-aware reviewer. First run the mechanical checks, then judge the change
against the invariants below. **These invariants encode deliberate design
decisions — flag a violation of one, but do not flag the invariant itself as a
bug.**

## First: mechanical checks

- Run `cd App/ZonaKit && swift test` and report failures. The **ZonaKit tests**
  check is required to merge; a red suite is the top-priority finding.
- If `App/project.yml` changed, note that `xcodegen generate` must be re-run and
  that files under `Zona/Resources/` are generated — hand-edits there are a bug.
- Scope the read to the actual diff (`git diff main...HEAD --stat`) before
  reading whole files, to keep the pass fast.

## Architecture invariants

**ZonaKit is pure and unit-tested; the app target is I/O + SwiftUI.** New
protocol/parsing/zone/recording logic belongs in `ZonaKit` with tests.
`URLSession`, Keychain, `ASWebAuthentication`, and CoreBluetooth glue belong in
the app target. Flag pure logic added to the app target that could have been
tested in ZonaKit, and flag `import`s of UIKit/Foundation-networking creeping
into ZonaKit.

**HR defines the target zone; power does the controlling.** The trainer holds a
power setpoint (FTMS ERG from FTP); HR only *defines and displays* the target
zone. A closed-loop HR→watts mode was built and deliberately removed — flag any
reintroduction of HR-driving-power.

**Interval sessions are the only mid-ride ERG writer.** Two ordering rules live
in `IntervalPlayback` and are easy to regress:
- Ending a block reverts to `preTargetW` — the target in force when the block
  *started*, captured on the countdown path too — never to `settings.target`.
  Reverting to the steady target silently discards a mid-ride `TargetAdjuster`
  trim. Flag any revert that reads settings instead of the captured value.
- `recordRun` is emitted *before* the accompanying `revert`, and callers must
  apply a returned `[Action]` **in order**. Flag a caller that reorders or
  filters them.

Interval step watts resolve from `PowerZone` via `ZoneEngine` at scheduling time
— flag raw watts stored on a step, which would stop sessions tracking FTP. The
ride is still scored end-to-end as one block (no TCX laps, no `RideSummary`
changes); the summary's interval review is display-only.

## Per-ride data invariants

**Rider-describing values are stamped onto the `Ride`, not read live at summary
time** — `weightKg`, `whoopMaxHR`/`whoopRestingHR`, and the HR-zone model. Flag a
summary that resolves any of these from current settings: it would retroactively
rewrite finished rides when the rider's weight changes or WHOOP reconnects.

**New `Ride` fields must be optional with no default** — that's what keeps the
CloudKit mirror valid and lets existing rides lightweight-migrate. Flag a
non-optional or defaulted new property.

## Sensor / recorder invariants

**The trainer is the source of truth.** A SRAM/Quarq power meter is a
**secondary, display+leg-power** readout on its own `powerMeterW` channel. It is
never merged into the trainer's `powerW`, never fed to ERG, and never part of the
zone math or Strava/TCX export. Flag any merge of meter watts into trainer power.

**The Quarq reading a few watts ABOVE the Kickr is correct** (direct crank torque
vs. flywheel estimate + drivetrain loss) — never "fix" that gap.

**Power-meter values expire after a few seconds and clear on disconnect.** A
quiet crank sends nothing rather than a 0 W frame, so:
- `RideRecorder.ingest` assigns `powerMeterW` outright (nil included), unlike the
  other scalars which nil-skip. Flag any change to nil-skip it — that would
  freeze a stale value and bank fabricated leg-power watts all ride.
- The ride screen's 1 Hz tick calls `sweepStalePowerMeter()` off its own clock
  before each ingest, so a coast expires even if the trainer also drops. Flag
  removal of that self-clocked sweep or making expiry depend on another sensor
  reporting.

**Never scan `bpmRange` bands to classify a heart-rate reading.** Bands are
inclusive at both ends and Friel Z1's floor is 0, so scanning them misclassifies
boundary values (a past bug lit Z5 at the LTHR boundary). `bpmRange` is for
DISPLAY only — including positioning the zone bar's handle *within* its segment —
and `RideHRZoning.zone(forHR:)` is the single classifier. Live in-zone time uses
`RideHRZoning.secondsInZone` so the live timer agrees with the summary.

**"On target" comes from the shared `ZoneState(bpm:target:zoning:)`.** The BPM
dial's PUSH/HOLD/EASE chip, the zone bar's outlined target segment, its tinted
handle, and its VoiceOver phrase all derive from that one value. Flag a parallel
below/on/above comparison (e.g. `activeZone == target`, or a fresh `bpmRange`
containment check) — it can disagree with the chip at a band edge, which is the
beat-for-beat agreement #76 and #107 established. The handle also needs its
contrast stroke to stay legible when it sits on a same-coloured segment.

**Scans are unfiltered (`services: nil`)** because some sensors (Garmin HRM 200)
don't advertise their service UUID; devices are classified after connecting. Flag
a switch to a filtered scan.

## Zone-model invariants

**The HR-zone model is a property of the ride**, latched at ride start
(`.lthr` or `.whoopHRR`). **WHOOP always wins when connected** — there is no
`useWhoopZones` opt-in flag; Disconnect is what reverts to LTHR. Flag any
re-added opt-in flag or any mid-ride model switch.

## Concurrency invariants (Swift 6 strict)

- `SensorHub` / `TrainerController` are `@MainActor @Observable`.
- All CoreBluetooth objects live inside `MultiBLEManager` on a dedicated BLE
  queue; only `Sendable` values cross to the main actor. Flag `@preconcurrency`
  escape hatches and any `CB*` object crossing actors.
- The UI observes `TrainerController`, whose stored properties are *republished*
  from the hub via callbacks. Flag a computed pass-through to `hub.metrics` — it
  registers no SwiftUI dependency and freezes the UI on stale values.

## OAuth invariants

Strava and WHOOP each split into a pure ZonaKit half (state machine / token
logic) and an app-target I/O half. Tokens live in the Keychain **per-device** (no
iCloud sync of tokens). Both bake the client secret into the binary (no PKCE) —
acceptable for this personal single-user build; don't flag it as a leak, but do
flag it if the code moves toward public distribution.

## Output

Report findings most-severe first: red tests and correctness bugs, then
invariant violations, then cleanup. For each, give the `file:line`, the concrete
failure scenario, and whether it's CONFIRMED or PLAUSIBLE. If a change looks like
it violates an invariant but is actually a legitimate redesign, say so rather
than reflexively blocking it — these are defaults, not laws.
