# Zona (iOS + macOS)

A SwiftUI multiplatform app for **steady heart-rate-zone indoor riding**. Zona
holds your Wahoo Kickr Core 2 at a steady power (ERG) while you aim for a target
**heart-rate zone**, records the ride, and keeps a local history.

Status: **verified on real hardware** (Kickr Core 2 + Garmin HRM 200) on iOS and
macOS, along with a SRAM/Quarq power meter and Whoop as additional BLE sources.

## What it does

1. **Setup** — enter your FTP (drives the ERG power target) and your LTHR (drives
   the HR zones). **Connect WHOOP** and its heart-rate zones take over as your
   source of truth, LTHR being the fallback for when it isn't connected (see
   *WHOOP heart-rate zones setup* below). Pick a target HR zone. Connect sensors.
2. **Ride** — the trainer holds a steady watt setpoint via **FTMS ERG**; a live,
   color-coded HR readout shows whether you're landing in the target HR band
   (green in-zone, blue too easy, orange too hard). Power/cadence/speed also show.
   A live **zone bar** (Z1–Z5, with a handle marking where the current effort sits
   inside its zone) answers the other question: not "am I on my target?" but "which
   zone is this?" — scored against the same model the ride itself is.
3. **Save & review** — on End ride the session is recorded to **SwiftData** and a
   summary appears (time-in-HR-zone headline, avg/max HR, power stats, and a
   dual-axis watts/HR-over-time chart with the target HR-zone band shaded — drift
   and trend are a question for after the ride, not during it). The ride
   keeps the HR-zone model it was ridden under — WHOOP or LTHR — so it's always
   scored against the bands you were actually chasing, and the headline names which.
   **History** lists past rides (read-only; delete a ride from its summary screen),
   and its toolbar opens an **All-Time Stats** screen (totals, personal bests,
   time in each HR zone, and a weekly in-zone trend).
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
├── ZonaKit/                 # Swift Package: verified core, no UI. Unit-tested.
│   ├── Sources/ZonaKit/
│   │   ├── FTMS.swift              # FTMS GATT: op codes, Indoor Bike Data decode
│   │   ├── Zones.swift            # FTP → Coggan power zones
│   │   ├── HeartRateZones.swift   # LTHR → HR zones (HRZone / HRZoneEngine), the manual fallback
│   │   ├── RideHRZoning.swift     # which model a ride is scored against: .lthr / .whoopHRR
│   │   ├── RideSettingsState.swift # pure ride-input state + logic (zone-sync, zoning); app persists it
│   │   ├── RideModels.swift       # ConnectionState, RideMetrics
│   │   ├── RideRecorder.swift     # 1 Hz sample capture during a ride
│   │   ├── RideSummary.swift      # avg/NP/max power, avg/max HR, time-in-(HR)zone
│   │   ├── RideHistoryStats.swift # all-time rollup: totals, bests, per-zone time, weekly trend
│   │   ├── ChartDownsampling.swift # ChartPoint + bucket-average downsampler for the ride charts
│   │   ├── TrainerController.swift # app-facing facade over SensorHub
│   │   ├── Sensors/
│   │   │   ├── SensorKind.swift            # trainer / heartRate / powerMeter
│   │   │   ├── HeartRateMeasurement.swift  # 0x2A37 decode
│   │   │   ├── CyclingPowerMeasurement.swift # 0x2A63 decode (SRAM/Quarq)
│   │   │   └── SensorHub.swift             # multi-peripheral BLE manager
│   │   ├── Export/
│   │   │   └── TCXExporter.swift  # ride → TCX (TrainingCenterDatabase v2) string
│   │   ├── Strava/               # pure OAuth/upload logic (no networking)
│   │   │   ├── StravaOAuth.swift   # authorize URL, callback parse, token bodies
│   │   │   ├── StravaToken.swift   # token decode + expiry
│   │   │   ├── StravaUpload.swift  # upload-status decode + poll state machine
│   │   │   └── TokenStore.swift    # token persistence seam (mirrors SensorMemory)
│   │   ├── HRRZones.swift        # HRR/Karvonen HR zones (WHOOP source-of-truth)
│   │   └── Whoop/                # pure WHOOP OAuth + DTOs (no networking)
│   │       ├── WhoopOAuth.swift    # authorize URL (state), callback parse, token bodies
│   │       ├── WhoopToken.swift    # token decode + expiry
│   │       ├── WhoopProfile.swift  # body-measurement + recovery DTOs
│   │       └── WhoopTokenStore.swift # token persistence seam
│   └── Tests/ZonaKitTests/  # ZonaKitTests, SensorTests, ExportTests, StravaTests, WhoopTests, HRRZonesTests, RideHRZoningTests, ChartDownsamplingTests
└── Zona/                    # App target
    ├── ZonaApp.swift        # @main, RideSettings (thin @Observable + UserDefaults over RideSettingsState), modelContainer
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
    │   ├── RideView.swift        # HR readout, power dial, live Z1–Z5 zone bar, record, End ride
    │   ├── HRZoneColor.swift     # shared Z1–Z5 cool→warm ramp (HRZone.color)
    │   ├── RideSummaryView.swift # per-ride summary + dual-axis watts/HR chart + Strava upload / Export
    │   ├── HistoryView.swift     # past rides list + All-Time Stats link
    │   └── AllTimeStatsView.swift # all-time totals, bests, time-in-each-zone, weekly trend
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

> **The app must be signed to *run*, not just build.** Zona opens a
> CloudKit-mirrored SwiftData store at launch, so it needs a provisioning profile
> granting the `iCloud.org.flightblog.zona` container. An **unsigned** build (e.g.
> `CODE_SIGNING_ALLOWED=NO`) still *builds*, but **crashes on launch** —
> `EXC_BREAKPOINT` in CloudKit `-[PFCloudKitContainerProvider containerWithIdentifier:]`
> during store setup, before any window draws. This is an entitlements gate, not an
> app bug. To run from the command line, sign with your team, e.g.:
> ```sh
> xcodebuild -project Zona.xcodeproj -scheme Zona -destination 'platform=macOS' \
>   -configuration Debug DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
>   CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
> ```
> then `open <DerivedData>/Build/Products/Debug/Zona.app`. (Running from Xcode with
> a signing team set does this for you.)

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
reconstructs those exact boundaries and uses them as the ride target. Once
connected, the section also shows today's **Recovery %, HRV, and resting HR** with
a one-line advisory zone suggestion ("go hard or keep it Z2?") — advisory only; it
never changes your settings.

**Holding WHOOP's two numbers _is_ what makes them your zone model** — there's no
separate "use WHOOP zones" switch to keep in step with the connection. So the
manual LTHR stepper is what you ride to only until WHOOP is connected (the Heart
rate section swaps it for a read-only *Zone source: WHOOP*), and **Disconnect
WHOOP** — which forgets the max/resting HR — is what reverts you to LTHR. Each
finished ride permanently records the model it was ridden under, so connecting
WHOOP never retroactively rescores your old LTHR rides.

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
   match. Use **Refresh** to re-pull zones and recovery after WHOOP updates them
   (it also auto-loads on launch when you're already connected).

> Auth is **per-device** (like Strava): tokens live in this device's Keychain and
> don't iCloud-sync, so connect WHOOP separately on each device. The same
> PKCE-less client-secret caveat as Strava applies.

## Verifying the core

```sh
cd App/ZonaKit
swift test        # zones (incl. which model a ride is scored against), FTMS/HR/power decode, recorder, summaries, chart downsampling, TCX export, Strava + WHOOP OAuth
```

`ZonaKit` is pure and fully unit-tested. The BLE connection logic in `SensorHub`
is exercised against real hardware rather than unit tests.

### Previewing Markdown rendering

This repo is **private**, so you can't sanity-check how a README edit will look by
opening the raw file on github.com. To render Markdown exactly as GitHub would —
useful when an edit uses a tricky construct like a fenced code block nested inside a
`>` blockquote — pipe it through GitHub's own renderer:

```sh
gh api -X POST /markdown -f mode=gfm -f text="$(cat App/README.md)" > /tmp/readme.html
open /tmp/readme.html
```

When scripting a structural check against that HTML, note GitHub wraps code blocks in
`<div class="highlight">…<pre>`, so a naive "is `<pre>` directly inside the
`<blockquote>`?" test gives a false negative — inspect the actual HTML region rather
than substring-matching.

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
  connect and rescans, putting the sensor's row back to *Scanning* — otherwise a
  connect that is in fact looping (stall → cancel → rescan → stall) reads in the
  UI as one patient "Connecting…", hiding the very failure the watchdog exists to
  catch.
- **Auto-reconnect.** HR straps disconnect on idle to save battery; a dropped
  still-wanted sensor is transparently reconnected rather than abandoned.
- **The power meter's values expire; the trainer's don't.** A crank meter that
  goes quiet (coasting, slept, dropped) sends *nothing*, where the trainer's FTMS
  stream keeps pushing a real 0 W. Since the ride screen re-ingests metrics once a
  second, a last-write-wins value left frozen would bank fabricated leg power for
  the rest of a coast — so the meter's watts/cadence are dropped after a few
  seconds without a reading, and cleared outright on disconnect. The ride screen's
  own 1 Hz tick drives that expiry (`sweepStalePowerMeter`), so it doesn't depend
  on some *other* sensor still reporting to fire.
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

Rides are stored with SwiftData and **sync across your own devices** via a
private **iCloud/CloudKit** container — nothing is shared with anyone else. The
only other outbound networking is the **optional** Strava upload and the
**optional** WHOOP Cloud fetch (recovery + max/resting HR for zones); OAuth
tokens are kept in the Keychain. Zona does **not** use the Wahoo Cloud API — see
the roadmap for why.

## Roadmap

Shipped since the first cut (all verified on device unless noted):

- **WHOOP** as a live HR source over standard `0x180D`, plus a **WHOOP Cloud**
  integration: HR zones reconstructed from max/resting HR via HRR (Karvonen),
  today's recovery/readiness shown as an advisory. The Setup WHOOP section lists
  all five zones (Z1–Z5). Connecting WHOOP *is* the opt-in — holding its max and
  resting HR makes them your zone model, and Disconnect reverts you to LTHR.
- **Per-ride HR-zone model** — each finished ride records whether it was ridden on
  WHOOP's HRR bands or the manual LTHR bands (`RideHRZoning`) and is scored against
  that, so connecting WHOOP doesn't retroactively rescore old LTHR rides (nor
  disconnecting restate WHOOP ones). The model is latched at ride start, so a
  mid-ride refresh can't move the target band under you.
- **iCloud/CloudKit** sync — rides sync across iPhone/iPad/Mac.
- A **device picker** (pin a preferred sensor per kind; hot-swaps live).
- **HRV/R-R** capture — R-R is parsed, stored per sample, and summarised as RMSSD.
- **Ride export** to TCX via the Share sheet, with simulated distance.
- **Dual-axis ride chart** — watts (left) and heart rate (right) over time on the
  post-ride summary, with the target HR-zone band shaded. Samples are downsampled
  so long rides stay responsive.
- **Live HR zone bar** on the ride screen — a segmented Z1–Z5 bar with a handle
  showing where the current effort sits inside its zone. It answers "which zone am
  I in right now?", where the gauges answer "am I inside my target band?", and it
  classifies through the same `RideHRZoning.zone(forHR:)` the ride's own scoring
  uses — so it can't name a zone the ride wouldn't record. (It replaced the live
  chart on this screen: mid-ride you're steering to a zone, not reading a trend.)
- **All-Time Stats** (off the History toolbar) — totals (rides / time / distance),
  personal bests, a **time-in-each-HR-zone** breakdown (Z1–Z5, recomputed from each
  ride's stored HR samples), and a weekly in-zone trend, all rolled up by a pure
  `RideHistoryStats` reducer in `ZonaKit`.
- **Quarq/SRAM leg power** — a connected SRAM/Quarq power meter shows its live
  watts and cadence on the ride screen, and its watts are **recorded** per-second
  as the rider's *leg* power (`RideSample.powerMeterW`), summarized into avg/max
  leg power on the ride summary. It's a **parallel channel, not a replacement**:
  the trainer's `powerW` remains the single source of truth for ERG, the zone
  math, and the TCX/Strava export, so leg power can never skew a recorded or
  uploaded ride. (The meter's *cadence* stays display-only.) Expect it to read a
  few watts *above* the trainer for the same effort — the Quarq measures crank
  torque directly while the Kickr estimates from its flywheel, so a small steady
  gap is the two working correctly, not a fault. Its readings **expire** when the
  crank goes quiet, so a coast doesn't record fabricated watts — see *Sensors &
  connection behavior* above.

Still open / optional:
- Direct **Strava OAuth upload** if the manual TCX Share export proves too clunky.
- Further **HRV** follow-ons now that R-R is stored — SDNN, and an HRV time-series
  chart (which can reuse the dual-axis chart + downsampler already shipped).
- **ERG session resiliency** — recover the ERG setpoint after a mid-ride trainer
  drop/reconnect.

Note: **closed-loop HR→watts** (auto-adjust ERG to hold an HR zone) was built and
then deliberately removed — the app stays open-loop (power holds the ERG setpoint,
HR only defines/shows the target zone).
