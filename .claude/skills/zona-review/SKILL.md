---
name: zona-review
description: Review a Zona diff or PR with the project's load-bearing invariants front-loaded — the ZonaKit/app-target split, power-meter expiry and leg-power TCX export, HR-zone classification, ERG/HR design, and concurrency rules. Use before pushing a branch or when reviewing Zona code.
allowed-tools: Read, Grep, Bash
---

Review the code under discussion (the current diff, a named branch, or a PR) as a
Zona-aware reviewer. First run the mechanical checks, then judge the change
against the invariants below. **These invariants encode deliberate design
decisions — flag a violation of one, but do not flag the invariant itself as a
bug.**

## Diagnosing a live failure

**Observe before diagnosing.** When a change is prompted by a real failure
(especially a network or hardware one), capture the actual request/response or
device behaviour before proposing a cause. The WHOOP `HTTP 400` hunt produced two
confident, wrong diagnoses from code-reading alone; replaying the request with
`curl` against the live endpoint settled it in one step. Flag a fix whose
rationale is "reading the code suggests…" when the real artifact was obtainable.

The corollary: **don't invent error handling for a failure mode you haven't
seen.** WHOOP's dead-token classification exists because its real response was
captured and found to use `invalid_request`; writing a speculative equivalent for
another provider would encode a guess as a rule.

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

**`HealthConnectKit` is a separate repo shared with another app (Helix).** It
holds the provider-agnostic OAuth/token plumbing (`TokenStore`,
`TokenRefresher`, `FormURLEncoding`) and the Strava/WHOOP OAuth + token/DTO
types; `ZonaKit` re-exports it via `SharedOAuth.swift`.
- **If the diff touches that package, Zona's suite passing is not enough** —
  it's a change to two shipped apps. Flag a PR that modifies it without evidence
  Helix still builds — its package suite lives at
  `~/Dev/github/Health-apps/Helix/App/HelixKit`.
- **Scope rule: a file belongs there only if both apps could use it.** Flag ride
  logic pushed across the boundary — `StravaUpload` and `WhoopReadiness` stayed
  in ZonaKit precisely because an aggregator has no use for them.
- Flag a new provider's OAuth/token code added to `ZonaKit` instead of the
  shared package; that's how the second copy starts.

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
changes); the summary's interval review is display-only. Intervals are a Zone 2
feature — "Add intervals" is hidden entirely on a Zone 1 ride.

**`IntervalSession`'s decoder must stay back-compatible.** Old blobs encoding
`repeats`/`work`/`rest` are snapshotted inside `IntervalRun` on every finished
`Ride` and decoded with `try?`, so dropping the legacy path in `init(from:)`
wouldn't throw — it would silently empty the interval review on every older ride.
Legacy keys are read, never written. A blob matching *neither* shape must keep
**throwing**: `try?` then drops the run, which is honest, where decoding to an
empty session renders a fabricated "No steps · 0:00 of 0:00" card. Flag a
decoder change that removes the legacy branch or swallows an unknown shape.

Per-step achieved figures (`IntervalAchievement.perStep`) slice the sample window
by walking the same flattened `session.steps` cursor the scheduler drove ERG on —
flag any attempt to divide elapsed time by the repeat count, which drifts on a
run stopped early and misattributes samples. Every achieved figure is optional
and renders "—" when absent; flag a `?? 0`, since the crank meter expires on a
coast and averaging a gap as zero fabricates watts.

## Per-ride data invariants

**Rider-describing values are stamped onto the `Ride`, not read live at summary
time** — `weightKg`, `whoopMaxHR`/`whoopRestingHR`, and the HR-zone model. Flag a
summary that resolves any of these from current settings: it would retroactively
rewrite finished rides when the rider's weight changes or WHOOP reconnects.

**New `Ride` fields must be optional with no default** — that's what keeps the
CloudKit mirror valid and lets existing rides lightweight-migrate. Flag a
non-optional or defaulted new property.

## Sensor / recorder invariants

**The trainer is the source of truth for control.** A SRAM/Quarq power meter is a
**secondary, display+leg-power** readout on its own `powerMeterW` channel. It is
never merged into the trainer's `powerW`, never fed to ERG, and never part of the
zone math. Flag any merge of meter watts into trainer power.

**The TCX export is the one consumer that prefers leg power** (PR #136) — the
channels are still never *merged*, but `TCXPowerSource.resolve` picks one for the
whole file. Don't flag the export reading `powerMeterW`; do flag these:
- **Per-sample source selection.** Choosing per trackpoint (e.g. `powerMeterW ??
  powerW`) alternates calibration scale at every coast and dropout. The source is
  resolved once per file.
- **Dropping or loosening the coverage floor** (`TCXPowerSource.minimumCoverage`,
  80%). Without it a meter that dropped after thirty seconds flips the whole file
  to leg power, and since Strava *interpolates* missing power, a sparse track
  becomes a mostly-invented one.
- **Defaulting a gap to 0 W** (`powerMeterW ?? 0`) *in a trackpoint*. The crank
  goes quiet on a coast instead of sending a zero frame; the trackpoint must omit
  `<ns3:Watts>`. Note the deliberate exception: `TCXEnergy` **does** treat a gap
  as `?? 0`, because an energy total has to account for every second it spans —
  don't flag that one.
- **Calories drifting off the exported channel** (PR #145). `<Calories>` is
  integrated from whichever channel `resolve` picked, reusing the value
  `makeTCX` already resolved; deriving it from `powerW` unconditionally would
  state one calibration while the power track carries another. Also flag a
  coast carrying the previous second's watts forward (banks power never held),
  and any change letting a gap's *duration* migrate onto a neighbouring
  reading's watts — that last one is the rule the tests actually pin.
- **Resolving the source in a computed property.** It walks every sample —
  `RideSummaryView` resolves once into `@State` in its `.task`, the same
  compute-once rule as the chart downsampling and `IntervalReview`'s slicing.

Cadence stays trainer-sourced: crank cadence isn't recorded at all, so exporting
it needs a new per-ride field and a CloudKit-safe migration, not a one-line
change.

**The in-app summary still scores on trainer watts while Strava shows leg
power.** That asymmetry is deliberate, not a bug — flag an attempt to "reconcile"
the two figures, and flag any doc or UI string that describes the trainer as what
the ride is *uploaded* on (it's what the ride is *scored* on).

**When this rule changes, sweep the docs by identifier, not by phrasing.** #136
changed the export and needed three follow-up PRs (#137, #138, #139) to catch
stale text, because each sweep grepped the previous wording. Two of the misses
were rider-facing strings that shared no vocabulary with the code — the summary's
Avg-leg-power popover and the Setup sensors footer, the latter read at the moment
a rider decides whether to pair a meter. On any diff that changes this behaviour,
check `grep -rn powerMeterW --include="*.swift" --include="*.md"` including
**tests and SwiftUI `Text(...)` strings**, and flag a PR that updates the
behaviour without them. Note `RideMetrics.powerMeterW` is the canonical
explanation five other comments defer to with "see `RideMetrics.powerMeterW`" —
fix it first, or the referring sites silently go stale.

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

**"On target" comes from the shared `ZoneState(bpm:target:zoning:)`**, pure and
in `ZonaKit` since #148. The BPM dial's PUSH/HOLD/EASE chip, the zone bar's
outlined target segment, its tinted handle, and its VoiceOver phrase all derive
from that one value. Flag a parallel below/on/above comparison (e.g.
`activeZone == target`, or a fresh `bpmRange` containment check) — it can
disagree with the chip at a band edge, which is the beat-for-beat agreement #76
and #107 established. The handle also needs its contrast stroke to stay legible
when it sits on a same-coloured segment.

Unlike the export's compute-once rule, this one is now **tested, not just
reviewed**: `ZoneStateTests` pins the HR init against `zone(forHR:)` at every BPM
across all five targets, so a regression inside `ZoneState` fails CI. What still
needs your eyes is a *new* on-target comparison written somewhere else, which no
test can see. Two shapes to flag specifically:
- **Logic added to `ZoneState.tint`** (the app-target extension). Only the colour
  mapping belongs there; a decision made in `tint` is invisible to the suite.
- **A `ZoneState` re-declared privately in a view**, which is exactly where it
  used to live. The type is `public` — a local copy silently opts out of every
  test above.

**Scans are unfiltered (`services: nil`)** because some sensors (Garmin HRM 200)
don't advertise their service UUID; devices are classified after connecting. Flag
a switch to a filtered scan.

**Kind resolution tries `.trainer` first**, in `SensorKind.allCases` order —
never `desired`'s `Set` order, which varies per process. The Kickr also
implements the legacy Cycling Power Service, so resolving it to `.powerMeter`
lets the trainer steal that slot and, via `SensorMemoryStore.remember`,
permanently lock a real standalone meter out of it. Flag a reordering of
`SensorKind`'s cases or an iteration over `desired`.

## Accessibility invariants

**A stat tile is one VoiceOver stop.** The ride screen's `Metric` tiles and the
summary's stat tiles merge into a single element with a spoken label and value.
Flag a separately focusable info button inside a tile — it gives a rider three
stops per reading. Ambiguous titles need an explicit `spokenLabel` (the "Leg …"
vocabulary), units must be spelled out ("W" reads as a letter, "RPM"
letter-by-letter), and the "—" placeholder needs a spoken form. Explanations are
delivered as an accessibility *hint* plus a popover — flag `.help()` alone, which
is macOS-hover-only and invisible on iOS.

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

Strava and WHOOP each split into a pure half (state machine / token logic, in
`HealthConnectKit`) and an app-target I/O half. `StravaUpload` is the exception
that stayed in ZonaKit — it's a ride feature, not provider plumbing. Tokens live
in the Keychain **per-device** (no iCloud sync of tokens). Both bake the client
secret into the binary (no PKCE) — acceptable for this personal single-user
build; don't flag it as a leak, but do flag it if the code moves toward public
distribution.

**Token refresh has three regression-prone rules** (all fixed in #112). Both
providers rotate the refresh token on every use, so a duplicate refresh burns it
and a late `save()` can overwrite the good rotated token, making the failure
sticky:
- Refreshes go through `HealthConnectKit`'s single-flight `TokenRefresher`,
  which caches the in-flight `Task` **before its first suspension point**. Flag
  a refresh that reads-then-`await`s-then-saves on its own, and flag any comment
  claiming `actor` isolation alone prevents the double refresh — it doesn't,
  since the actor is released at every `await`. Both `WhoopService` and
  `StravaService` route through it; a new provider should too, not a second
  implementation.
- Form bodies use `HealthConnectKit`'s `FormURLEncoding`. Flag a hand-rolled
  `urlEncode` in an app-target service, and specifically flag percent-encoding with
  `.alphanumerics` — RFC 3986 unreserved characters (`- . _ ~`) must stay
  literal, or `grant_type` ships as `refresh%5Ftoken` and tokens get corrupted.
- A refusal the provider won't honour must **clear** the stored tokens. Flag a
  path that leaves a dead token in the Keychain: `isConnected` stays true and
  every retry replays it, wedging the account. Note WHOOP signals this as
  `invalid_request` (not `invalid_grant`) via `error_hint`, and
  `WhoopTokenErrorKind.classify` only reports a dead token for a `refresh_token`
  grant — don't "simplify" that guard away, it stops a failed auth-code exchange
  looping the rider through reconnects.

## Testing standards

**A new test earns its place by failing.** Before claiming a test covers
something, mutate the code it guards and confirm it goes red — a test that passes
against broken code is worse than none, because it advertises coverage that isn't
there. State the mutation and its failure message when reporting new coverage. If
a mutation "survives", first suspect the run was invalid (didn't compile, crashed
before asserting) rather than concluding the code is untested. Note `--filter`
matches the **type** name, not the `@Suite` display name.

**Don't add a test that restates one that exists.** A 2026-07-25 audit
(#104–#106) reviewed the suite for duplicates and removed none, so near-identical
tests are usually deliberate boundary cases, not redundancy — read them before
proposing a merge. The corollary for new code: when behaviour is already covered
generically (a shared helper's own suite), a provider-flavoured copy tests the
same code twice. Flag proposed tests that would.

**Pure logic in `ZonaKit` is testable; app-target I/O is not, by design.** Don't
flag a `Service` class for lacking unit tests — flag it for holding logic that
should have been pushed into `ZonaKit` where it could be tested.

## Docs conventions

If the diff touches Markdown, enforce both rules — each was learned from notes
that went stale within a PR or two:
- **No hard-coded test counts.** "234 tests pass" is wrong by the next PR that
  adds one. Flag it; say "unit-tested" and let CI be the authority. (A count in a
  *commit message* is fine — that's a point-in-time record, not a live doc.)
- **State how far something *was* verified, never what hasn't happened yet.**
  "Compile-verified on both platforms" and "verified on device" stay true
  permanently; "not yet observed on hardware" is false the moment the rider tries
  it and nobody goes back to fix it. Flag the forward-looking form. Verification
  level is worth recording precisely here because Zona drives real hardware — a
  passing suite and a held ERG session are different claims. Per-feature
  verification lives in `ROADMAP.md`; `App/README.md` defers to it.
- **A behaviour change must sweep the text that describes it, by identifier.**
  The prose docs are only half of it: code comments and rider-facing SwiftUI
  strings state the same rules in different vocabularies, so a phrase-based grep
  misses them (see the leg-power export above, which took three follow-up PRs).
  Flag a behaviour change that leaves a `Text(...)` telling the rider something
  the code no longer does — a wrong user-facing string outranks a wrong comment,
  since the rider can't read the code to correct it.

## Output

Report findings most-severe first: red tests and correctness bugs, then
invariant violations, then cleanup. For each, give the `file:line`, the concrete
failure scenario, and whether it's CONFIRMED or PLAUSIBLE. If a change looks like
it violates an invariant but is actually a legitimate redesign, say so rather
than reflexively blocking it — these are defaults, not laws.
