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
- `Prototype/` — a retired Phase-0 CLI proof-of-concept for FTMS trainer
  control. Historical only; don't build on it.

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

**`ZonaKit` (pure, no UI, 138 tests) vs. the `Zona` app target (I/O + SwiftUI).**
This split is the main thing to preserve: BLE decoding, zone math, ride
recording/summarizing, TCX export, and the pure OAuth/token logic for Strava and
WHOOP all live in `ZonaKit` and are unit-tested. The app target supplies the
networking, Keychain, and UI glue around that pure core (e.g. `StravaService`
wraps `ZonaKit`'s `StravaUpload` state machine with `URLSession`; `WhoopService`
does the same for WHOOP). When adding a new integration, keep protocol/parsing
logic testable in `ZonaKit` and put `URLSession`/`Keychain`/`ASWebAuthentication`
calls in the app target.

**Design: HR defines the target zone, power does the controlling.** The trainer
can only hold a *power* setpoint (FTMS ERG, from FTP); HR lags and drifts too
much to close the loop on directly. So the ride is power-steady while HR is used
only to *define and display* the target zone (from LTHR, or from WHOOP's
HRR-derived zones if connected). A closed-loop HR→watts mode was built and then
deliberately removed — don't reintroduce it without discussion.

**`SensorHub` manages multiple independent BLE sensors over one
`CBCentralManager`**, keyed by `SensorKind` (`trainer` / `heartRate` /
`powerMeter`), each using its standard GATT service (FTMS `0x1826`, Heart Rate
`0x180D`, Cycling Power `0x1818`). The trainer is the source of truth for ride
data; a connected SRAM/Quarq power meter is a **display-only** secondary readout
(power, cadence derived from its crank revolutions, and L/R balance) that is
never recorded, exported, or fed to ERG — see `RideMetrics.powerMeterW`. Notable
behaviors baked into it, worth knowing before touching connection logic:
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
the ride target instead of manual LTHR). Both need credentials in the gitignored
`App/Zona/Config/Secrets.xcconfig` (copy from `Secrets.example.xcconfig`); the
corresponding UI section simply hides when credentials aren't configured. Both
store OAuth tokens in the Keychain, per-device (no iCloud sync of tokens). Both
accept a client secret baked into the binary (no PKCE on either provider's
token endpoint) — acceptable for a personal single-user build, not for public
distribution.

**Data**: rides are stored with SwiftData and synced across the user's own
devices via a private iCloud/CloudKit container. Outbound networking is limited
to the optional Strava upload and the optional WHOOP fetch; Zona does not use
the Wahoo Cloud API.

See `App/README.md` for the full source-tree map, Strava/WHOOP setup steps, and
the roadmap; `ROADMAP.md` at the repo root tracks longer-term app-level plans.
