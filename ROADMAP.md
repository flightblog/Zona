# Zona — Roadmap

Possible new features, grouped by value and by how much of the plumbing already
exists. Zona today holds a Kickr Core 2 at a steady ERG wattage while you aim for
a target HR zone, records the ride to SwiftData, computes summaries
(avg/NP/max power, time-in-zone, distance, RMSSD), shows a live HR-zone bar and a
running Total / In-zone timer pair, plays rider-triggered interval sessions that
steer ERG mid-ride and reviews them per-step afterwards, charts watts and HR over
time post-ride, rolls the whole history up into an all-time stats screen, exports
TCX, uploads directly to Strava, and syncs across devices via iCloud/CloudKit.
Several of the items below build on infrastructure that already exists but isn't
yet fully surfaced (persisted R-R intervals; a Quarq's per-second leg power,
recorded, summarized and exported to Strava but not charted).

Two sections at the end are as load-bearing as the tiers: **Suggested next steps**
for where to start, and **Deliberately not planned** for ideas already considered
and dropped — check the latter before adding a candidate, since several of them
look like obvious wins from the code alone and were rejected on how the app is
actually ridden.

## Tier 1 — Highest value, plumbing largely exists

- **Structured workouts / interval sessions.** ✅ _v1 shipped (issue #88): a
  rider-triggered interval block._ A small pre-authored library
  (`IntervalSession` — a free-form ordered `[IntervalStep]` since PR #110,
  `Z3`-and-up work zones typical, authored in a Setup "Interval sessions"
  editor) can be triggered mid-ride,
  typically near the end of a Z2 session; choosing one opens a short 15s "get
  ready" countdown (cancelable) before the first block drives ERG, then
  `IntervalScheduler` steps the ERG target through it via the ride screen's
  existing 1 Hz `.task` loop, only calling `setTargetPower` at a step boundary. A running block can be stopped
  early from a HUD that replaces the manual `TargetAdjuster` while it's active;
  ending (naturally or via Stop) reverts to the **pre-block** target — the one in
  force when the block started, so a mid-ride `TargetAdjuster` trim survives the
  interval — not to `settings.target`. Both ways out of a session early — Stop,
  and the countdown's Cancel — confirm first (PRs #151/#152, verified in the
  app), since neither is undoable from the ride screen. Stop moved out of the HUD
  and into the bottom row's "Add intervals" slot, in orange, while a block runs
  (PR #154, signed-build compiled; that placement is not yet ridden). Cancelling
  in the countdown's last
  seconds is best-effort: the count keeps running under the alert, so a late
  answer gets the block anyway and the Stop confirmation is the backstop.
  Sessions that ran
  are now recorded (`IntervalRun` — the session as ridden, its start second, and
  actual vs. planned length) and reviewed on the summary; the ride is still
  *scored* end-to-end as one block, and the interval only steers watts (no TCX
  laps, no `RideHRZoning`/`RideSummary` scoring changes, no closed-loop HR).
  - **Per-block achieved power/HR in the summary review.** ✅ _Shipped (PR #109)._
    Each `IntervalRun`'s `startedAtSecond` + `actualSeconds` delimit its window
    into the ride's samples, and `IntervalAchievement.perStep` (pure, ZonaKit)
    slices it **per step**, walking the same `session.steps` cursor
    `IntervalScheduler` drove ERG on — so a step is scored over exactly the
    seconds it was commanded over. The card renders an
    achieved table beside the prescription, with a leg-power column when a crank
    meter was paired. Missing readings report nil and render "—", never 0: the
    meter expires on a coast and a strap can drop, and averaging a gap as zero
    would fabricate watts the rider never held.
  - **A general `[IntervalStep]` model** for warmups, ramps, and pyramids.
    ✅ _Shipped (PR #110)._ `IntervalSession` now holds a free-form ordered step
    list instead of `repeats × (work, rest)`; repeat structure is implicit (a
    uniform 4×30/30 is simply eight steps). The editor became an
    add/remove/reorder list with an "Add repeats…" shortcut that expands the
    common shape into ordinary steps. The HUD and summary count steps and name
    zones, since there's no longer a work/rest alternation to label.
    `IntervalSession.init(from:)` still decodes the old shape — sessions are
    snapshotted into `IntervalRun` on every finished ride, and a decode failure
    there is silent (`[]`), so that path is load-bearing for old rides' reviews.
  Remaining as a natural v2:
  - **Workout import/export (.zwo / .erg / .mrc)** below — now unblocked, since
    those formats describe exactly this kind of free-form step list.
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
- **Ride notes / tags / RPE.** A free-text note and a 1–10 perceived-effort rating
  captured at ride end and stored on the ride, so the history records how a session
  *felt* and not only what it measured — the one thing about a steady Z2 hour that
  no sensor on the bike reports. Rides that read identically on watts and HR are
  routinely different rides, and today that difference is lost the moment the
  summary closes. Cheap for what it gives: an input on `RideSummaryView` plus new
  fields on `Ride`, which follow the same rule as `weightKg` and the WHOOP numbers
  — **optional with no default**, so existing rides lightweight-migrate and the
  store stays CloudKit-safe. It also feeds the two features that want a subjective
  signal: the All-Time Stats trends (an RPE-against-power cut says more about
  fitness drift than either number alone) and any future HRV-guided target
  suggestion, which currently has only WHOOP's morning reading to go on and nothing
  about how the last few sessions actually went.

## Tier 2 — Rounds out the ride experience

- **Quarq/SRAM as a recorded power source.** ✅ _Shipped (PR #36 display, PR #70
  recording); verified on a physical meter._ A connected SRAM/Quarq shows its live
  watts, cadence and watts-per-kilo on the ride screen, and its watts are
  **recorded** per-second alongside the trainer's
  (`RideSample.powerMeterW` → `RideSampleModel.powerMeterW`) and summarized into
  the ride summary's own **Power Meter** section on rides ridden with a meter:
  avg, normalized and max leg power, joined by **Avg leg W/kg** and **Normalized
  leg W/kg** (PR #122, verified in-app). Those two reuse the same pure
  `PowerPerWeight.wattsPerKg` as every other W/kg figure, but over the ride's
  *stamped* `weightKg` rather than current settings — so a later weight change or
  WHOOP re-sync can't retroactively rescore a finished ride. They're computed from
  columns that already existed, so no new persisted field was needed. Their labels
  carry the "leg" prefix rather than relying on the section heading, which
  VoiceOver doesn't speak per-tile.
  Back on the ride screen, those three live tiles sit on **their own row** beneath W/kg / Speed / Distance
  (PR #111) rather than sharing that line, which had to shrink its font to fit
  five tiles across a phone. The leg-power W/kg tile (PR #114) reuses the same
  pure `PowerPerWeight.wattsPerKg` as the trainer-derived W/kg tile above it,
  against the same WHOOP-over-manual `effectiveWeightKg` — so the row reads the
  rider's *leg* output per kilo next to the trainer's, and the two figures differ
  for the same reason the raw watts do. The row is keyed on the meter being
  *connected*, not on it having a current reading: a quiet crank sends nothing
  rather than a 0 W frame, so the values expire on a coast and go nil, and keying
  on the reading made the whole row vanish and shift the layout every time the
  rider stopped pedalling. Each value falls back independently to "—" — never 0,
  which would claim watts the rider never held.
  It stays a **parallel channel, not a replacement** for ride *control*: the
  trainer's `powerW` is still the single source of truth for ERG and zone math,
  so leg power can never skew how a ride is held or scored. The **TCX/Strava
  export now prefers leg power** (PR #136), which is the one place the channel
  isn't display-only. Outdoor rides are recorded from the crank meter, so
  uploading the trainer's post-drivetrain-loss estimate left Strava mixing two
  calibrations depending on where the ride happened. The source is chosen once
  per file by the pure `TCXPowerSource.resolve` — never per sample, which would
  alternate scales at every coast — and only when the meter covered ≥80% of the
  ride's samples; below that floor the whole file reverts to trainer watts,
  since Strava interpolates missing power and a sparse leg-power track would be
  mostly invented. Gap seconds omit `<ns3:Watts>` rather than exporting a
  fabricated 0 W. The file's `<Calories>` is derived from that same chosen
  channel (`TCXEnergy`, PR #145 — it had been a hard-coded 0, which anything
  reading the file directly imported as a zero-energy session), so the stated
  energy can't imply one calibration while the power track carries another;
  it's mechanical work over time at a 24% gross-efficiency constant, since Zona
  measures nothing metabolic. Two consequences are deliberate and worth knowing: cadence
  stays trainer-sourced (crank cadence isn't recorded at all, so a trackpoint
  pairs leg watts with trainer cadence), and the in-app summary still scores on
  trainer watts, so a metered ride reads higher on Strava than in Zona — the
  summary captions the trainer-sourced case so an upload's provenance is visible
  before it happens. _Unit-tested (including the floor's boundary and the
  gap-omission rule, each mutation-checked) and verified to build signed on
  macOS._ As expected, a real
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
  #67, target marked in #107); verified on device._ A segmented Z1–Z5 bar on the ride
  screen with a handle marking where the current effort sits inside its zone, plus
  the **target zone** marked by an outlined segment, a below/on/above-tinted handle,
  and a bolded label — so the bar now answers both "which zone am I in *right now*?"
  and "am I where I'm meant to be?" that previously needed the `ZoneGauge` dials.
  That on-target state comes from the same `ZoneState` the dials' PUSH/HOLD/EASE cue
  reads, never a parallel comparison, so the two can't disagree at a band edge.
  `ZoneState` moved into `ZonaKit` in #148 and is unit-tested there, so that
  agreement is now pinned by the suite rather than by review alone.
  It classifies through `RideHRZoning.zone(forHR:)`, i.e. the exact
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
- **Explained summary stats.** ✅ _Shipped (PR #118); verified in-app._ Every
  summary tile whose meaning isn't obvious from its label carries an info glyph
  and opens a plain-English explanation on tap. The pair that prompted it was
  **Avg power** / **Normalized** (and their W/kg counterparts): both are the same
  trainer watts over the same stamped weight, differing only in the averaging, so
  on a steady ERG ride they read almost identically and only visibly diverge after
  an interval session — exactly when the rider wonders why. The Normalized wording
  names the 4th-power effort-weighting and says the gap to Avg measures how spiky
  the ride was. The **Power Meter** section's tiles — the three leg-power ones and
  the two leg W/kg ones added with them (PR #122) — each also
  answer the question that section raises first — why its figures sit above the
  trainer's — repeating that the gap is drivetrain loss rather than an error and
  that the trainer stays what the ride is *scored* on, while the upload prefers
  the meter's watts when it covered the ride (PR #136 narrowed this blurb, which
  until then also claimed the trainer was what the ride uploaded on), wording
  kept in step with the physical explanation on `RideMetrics.powerMeterW`. Two things
  worth not undoing: it's a **popover, not `.help()` alone** (`.help` is a
  macOS-only hover affordance and would be invisible on iOS, where a summary is
  most likely to be read — it's kept alongside so macOS still gets hover); and the
  whole tile stays **one** accessibility element spoken "Avg power: 210 W" with
  the explanation as its hint, the same merge the ride screen's `Metric` tiles
  make. A separately focusable info button gives a rider swiping the grid three
  stops per reading instead of one — the first cut did exactly that and was caught
  in review.

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
  - **OAuth token hardening.** ✅ _Shipped (PR #112)._ Three fixes to the shared
    token plumbing, prompted by a WHOOP refresh failing with `HTTP 400`. A
    refresh token WHOOP won't honour now **clears itself** and asks the rider to
    reconnect: previously it stayed in the Keychain, so `isConnected` stayed
    true and every retry — including the automatic one on each visit to the
    setup screen — replayed the same dead credential, wedging the account with
    no way out but a Disconnect the rider had no reason to suspect. Recognising
    that state needs care, because WHOOP answers a dead token with
    `invalid_request` — the *same* code as a genuinely malformed request, not
    the standard `invalid_grant` — so only `error_hint` separates "reconnect"
    from "our request is wrong"; `WhoopTokenErrorKind` (pure; it now lives in
    HealthConnectKit) matches
    the hint and, deliberately, only ever reports a dead token for a
    `refresh_token` grant, so a malformed code exchange can't send the rider
    round a reconnect loop that wouldn't fix it. Alongside it:
    `FormURLEncoding` replaced two hand-rolled copies of a form encoder that
    escaped RFC 3986's unreserved characters, putting `grant_type` on the wire
    as `refresh%5Ftoken` and corrupting any token containing `-`, `.` or `_`;
    and `TokenRefresher` collapses concurrent refreshes into one, since an
    `actor` alone does **not** serialize them (isolation is released at every
    `await`, so two callers could each burn the same single-use token). Both new
    types are generic, and Strava carried the identical encoder bug. Error
    banners now show WHOOP's `error_hint` rather than the
    boilerplate `error_description` that is identical for every
    `invalid_request` — that change is what identified the real fault.
    _Note: the classifier is tested against error bodies captured from the live
    endpoint; the full expire → clear → reconnect sequence is covered by unit
    tests rather than by an exercised device run._
  - **Strava on the shared refresher.** ✅ _Shipped (PR #125)._ `StravaService`
    now routes its refresh through the same `TokenRefresher`, closing the last
    hand-rolled read-`await`-save refresh in the app — and correcting a doc
    comment that claimed its `actor` serialized the refresh, the same false
    claim WHOOP's carried and probably why the shape survived in two places.
    Latent rather than a live bug: only one call site issues uploads today, so
    it never fired, but the hazard is in the shape of the code rather than in
    how it happens to be called. Strava deliberately does *not* get WHOOP's
    dead-token classification — that exists only because WHOOP answers
    `invalid_request` instead of `invalid_grant`, and writing a Strava
    equivalent without having observed its real failure body would be guessing.
    _Compile- and unit-verified; the refresh path runs only on an expired token
    against a connected account, so it has not been exercised on the wire._
  - **The OAuth plumbing extracted to a shared package.** ✅ _Shipped._ A second
    app (Helix, a multi-source health aggregator) needs the same Strava and WHOOP
    code, so `TokenStore`, `TokenRefresher`, `FormURLEncoding` and the
    Strava/WHOOP OAuth + token/DTO types moved to **HealthConnectKit**, a package
    both depend on. Copying them would have meant two divergent copies of exactly
    the logic whose bugs cost the most to find — the encoder and the
    single-flight refresher above. A move, not a redesign: no logic changed, only
    doc comments naming ZonaKit-internal types. `ZonaKit` re-exports the package
    (`SharedOAuth.swift`), so no app-target file changed. `StravaUpload` and
    `WhoopReadiness` stayed — the scope rule is that a file belongs there only
    if *both* apps could use it, and those are ride features. The consequence to
    remember: **a change to that package is a change to two shipped apps**, so
    Zona's suite passing is no longer sufficient evidence on its own.
    _Verified: ZonaKit's suite passes (the FormURLEncoding and TokenRefresher
    suites moved with their code and pass in the new package), and the app target
    builds unsigned on both platforms with zero source changes — the real check
    on the re-export. The package lives at `flightblog/HealthConnectKit`
    (private), but both repos resolve it by relative path to a sibling checkout
    rather than by URL; CI checks it out alongside using a PAT, since the default
    `GITHUB_TOKEN` can't read another private repo._
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

- **Live Activity / Dynamic Island.** Ride timer, current HR/zone on the lock
  screen.
- **Screen-on / idle management.** ✅ _Shipped (PR #39)._ The display
  stays awake for the whole ride via a `.keepAwake()` modifier on `RideView`
  (which is on screen exactly when a ride is live): iOS sets
  `UIApplication.isIdleTimerDisabled`, macOS holds a `ProcessInfo` activity
  assertion (`.idleDisplaySleepDisabled`). Both are released the moment the view
  disappears (End ride), so normal power management resumes and the screen never
  stays on after a session. Compile-verified on both platforms.
- **VoiceOver on the ride screen.** ✅ _Shipped (PR #65 zone bar, PR #116 metric
  tiles); CI-green on a signed build._ The Z1–Z5 zone bar and all six small
  metric tiles are each a single accessibility element with a spoken label and
  value, rather than the pile of separate number/caption stops SwiftUI produces by
  default. Two rules the tiles encode, both easy to undo by accident: the row
  deliberately repeats short visible titles (three read "SRAM", two read
  "W/kg") because position and unit disambiguate them at a glance — which doesn't
  survive being read aloud, so `Metric` takes an optional `spokenLabel` that
  overrides the visible one ("Leg power" / "Leg cadence" / "Leg watts per
  kilogram", reusing the leg-power vocabulary the summary already uses). And the
  "—" placeholder is announced as **"No reading"**, never as punctuation or
  silence — the audible half of the never-report-a-value-the-rider-didn't-hold
  rule, so an expired crank says "No reading" rather than implying zero.
  The gauges, HUDs and buttons still read as default SwiftUI elements; extending
  the treatment to them is the remaining work.
- **FTP / LTHR test protocols.** Guided ramp or 20-min tests to set the two
  numbers the whole app depends on, instead of typing them in.

## New ideas — worth considering

Fresh candidates not yet on the tiers above, roughly ordered by value-to-effort.

- **Manual pause / resume control.** A user-driven pause button on the ride screen
  (distinct from the proposed auto-pause coasting detection) for bathroom/phone
  breaks, so total vs. in-zone timers and time-in-zone math stay honest. Pairs with
  the recorder's existing 1 Hz tick.
- **Configurable ERG / zone tolerance.** The ±8 W in-zone window and the ERG target
  are fixed constants today. Expose them as preferences (per-rider comfort) so the
  in-zone timer and cues reflect how tightly *you* want to hold the number.
- **Export beyond Strava (.fit / .tcx share sheet, Apple Health).** Zona exports TCX
  to Strava only. A generic share-sheet export of the finished ride's TCX/FIT, plus
  writing the workout (duration, avg HR, energy) to Apple Health via HealthKit,
  makes rides portable to TrainingPeaks, intervals.icu, etc.
- **Warmup / cooldown auto-segments.** Even without a full workout builder, auto-tag
  the opening and closing minutes as warmup/cooldown and exclude them from
  time-in-zone scoring, so a session's "quality" isn't diluted by ramp-up.
- **Post-ride Strava-upload retry queue.** If the Strava upload fails (offline,
  token expired), the finished ride currently isn't re-attempted automatically.
  A small pending-upload queue that retries on next launch / reconnect would make
  the integration robust to a flaky network at ride end.

## Suggested next steps

- **HRV chart + SDNN** is the cheapest high-value win — the raw per-second R-R is
  already persisted, so it needs no new capture and no re-riding, and the summary
  already has the dual-axis chart and the downsampler to reuse.
- **Ride notes / RPE** is the next cheapest, and the only item here that adds a
  kind of data the app doesn't currently hold at all.
- **ERG session resiliency** is the one open item that affects a ride in progress
  rather than the review of it — a mid-ride drop currently leaves the ERG setpoint
  dependent on unverified Kickr firmware behavior.

## Deliberately not planned

Ideas considered and dropped, recorded so they aren't re-proposed. Zona is a
personal, single-rider app that runs on a phone or Mac propped in front of the
trainer, and each of these is a real feature somewhere else that doesn't earn its
keep here. Reopening one needs a reason that changes the premise, not just a
restatement of the idea.

- **Apple Watch companion** (was Tier 4) and **Apple Health as an HR source**. Both
  chase an HR problem that isn't open: a Garmin HRM 200 and a WHOOP both already
  work as ordinary BLE straps, hardware-verified, and `SensorHub` reconnects them
  automatically. A watch target would be a second app to sign, build and keep in
  step with the ride model for a reading Zona already has, and HealthKit live HR
  would be a third path to the same beat.
- **Multiple rider / FTP profiles.** The build is single-user by construction — the
  OAuth client secrets are baked into the binary and the Keychain tokens are
  per-device — so a second rider would want their own install, not a profile
  switcher inside this one.
- **Cadence target range.** The Kickr's cadence is parsed, recorded and shown, so
  the band itself would be easy; the reason to skip it is the ride, not the code.
  Holding a zone already gives the rider one number to steer to, and a second
  simultaneous target competes with it for attention on exactly the sessions meant
  to be unhurried.
- **Closed-loop HR→watts.** Built and then deliberately removed. HR lags and drifts
  too much to close the loop on, which is the whole reason the design holds power
  steady and lets HR define the target zone. Noted here as well as in `CLAUDE.md`
  because it's the idea most likely to look like an obvious improvement.
- **L/R pedal balance.** A tile existed and was removed in PR #52 — see the Quarq
  item above for why a spider-based meter can only estimate the split.
