import Foundation

/// Result of a conversion rate evaluation.
///
/// Apple's definition (Analytics metric definitions):
/// "Total downloads and pre-orders divided by unique device impressions.
/// When a user pre-orders an app, it counts towards your conversion rate.
/// It is not counted again when it downloads to their device."
///
/// The package returns a number only when numerator and denominator are
/// provably comparable; otherwise it reports why the value is unavailable
/// or, on explicit request, marks an approximation as estimated. It never
/// returns an unreliable percentage dressed up as exact.
public enum ASCConversionRateResult: Hashable, Codable, Sendable {
    /// Exactly recomputed for a single-day window with a single unique
    /// impressions deduplication domain.
    case available(rate: Decimal, numerator: Int, denominator: Int)
    /// An approximation, with the reason it is not exact. The denominator
    /// of an estimated rate is an upper bound (daily unique counts summed
    /// without cross-day deduplication), so the estimated rate is a lower
    /// bound of Apple's own value.
    case estimated(rate: Decimal, numerator: Int, denominator: Int, note: String)
    /// The metric is well defined but the inputs do not support computing
    /// it honestly.
    case unavailable(reason: String)
    /// The metric cannot be computed from Apple's published reports.
    case unsupported(reason: String)

    /// The rate as a percentage, when a rate is present.
    public var ratePercent: Decimal? {
        switch self {
        case .available(let rate, _, _): return rate * 100
        case .estimated(let rate, _, _, _): return rate * 100
        case .unavailable, .unsupported: return nil
        }
    }
}

/// Inputs for a conversion rate evaluation. Every input carries its own
/// scope so the evaluator can verify comparability instead of trusting the
/// caller.
public struct ASCConversionRateInputs: Hashable, Codable, Sendable {
    /// Apple identifier of the app the numerator counts downloads for.
    public let numeratorAppIdentifier: String
    /// Date range the numerator covers.
    public let numeratorWindow: ASCDateRange
    /// Total downloads and pre-orders within `numeratorWindow` (Apple's
    /// "Total Downloads" = first-time downloads + redownloads, plus
    /// pre-order placements).
    public let downloadsAndPreOrders: Int

    /// Apple identifier of the app the denominator counts impressions for.
    public let denominatorAppIdentifier: String
    /// Date range the denominator covers.
    public let denominatorWindow: ASCDateRange
    /// Unique device impressions, when available.
    public let uniqueDeviceImpressions: Int?
    /// Number of distinct deduplication domains the unique impressions
    /// were aggregated over (1 means one date in one dimension
    /// combination).
    public let impressionsDeduplicationDomainCount: Int

    public init(
        numeratorAppIdentifier: String,
        numeratorWindow: ASCDateRange,
        downloadsAndPreOrders: Int,
        denominatorAppIdentifier: String,
        denominatorWindow: ASCDateRange,
        uniqueDeviceImpressions: Int?,
        impressionsDeduplicationDomainCount: Int
    ) {
        self.numeratorAppIdentifier = numeratorAppIdentifier
        self.numeratorWindow = numeratorWindow
        self.downloadsAndPreOrders = downloadsAndPreOrders
        self.denominatorAppIdentifier = denominatorAppIdentifier
        self.denominatorWindow = denominatorWindow
        self.uniqueDeviceImpressions = uniqueDeviceImpressions
        self.impressionsDeduplicationDomainCount = impressionsDeduplicationDomainCount
    }
}

/// Evaluates Apple's conversion rate under explicit comparability rules.
public enum ASCConversionRateEvaluator {
    /// Attempts an exact evaluation.
    ///
    /// Rules enforced:
    /// - Numerator and denominator must belong to the same app.
    /// - Numerator and denominator windows must be identical.
    /// - Exactness requires a single-day window: Apple deduplicates
    ///   impression devices per day, and a multi-day unique device count
    ///   cannot be recomputed from published daily values.
    /// - Exactness requires a single deduplication domain (one dimension
    ///   combination); otherwise summing unique counts across source or
    ///   page types would double-count devices.
    /// - A zero denominator produces `unavailable`, never a fabricated
    ///   rate.
    public static func evaluate(
        _ inputs: ASCConversionRateInputs
    ) -> ASCConversionRateResult {
        guard inputs.numeratorAppIdentifier == inputs.denominatorAppIdentifier else {
            return .unavailable(
                reason: "numerator app (\(inputs.numeratorAppIdentifier)) and denominator app (\(inputs.denominatorAppIdentifier)) differ; the ratio would mix populations"
            )
        }
        guard inputs.numeratorWindow == inputs.denominatorWindow else {
            return .unavailable(
                reason: "numerator window (\(inputs.numeratorWindow)) and denominator window (\(inputs.denominatorWindow)) differ; Apple's conversion rate requires the same window on both sides"
            )
        }
        guard let impressions = inputs.uniqueDeviceImpressions else {
            return .unavailable(
                reason: "unique device impressions are not available for this window"
            )
        }
        guard inputs.impressionsDeduplicationDomainCount == 1 else {
            return .unavailable(
                reason: "unique impressions span \(inputs.impressionsDeduplicationDomainCount) deduplication domains (dates and/or dimension combinations); they cannot be deduplicated from published data"
            )
        }
        guard inputs.numeratorWindow.dayCount == 1 else {
            return .unavailable(
                reason: "the window spans \(inputs.numeratorWindow.dayCount) days; unique devices are deduplicated per day, so a multi-day conversion rate cannot be reproduced exactly (use evaluateAllowingEstimate for a labeled lower bound)"
            )
        }
        guard impressions > 0 else {
            return .unavailable(
                reason: "unique device impressions are zero for this window"
            )
        }
        let rate = Decimal(inputs.downloadsAndPreOrders) / Decimal(impressions)
        return .available(
            rate: rate,
            numerator: inputs.downloadsAndPreOrders,
            denominator: impressions
        )
    }

    /// Attempts an evaluation, falling back to an explicitly labeled
    /// estimate when exactness is impossible but a defensible approximation
    /// exists: the denominator becomes the sum of per-day unique counts,
    /// which double-counts devices across days and is therefore an upper
    /// bound; the estimated rate is a lower bound of Apple's value.
    ///
    /// Only the multi-day case is estimable. Dimension splits, app
    /// mismatches, and window mismatches remain `unavailable` even here —
    /// there is no defensible approximation for those.
    public static func evaluateAllowingEstimate(
        _ inputs: ASCConversionRateInputs
    ) -> ASCConversionRateResult {
        let exact = evaluate(inputs)
        if case .available = exact {
            return exact
        }

        guard inputs.numeratorAppIdentifier == inputs.denominatorAppIdentifier else {
            return exact
        }
        guard inputs.numeratorWindow == inputs.denominatorWindow else {
            return exact
        }
        guard inputs.impressionsDeduplicationDomainCount == 1 else {
            return exact
        }
        guard let impressions = inputs.uniqueDeviceImpressions, impressions > 0 else {
            return exact
        }
        let days = inputs.numeratorWindow.dayCount
        guard days > 1 else {
            return exact
        }

        let rate = Decimal(inputs.downloadsAndPreOrders) / Decimal(impressions)
        return .estimated(
            rate: rate,
            numerator: inputs.downloadsAndPreOrders,
            denominator: impressions,
            note: "denominator sums \(days) days of per-day unique device impressions without cross-day deduplication; it is an upper bound, so this rate is a lower bound of Apple's conversion rate"
        )
    }
}

/// Static status of the D1/D7/D35 download-to-paid family: deliberately
/// unsupported. Cohort-level purchase attribution is not published in any
/// report this package consumes, and computing it from aggregate data
/// would fabricate precision.
public enum ASCDownloadToPaidStatus {
    public static func status(day: Int) -> ASCSupportStatus {
        .unsupported(
            reason: "D\(day) download-to-paid requires knowing which purchases came from which download cohort. Apple's public reports do not publish cohort-level purchase attribution, so this package does not approximate it."
        )
    }
}
