import Foundation

/// Counts for a download type that this package version does not
/// classify. The raw Apple value is preserved.
public struct ASCOtherDownloadTypeCounts: Hashable, Codable, Sendable {
    /// Raw `Download Type` value as reported by Apple.
    public let rawDownloadType: String
    /// Σ counts of rows with this raw type.
    public let counts: Int
}

/// Metrics computed over a set of App Downloads report records.
///
/// All counts are additive over time, territory, and app. Per Apple's
/// metric definitions, `appleTotalDownloads` (First Time Downloads +
/// Redownloads) is the metric Apple calls "Total Downloads"; updates are a
/// separate metric and are tracked in their own buckets.
public struct ASCDownloadMetrics: Hashable, Codable, Sendable {
    /// `First-time Download` counts (Apple ID account based, not device
    /// based).
    public let firstTimeDownloads: Int
    /// `Redownload` counts.
    public let redownloads: Int
    /// `Manual update` counts.
    public let manualUpdates: Int
    /// `Auto-update` counts.
    public let autoUpdates: Int
    /// `Restore` counts.
    public let restores: Int
    /// Counts of download types not in Apple's published glossary,
    /// preserved by raw value and sorted by it.
    public let otherDownloadTypeCounts: [ASCOtherDownloadTypeCounts]
    /// Σ counts of rows whose `Pre-Order` flag is true.
    ///
    /// This flag means the *download came from a pre-order* — those rows
    /// are already inside their download-type buckets above and are NOT
    /// independent pre-order placements. Apple's Pre-Orders metric ("the
    /// total number of pre-orders placed, minus cancelations") is not
    /// computable from the downloads report; placements live in the App
    /// Store Pre-orders report. Never add `preOrderCounts` on top of
    /// `appleTotalDownloads` — that would double count.
    public let preOrderCounts: Int

    /// Number of records contributing.
    public let recordCount: Int

    /// Apple's "Total Downloads" metric: First Time Downloads +
    /// Redownloads.
    public var appleTotalDownloads: Int {
        firstTimeDownloads + redownloads
    }

    /// Σ of every count bucket, including unknown download types.
    public var allCountsTotal: Int {
        firstTimeDownloads + redownloads + manualUpdates + autoUpdates
            + restores + otherDownloadTypeCounts.map(\.counts).reduce(0, +)
    }

    /// Computes metrics over the given records.
    public init(records: [ASCDownloadRecord]) {
        var firstTime = 0
        var redownload = 0
        var manual = 0
        var auto = 0
        var restore = 0
        var other: [String: Int] = [:]
        var preOrders = 0

        for record in records {
            switch record.downloadType {
            case .firstTimeDownload: firstTime += record.counts
            case .redownload: redownload += record.counts
            case .manualUpdate: manual += record.counts
            case .autoUpdate: auto += record.counts
            case .restore: restore += record.counts
            case .other(let raw):
                other[raw, default: 0] += record.counts
            }
            if record.isPreOrder == true {
                preOrders += record.counts
            }
        }

        self.firstTimeDownloads = firstTime
        self.redownloads = redownload
        self.manualUpdates = manual
        self.autoUpdates = auto
        self.restores = restore
        self.otherDownloadTypeCounts = other
            .map { ASCOtherDownloadTypeCounts(rawDownloadType: $0.key, counts: $0.value) }
            .sorted { $0.rawDownloadType < $1.rawDownloadType }
        self.preOrderCounts = preOrders
        self.recordCount = records.count
    }
}
