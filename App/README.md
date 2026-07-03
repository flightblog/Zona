# Zona (iOS + macOS)

A SwiftUI multiplatform app for **steady heart-rate-zone indoor riding**. Zona
holds your Wahoo Kickr Core 2 at a steady power (ERG) while you aim for a target
**heart-rate zone**, records the ride, and keeps a local history.

Status: **verified on real hardware** (Kickr Core 2 + Garmin HRM 200) on iOS and
macOS. Extensible to more BLE sensors (a SRAM/Quarq power meter and Whoop are the
next planned sources).

## What it does

1. **Setup** — enter your FTP (drives the ERG power target) and your LTHR (drives
   the HR zones), or **connect WHOOP** to use its heart-rate zones as your source
   of truth instead (see *WHOOP heart-rate zones setup* below). Pick a target HR
   zone. Connect sensors.
2. **Ride** — the trainer holds a steady watt setpoint via **FTMS ERG**; a live,
   color-coded HR readout shows whether you're landing in the target HR band
   (green in-zone, blue too easy, orange too hard). Power/cadence/speed also show.
3. **Save & review** — on End ride the session is recorded to **SwiftData** and a
   summary appears (time-in-HR-zone headline, avg/max HR, power stats, HR+power
   chart). **History** lists past rides; swipe to delete.
4. **Send to Strava** — two options in the summary toolbar:
   - **Upload to Strava** — one tap uploads the ride directly (OAuth, no files).
     First use opens a Strava consent screen; after that it's automatic. The button
     then becomes **View on Strava**, and the ride won't be uploaded twice.
     Requires a Strava API app to be configured (see *Strava upload setup* below);
     the button is hidden when it isn't.
   - **Export** (⬆️) — shares the ride as a `.tcx` file to Strava, Files, AirDrop,
     or mail, with no account. Both paths brand the file with `<Creator>Zona</Creator>`.

   Indoor rides have no GPS, so they import as virtual rides (HR/power/cadence
   graphs, no map).

### Zones: HR defines the target, power does the controlling

The trainer can only hold *power* (ERG), but HR lags and drifts, so Zona doesn't
try to steer HR directly. Instead it rides a steady **power** setpoint (from FTP)
and uses **heart rate** to *define and display* the zone you're aiming for (from
LTHR). No closed-loop HR→watts control — that's a possible future phase.

## Layout

```
App/
├── project.yml              # XcodeGen spec → Zona.xcodeproj (iOS + macOS).
│                            #   Owns Info.plist + entitlements — see note below.
├── ZonaKit/                 # Swift Package: verified core, no UI. 104 tests.
│   ├── Sources/ZonaKit/
│   │   ├── FTMS.swift              # FTMS GATT: op codes, Indoor Bike Data decode
│   │   ├── Zones.swift            # FTP → Coggan power zones
│   │   ├── HeartRateZones.swift   # LTHR → HR zones (HRZone / HRZoneEngine)
│   │   ├── RideModels.swift       # ConnectionState, RideMetrics
│   │   ├── RideRecorder.swift     # 1 Hz sample capture during a ride
│   │   ├── RideSummary.swift      # avg/NP/max power, avg/max HR, time-in-(HR)zone
│   │   ├── TrainerController.swift # app-facing facade over SensorHub
│   │   ├── Sensors/
│   │   │   ├── SensorKind.swift            # trainer / heartRate / powerMeter
│   │   │   ├── HeartRateMeasurement.swift  # 0x2A37 decode
│   │   │   ├── CyclingPowerMeasurement.swift # 0x2A63 decode (Quarq-ready)
│   │   │   └── SensorHub.swift             # multi-peripheral BLE manager
│   │   ├── Export/
│   │   │   └── TCXExporter.swift  # ride → TCX (TrainingCenterDatabase v2) string
│   │   ├── Strava/               # pure OAuth/upload logic (no networking)
│   │   │   ├── StravaOAuth.swift   # authorize URL, callback parse, token bodies
│   │   │   ├── StravaToken.swift   # token decode + expiry
│   │   │   ├── StravaUpload.swift  # upload-status decode + poll state machine
│   │   │   └── TokenStore.swift    # token persistence seam (mirrors SensorMemory)
│   │   ├── HeartRateZones.swift  # LTHR/Friel HR zones (manual fallback)
│   │   ├── HRRZones.swift        # HRR/Karvonen HR zones (WHOOP source-of-truth)
│   │   └── Whoop/                # pure WHOOP OAuth + DTOs (no networking)
│   │       ├── WhoopOAuth.swift    # authorize URL (state), callback parse, token bodies
│   │       ├── WhoopToken.swift    # token decode + expiry
│   │       ├── WhoopProfile.swift  # body-measurement + recovery DTOs
│   │       └── WhoopTokenStore.swift # token persistence seam
│   └── Tests/ZonaKitTests/  # ZonaKitTests, SensorTests, ExportTests, StravaTests, WhoopTests, HRRZonesTests
└── Zona/                    # App target
    ├── ZonaApp.swift        # @main, RideSettings (FTP/zone/LTHR/HR zone), modelContainer
    ├── Model/
    │   ├── RideStore.swift          # SwiftData @Model: Ride, RideSampleModel
    │   ├── RideExport.swift         # Ride → .tcx temp file for the Share sheet
    │   └── SensorMemoryStore.swift  # UserDefaults-backed SensorMemory
    ├── Strava/                      # app-side I/O glue for Strava upload
    │   ├── StravaService.swift      # URLSession: exchange, refresh, upload + poll
    │   ├── StravaAuthenticator.swift # ASWebAuthenticationSession OAuth login
    │   ├── KeychainTokenStore.swift # Keychain-backed TokenStore
    │   ├── StravaSecrets.swift      # client id/secret from Info.plist
    │   └── StravaUploadModel.swift  # @Observable upload view-model
    ├── Whoop/                       # app-side I/O glue for WHOOP zones
    │   ├── WhoopService.swift       # URLSession: exchange, refresh, fetch zone inputs
    │   ├── WhoopAuthenticator.swift # ASWebAuthenticationSession OAuth login
    │   ├── KeychainWhoopTokenStore.swift # Keychain-backed WhoopTokenStore
    │   ├── WhoopSecrets.swift       # client id/secret from Info.plist
    │   └── WhoopModel.swift         # @Observable connect/refresh view-model
    ├── Config/
    │   └── Secrets.example.xcconfig # template → gitignored Secrets.xcconfig
    ├── Views/
    │   ├── ContentView.swift    # setup ↔ ride router + History link
    │   ├── SetupView.swift       # FTP, LTHR/WHOOP zones, sensor rows, connect, Diagnostics
    │   ├── RideView.swift        # HR readout, power dial, record, End ride
    │   ├── RideSummaryView.swift # per-ride summary + chart + Strava upload / Export
    │   └── HistoryView.swift     # past rides list
    └── Resources/
        ├── Info.plist                # generated — BLE usage, URL scheme, Strava + WHOOP keys
        ├── Zona.macOS.entitlements   # generated — sandbox + bluetooth + network
        └── Assets.xcassets           # AppIcon (iOS 1024 + macOS ladder)
```

## Build & run

```sh
brew install xcodegen        # one time
cd App
xcodegen generate            # creates Zona.xcodeproj
open Zona.xcodeproj
```

Pick the **Zona** scheme, choose a Mac or iOS destination, set your signing team
under Signing & Capabilities, and run. First launch prompts for Bluetooth.

> **Info.plist and entitlements are generated by XcodeGen from `project.yml`.**
> Don't hand-edit the files in `Zona/Resources/` — they're overwritten on every
> `xcodegen generate`. The Bluetooth usage string and the sandbox/bluetooth
> entitlements are declared under the target's `info.properties` /
> `entitlements.properties` in `project.yml` so they survive regeneration.

Command-line builds (used in CI-style checks):

```sh
xcodebuild -project Zona.xcodeproj -scheme Zona -destination 'platform=macOS' build
xcodebuild -project Zona.xcodeproj -scheme Zona \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build
```

## Strava upload setup

The **Upload to Strava** button needs a Strava API app's credentials. Without
them the button simply hides (the `.tcx` Share export still works).

1. Create an API application at <https://www.strava.com/settings/api>. Set its
   **Authorization Callback Domain** to exactly `strava-auth` (no scheme, no
   slashes) — this matches the app's `zona://strava-auth` OAuth redirect.
2. Copy `Zona/Config/Secrets.example.xcconfig` to `Zona/Config/Secrets.xcconfig`
   and fill in your **Client ID** and **Client Secret**:
   ```
   STRAVA_CLIENT_ID = 12345
   STRAVA_CLIENT_SECRET = your_secret
   ```
   `Secrets.xcconfig` is **gitignored** — credentials never get committed.
3. Run `xcodegen generate` and rebuild. The values are injected into Info.plist;
   the app requests its own upload token via OAuth on first use (you never paste
   access/refresh tokens — those are captured by the login flow and stored in the
   Keychain).

> **Security note.** Strava's token endpoint has no PKCE, so the client secret is
> baked into the built binary and is extractable. That's acceptable for a
> personal, single-user build but blocks unmodified public distribution. A
> server-side token-exchange proxy would be the fix.

## WHOOP heart-rate zones setup

The **WHOOP** section on the setup screen makes WHOOP the source of truth for your
HR zones. Without credentials the section simply hides (the manual LTHR zones
still work).

WHOOP's API doesn't expose zone boundaries directly, but it returns your **max
heart rate** (body measurement) and **resting heart rate** (recovery), from which
WHOOP builds its zones using **Heart Rate Reserve** (`bpm = restingHR +
fraction × (maxHR − restingHR)`, fixed 40/60/70/80/90/100% bands). Zona
reconstructs those exact boundaries and uses them as the ride target when
connected, falling back to the manual LTHR zones otherwise.

1. Create an app at <https://developer.whoop.com>. Set its **redirect URI** to
   exactly `zona://whoop-auth` (matches the app's OAuth redirect), and grant the
   scopes `read:body_measurement`, `read:recovery`, and `offline` (the last is
   what lets WHOOP issue a refresh token).
2. Add your **Client ID** and **Client Secret** to `Zona/Config/Secrets.xcconfig`
   (the same gitignored file as Strava — copy from `Secrets.example.xcconfig` if
   you haven't already):
   ```
   WHOOP_CLIENT_ID = your_client_id
   WHOOP_CLIENT_SECRET = your_secret
   ```
3. Run `xcodegen generate` and rebuild. On the setup screen, tap **Connect WHOOP**
   to complete the OAuth login (tokens are captured by the flow and stored in the
   Keychain — you never paste them), then the WHOOP section shows your zone bands.
   Cross-check them against the WHOOP app for the same max/resting HR — they should
   match. Use **Refresh zones** to re-pull after WHOOP updates your numbers.

> Auth is **per-device** (like Strava): tokens live in this device's Keychain and
> don't iCloud-sync, so connect WHOOP separately on each device. The same
> PKCE-less client-secret caveat as Strava applies.

## Verifying the core

```sh
cd App/ZonaKit
swift test        # 104 tests: zones, FTMS/HR/power decode, recorder, summaries, TCX export, Strava OAuth/upload
```

`ZonaKit` is pure and fully unit-tested. The BLE connection logic in `SensorHub`
is exercised against real hardware rather than unit tests.

## Sensors & connection behavior

`SensorHub` manages several independent BLE sensors over one `CBCentralManager`,
keyed by `SensorKind` (`trainer` / `heartRate` / `powerMeter`). Each uses its
standard GATT service — FTMS `0x1826`, Heart Rate `0x180D`, Cycling Power
`0x1818` — so a Whoop (standard HR) or a Quarq (standard power) can join without
new plumbing.

- **Auto-connect + remember.** The first sensor of each type is connected and its
  identifier persisted (`SensorMemoryStore`), so the same device reconnects next
  session.
- **Robust discovery.** The scan is **unfiltered** (`scanForPeripherals(services: nil)`)
  and devices are identified from their **actual GATT services** after connecting,
  not the advertisement — because some sensors (the Garmin HRM 200 among them)
  don't advertise their service UUID at all, so a service-filtered scan never
  surfaces them. A device-name heuristic keeps the unfiltered scan from dialing up
  unrelated peripherals.
- **Connect watchdog.** CoreBluetooth's `connect(_:)` never times out, so a stale
  remembered peripheral would hang forever. An 8s watchdog cancels a stalled
  connect and rescans.
- **Auto-reconnect.** HR straps disconnect on idle to save battery; a dropped
  still-wanted sensor is transparently reconnected rather than abandoned.
- **HR required to ride.** A ride won't start until both the trainer (in ERG) and
  an HR strap are connected. Once started, the session **latches** — a transient
  mid-ride sensor drop won't eject you back to setup.

## Concurrency (Swift 6, strict)

`SensorHub` / `TrainerController` are `@MainActor @Observable`. All CoreBluetooth
object references (`CBCentralManager`, `CBPeripheral`, `CBCharacteristic`) live
inside a private `MultiBLEManager` on a dedicated BLE queue that does all GATT
I/O; only `Sendable` values (bytes, decoded structs, UUID strings, names) cross
to the main actor. No `@preconcurrency` escape hatches.

> Observation note: the UI observes `TrainerController`, not the `SensorHub`
> behind it. So the controller holds **real observed stored properties**
> (`metrics`, plus mirrored connection state) that are **republished from the hub**
> via `onMetricsChange` / `onStateChange` callbacks. A computed pass-through to
> `hub.metrics` registers no SwiftUI dependency and leaves live values frozen —
> don't reintroduce one.

## Data & privacy

Rides are stored **locally** with SwiftData (on-device only). The model is
CloudKit-ready (all properties defaulted, no `.unique`, optional relationships)
so iCloud sync can be enabled later with no migration. The only outbound
networking is the **optional** Strava upload — nothing leaves the device unless
you tap Upload; OAuth tokens are kept in the Keychain. Zona does **not** use the
Wahoo Cloud API — see the roadmap for why.

## Roadmap

- **Quarq power meter** as the power source (decoder already built and tested).
- **Whoop** as an HR source (should work over standard `0x180D`; verify on device).
- Optional **iCloud/CloudKit** sync (model already compatible).
- A **device picker** (currently the scan is unfiltered + name-heuristic; see the
  SensorHub note above).
- Possible **closed-loop HR→watts** (auto-adjust ERG to hold an HR zone) and
  **HRV/R-R** capture (R-R is already parsed, just not stored).
