import Foundation

/// One second of a ride for export. Mirrors `RideSample` but decoupled from it
/// so the exporter has no dependency on the recorder or SwiftData.
public struct TCXSample: Sendable, Equatable {
    public let secondsFromStart: Int
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?
    /// Watts from a paired SRAM/Quarq crank meter this second — the rider's leg
    /// power, carried alongside (never merged into) the trainer's `powerW`. nil
    /// on a meterless ride and on any second the meter didn't report. Which of
    /// the two channels this ride exports is decided once by
    /// `TCXPowerSource.resolve`, not per sample — see there for why.
    public var powerMeterW: Int?

    public init(secondsFromStart: Int,
                powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil,
                powerMeterW: Int? = nil) {
        self.secondsFromStart = secondsFromStart
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
        self.powerMeterW = powerMeterW
    }
}

/// Which recorded power channel a TCX export writes into `<ns3:Watts>`.
///
/// Zona records two power channels per second: the trainer's FTMS watts
/// (`TCXSample.powerW`, the source of truth for ERG and all zone math) and, when
/// a SRAM/Quarq is paired, the rider's leg power (`TCXSample.powerMeterW`). The
/// trainer's figure is a flywheel/resistance-curve *estimate* taken after
/// drivetrain loss; the crank meter measures strain directly and so reads a few
/// watts higher by design. Outdoor rides are recorded from the crank meter, so
/// exporting the trainer's number leaves a rider's Strava history mixing two
/// differently-calibrated sources depending on where they rode.
///
/// This picks one channel for the *whole file*. Choosing per sample — preferring
/// leg power wherever it's present — would swap calibration scale at every coast
/// and dropout, producing a power track that alternates between two scales:
/// worse for anything Strava derives across a ride (power curve, NP, training
/// load) than either source used consistently.
public enum TCXPowerSource: Sendable, Equatable {
    /// The trainer's FTMS watts. Also the fallback whenever leg power is absent
    /// or too sparse to stand alone as a ride's power track.
    case trainer
    /// The crank meter's leg power.
    case powerMeter

    /// The fraction of a ride's samples that must carry leg power before it can
    /// be the export's power source.
    ///
    /// A bare "was a meter ever paired?" test is too permissive: a meter that
    /// connected for thirty seconds and dropped would flip the entire file to
    /// leg power, leaving the vast majority of trackpoints with no `<ns3:Watts>`
    /// at all — and Strava *interpolates* missing power rather than recording
    /// none, so a nearly-empty power track becomes a nearly-invented one. The
    /// floor keeps the one-scale-per-file rule while ensuring the chosen channel
    /// actually covers the ride.
    public static let minimumCoverage = 0.8

    /// Decide the export's power source from the ride's samples.
    ///
    /// Returns `.powerMeter` only when leg power covers at least
    /// `minimumCoverage` of the samples; anything less falls back to `.trainer`,
    /// which streams continuously (including real 0 W frames through a coast).
    /// Coverage is measured against *all* samples, not against those carrying
    /// trainer watts, so a ride is judged on how much of itself the meter
    /// actually recorded.
    public static func resolve(samples: [TCXSample]) -> TCXPowerSource {
        guard !samples.isEmpty else { return .trainer }
        let covered = samples.reduce(into: 0) { count, sample in
            if sample.powerMeterW != nil { count += 1 }
        }
        let coverage = Double(covered) / Double(samples.count)
        return coverage >= minimumCoverage ? .powerMeter : .trainer
    }

    /// The watts this source contributes for a given sample, or nil when that
    /// second has no reading on the chosen channel. A nil is omitted from the
    /// trackpoint entirely rather than written as 0 — the crank meter goes quiet
    /// on a coast instead of sending a zero frame, and banking that as 0 W would
    /// fabricate a reading the rider never held.
    func watts(for sample: TCXSample) -> Int? {
        switch self {
        case .trainer: sample.powerW
        case .powerMeter: sample.powerMeterW
        }
    }
}

/// Encodes a ride as a Garmin TrainingCenterDatabase v2 (TCX) document — plain
/// XML that Strava, TrainingPeaks, intervals.icu, etc. import directly. Pure:
/// takes values in, returns a `String`; no file I/O, no SwiftData. Power lives
/// in the Activity Extension namespace (`ns3:Watts`), which is how Strava reads
/// trainer/power-meter watts from a TCX.
///
/// Which power channel fills `<ns3:Watts>` is decided per file by
/// `TCXPowerSource.resolve` — leg power when a crank meter covered the ride,
/// the trainer otherwise. Cadence is always the trainer's: crank cadence isn't
/// recorded per sample at all, so an exported trackpoint can pair leg-power
/// watts with trainer-derived cadence.
public enum TCXExporter {
    /// Build a TCX document. `start` is the activity start; each sample's time is
    /// `start + secondsFromStart`. `sport` is the TCX Sport attribute.
    /// `durationSeconds` is the ride's true wall-clock length (`RideRecording
    /// .durationSeconds` / `Ride.durationSec`) and, when positive, is what's
    /// written as `<TotalTimeSeconds>` — this is what Strava imports as the
    /// activity's duration, so it must agree with what Zona itself shows,
    /// not with the last sample's index (samples can lag the actual stop
    /// time by a second or more, e.g. on a dropped BLE notification). Falls
    /// back to the last-sample derivation only when no duration was recorded
    /// (0, the same convention `RideSummary` uses).
    public static func makeTCX(start: Date,
                               samples: [TCXSample],
                               sport: String = "Biking",
                               durationSeconds: Int = 0) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")
        iso.formatOptions = [.withInternetDateTime]  // e.g. 2026-07-01T07:30:00Z

        let ordered = samples.sorted { $0.secondsFromStart < $1.secondsFromStart }
        // One power channel for the whole file — resolved once here, never
        // re-decided per trackpoint. See `TCXPowerSource`.
        let powerSource = TCXPowerSource.resolve(samples: ordered)
        let startId = iso.string(from: start)
        let totalSeconds = durationSeconds > 0
            ? durationSeconds
            : ordered.last.map { $0.secondsFromStart + 1 } ?? 0

        // Running distance (metres) at each trackpoint, integrated from speed:
        // each sample's speed is held over the gap to the next (step
        // integration). Matches RideRecording.cumulativeDistanceMeters(); kept
        // local so the exporter stays dependency-free.
        var cumulative = [Double](repeating: 0, count: ordered.count)
        var running = 0.0
        for i in ordered.indices {
            if i + 1 < ordered.count, let kph = ordered[i].speedKph {
                let dt = ordered[i + 1].secondsFromStart - ordered[i].secondsFromStart
                if dt > 0 { running += (kph / 3.6) * Double(dt) }
            }
            cumulative[i] = running
        }
        let totalDistance = cumulative.last ?? 0

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase \
        xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 \
        http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd" \
        xmlns:ns5="http://www.garmin.com/xmlschemas/ActivityGoals/v1" \
        xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2" \
        xmlns:ns2="http://www.garmin.com/xmlschemas/UserProfile/v2" \
        xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <Activities>
            <Activity Sport="\(escape(sport))">
              <Id>\(startId)</Id>
              <Lap StartTime="\(startId)">
                <TotalTimeSeconds>\(totalSeconds)</TotalTimeSeconds>
                <DistanceMeters>\(format(totalDistance))</DistanceMeters>
                <Calories>0</Calories>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>

        """

        for (i, sample) in ordered.enumerated() {
            let time = iso.string(from: start.addingTimeInterval(TimeInterval(sample.secondsFromStart)))
            xml += "          <Trackpoint>\n"
            xml += "            <Time>\(time)</Time>\n"
            // Cumulative distance to this point. Only emitted once the ride has
            // actually covered ground, so power/HR-only rides omit it (0 stays 0).
            if totalDistance > 0 {
                xml += "            <DistanceMeters>\(format(cumulative[i]))</DistanceMeters>\n"
            }
            if let hr = sample.heartRateBpm {
                xml += "            <HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>\n"
            }
            if let cad = sample.cadenceRpm {
                xml += "            <Cadence>\(cad)</Cadence>\n"
            }
            // Speed (m/s) and Watts both live in the ns3 extension. Watts come
            // from whichever channel `powerSource` picked for this file; a
            // second with no reading on that channel omits the element rather
            // than exporting a fabricated 0 W.
            let watts = powerSource.watts(for: sample)
            if sample.speedKph != nil || watts != nil {
                xml += "            <Extensions>\n              <ns3:TPX>\n"
                if let kph = sample.speedKph {
                    let mps = kph / 3.6
                    xml += "                <ns3:Speed>\(format(mps))</ns3:Speed>\n"
                }
                if let watts {
                    xml += "                <ns3:Watts>\(watts)</ns3:Watts>\n"
                }
                xml += "              </ns3:TPX>\n            </Extensions>\n"
            }
            xml += "          </Trackpoint>\n"
        }

        // <Creator> identifies the app that recorded the activity — the standard
        // TCX slot Strava/TrainingPeaks read for "recorded with". It's abstract,
        // so it needs a concrete xsi:type (Device_t). <Author> is the
        // document-level equivalent (Application_t). Both name the app "Zona".
        xml += """
                </Track>
              </Lap>
              <Creator xsi:type="Device_t">
                <Name>\(escape(appName))</Name>
              </Creator>
            </Activity>
          </Activities>
          <Author xsi:type="Application_t">
            <Name>\(escape(appName))</Name>
            <Build>
              <Version>
                <VersionMajor>0</VersionMajor>
                <VersionMinor>1</VersionMinor>
              </Version>
            </Build>
            <LangID>en</LangID>
            <PartNumber>000-00000-00</PartNumber>
          </Author>
        </TrainingCenterDatabase>

        """
        return xml
    }

    /// Name written into the TCX Creator/Author elements (the "recorded with"
    /// source app).
    static let appName = "Zona"

    private static func format(_ v: Double) -> String {
        String(format: "%.3f", v)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
