# Zona

A SwiftUI (iOS + macOS) app for **steady heart-rate-zone indoor riding**. Zona
holds a Wahoo Kickr Core 2 at a steady power (ERG) over Bluetooth while you aim
for a target **heart-rate zone**, records the ride, and keeps a local history.

Verified on real hardware: **Kickr Core 2 + Garmin HRM 200**, on iOS and macOS.

## Repo layout

- **[`App/`](App/)** — the app. `ZonaKit` (a pure, unit-tested Swift package:
  FTMS/HR/power BLE decoding, power & HR zone math, ride recording) plus the
  SwiftUI target. See **[`App/README.md`](App/README.md)** for build/run details,
  architecture, and roadmap.
- **[`Prototype/`](Prototype/)** — a retired Phase-0 command-line proof-of-concept
  that validated FTMS trainer control before the app existed. Historical only.

## Quick start

```sh
brew install xcodegen        # one time
cd App
xcodegen generate            # generates Zona.xcodeproj from project.yml
open Zona.xcodeproj          # pick the "Zona" scheme, set signing, run
```

The Xcode project and its Info.plist/entitlements are **generated** from
`App/project.yml` (the source of truth) and are not committed — run
`xcodegen generate` after cloning.

```sh
cd App/ZonaKit && swift test   # 134 tests: zones, BLE decoders, recorder, summaries, TCX export, Strava + WHOOP
```

## What it does

The trainer holds a steady **power** setpoint via FTMS ERG (from your FTP), while
**heart rate** defines and displays the zone you're aiming for — a stable design
that avoids chasing a laggy HR signal with the trainer. HR zones come from your
LTHR by default, or **connect WHOOP** to use its zones as your source of truth
(Zona reconstructs WHOOP's boundaries from your max/resting HR). Rides are stored
locally with SwiftData (CloudKit-ready for later sync). Finished rides can go to
**Strava** two ways: a one-tap **Upload to Strava** button (OAuth, no files), or a
`.tcx` **Share-sheet export** to Strava or anywhere else.

Built collaboratively with Claude Code.
