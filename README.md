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
cd App/ZonaKit && swift test   # 36 tests: zones, BLE decoders, recorder, summaries
```

## What it does

The trainer holds a steady **power** setpoint via FTMS ERG (from your FTP), while
**heart rate** (from your LTHR) defines and displays the zone you're aiming for —
a stable design that avoids chasing a laggy HR signal with the trainer. Rides are
stored locally with SwiftData; the model is CloudKit-ready for later sync.

Built collaboratively with Claude Code.
