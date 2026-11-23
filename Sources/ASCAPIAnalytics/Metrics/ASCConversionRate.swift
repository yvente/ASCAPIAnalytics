import Foundation

/// What basis the denominator of a conversion rate was computed on.
///
/// Apple's dashboard denominator is **"Impressions (Unique Devices)"**,
/// which *includes unique product page views* ("The number of unique
/// devices that have viewed your app on the Today, Games, Apps, and
/// Search tabs of the App Store. Includes unique product page views.").
/// The App Store Discovery and Engagement report splits that universe
/// into separate `Impression` and `Page view` events, and the per-device
/// overlap between the two event types is not published — so a
/// denominator derived from the report's impression events alone is
/// narrower than Apple's, and its exact distance from Apple's value
/// cannot be proven in either direction.
public enum ASCImpressionBasis: Hashable, Codable, Sendable {
    /// The caller asserts that the denominator equals Apple's dashboard
    /// "Impressions (Unique Devices)" for the window — for example because
    /// it was read from Apple's own dashboard export. The assertion is the
    /// caller's responsibility; ASCAPIAnalytics cannot verify it.
    case assertedDashboardUniqueDevices
    /// The denominator was derived from Discovery-report Impression-event
    /// unique counts only. This basis is provably narrower than Apple's
    /// dashboard impressions whenever any product page view occurred, and
    /// the overlap is unknowable — it can never produce a conversion rate
    /// proven to match Apple's, so evaluation refuses it.
    case discoveryReportImpressionEventsOnly
}

/// Result of a conversion rate evaluation.
///
/// Apple's definition (Analytics metric definitions):
/// "Total downloads and pre-orders divided by unique device impressions.
/// When a user pre-orders an app, it counts towards your conversion rate.
/// It is not counted again when it downloads to their device."
///
/// The package returns a number only when numerator and denominator are
/// provably comparable **and** the denominator's basis is asserted to be
/// Apple's dashboard basis; otherwise it reports why the value is
/// unavailable or, on explicit request and only for the multi-day case,
/// marks an approximation as estimated. It never returns an unreliable
/// percentage dressed up as exact, and it never labels an approximation
/// as a mathematically proven bound.
public enum ASCConversionRateResult: Hashable, Codable, Sendable {
    /// Exactly recomputed for a single-day window with a single unique
    /// impressions deduplication domain and an asserted dashboard basis.
    case available(rate: Decimal, numerator: Int, denominator: Int)
    /// An approximation, with the reason it is not exact. The note states
    /// what was approximated; because the true dashboard value is not
    /// reconstructable from published data, no mathematical bound
    /// direction is claimed.
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
    /// Total downloads **and pre-order placements** within
    /// `numeratorWindow`, each counted exactly once.
    ///
    /// Apple counts a pre-order towards the conversion rate when it is
    /// placed and "not counted again when it downloads to their device".
    /// The App Downloads report's `Pre-Order` flag marks downloads that
    /// came from a pre-order — those rows are already inside the download
    /// counts and must **not** be added a second time. Pre-order
    /// placements themselves live in the App Store Pre-orders report
    /// ("placed, minus cancelations"), not in the downloads report.
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
    /// What the denominator was computed on. Only an asserted dashboard
    /// basis can produce an `available` result.
    public let denominatorBasis: ASCImpressionBasis

    public init(
        numeratorAppIdentifier: String,
        numeratorWindow: ASCDateRange,
        downloadsAndPreOrders: Int,
        denominatorAppIdentifier: String,
        denominatorWindow: ASCDateRange,
        uniqueDeviceImpressions: Int?,
        impressionsDeduplicationDomainCount: Int,
        denominatorBasis: ASCImpressionBasis
    ) {
        self.numeratorAppIdentifier = numeratorAppIdentifier
        self.numeratorWindow = numeratorWindow
        self.downloadsAndPreOrders = downloadsAndPreOrders
        self.denominatorAppIdentifier = denominatorAppIdentifier
        self.denominatorWindow = denominatorWindow
        self.uniqueDeviceImpressions = uniqueDeviceImpressions
        self.impressionsDeduplicationDomainCount = impressionsDeduplicationDomainCount
        self.denominatorBasis = denominatorBasis
    }
}

/// Evaluates Apple's conversion rate under explicit comparability rules.
public enum ASCConversionRateEvaluator {
    /// Attempts an exact evaluation.
    ///
    /// Rules enforced:
    /// - The denominator basis must be asserted to be Apple's dashboard
    ///   "Impressions (Unique Devices)". A denominator derived from
    ///   Discovery-report impression events alone is refused: Apple's
    ///   dashboard impressions include unique product page views, and the
    ///   per-device overlap between impression and page-view events is
    ///   not published.
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
        guard inputs.denominatorBasis == .assertedDashboardUniqueDevices else {
            return .unavailable(
                reason: "the denominator is derived from Discovery-report impression events only; Apple's conversion-rate denominator is dashboard Impressions (Unique Devices), which include unique product page views — the per-device overlap between impression and page-view events is not published, so this basis cannot reproduce Apple's conversion rate"
            )
        }
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
                reason: "the window spans \(inputs.numeratorWindow.dayCount) days; unique devices are deduplicated per day, so a multi-day conversion rate cannot be reproduced exactly (use evaluateAllowingEstimate for a labeled approximation)"
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
    /// approximation when exactness is impossible but the only obstacle is
    /// the multi-day window: the denominator becomes the sum of per-day
    /// unique counts, which double-counts devices across days. The note
    /// states this without claiming a mathematical bound direction — the
    /// true dashboard value is not reconstructable from published data, so
    /// neither "lower bound" nor "upper bound" can be proven.
    ///
    /// Only the multi-day case is estimable, and only on an asserted
    /// dashboard basis. Dimension splits, app mismatches, window
    /// mismatches, and report-derived impression bases remain
    /// `unavailable` even here.
    public static func evaluateAllowingEstimate(
        _ inputs: ASCConversionRateInputs
    ) -> ASCConversionRateResult {
        let exact = evaluate(inputs)
        if case .available = exact {
            return exact
        }

        guard inputs.denominatorBasis == .assertedDashboardUniqueDevices else {
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
            note: "denominator sums \(days) days of per-day unique device impressions without cross-day device deduplication; it is an approximation whose direction and magnitude relative to Apple's own conversion rate cannot be proven from published data"
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
