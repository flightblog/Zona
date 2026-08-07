# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Zona is a SwiftUI (iOS + macOS) app for steady heart-rate-zone indoor riding: it
holds a Wahoo Kickr Core 2 at a steady power (ERG) over Bluetooth while the rider
aims for a target HR zone, records the ride, and keeps local history. Verified on
real hardware (Kickr Core 2 + Garmin HRM 200) on iOS and macOS.

Repo layout:
- `App/` — the app: `ZonaKit` (pure, unit-tested Swift package) + the SwiftUI
  target. This is where almost all work happens.

## Commands

```sh
# One-time setup after cloning
brew install xcodegen
cd App && xcodegen generate      # generates Zona.xcodeproj from project.yml (not committed)

# ZonaKit depends on HealthConnectKit by relative path until that repo is
# published, so it must be checked out as a sibling of Zona:
#   ~/Dev/github/{HealthConnectKit, Zona}
git -C ~/Dev/github clone https://github.com/flightblog/HealthConnectKit.git

# That relative path is why `git worktree` needs one extra step: a worktree
# created outside ~/Dev/github can't see the sibling, and `swift test` fails
# with "the package at '…/HealthConnectKit' cannot be accessed" — a path
# error, not a broken dependency. Symlink it next to the worktree:
#   ln -s ~/Dev/github/HealthConnectKit <worktree-parent>/HealthConnectKit

# Run the app
open App/Zona.xcodeproj          # pick the "Zona" scheme, set signing, run

# Test the core logic (fast, no signing needed)
cd App/ZonaKit && swift test                              # full suite
swift test --filter ZonaKitTests                          # one test target
swift test --filter ZonaKitTests.RideRecorderTests/testX   # one test

# Command-line build (needs a signing team to actually *run*, see below)
xcodebuild -project App/Zona.xcodeproj -scheme Zona -destination 'platform=macOS' build
```

CI (`.github/workflows/`) runs `swift test` in `App/ZonaKit` on macOS on every PR
and push to `main`; the **ZonaKit tests** check is required to merge. It does not
build/run the app target.

To verify a change in the running app, use a **signed macOS build** (see the
unsigned-build note below — an unsigned one compiles but crashes at launch):

```sh
xcodebuild -project App/Zona.xcodeproj -scheme Zona -destination 'platform=macOS' \
  build DEVELOPMENT_TEAM=<YOUR_TEAM_ID> CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates
```

A SourceKit `No such module 'ZonaKit'` diagnostic while editing app-target files
is usually a stale-index artifact, not a real error — confirm with a real build
before chasing it.

## Workflow

Work lands on a branch via PR, never directly on `main`. Squash-merge and delete
the branch (`gh pr merge <n> --squash --delete-branch`), then `git fetch --prune`
— the repo is kept main-only with no lingering merged branches. Wait for the
required **ZonaKit tests** check before merging (`gh pr checks <n> --watch`).

**A green check is not the same as mergeable — read `mergeStateStatus`.** Branch
protection here is `strict`, so a branch must also be *up to date with `main`*.
`gh pr checks` can report `pass` while the merge is refused, and the refusal
reads `Required status check "ZonaKit tests" is expected` — which looks like a CI
or workflow-syntax failure and isn't one. The real signal:

```sh
gh pr view <n> --json mergeStateStatus -q .mergeStateStatus
# CLEAN → merge. BEHIND → gh pr update-branch <n>, then wait for CI on the new head.
# BLOCKED → usually CI still running; re-check before assuming anything else.
```

**Code and docs ship as separate PRs**, code first, docs immediately after
(#122→#123, #118→#119, #116→#117, #114→#115). The docs PR updates whichever of
`CLAUDE.md` / `App/README.md` / `ROADMAP.md` the change invalidates. Keep this
split rather than folding docs into the code PR.

That split has one recurring cost worth planning for: **the docs PR is always
stale by the time its code half merges**, and in two different ways. If it
branched off `main`, it comes back `BEHIND` (see above). If it branched off the
*code branch* so it could describe the finished behaviour, the squash-merge
leaves it carrying a duplicate of code already on `main` — `gh pr diff <n>
--name-only` still lists the code files. Fix that by rebasing onto the merged
main and force-pushing, then confirm it's docs-only before merging:

```sh
git rebase --onto main <code-branch-sha>   # drops the already-merged commit
git diff main...HEAD --stat                # must show docs files only
git push --force-with-lease
```

**Branch names are `<type>/<kebab-case-summary>`** — `feat/zone-bar-target-marker`,
`fix/whoop-concurrent-token-refresh`, `docs/roadmap-oauth-hardening`,
`tests/coverage-gaps`, `refactor/ride-settings-state`, `a11y/metric-voiceover-labels`.
Those six types cover everything so far; add another only when none fits. Name the
change, not the file touched, and keep it short enough to read in `gh pr list`.

Two things you'll see in the history that aren't the convention: bare unprefixed
names (`interval-step-list`, `sram-own-row`) are the older style, still common up
to ~#111 and superseded from #104 onward — don't imitate them. And `claude/*`
branches with a random suffix are generated when work is started from the GitHub
/ web agent rather than chosen; renaming one isn't worth a force-push, but don't
create them by hand.

Commit messages and PR bodies here run long by design: they explain *why*, name
the failure mode a change prevents, and record what was deliberately **not** done
and on what evidence. Several invariants in this file were recovered from commit
messages, so treat them as the durable record. Test counts are fine in a commit
message (a point-in-time record) but not in a doc — see Docs conventions.

**The Xcode project is generated, not committed.** `App/project.yml` is the
source of truth for the project, `Info.plist`, and entitlements — re-run
`xcodegen generate` after editing it, and never hand-edit files under
`Zona/Resources/` (they're overwritten on generate).

**Unsigned builds crash on launch, not just fail to build.** Zona opens a
CloudKit-mirrored SwiftData store at launch and needs a provisioning profile for
the `iCloud.org.flightblog.zona` container; an unsigned build compiles fine but
hits `EXC_BREAKPOINT` in CloudKit before any window draws. Running from Xcode
with a signing team set handles this; from the CLI pass
`DEVELOPMENT_TEAM=<id> CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates`.

## Architecture

**`ZonaKit` (pure, no UI, unit-tested) vs. the `Zona` app target (I/O + SwiftUI).**
This split is the main thing to preserve: BLE decoding, zone math, ride
recording/summarizing, TCX export, and HRV (RMSSD) live in `ZonaKit` and are
unit-tested; the pure OAuth/token logic for Strava and WHOOP lives in the shared
`HealthConnectKit` package (see below) and is unit-tested there. The app target
supplies the networking, Keychain, and UI glue around that pure core (e.g.
`StravaService` wraps `ZonaKit`'s `StravaUpload` state machine with
`URLSession`; `WhoopService` does the same for WHOOP). When adding a new
integration, keep protocol/parsing logic testable in `ZonaKit` and put
`URLSession`/`Keychain`/`ASWebAuthentication` calls in the app target.

**The same "pure decision logic in ZonaKit, thin `@Observable` wrapper in the
app" shape recurs throughout** — recognize it before adding logic anywhere else:
`TrainerController` wraps `SensorHub`, `RideSettings` wraps `RideSettingsState`
(all ride-input decisions — FTP/zone targets, zone-sync, WHOOP-vs-LTHR
resolution via `RideSettingsState.zoning`, rider weight — live in the pure
struct; the app class just persists it to `UserDefaults` on every mutation),
`IntervalLibrary` wraps `IntervalLibraryState`, and
`StravaUploadModel`/`WhoopModel` wrap the `StravaUpload`/WHOOP state machines.
`RideView`'s interval playback follows the same split without an `@Observable`
class: the pure `IntervalPlayback` struct is held in `@State` and the view just
applies the `Action`s it returns (see below). Put new decision logic in the
`ZonaKit` half so it's unit-testable without running the app; the wrapper should
do little more than persist/publish it.

**Design: HR defines the target zone, power does the controlling.** The trainer
can only hold a *power* setpoint (FTMS ERG, from FTP); HR lags and drifts too
much to close the loop on directly. So the ride is power-steady while HR is used
only to *define and display* the target zone (from LTHR, or from WHOOP's
HRR-derived zones if connected). A closed-loop HR→watts mode was built and then
deliberately removed — don't reintroduce it without discussion.

**Interval sessions are the one thing that moves ERG mid-ride, and they revert
to the *pre-block* target.** A session is a free-form ordered `[IntervalStep]`
(so warmups, ramps and pyramids are expressible; a uniform `4×30/30` is just
eight steps, with repeat structure implicit in the list) whose watts resolve from
`PowerZone` via `ZoneEngine` at scheduling time — never stored as raw watts, so a
session follows the rider's FTP. Intervals are a **Zone 2 feature**: on a Zone 1
ride "Add intervals" is hidden entirely (End ride spans the bottom row alone),
since Zone 1 is recovery-steady with no interval mode.

**`IntervalSession`'s decoding is back-compatible and must stay that way.**
Sessions are persisted twice: the library in `UserDefaults`, and — the
load-bearing one — snapshotted inside `IntervalRun` on every finished `Ride`, so
a later library edit can't restate history. Blobs written before the step list
encode `repeats`/`work`/`rest`, and `Ride.intervalRuns` swallows a decode failure
as `[]` — so dropping the legacy path in `init(from:)` wouldn't throw, it would
silently empty the interval review on every older ride. Legacy keys are read,
never written, so a re-saved session migrates forward. A blob matching *neither*
shape deliberately **throws**: that same `try?` then drops the run entirely,
which is honest, where decoding it to an empty session would render a card
reading "No steps · Stopped early · 0:00 of 0:00" — fabricated history.

Repeat structure is implicit in the list, but `IntervalSession.isUniformSet` /
`repeatPosition(ofStep:)` still *detect* the common `n × (work, rest)` shape so
the ride HUD can count reps ("Rep 3 of 4 · REST") instead of steps — mid-set the
rider wants to know how many hard efforts remain, not a step index. That
detection lives in `ZonaKit` where it's tested; the view only picks a string.
Note it requires `work != rest`, so an all-identical session isn't mistaken for a
work/rest set. `IntervalPlayback` (pure,
`ZonaKit`) owns the whole `idle → countdown → running → idle` lifecycle as one
enum rather than the correlated optionals `RideView` used to hold, and returns
`Action`s (`setWatts` / `revert` / `recordRun`) for the view to apply **in
order**. Two rules are encoded there and are easy to regress:
- Ending a block reverts to the ERG target that was in force when the block
  *started* — captured as `preTargetW`, including the countdown path — not to
  `settings.target`. That's what lets a mid-ride `TargetAdjuster` trim survive an
  interval.
- `recordRun` is always emitted *before* the accompanying `revert`, so the
  finished run banks against the right state.

Choosing a session arms a cancelable 15s "get ready" countdown before the first
block drives ERG.

**Both ways out of an interval session confirm before firing, and the flags live
in `RideView`.** Neither is undoable from the ride screen, so each raises an
alert rather than acting on the first tap, the same guard End ride has. Their
wording distinguishes them from End ride ("The ride keeps recording" / "Your
steady target is unchanged").

They sit in **different places, by phase.** While a block runs, "Stop intervals"
takes over the bottom row's "Add intervals" slot (#154) — orange, beside the red
End ride: that slot's button was otherwise a greyed-out "Add intervals", giving
the widest control on the screen to something that did nothing, when the only
thing wanted from it mid-block is the way out. Orange because both neighbours are
spoken for — it's not the ride-ending red, nor the idle blue whose place it takes
— and the label and `stop.fill` icon change too, so colour isn't carrying the
distinction alone. During a *countdown* the bottom row keeps showing the disabled
"Add intervals" and Cancel stays in the HUD: a second control reading "Stop
intervals" for a session that hasn't started would ask the rider to tell two
similar-sounding outs apart mid-effort. The HUD had its own duplicate stop button
until #154; it was removed rather than left alongside the new one, since both
raised the same alert.

Three things here are easy to regress:
- `endInterval` stays the **single path** into `playback.stop`; the button
  callback only raises a flag. `endRide` calls `endInterval()` directly to bank
  an in-flight block before `finish()` locks the recording, and must not be
  routed through a confirmation the rider has already answered.
- The stale-flag check is **per-phase — two tests, not one**: `!isRunning`
  lowers the stop flag, `!isCounting` the countdown flag. A single `!isRunning`
  would clear the countdown flag on the very tick that raised it, since playback
  isn't running *during* a countdown.
- **The countdown confirmation races a clock and deliberately doesn't win.** The
  countdown keeps ticking while the alert is up and `cancelCountdown` guards on
  `.countdown`, so a Cancel tapped at 0:03 and answered four seconds later gets
  the block anyway. Don't "fix" that by pausing the countdown — an unanswered
  alert would then stall a session indefinitely, which is worse. The tick just
  dismisses the alert when the countdown fires, so it never sits over a block
  that is already driving ERG; the stop confirmation is the backstop.

Runs that happened are persisted per-ride (`IntervalRun`, a
JSON blob in `Ride.intervalRunsData`) and reviewed on the summary — display only;
the ride is still scored as one block. That review shows both the prescription
and what was *achieved*: `IntervalAchievement.perStep` (pure, `ZonaKit`) slices
the run's sample window per work/rest step by walking the same flattened
`session.steps` cursor `IntervalScheduler` drove ERG on — never by dividing
elapsed time by the repeat count, which would drift on a run stopped early and
misattribute samples to the wrong repeat. Every achieved figure is optional and
renders "—" when absent: a step with no readings must not report 0, since the
crank meter expires on a coast and a strap can drop, and averaging a gap as zero
fabricates watts the rider never held.

**`SensorHub` manages multiple independent BLE sensors over one
`CBCentralManager`**, keyed by `SensorKind` (`trainer` / `heartRate` /
`powerMeter`), each using its standard GATT service (FTMS `0x1826`, Heart Rate
`0x180D`, Cycling Power `0x1818`). The trainer is the source of truth for ride
data; a connected SRAM/Quarq power meter is a **secondary** readout whose watts
are recorded on their own channel (as the rider's leg power, surfaced on the ride
summary) but are never merged into the trainer's power or fed to ERG — the
trainer alone drives ERG and the zone math. Its cadence stays display-only.

**The one thing leg power *does* feed is the TCX export.** A finished ride
uploads the crank meter's watts when the meter covered at least
`TCXPowerSource.minimumCoverage` (80%) of the ride's samples, and the trainer's
otherwise. Outdoor rides are recorded from the crank meter, so exporting the
trainer's post-drivetrain-loss estimate left a rider's Strava history mixing two
calibrations depending on where they rode. Two rules keep that honest and are
easy to regress:
- **One channel per file, chosen once** (`TCXPowerSource.resolve`), never
  per-sample. Preferring leg power wherever it happens to be present would swap
  calibration scale at every coast, producing a track that alternates between two
  scales — worse for Strava's power curve and NP than either source used
  consistently.
- **The coverage floor is what makes that safe.** A bare "was a meter paired?"
  test would let a meter that dropped after thirty seconds flip the whole file to
  leg power, leaving most trackpoints with no `<ns3:Watts>` — and Strava
  *interpolates* missing power rather than recording none, so a nearly-empty
  track becomes a nearly-invented one. Below the floor the ride reverts entirely
  to trainer watts, which stream continuously (real 0 W frames included).

Gap seconds inside a qualifying ride omit `<ns3:Watts>` rather than exporting 0.
Cadence stays trainer-sourced regardless: crank cadence isn't recorded at all
(`RideSample`/`RideSampleModel` have a single `cadenceRpm`), so an exported
trackpoint deliberately pairs leg-power watts with trainer-derived cadence.
Note the consequence — the in-app summary still scores the ride on trainer watts
while Strava shows the higher figure for that same ride.

**`<Calories>` is derived from that same chosen channel** (`TCXEnergy`, pure and
in `ZonaKit`), so a file's stated energy can't imply one calibration while its
power track carries another — and a reader deriving kJ from the trackpoints
lands where `<Calories>` already sits. Zona measures nothing metabolic: the
figure is mechanical work integrated over time, divided by a 24% gross
efficiency constant, which is why kJ ≈ kcal here as in every head unit. The
element read a hard-coded 0 until #145, which anything reading the file directly
(TrainingPeaks, intervals.icu) imported as a zero-energy session. Two rules,
both easy to regress:
- **A coasted second is zero work, never the previous second's watts carried
  forward** — the crank meter goes quiet instead of sending a 0 W frame, so
  carrying forward banks power the rider never held. (Counting that second as
  zero and skipping it are arithmetically the same, since intervals span adjacent
  *samples* rather than adjacent readings; don't add a test claiming otherwise.)
- **A gap's duration stays put** rather than migrating onto a neighbouring
  reading's watts. That's the rule with teeth, and what the tests actually pin.

`<TotalTimeSeconds>` is separate and already correct: it uses the ride's true
`durationSec`, deliberately *not* the last sample's index, since samples can lag
the stop by a second or more and Strava's imported duration must match what Zona
shows.

Unlike the trainer's fields the meter's values are
**expired after a few seconds** without a reading (and cleared on disconnect): a
quiet crank meter sends nothing rather than a 0 W frame, and the 1 Hz recorder
would otherwise bank a frozen value all ride. Because that expiry must not depend
on some *other* sensor still reporting to trigger it, the ride screen's 1 Hz tick
calls `sweepStalePowerMeter()` off its own clock before each ingest — so a coast
expires on time even if the trainer drops too. `RideRecorder.ingest` also assigns
`powerMeterW` outright (nil included) rather than nil-skipping it like the other
scalars, so an expired meter clears the second instead of freezing it. See
`RideMetrics.powerMeterW`.
Notable behaviors baked into it, worth knowing before touching connection logic:
- Scans are **unfiltered** (`services: nil`) and devices are classified by their
  actual GATT services after connecting — some sensors (Garmin HRM 200 included)
  don't advertise their service UUID, so a filtered scan would miss them.
- An 8s watchdog cancels a stalled `connect(_:)`, since CoreBluetooth's own call
  never times out.
- Sensors auto-reconnect on drop (HR straps disconnect on idle to save battery)
  and the first-seen device of each kind is remembered (`SensorMemoryStore`) for
  next session.
- A ride won't *start* without both the trainer (in ERG) and an HR strap
  connected, but once started the session latches — a transient mid-ride sensor
  drop doesn't eject back to setup.
- Kind resolution (from an advertised service, or from the full GATT service
  list once connected) always tries `.trainer` first, in `SensorKind.allCases`
  order — never `desired`'s Set order, which varies by process. Some trainers
  (the Kickr included) also implement the legacy Cycling Power Service for
  compatibility with power-only head units, so a single peripheral can satisfy
  both `.trainer` and `.powerMeter`; resolving it to `.powerMeter` would let the
  trainer itself grab that slot (and, via `SensorMemoryStore.remember`,
  permanently lock the real standalone meter out of it on every future ride).

**One classifier decides every HR zone, and one state decides "on target".**
`RideHRZoning.zone(forHR:)` is the *only* thing that turns a BPM reading into a
zone — `bpmRange` is for display and for positioning the zone bar's handle
*within* its segment, never for classification. Bands are inclusive at both ends
and Friel Z1's floor is 0, so scanning them to classify misreads every rounded
band edge (a past bug lit Z5 at the LTHR boundary). Likewise, whether the rider
is below/on/above target comes from the shared `ZoneState(bpm:target:zoning:)` —
the BPM dial's tint, the zone bar's outlined target segment and
tinted handle, and its VoiceOver phrase all read that one value. Don't add a
parallel `activeZone == target` comparison anywhere: the whole point is that the
dial, the zone bar, the live "In zone" timer, and the summary's time-in-zone
agree beat-for-beat.

`ZoneState` is **pure and in `ZonaKit`** (#148), so that agreement is unit-tested
rather than review-enforced: its HR init is checked against `zone(forHR:)` at
every BPM across all five targets, since this failure is always a single boundary
beat. It lived as a `private enum` inside `RideView.swift` until then, which left
the rule real but unenforceable — and unreachable from the summary, which agrees
by calling `RideHRZoning.zone(forHR:)` directly. Only `ZoneState.tint` stays in
the app target, as an extension: it returns a SwiftUI `Color`, the same
pure-math/app-paints split `HRZone.color` uses. Don't move `tint` into the
package to reunite them — SwiftUI in `ZonaKit` is what the split exists to avoid.

**The gauges show that state as tint only — the PUSH/HOLD/EASE chip is gone**
(#158). Each `ZoneGauge` carried a tinted capsule reading "↑ PUSH" / "✓ HOLD" /
"↓ EASE" beneath it until then; it repeated what the ring above it already said,
three times across the row, and mid-effort the rider is reading the numbers. It
was never a control — a common misreading, since "chip" and "button" look alike
in a screenshot — so removing it took no action away. `ZoneState.cue` was
deleted with it rather than left as dead `public` API.

Worth knowing before restoring anything there: that chip was the gauges' only
non-colour cue. The zone bar still has two (the target segment's outline, the
active zone's bolded label) and the bar's VoiceOver value still speaks the
relation ("on target" / "below target Z2"), so nothing regressed for a screen
reader — but a rider reading only the dials now has tint alone. If that needs
answering, the answer is a glyph inside the ring, not a fourth row of text under
it; the row's vertical budget is what the removal bought.

**A stat tile is one VoiceOver stop, and units are spelled out.** The ride
screen's `Metric` tiles and the summary's stat tiles both merge into a single
accessibility element with a spoken label and value ("Avg power: 210 W"), because
the visual rows lean on position and unit to disambiguate and that doesn't
survive being read aloud — three tiles all announcing "SRAM" is the failure this
fixed. Tiles whose visible title is ambiguous pass an explicit `spokenLabel`
("Leg power" / "Leg cadence" / "Leg watts per kilogram"), reusing the same
*leg*-power vocabulary the summary and these docs use for that channel. Spell
units out (VoiceOver reads "W" as a letter and "RPM" letter-by-letter) and give
the "—" placeholder a spoken form ("No reading") so it isn't announced as
punctuation or skipped. On the summary, a tile's explanation is its
accessibility *hint*, not a separately focusable button — that would give a rider
swiping the grid three stops per reading instead of one.

**Explanatory text uses a popover, not `.help()` alone.** `.help` is a macOS-only
hover affordance and would be invisible on iOS, where a summary is most likely to
be read; the summary keeps both, so macOS still gets hover. Any tile whose
meaning isn't obvious from its label (Avg vs. Normalized, and the leg-power
tiles, whose blurbs also explain that the gap above the trainer's watts is
drivetrain loss rather than an error) carries one.

**Concurrency (Swift 6, strict).** `SensorHub` / `TrainerController` are
`@MainActor @Observable`. All CoreBluetooth objects (`CBCentralManager`,
`CBPeripheral`, `CBCharacteristic`) live inside a private `MultiBLEManager` on a
dedicated BLE queue; only `Sendable` values (bytes, decoded structs, UUID
strings, names) cross to the main actor. No `@preconcurrency` escape hatches.
The UI observes `TrainerController`, not `SensorHub` directly — the controller
holds real stored properties (`metrics`, connection state) that are
*republished* from the hub via `onMetricsChange`/`onStateChange` callbacks. A
computed pass-through to `hub.metrics` would register no SwiftUI dependency and
freeze the UI on stale values — don't reintroduce one.

**The OAuth/token plumbing lives in `HealthConnectKit`, a package shared with
another app.** `TokenStore`, `TokenRefresher`, `FormURLEncoding`, and the
Strava/WHOOP OAuth + token/DTO types are not in this repo — they're in
[HealthConnectKit](https://github.com/flightblog/HealthConnectKit), which Helix
(a multi-source health aggregator) depends on too. They were already written
provider-agnostically here, and a second copy would eventually re-inherit the
refresh and encoding bugs below. `ZonaKit` re-exports the package
(`SharedOAuth.swift`), so `import ZonaKit` still sees every one of those types
and no app-target file changed for the move.

Three things follow from that:
- **A change there is a change to two shipped apps** — build both before
  merging.
- **The scope rule is "both apps could use it."** `StravaUpload` and
  `WhoopReadiness` stayed here because they're Zona ride features, not provider
  plumbing. Don't push ride logic across, and don't add Helix-shaped aggregation
  logic to it either.
- It lives at `flightblog/HealthConnectKit` (private), but `ZonaKit/Package.swift`
  still resolves it by **relative path to a sibling checkout**, not by URL — so a
  fresh clone needs `~/Dev/github/HealthConnectKit` present to build. CI checks it
  out alongside, using the `HEALTHCONNECTKIT_TOKEN` secret because the default
  `GITHUB_TOKEN` can't read another private repo. Moving to a versioned URL
  dependency is a deliberate separate step; a comment in the manifest marks it.
- **That secret is a PAT, and it expires.** When it does, CI here *and* in Helix
  breaks at once on the `Check out HealthConnectKit` step, with a message naming
  neither the token nor its expiry — `Input required and not supplied: token`,
  the same thing it says when the secret is missing entirely. **If the required
  ZonaKit tests check goes red on that step and the diff doesn't explain it,
  check the PAT before reading any code.** It reads like a workflow-syntax error
  and isn't one.

**Two optional OAuth integrations follow the same shape**, each with a pure
package half and an app-target I/O half: Strava (upload finished rides) and
WHOOP (use its HR zones, reconstructed from max/resting HR via HRR/Karvonen, as
the ride target instead of manual LTHR; also surfaces today's recovery as an
advisory zone suggestion, `WhoopReadiness` — never changes settings; and supplies
the rider's body weight for W/kg). Both need credentials in the gitignored
`App/Zona/Config/Secrets.xcconfig` (copy from
`Secrets.example.xcconfig`); the corresponding UI section simply hides when
credentials aren't configured. The interactive OAuth leg and the Keychain
storage are **shared, provider-agnostic code**, not duplicated per provider:
`OAuthAuthenticator` drives `ASWebAuthenticationSession` given just an
authorize URL and a callback parser, and `KeychainTokenStore<Tokens>` is one
generic Keychain-backed store keyed by a per-provider `service` string
(`org.flightblog.zona.strava` / `.whoop` — load-bearing, existing users' tokens
live under those exact strings). Tokens are per-device (no iCloud sync — the
refresh token rotates on every use, so syncing it would let two devices
invalidate each other's). Both accept a client secret baked into the binary (no
PKCE on either provider's token endpoint) — acceptable for a personal
single-user build, not for public distribution.

**Refreshing those tokens has three hazards, all fixed once and easy to
reintroduce.** Both providers rotate the refresh token on every use, so a second
refresh with the same token fails *and* a late `save()` can overwrite the good
rotated one, making the failure sticky rather than self-clearing:
- **An `actor` alone does not serialize a refresh.** Actor isolation holds only
  across synchronous regions; a refresh that `await`s the network POST releases
  the actor and lets a second caller re-read the still-unrotated token. WHOOP hit
  this because `fetchZonesAndRecovery` issues two GETs concurrently.
  `HealthConnectKit`'s generic `TokenRefresher` actor caches the in-flight `Task`
  so later callers join it — **the cache is assigned before the first suspension
  point**, which is the whole fix. Both services route their refresh through it —
  extend it rather than hand-rolling a second refresh in a new provider.
- **Form bodies must leave RFC 3986's unreserved characters literal.** Encoding
  with `.alphanumerics` looks conservative but is malformed: it sent `grant_type`
  as `refresh%5Ftoken` and corrupted any refresh token containing `-`, `.` or `_`.
  One tested `FormURLEncoding` in `HealthConnectKit` serves both providers (keys
  sorted so the body is deterministic and therefore testable) — don't hand-roll a
  second `urlEncode` in an app-target service.
- **A dead refresh token must clear the stored tokens, not wedge the account.**
  Leaving it in the Keychain keeps `isConnected` true, so every retry replays the
  same dead credential with no way out but a Disconnect the rider has no reason to
  suspect. Note WHOOP answers `invalid_request` — *not* the standard
  `invalid_grant` — for this, putting the only signal in `error_hint`;
  `WhoopTokenErrorKind.classify` reads that, and deliberately only reports a dead
  token for a `refresh_token` grant so a failed authorization-code exchange can't
  send the rider round a reconnect loop that wouldn't help.

**Values that describe the rider are stamped onto the ride, not read live at
summary time.** `weightKg` (for watts-per-kilogram) joins `whoopMaxHR` /
`whoopRestingHR` / the HR-zone model in this: each `Ride` carries what was true
when it was ridden, so a later weight change or a WHOOP reconnect doesn't
retroactively rewrite old summaries. All of them are **optional with no default**
— that's what keeps them CloudKit-safe and lets existing rides lightweight-migrate;
follow that pattern for any new per-ride field. Weight itself resolves
WHOOP-over-manual via `RideSettingsState.effectiveWeightKg` (holding WHOOP's
number *is* the decision to use it, the same shape as the HR zones), and the one
division lives in `ZonaKit`'s `PowerPerWeight` so the live tile and the summary
can't drift apart.

**Data**: rides are stored with SwiftData and synced across the user's own
devices via a private iCloud/CloudKit container. Outbound networking is limited
to the optional Strava upload and the optional WHOOP fetch; Zona does not use
the Wahoo Cloud API.

See `App/README.md` for the full source-tree map, Strava/WHOOP setup steps, and
the roadmap; `ROADMAP.md` at the repo root tracks longer-term app-level plans.

**Docs conventions.** Two rules, both learned from notes that went stale a PR or
two after they were written:
- **No hard-coded test counts.** "234 tests pass" is wrong by the next PR that
  adds one. Say "unit-tested" and let CI be the authority.
- **State how far something *was* verified, never what hasn't happened yet.**
  "Compile-verified on both platforms" and "verified on device" stay true
  permanently; "not yet observed on hardware" is false the moment the rider tries
  it, and nobody goes back to correct it — it silently understates the app.
  Verification level matters here because Zona drives real hardware, so a passing
  test suite and a held ERG session are genuinely different claims: record which
  one you have. When device confirmation later arrives, upgrading the line is a
  real improvement, but let it ride along with the next PR touching that file
  rather than opening one just to flip a status. `ROADMAP.md` is where
  per-feature verification lives; `App/README.md` describes what the app does and
  defers to it, so entries there don't each need their own status.
