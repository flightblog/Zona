import Foundation

/// Decoded body of `POST /uploads` and `GET /uploads/{id}`. During processing
/// `activityId` and `error` are both null; on success `activityId` is set; on
/// failure (including a duplicate) `error` carries a human-readable message.
public struct StravaUploadStatus: Codable, Sendable, Equatable {
    public let id: Int64
    public let idStr: String?
    public let error: String?
    public let status: String?
    public let activityId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case idStr = "id_str"
        case error
        case status
        case activityId = "activity_id"
    }

    public init(id: Int64, idStr: String? = nil, error: String? = nil,
                status: String? = nil, activityId: Int64? = nil) {
        self.id = id
        self.idStr = idStr
        self.error = error
        self.status = status
        self.activityId = activityId
    }
}

/// Terminal (or not-yet-terminal) interpretation of an upload status. Pure — the
/// caller keeps polling while `.pending`, and stops on anything else.
public enum StravaUploadOutcome: Sendable, Equatable {
    /// Still processing — keep polling.
    case pending
    /// Imported successfully; the new Strava activity id.
    case succeeded(activityId: Int64)
    /// Strava rejected it as a duplicate of an existing activity. The id is
    /// present when it could be parsed out of the error message, else nil.
    case duplicate(activityId: Int64?)
    /// Any other failure, with Strava's message.
    case failed(message: String)
}

/// Pure interpretation of upload status bodies + the multipart field constants.
/// No timers, no networking: the app drives the poll loop and hands each decoded
/// body here.
public enum StravaUploadPoll {
    /// `data_type` form value for a TCX upload.
    public static let dataType = "tcx"

    /// The multipart file's filename, e.g. `Zona-2026-07-01-0730.tcx`. Strava
    /// keys the format off `data_type`, but a sensible `.tcx` filename is tidy.
    public static func multipartFilename(for base: String) -> String { "\(base).tcx" }

    /// Map one status body to an outcome. Order matters: a successful
    /// `activity_id` wins; then a non-null `error` is inspected for Strava's
    /// duplicate phrasing ("duplicate of activity <id>"); any other error is a
    /// plain failure; otherwise we're still processing.
    public static func outcome(for status: StravaUploadStatus) -> StravaUploadOutcome {
        if let activityId = status.activityId {
            return .succeeded(activityId: activityId)
        }
        if let error = status.error, !error.isEmpty {
            if isDuplicate(error) {
                return .duplicate(activityId: duplicateActivityId(in: error))
            }
            return .failed(message: error)
        }
        return .pending
    }

    /// Whether Strava's error message indicates a duplicate upload.
    static func isDuplicate(_ error: String) -> Bool {
        error.range(of: "duplicate", options: .caseInsensitive) != nil
    }

    /// Extract the conflicting activity id from a duplicate error like
    /// "duplicate of activity 123456", or nil if it can't be parsed (the message
    /// phrasing isn't formally versioned, so degrade gracefully).
    static func duplicateActivityId(in error: String) -> Int64? {
        // First run of digits in the message. Duplicate errors name the id and
        // carry no other numbers, so the first integer is the activity id.
        guard let match = error.range(of: #"[0-9]+"#, options: .regularExpression) else {
            return nil
        }
        return Int64(error[match])
    }
}

/// The web URL for a Strava activity, for the "View on Strava" link.
public func stravaActivityURL(_ activityId: Int64) -> URL {
    URL(string: "https://www.strava.com/activities/\(activityId)")!
}
