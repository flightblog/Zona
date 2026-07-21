# Zona — Roadmap

Possible new features, grouped by value and by how much of the plumbing already
exists. Zona today holds a Kickr Core 2 at a steady ERG wattage while you aim for
a target HR zone, records the ride to SwiftData, computes summaries
(avg/NP/max power, time-in-zone, distance, RMSSD), shows a live HR-zone bar and a
running Total / In-zone timer pair, charts watts and HR over time post-ride,
exports TCX, uploads directly to Strava, and syncs
across devices via iCloud/CloudKit. The `App/` project (the `ZonaKit` package
plus the SwiftUI target) is now the sole codebase — the retired Phase-0
`WahooFTMSPrototype` CLI that validated FTMS trainer control before the app
existed has been removed. The pure-core / app-glue split now extends to the
settings layer too: the ride-input decision logic (zone-sync, WHOOP-vs-LTHR
zoning) lives in a unit-tested `RideSettingsState` in `ZonaKit`, with
`RideSettings` a thin `@Observable` wrapper that just persists it to
`UserDefaults` (PR #84). Several of the
items below build on infrastructure that already exists but isn't yet fully
surfaced (persisted R-R intervals; a Quarq's per-second leg power, recorded and
summarized but not charted).

## Tier 1 — Highest value, plumbing largely exists

- **Structured workouts / interval sessions.** ✅ _v1 shipped (issue #88): a
  rider-triggered interval block._ A small pre-authored library
  (`IntervalSession` — `repeats × (work, rest)`, `Z3`-and-up work zones typical,
  authored in a new Setup "Interval sessions" editor) can be triggered mid-ride,
  typically near the end of a Z2 session; `IntervalScheduler` steps the ERG
  target through it via the ride screen's existing 1 Hz `.task` loop, only
  calling `setTargetPower` at a step boundary. A running block can be stopped
  early from a HUD that replaces the manual `TargetAdjuster` while it's active;
  ending (naturally or via Stop) reverts to the steady target. No TCX laps,
  `RideHRZoning`/`RideSummary` changes, or closed-loop HR control — the ride is
  still scored end-to-end as one block, and the interval only steers watts.
  Remaining as a natural v2: a general `[IntervalStep]` model for warmups,
  ramps, and pyramids (today's shape is uniform work/rest only), plus
  **workout import/export (.zwo / .erg / .mrc)** below.
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

- **Quarq/SRAM as a recorded power source.** ✅ _Shipped (PR #36 display, PR #70
  recording); verified on a physical meter._ A connected SRAM/Quarq shows its live
  watts and cadence on the ride screen, and its watts are **recorded** per-second
  alongside the trainer's (`RideSample.powerMeterW` → `RideSampleModel.powerMeterW`),
  summarized into avg/max leg power, and shown as their own summary tiles on rides
  ridden with a meter.
  It stays a **parallel channel, not a replacement**: the trainer's `powerW` is
  still the single source of truth for ERG, zone math, and the TCX/Strava export,
  so leg power can never skew a recorded or uploaded ride. As expected, a real
  Quarq reads a few watts higher than the Kickr (direct crank torque vs. flywheel
  estimate + drivetrain loss; see the `RideMetrics.powerMeterW` doc comment) — that
  small gap is the two meters working correctly, not a bug to reconcile.
  **L/R balance is deliberately out of scope** — a tile existed and was removed in
  PR #52. A spider-based Quarq can only *estimate* the split (it measures total
  torque at one point and infers the legs from where in the stroke torque peaks),
  and the number isn't actionable for steady-zone riding. The decoder still skips
  that byte so the crank data behind it stays at the right offset; don't re-add the
  field without a concrete use for it. Charting leg power as a third series on the
  summary chart remains possible — the per-second data is stored — but isn't planned.
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
- **Ride charts.** ✅ _Shipped (PR #47); verified on device._ The post-ride summary
  plots a dual-axis watts/BPM time-series (trainer watts on the left axis, HR on the
  right, target HR band shaded) so you can see drift and trend across the finished
  ride. Swift Charts plots one shared Y-domain, so the second axis is
  faked by scaling BPM into the watts domain and relabelling the trailing axis
  back to BPM (`scaleBPMToWatts` / `unscaleWattsToBPM`). Samples are
  downsampled to ≤200 bucket-averaged points before plotting (pure, unit-tested
  `[ChartPoint].downsampled(to:)` in ZonaKit) — a `LineMark` per second is
  thousands of marks on an hour ride. NB the reduction and axis ranges must be
  computed *once* per render, not in computed properties the chart body re-reads
  per point: doing the latter reprocessed every sample hundreds of times per
  layout pass and froze the summary when opening a long old ride (fixed same PR).
  The same chart also drew *live* on the ride screen until PR #67 replaced it there
  with the zone bar below — mid-ride you're steering to a zone, not reading a trend,
  and the drift question is better asked afterwards, which the summary still answers.
- **Live HR zone bar.** ✅ _Shipped (PR #65, trimmed in #66, took the chart's slot in
  #67); verified on device._ A segmented Z1–Z5 bar on the ride screen with a handle
  marking where the current effort sits inside its zone — the "which zone am I in
  *right now*?" readout, complementing the `ZoneGauge` dials ("am I inside my
  *target* band?"). It classifies through `RideHRZoning.zone(forHR:)`, i.e. the exact
  classifier the ride's own time-in-zone scoring uses, so the bar can never name a
  different zone than the ride records for the same beat. **Don't classify a reading
  by scanning `bpmRange`s** — the bands are inclusive at both ends and Friel's Z1
  floor is 0, so a band-scan lands on the wrong zone (it shipped that way in #65's
  first commit and put a 160 bpm Z4 effort in Zone 5); `zone(forHR:)` is the only
  classifier. Pinned by a regression test.
- **Total / In-zone timer pair.** ✅ _Shipped (PR #74 live, PR #75 summary);
  verified in-app._ A running **In-zone** mm:ss timer sits beside the **Total** ride
  timer atop `RideView`, counting seconds of HR-in-target-zone through the same
  `RideHRZoning.secondsInZone` classifier the summary scores with — so the live
  figure can't disagree with the finished ride (it's HR-in-zone, *not* the ±8 W
  power window). The same Total / In-zone pair is mirrored onto `RideSummaryView`
  below the green headline, reading from the persisted `durationSec` and
  `timeInHRZoneSec`, so the two screens read alike.

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

## New ideas — worth considering

Fresh candidates not yet on the tiers above, roughly ordered by value-to-effort.

- **Ride notes / tags / RPE.** A free-text note and a 1–10 perceived-effort rating
  captured at ride end and stored on the ride, so the history is searchable by how
  a session *felt*, not just its numbers. Small SwiftData field + a summary-screen
  input; feeds the trends dashboard and any future HRV-guided suggestions.
- **Manual pause / resume control.** A user-driven pause button on the ride screen
  (distinct from the proposed auto-pause coasting detection) for bathroom/phone
  breaks, so total vs. in-zone timers and time-in-zone math stay honest. Pairs with
  the recorder's existing 1 Hz tick.
- **Cadence target range.** The Kickr's cadence is already parsed, recorded, and
  shown live (`metrics.cadenceRpm`, from Indoor Bike Data). The net-new piece is an
  optional target-cadence band with a visual/audio cue when you drift out of it, so
  steady-zone riders can hold a consistent spin, not just a wattage — reusing the
  same tolerance-window pattern the HR zone bar uses.
- **Configurable ERG / zone tolerance.** The ±8 W in-zone window and the ERG target
  are fixed constants today. Expose them as preferences (per-rider comfort) so the
  in-zone timer and cues reflect how tightly *you* want to hold the number.
- **Export beyond Strava (.fit / .tcx share sheet, Apple Health).** Zona exports TCX
  to Strava only. A generic share-sheet export of the finished ride's TCX/FIT, plus
  writing the workout (duration, avg HR, energy) to Apple Health via HealthKit,
  makes rides portable to TrainingPeaks, intervals.icu, etc.
- **Apple Health as an HR source.** Beyond exporting, read live HR from HealthKit /
  a paired Apple Watch as an alternative to a BLE strap — dovetails with the Tier 4
  Apple Watch companion but is a smaller first step.
- **Warmup / cooldown auto-segments.** Even without a full workout builder, auto-tag
  the opening and closing minutes as warmup/cooldown and exclude them from
  time-in-zone scoring, so a session's "quality" isn't diluted by ramp-up.
- **Multiple rider / FTP profiles.** One set of FTP/LTHR numbers today. Named
  profiles (or a guest mode) would let a second rider use the same install without
  clobbering the primary rider's settings and history.
- **Post-ride Strava-upload retry queue.** If the Strava upload fails (offline,
  token expired), the finished ride currently isn't re-attempted automatically.
  A small pending-upload queue that retries on next launch / reconnect would make
  the integration robust to a flaky network at ride end.

## Suggested next steps

- **Structured workouts** v1 (rider-triggered work/rest block) is done (issue
  #88); a general step-list model for warmups/ramps/pyramids and workout
  import/export remain as follow-ons.
- **HRV chart + SDNN** is the cheapest high-value win — the raw data is already
  stored.
- **Quarq** is done: it both displays (PR #36) and records leg power alongside the
  trainer's (PR #70). L/R balance was considered and dropped — see the item above.
