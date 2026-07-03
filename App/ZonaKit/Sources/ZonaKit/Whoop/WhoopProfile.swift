import Foundation

/// `GET /v2/user/measurement/body` — a flat object. We only need `max_heart_rate`
/// (one of the two inputs to WHOOP's HRR zones), but decode the rest for clarity.
public struct WhoopBodyMeasurement: Codable, Sendable, Equatable {
    public let maxHeartRate: Int
    public let heightMeter: Double?
    public let weightKilogram: Double?

    enum CodingKeys: String, CodingKey {
        case maxHeartRate = "max_heart_rate"
        case heightMeter = "height_meter"
        case weightKilogram = "weight_kilogram"
    }
}

/// One recovery record's score. WHOOP nests the physiological numbers here.
/// `restingHeartRate` is the second input to the HRR zones. Optional because a
/// still-calibrating or scoreless recovery can omit the score object.
public struct WhoopRecoveryScore: Codable, Sendable, Equatable {
    public let restingHeartRate: Double?
    public let hrvRmssdMilli: Double?
    public let recoveryScore: Double?

    enum CodingKeys: String, CodingKey {
        case restingHeartRate = "resting_heart_rate"
        case hrvRmssdMilli = "hrv_rmssd_milli"
        case recoveryScore = "recovery_score"
    }
}

/// One record in `GET /v2/recovery`. The `score` is nil while WHOOP is still
/// scoring the associated sleep.
public struct WhoopRecoveryRecord: Codable, Sendable, Equatable {
    public let score: WhoopRecoveryScore?
}

/// The paginated envelope WHOOP wraps collection endpoints in. Records for
/// `GET /v2/recovery` are sorted by sleep start descending, so `records.first` is
/// the most recent recovery.
public struct WhoopRecoveryPage: Codable, Sendable, Equatable {
    public let records: [WhoopRecoveryRecord]
    public let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case records
        case nextToken = "next_token"
    }

    /// Resting HR (bpm) from the most recent scored recovery, or nil if none of
    /// the returned records has a score yet.
    public var latestRestingHR: Int? {
        for record in records {
            if let rhr = record.score?.restingHeartRate {
                return Int(rhr.rounded())
            }
        }
        return nil
    }
}
