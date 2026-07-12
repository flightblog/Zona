# Zona — Roadmap

Possible new features, grouped by value and by how much of the plumbing already
exists. Zona today holds a Kickr Core 2 at a steady ERG wattage while you aim for
a target HR zone, records the ride to SwiftData, computes summaries
(avg/NP/max power, time-in-zone, distance, RMSSD), charts watts and HR over time
both live and post-ride, exports TCX, uploads directly to Strava, and syncs
across devices via iCloud/CloudKit. The `App/` project (the `ZonaKit` package
plus the SwiftUI target) is now the sole codebase — the retired Phase-0
`WahooFTMSPrototype` CLI that validated FTMS trainer control before the app
existed has been removed. Several of the
items below build on infrastructure that already exists but isn't yet fully
surfaced (the Quarq power meter now shows a live readout but isn't recorded;
persisted R-R intervals).

## Tier 1 — Highest value, plumbing largely exists

- **Structured workouts / interval sessions.** A workout builder (or preset
  library: 2×20 sweet-spot, Z2 endurance blocks, warmup→steady→cooldown ramps)
  that drives the ERG target automatically over time — turning Zona from "hold one
  number" into a training tool. The `setTargetPower` lever, `RideRecorder`, and
  time base already exist; this is mostly a workout model + a scheduler ticking
  targets, reusing the same 1 Hz `.task` loop the ride screen already runs.
- **Workout import/export (.zwo / .erg / .mrc).** Import standard workout files so
  sessions don't all have to be authored in-app. Reuses the XML-handling patterns
  proven in `TCXExporter`.
- **HRV time-series chart + SDNN.** Raw per-second R-R is already persisted
  (`RideSampleModel.rrIntervalsSec`) precisely so this can be added without
  re-riding. Add `HRV.sdnn` alongside the existing `rmssd`, plus an HRV-over-the-
  ride chart in `RideSummaryView` (which now has the dual-axis time-series chart
  and the `[ChartPoint].downsampled(to:)` reducer to reuse). Pure and testable.
- **Trends / history dashboard.** ✅ _Shipped (PR #54); verified in-app._ An
  **All-Time Stats** screen off the History toolbar rolls every saved ride up into
  totals (rides / time / distance), personal bests (longest ride, best avg power),
  a **time-in-each-HR-zone** breakdown (Z1–Z5, recomputed from each ride's stored
  per-second HR samples), and a weekly in-zone trend chart. Entirely local (all
  data is in SwiftData) via a pure, unit-tested `RideHistoryStats` reducer in
  ZonaKit. Still open as follow-ons: an RMSSD/HRV trend (the R-R data is already
  stored — see the HRV item above) and any further Z2-discipline cuts.

## Tier 2 — Rounds out the ride experience

- **Quarq/SRAM as a selectable power source.** 🚧 _Display half shipped (PR #36)
  and verified on a physical meter._ A connected SRAM/Quarq shows its live
  watts and cadence on the ride screen as a display-only secondary readout (its
  own `powerMeterW` field, deliberately never merged into the trainer's `powerW`,
  so it can't skew recording, zone math, or the Strava export). As expected, a real
  Quarq reads a few watts higher than the Kickr (direct crank torque vs. flywheel
  estimate + drivetrain loss; see the `RideMetrics.powerMeterW` doc comment) — that
  small gap is the two meters working correctly, not a bug to reconcile.
  Still to do: make it a *recorded* source (true leg power alongside the
  ERG-held trainer power), plus L/R balance.
- **Audio / haptic zone cues.** Optional voice or haptic feedback ("push," "ease,"
  "back in zone") so you can ride heads-down without watching the gauges.
- **Auto-pause / coasting detection.** When you stop pedaling (watts=0) the timer
  keeps running; detect a coast/stop and auto-pause the recorder to clean up
  summaries and time-in-zone math.
- **ERG session resiliency (Machine Status + reconnect resend).** `SensorHub`
  subscribes to Fitness Machine Status (`2ADA`, the Kickr Core 2 requires it before
  it will answer control-point commands) but never parses its notifications, so an
  external stop/pause, a safety-key pull, or another app taking the control point
  goes undetected. Separately, a mid-ride BLE reconnect reruns the Request Control →
  Start handshake and flips `trainerReady` back to true, but never re-sends the last
  commanded watts — ERG target state after a drop currently depends on unverified
  Kickr firmware behavior. Needs `2ADA` frame decoding in `didUpdateValueFor` plus
  resending `metrics.targetW` whenever `trainerReady` transitions to true, not just
  on the initial connect.
- **Live ride charts.** ✅ _Shipped (PR #47); verified on device._ A dual-axis
  watts/BPM time-series now draws live on the ride screen (below the SRAM row,
  trainer watts on the left axis, HR on the right) so you can see drift and trend,
  not only the instantaneous gauges; the post-ride summary's power chart was
  rebuilt to match. Swift Charts plots one shared Y-domain, so the second axis is
  faked by scaling BPM into the watts domain and relabelling the trailing axis
  back to BPM (shared `scaleBPMToWatts` / `unscaleWattsToBPM`). Samples are
  downsampled to ≤200 bucket-averaged points before plotting (pure, unit-tested
  `[ChartPoint].downsampled(to:)` in ZonaKit) — a `LineMark` per second is
  thousands of marks on an hour ride. NB the reduction and axis ranges must be
  computed *once* per render, not in computed properties the chart body re-reads
  per point: doing the latter reprocessed every sample hundreds of times per
  layout pass and froze the summary when opening a long old ride (fixed same PR).

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
- **Per-ride HR-zone model (WHOOP vs. LTHR).** ✅ _Shipped (PR #61 model, PR #62
  the WHOOP-always-wins rule); verified in-app._ Which HR-zone model a ride is
  scored against is now a **fact about the ride**, not a re-reading of today's
  settings: a finished ride stores the model it was actually ridden under
  (`RideHRZoning` in ZonaKit, `.lthr` / `.whoopHRR`), so connecting WHOOP no longer
  retroactively rescores old LTHR rides and disconnecting it no longer restates
  WHOOP ones. `RideView` latches the model at ride start, so a mid-ride refresh
  can't move the target band under you. And the live rule is now simply **holding
  WHOOP's max + resting HR *is* the model** — there's no separate opt-in flag to
  fall out of step with it (there used to be, and it could leave you connected to
  WHOOP while still scoring against a hand-typed LTHR). LTHR is the fallback until
  WHOOP is connected; **Disconnect** clears the numbers and is what reverts you.
- **HRV-guided target suggestions.** Combine the stored ride R-R / HRV history with
  the WHOOP recovery readiness (now available) to suggest an FTP% or zone for the
  session — a richer, auto-applied version of the current advisory.

## Tier 4 — Platform polish

- **Apple Watch companion.** Live HR from the watch as an HR source and/or a
  glanceable ride controller.
- **Live Activity / Dynamic Island.** Ride timer, current HR/zone on the lock
  screen.
- **Screen-on / idle management.** ✅ _Shipped (PR #39)._ The display
  stays awake for the whole ride via a `.keepAwake()` modifier on `RideView`
  (which is on screen exactly when a ride is live): iOS sets
  `UIApplication.isIdleTimerDisabled`, macOS holds a `ProcessInfo` activity
  assertion (`.idleDisplaySleepDisabled`). Both are released the moment the view
  disappears (End ride), so normal power management resumes and the screen never
  stays on after a session. Compile-verified on both platforms; not yet observed
  on hardware.
- **FTP / LTHR test protocols.** Guided ramp or 20-min tests to set the two
  numbers the whole app depends on, instead of typing them in.

## Suggested next steps

- **Structured workouts** is the biggest capability jump and reuses infrastructure
  already trusted.
- **HRV chart + SDNN** is the cheapest high-value win — the raw data is already
  stored.
- **Quarq display** shipped (PR #36); recording the meter's power + L/R balance is
  the natural follow-on now that the read path is proven.
