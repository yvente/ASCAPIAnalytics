/// Root namespace of the ASCAPIAnalytics module.
///
/// ASCAPIAnalytics is the reporting companion to `ASCAPIKit`. Its planned
/// scope is the post-API layer of App Store Connect reporting:
///
/// - Report retrieval flows
/// - Decompression and parsing of report files
/// - Metric definitions and computation
/// - Aggregation with currency and additivity rules
/// - Data quality and provenance records
/// - Synchronization state (late data, corrections, duplicate segments,
///   interrupted resumes)
///
/// All App Store Connect authentication and API requests are delegated to
/// `ASCAPIKit`; this module never re-implements ES256 JWT signing or Apple's
/// HTTP API client.
///
/// The package is currently in initial development: none of the analytics
/// functionality above is implemented yet, and the package has no published
/// release.
public enum ASCAPIAnalytics {
    /// Version of the package. Reflects its initial development state; no
    /// release has been published under this version.
    public static let version = "0.1.0-dev"
}
