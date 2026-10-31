import Foundation

/// Support level of a metric or aggregate value.
///
/// The package refuses to dress unavailable numbers up as zeros: anything
/// Apple does not publish precisely, or that cannot be recomputed honestly
/// from published data, is returned with an explicit status and reason
/// (repository rules 4 and 10).
public enum ASCSupportStatus: Hashable, Codable, Sendable {
    /// The value is directly supported by published Apple data and
    /// recomputed deterministically from it.
    case supported
    /// The value is an approximation of Apple's own number; `note` states
    /// what was approximated.
    case estimated(note: String)
    /// The value cannot be produced for the given inputs, but the metric
    /// itself is well defined. `reason` states what is missing.
    case unavailable(reason: String)
    /// The metric cannot be produced from Apple's published reports at all.
    case unsupported(reason: String)
}

/// Data completeness of an Analytics report instance relative to Apple's
/// published completeness thresholds (App Downloads report: "Completeness:
/// Within two days"; App Store Discovery and Engagement report:
/// "Completeness: Within three days").
///
/// Apple's Data Completeness and Corrections documentation: an instance
/// processed on date P contains *complete* data for event dates up to the
/// completeness threshold before P, and *full but not complete* data for
/// more recent event dates.
public enum ASCDataCompleteness: Hashable, Codable, Sendable {
    /// Data for the given event date is complete according to the report's
    /// published threshold and the instance processing date.
    case complete
    /// Data is full but not yet complete; `expectedCompleteOnOrAfter` is
    /// the earliest processing date that will carry the completed data.
    case notYetComplete(expectedCompleteOnOrAfter: String)
    /// Completeness cannot be assessed (for example Sales and Trends
    /// reports, for which Apple does not publish an exact day threshold).
    case unknown
}

/// A data-quality annotation attached to results.
public struct ASCQualityNote: Hashable, Codable, Sendable, CustomStringConvertible {
    /// Stable machine-readable code, for example `unique-counts-dedup`.
    public let code: String
    /// Human-readable explanation.
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "[\(code)] \(message)" }
}

/// Completeness thresholds published by Apple for the Analytics reports
/// this package adapts. Values are taken verbatim from each report's
/// documentation page and must be re-verified if Apple changes them.
public enum ASCReportCompletenessThreshold {
    /// App Downloads report: "Completeness: Within two days."
    public static let analyticsDownloadsDays = 2
    /// App Store Discovery and Engagement report:
    /// "Completeness: Within three days."
    public static let analyticsDiscoveryAndEngagementDays = 3

    /// Assesses completeness of an event date within an instance.
    ///
    /// - Parameters:
    ///   - eventDate: the report Date column value.
    ///   - processingDate: Apple's processing date of the instance.
    ///   - thresholdDays: the report's published completeness threshold.
    public static func assess(
        eventDate: ASCCalendarDate,
        processingDate: ASCCalendarDate,
        thresholdDays: Int
    ) -> ASCDataCompleteness {
        let completeOnOrAfter = eventDate.adding(days: thresholdDays)
        if processingDate >= completeOnOrAfter {
            return .complete
        }
        return .notYetComplete(expectedCompleteOnOrAfter: completeOnOrAfter.iso8601Day)
    }
}
