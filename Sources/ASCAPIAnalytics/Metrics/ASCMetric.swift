import Foundation

/// Additivity semantics of a metric, following the repository's
/// non-negotiable rules: money is `Decimal` and never summed across
/// currencies, and non-additive metrics are never accumulated by simple
/// summation.
public enum ASCMetricAdditivity: Hashable, Codable, Sendable {
    /// May be summed across time, territory, and other dimensions.
    case additive
    /// Apple deduplicates the value within each date and dimension
    /// combination; summing across dates or dimensions double-counts.
    case nonAdditive(deduplication: String)
    /// A ratio of two measures; only recomputable when numerator and
    /// denominator are comparable and cover the same basis.
    case ratio(numerator: String, denominator: String)
}

/// Catalog of the metrics ASCAPIAnalytics models, with their data source,
/// definition, additivity semantics, and support status.
///
/// Support statuses are statements about Apple's published reports:
/// - `supported`: recomputed deterministically from published report data.
/// - `estimated`: computable as a clearly labeled approximation.
/// - `unavailable`: well defined, but not computable for the given inputs.
/// - `unsupported`: Apple's public reports do not publish the data needed,
///   so the package refuses to fabricate it.
public enum ASCMetricCatalog: CaseIterable, Sendable {
    case firstTimeDownloads
    case redownloads
    case manualUpdates
    case autoUpdates
    case restores
    case totalDownloads
    case impressions
    case impressionsUniqueDevices
    case productPageViews
    case productPageViewsUniqueDevices
    case conversionRate
    case salesUnits
    case grossSalesByCurrency
    case developerProceedsByCurrency
    case downloadToPaidDay1
    case downloadToPaidDay7
    case downloadToPaidDay35
    case retentionCohorts

    /// Human-readable definition, citing Apple's published metric
    /// definitions where applicable.
    public var definition: String {
        switch self {
        case .firstTimeDownloads:
            return "First-time downloads. Apple: 'The first time a user downloaded your app. Based on the user's Apple ID account.' (App Downloads report)"
        case .redownloads:
            return "Redownloads. Apple: 'A subsequent installation of an app onto a device by an Apple ID account.' (App Downloads report)"
        case .manualUpdates:
            return "Manual updates: replacing an app on a device with another version, triggered by the user tapping Update. (App Downloads report)"
        case .autoUpdates:
            return "Auto-updates: replacing an app on a device with another version, controlled by the device's settings. (App Downloads report)"
        case .restores:
            return "Restores: restoring an app onto a user's device from iCloud Backup. (App Downloads report)"
        case .totalDownloads:
            return "Apple: 'The sum of First Time Downloads and Redownloads.' Updates are a separate metric. (Analytics metric definitions)"
        case .impressions:
            return "Apple: 'The number of times your app was viewed on the Today, Games, Apps, and Search tabs of the App Store for more than one second. Includes product page views.' (App Store Discovery and Engagement report, Counts)"
        case .impressionsUniqueDevices:
            return "Apple: 'The number of unique devices that have viewed your app on the Today, Games, Apps, and Search tabs of the App Store.' (Discovery and Engagement report, Unique Counts)"
        case .productPageViews:
            return "Apple: 'The total number of times your App Store product page was viewed.' (Discovery and Engagement report, Counts, Event = Page view)"
        case .productPageViewsUniqueDevices:
            return "Apple: 'The number of unique devices that have viewed your App Store product page.' (Discovery and Engagement report, Unique Counts, Event = Page view)"
        case .conversionRate:
            return "Apple: 'Total downloads and pre-orders divided by unique device impressions. When a user pre-orders an app, it counts towards your conversion rate. It is not counted again when it downloads to their device.' Exactly reproducible only for single-day windows with a single unique-impressions deduplication domain; otherwise unavailable or explicitly estimated."
        case .salesUnits:
            return "Aggregated units from the Summary Sales report, split by product type. Negative values are refunds or CMB-C credits."
        case .grossSalesByCurrency:
            return "Customer-price value: units × |customer price| per row, summed only within the same Customer Currency."
        case .developerProceedsByCurrency:
            return "Units × |developer proceeds per unit|, summed only within the same Currency of Proceeds. Apple reports proceeds per unit; the per-unit value must never be summed across rows."
        case .downloadToPaidDay1:
            return "Share of a download cohort that pays within 1 day. Requires cohort-level purchase attribution Apple's public reports do not provide."
        case .downloadToPaidDay7:
            return "Share of a download cohort that pays within 7 days. Requires cohort-level purchase attribution Apple's public reports do not provide."
        case .downloadToPaidDay35:
            return "Share of a download cohort that pays within 35 days. Requires cohort-level purchase attribution Apple's public reports do not provide."
        case .retentionCohorts:
            return "Share of an install cohort still active after N days. Not reconstructable from Apple's public exports; requires cohort-specific data Apple does not publish."
        }
    }

    /// Additivity semantics of the metric.
    public var additivity: ASCMetricAdditivity {
        switch self {
        case .firstTimeDownloads, .redownloads, .manualUpdates, .autoUpdates,
             .restores, .totalDownloads, .salesUnits:
            return .additive
        case .impressions:
            return .additive
        case .productPageViews:
            return .additive
        case .impressionsUniqueDevices:
            return .nonAdditive(
                deduplication: "Unique devices are deduplicated per date and dimension; sums across dates or dimensions double-count devices."
            )
        case .productPageViewsUniqueDevices:
            return .nonAdditive(
                deduplication: "Unique devices are deduplicated per date and dimension; sums across dates or dimensions double-count devices."
            )
        case .conversionRate:
            return .ratio(numerator: "downloads and pre-orders", denominator: "unique device impressions")
        case .grossSalesByCurrency, .developerProceedsByCurrency:
            return .additive
        case .downloadToPaidDay1, .downloadToPaidDay7, .downloadToPaidDay35,
             .retentionCohorts:
            return .nonAdditive(deduplication: "Cohort measure; cannot be recomputed from daily aggregates.")
        }
    }

    /// Static support status of the metric. Input-dependent metrics
    /// (conversion rate) are evaluated per query by their evaluator; the
    /// catalog records the metric-level status.
    public var supportStatus: ASCSupportStatus {
        switch self {
        case .firstTimeDownloads, .redownloads, .manualUpdates, .autoUpdates,
             .restores, .totalDownloads, .impressions, .productPageViews,
             .impressionsUniqueDevices, .productPageViewsUniqueDevices,
             .salesUnits, .grossSalesByCurrency, .developerProceedsByCurrency:
            return .supported
        case .conversionRate:
            return .supported
        case .downloadToPaidDay1, .downloadToPaidDay7, .downloadToPaidDay35:
            return .unsupported(
                reason: "D1/D7/D35 download-to-paid requires cohort-level purchase attribution that Apple's public reports do not publish. The package deliberately does not approximate it."
            )
        case .retentionCohorts:
            return .unsupported(
                reason: "Retention cohorts require cohort-specific data that Apple's public exports do not provide and cannot be rebuilt by summing daily aggregates."
            )
        }
    }
}
