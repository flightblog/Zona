import Foundation

/// One second of a ride for export. Mirrors `RideSample` but decoupled from it
/// so the exporter has no dependency on the recorder or SwiftData.
public struct TCXSample: Sendable, Equatable {
    public let secondsFromStart: Int
    public var powerW: Int?
    public var cadenceRpm: Int?
    public var speedKph: Double?
    public var heartRateBpm: Int?

    public init(secondsFromStart: Int,
                powerW: Int? = nil,
                cadenceRpm: Int? = nil,
                speedKph: Double? = nil,
                heartRateBpm: Int? = nil) {
        self.secondsFromStart = secondsFromStart
        self.powerW = powerW
        self.cadenceRpm = cadenceRpm
        self.speedKph = speedKph
        self.heartRateBpm = heartRateBpm
    }
}

/// Encodes a ride as a Garmin TrainingCenterDatabase v2 (TCX) document — plain
/// XML that Strava, TrainingPeaks, intervals.icu, etc. import directly. Pure:
/// takes values in, returns a `String`; no file I/O, no SwiftData. Power lives
/// in the Activity Extension namespace (`ns3:Watts`), which is how Strava reads
/// trainer/power-meter watts from a TCX.
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
            // Speed (m/s) and Watts both live in the ns3 extension.
            if sample.speedKph != nil || sample.powerW != nil {
                xml += "            <Extensions>\n              <ns3:TPX>\n"
                if let kph = sample.speedKph {
                    let mps = kph / 3.6
                    xml += "                <ns3:Speed>\(format(mps))</ns3:Speed>\n"
                }
                if let watts = sample.powerW {
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
