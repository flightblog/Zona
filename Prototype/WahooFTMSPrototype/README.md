# Zona — FTMS control prototype

> ⚠️ **Retired / superseded.** This was the Phase-0 proof-of-concept that
> validated real-time FTMS ERG control before the real app existed. That job is
> done — the shipping app in [`../../App`](../../App) now does everything here
> (and far more: heart-rate zones, multi-sensor BLE, ride recording), and is
> **verified on real hardware** (Kickr Core 2 + Garmin HRM 200). The FTMS logic
> proven here lives on as `App/ZonaKit/Sources/ZonaKit/FTMS.swift`.
>
> Kept only as a historical reference. **Not maintained** — build/run the app,
> not this. See [`App/README.md`](../../App/README.md).

Proves the risky part of the Zona app: real-time **ERG-mode control** of a
Wahoo Kickr Core 2 over Bluetooth **FTMS**, with live power/cadence readout and
the **FTP → Zone** watt math for steady Zone 1/2 riding.

## Why FTMS and not the Wahoo Cloud API

There are two things called "the Wahoo API":

- **Wahoo Cloud API** (`api.wahooligan.com`, OAuth 2.0 REST) — reads/writes
  user data: FTP, power zones, workouts, FIT uploads. It **cannot** control the
  trainer in real time.
- **Bluetooth FTMS** (`0x1826`, the open Bluetooth SIG standard) — this is how
  you actually put the trainer in ERG mode and set target watts. The Kickr Core
  exposes FTMS on firmware ≥ 1.1.1.

Steady Zone 1/2 riding = compute watts from FTP → hold them in ERG over FTMS.
The Cloud API is only needed later (pull configured zones, upload the ride).

## Run it (macOS, real trainer required)

```sh
cd Prototype/WahooFTMSPrototype
swift run WahooFTMSPrototype [FTP] [zone]

# examples
swift run WahooFTMSPrototype 220 2   # hold mid-Zone-2 off a 220 W FTP
swift run WahooFTMSPrototype 220 1   # Zone 1 recovery spin
```

First run triggers a **Bluetooth permission** prompt. If denied, grant it in
System Settings › Privacy & Security › Bluetooth. Ctrl-C sends a Stop to the
trainer before exiting.

Wake the trainer (spin the cranks) so it advertises before you start. Make sure
no other app (Wahoo app, Zwift) holds the BLE connection.

## What each file becomes in the app

| File                 | Role                              | Migrates to |
| -------------------- | --------------------------------- | ----------- |
| `Zones.swift`        | FTP → Coggan zone watt math       | App core (unchanged) |
| `FTMS.swift`         | FTMS command encode / data decode | App core (unchanged) |
| `TrainerControl.swift` | CoreBluetooth driver            | App control layer → `@Observable` |
| `main.swift`         | CLI runner / demo                 | replaced by SwiftUI |

`Zones.swift` and `FTMS.swift` are pure and unit-verified (zone bounds, the
`0x05` Set-Target-Power encoding, and Indoor Bike Data parsing).

## FTMS command reference (as implemented)

| Step            | Op code | Payload                     |
| --------------- | ------- | --------------------------- |
| Request Control | `0x00`  | —                           |
| Start / Resume  | `0x07`  | —                           |
| Set Target Power| `0x05`  | Int16 LE watts              |
| Stop            | `0x08`  | `0x01`                      |

Sequence: Request Control → (ack) → Start → (ack) → Set Target Power → stream
Indoor Bike Data (`0x2AD2`) for live power/cadence/speed.

## Next steps (app)

1. SwiftUI multiplatform target; wrap `TrainerControl` as `@Observable`.
2. FTP entry + zone picker; a live watts dial with in/out-of-zone color.
3. Wahoo Cloud OAuth: pull configured zones, upload the ride as a FIT file.
