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
recording/summarizing, TCX export, HRV (RMSSD), and the pure OAuth/token logic
for Strava and WHOOP all live in `ZonaKit` and are unit-tested. The app target
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
to the *pre-block* target.** A session is `repeats × (work, rest)` steps whose
watts resolve from `PowerZone` via `ZoneEngine` at scheduling time — never stored
as raw watts, so a session follows the rider's FTP. `IntervalPlayback` (pure,
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
block drives ERG. Runs that happened are persisted per-ride (`IntervalRun`, a
JSON blob in `Ride.intervalRunsData`) and reviewed on the summary — display only;
the ride is still scored as one block, and per-block achieved power/HR is a
deliberate v2 follow-on.

**`SensorHub` manages multiple independent BLE sensors over one
`CBCentralManager`**, keyed by `SensorKind` (`trainer` / `heartRate` /
`powerMeter`), each using its standard GATT service (FTMS `0x1826`, Heart Rate
`0x180D`, Cycling Power `0x1818`). The trainer is the source of truth for ride
data; a connected SRAM/Quarq power meter is a **secondary** readout whose watts
are recorded on their own channel (as the rider's leg power, surfaced on the ride
summary) but are never merged into the trainer's power, exported, or fed to ERG —
the trainer alone drives ERG, the zone math, and the Strava/TCX upload. Its
cadence stays display-only. Unlike the trainer's fields the meter's values are
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

**Two optional OAuth integrations follow the same shape**, each with a pure
`ZonaKit` half and an app-target I/O half: Strava (upload finished rides) and
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
