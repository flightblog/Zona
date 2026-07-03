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

/// A single day's WHOOP recovery, in the units the UI shows: recovery percentage
/// (0–100), HRV in milliseconds (RMSSD), and resting HR in bpm. Any field can be
/// absent if WHOOP hasn't scored it. Derived from a `WhoopRecoveryScore` so the
/// wire shape stays confined to the DTO.
public struct WhoopRecovery: Sendable, Equatable {
    public let recoveryScore: Int?
    public let hrvMs: Int?
    public let restingHR: Int?

    public init(recoveryScore: Int?, hrvMs: Int?, restingHR: Int?) {
        self.recoveryScore = recoveryScore
        self.hrvMs = hrvMs
        self.restingHR = restingHR
    }

    /// Build from a WHOOP score, rounding the wire doubles to whole units.
    public init(from score: WhoopRecoveryScore) {
        self.recoveryScore = score.recoveryScore.map { Int($0.rounded()) }
        self.hrvMs = score.hrvRmssdMilli.map { Int($0.rounded()) }
        self.restingHR = score.restingHeartRate.map { Int($0.rounded()) }
    }
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
        latestRecovery?.restingHR
    }

    /// The most recent scored recovery (score/HRV/resting HR together), or nil if
    /// none of the returned records has a score yet. Records are newest-first, so
    /// this is the first one carrying a score.
    public var latestRecovery: WhoopRecovery? {
        for record in records {
            if let score = record.score {
                return WhoopRecovery(from: score)
            }
        }
        return nil
    }
}
