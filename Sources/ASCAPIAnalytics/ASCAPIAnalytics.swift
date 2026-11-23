/// Root namespace of the ASCAPIAnalytics module.
///
/// ASCAPIAnalytics is the reporting companion to `ASCAPIKit`. Its scope is
/// the post-API layer of App Store Connect reporting:
///
/// - Report retrieval flows (through the `ASCReportProvider` abstraction)
/// - Decompression (gzip) and parsing of report files (TSV/CSV)
/// - Metric definitions and computation
/// - Aggregation with currency and additivity rules
/// - Data quality, completeness, and provenance records
/// - Synchronization state (late data, corrections, duplicate segments,
///   interrupted resumes) against the `ASCAnalyticsStore` protocol
///
/// All App Store Connect authentication and API requests are delegated to
/// `ASCAPIKit`; this module never re-implements ES256 JWT signing or Apple's
/// HTTP API client.
///
/// The package has no published release yet. The implemented core covers
/// the Summary Sales report, the App Downloads report, the App Store
/// Discovery and Engagement report, their metrics, aggregation, an
/// in-memory store, and an idempotent sync engine; see `README.md` and
/// `docs/METRIC_DEFINITIONS.md` for exactly what is supported, estimated,
/// or explicitly unsupported.
public enum ASCAPIAnalytics {
    /// Version of the package. Reflects its initial development state; no
    /// release has been published under this version.
    public static let version = "0.1.0-dev"
}
