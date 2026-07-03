# Zona — Roadmap

Possible new features, grouped by value and by how much of the plumbing already
exists. Zona today holds a Kickr Core 2 at a steady ERG wattage while you aim for
a target HR zone, records the ride to SwiftData, computes summaries
(avg/NP/max power, time-in-zone, distance, RMSSD), exports TCX, uploads
directly to Strava, and syncs across devices via iCloud/CloudKit. Several of the
items below build on infrastructure that already exists but isn't yet surfaced
(the Quarq power decoder, persisted R-R intervals, closed-loop HR-hold behind a
toggle).

## Tier 1 — Highest value, plumbing largely exists

- **Structured workouts / interval sessions.** A workout builder (or preset
  library: 2×20 sweet-spot, Z2 endurance blocks, warmup→steady→cooldown ramps)
  that drives the ERG target automatically over time — turning Zona from "hold one
  number" into a training tool. The `setTargetPower` lever, `RideRecorder`, and
  time base already exist; this is mostly a workout model + a scheduler ticking
  targets, reusing the same `.task` loop that drives HR-hold.
- **Workout import/export (.zwo / .erg / .mrc).** Import standard workout files so
  sessions don't all have to be authored in-app. Reuses the XML-handling patterns
  proven in `TCXExporter`.
- **HRV time-series chart + SDNN.** Raw per-second R-R is already persisted
  (`RideSampleModel.rrIntervalsSec`) precisely so this can be added without
  re-riding. Add `HRV.sdnn` alongside the existing `rmssd`, plus an HRV-over-the-
  ride chart in `RideSummaryView` (already uses Swift Charts). Pure and testable.
- **Trends / history dashboard.** `HistoryView` is a flat list today. A trends
  screen — weekly time-in-zone, RMSSD trend, distance/duration totals, a simple
  Z2-discipline view — is high-value and entirely local (all data is in SwiftData).

## Tier 2 — Rounds out the ride experience

- **Quarq/SRAM as a selectable power source.** The `CyclingPowerMeasurement`
  decoder, `powerMeter` SensorKind, and preferred-device picker already exist and
  are dormant-but-ready. Surface it as a display/record source (true leg power
  alongside the ERG-held trainer power, L/R balance).
- **Audio / haptic zone cues.** Optional voice or haptic feedback ("push," "ease,"
  "back in zone") so you can ride heads-down without watching the gauges.
- **Auto-pause / coasting detection.** When you stop pedaling (watts=0) the timer
  keeps running; detect a coast/stop and auto-pause the recorder to clean up
  summaries and time-in-zone math.
- **Live ride charts.** A scrolling HR/power trace during the ride (not just the
  post-ride summary), to see drift and trend, not only the instantaneous gauge.

## Tier 3 — Connectivity & sync (known deferred items)

- **iCloud / CloudKit sync.** ✅ _Shipped (PR #12); verified on device._ Rides
  follow you across iPhone/iPad/Mac via the private CloudKit database, with no
  migration — the SwiftData model was deliberately built CloudKit-ready (all
  defaults, no `.unique`, optional relationships). The container is wired to
  `iCloud.org.flightblog.zona`, the iCloud + Push Notifications capabilities and
  entitlements (incl. the `remote-notification` background mode) are in place,
  and the store is opened under `Application Support` (created up front) to avoid
  a first-launch Core Data recovery stall.
- **WHOOP Cloud API (HR zones + recovery / readiness).** ✅ _Shipped (PR #15 zones,
  PR #16 readiness); verified on device._ Connect WHOOP on the setup screen to use
  its heart-rate zones as your source of truth — Zona reads your max + resting HR
  (`read:body_measurement` + `read:recovery`) and reconstructs WHOOP's HRR zone
  boundaries exactly, with the manual LTHR model as the fallback. The same section
  shows today's Recovery % / HRV / resting HR plus an advisory "go hard or keep it
  Z2?" zone suggestion (advisory only — it never changes your settings). Per-device
  OAuth, tokens in the Keychain, cloned from the Strava plumbing. Requires a WHOOP
  dev app (redirect `zona://whoop-auth`) and the privacy policy at
  <https://flightblog.github.io/Zona/privacy-policy>.
- **HRV-guided target suggestions.** Combine the stored ride R-R / HRV history with
  the WHOOP recovery readiness (now available) to suggest an FTP% or zone for the
  session — a richer, auto-applied version of the current advisory.

## Tier 4 — Platform polish

- **Apple Watch companion.** Live HR from the watch as an HR source and/or a
  glanceable ride controller.
- **Live Activity / Dynamic Island.** Ride timer, current HR/zone on the lock
  screen.
- **Screen-on / idle management.** Keep the display awake while riding.
- **FTP / LTHR test protocols.** Guided ramp or 20-min tests to set the two
  numbers the whole app depends on, instead of typing them in.

## Suggested next steps

- **Structured workouts** is the biggest capability jump and reuses infrastructure
  already trusted.
- **HRV chart + SDNN** is the cheapest high-value win — the raw data is already
  stored.
- **Quarq display** is the lowest-risk way to exercise dormant code.
