import Foundation

/// A `Unique Counts` value together with the deduplication domain it was
/// computed in. Unique counts are deduplicated by Apple per device within
/// one date and one dimension combination, so the domain travels with the
/// value.
public struct ASCUniqueCountEntry: Hashable, Codable, Sendable {
    /// Deduplication domain key (event date + all dimension values).
    public let deduplicationKey: String
    /// Event date of the row.
    public let date: ASCCalendarDate
    /// Raw event value (for example `Impression`, `Page view`).
    public let rawEvent: String
    /// The unique count for this domain.
    public let uniqueCounts: Int
}

/// Metrics computed over a set of App Store Discovery and Engagement
/// report records.
///
/// `Counts` values are additive and are summed here. `Unique Counts`
/// values are **never summed**: they are kept per deduplication domain,
/// and `combinedUniqueCounts` reports why a combined number cannot be
/// produced honestly. Summing unique counts across dates or dimension
/// values would double-count devices.
public struct ASCDiscoveryMetrics: Hashable, Codable, Sendable {
    /// Σ `Counts` of rows with `Event` = Impression.
    public let impressionCounts: Int
    /// Σ `Counts` of rows with `Event` = Page view.
    public let pageViewCounts: Int
    /// Σ `Counts` of rows with `Event` = Tap.
    public let tapCounts: Int
    /// Σ `Counts` of rows with any other raw `Event` value.
    public let otherEventCounts: Int
    /// Raw event values of the `other` bucket, sorted.
    public let otherEventValues: [String]
    /// Σ `Counts` over all rows.
    public let totalEventCounts: Int
    /// Breakdown of impression counts by raw `Source Type` (additive),
    /// sorted by source.
    public let impressionCountsBySourceType: [ASCOtherDownloadTypeCounts]
    /// Breakdown of impression counts by raw `Page Type` (additive),
    /// sorted by page type.
    public let impressionCountsByPageType: [ASCOtherDownloadTypeCounts]
    /// Breakdown of page view counts by raw `Page Type` (additive), sorted.
    public let pageViewCountsByPageType: [ASCOtherDownloadTypeCounts]
    /// `Unique Counts` values, one entry per contributing deduplication
    /// domain, sorted by domain key. Never aggregated.
    public let uniqueCountEntries: [ASCUniqueCountEntry]

    /// Number of records contributing.
    public let recordCount: Int

    /// Status of a combined unique-impressions number.
    ///
    /// Only available when exactly one deduplication domain contributed a
    /// unique count (a single date in a single dimension combination).
    /// Anything else — multiple dates, multiple source or page types,
    /// multiple devices breakdowns — cannot be deduplicated from published
    /// data and stays unavailable.
    public var combinedUniqueImpressionCounts: ASCSupportStatus {
        combinedUniqueCounts(events: [.impression])
    }

    /// Same as `combinedUniqueImpressionCounts` for page views.
    public var combinedUniquePageViewCounts: ASCSupportStatus {
        combinedUniqueCounts(events: [.pageView])
    }

    private func combinedUniqueCounts(events: [ASCDiscoveryEvent]) -> ASCSupportStatus {
        let relevant = uniqueCountEntries.filter { entry in
            events.contains(ASCDiscoveryEvent.classify(entry.rawEvent))
        }
        guard !relevant.isEmpty else {
            return .unavailable(reason: "no unique counts present for the requested events")
        }
        let domains = Set(relevant.map(\.deduplicationKey))
        guard domains.count == 1 else {
            return .unavailable(
                reason: "unique counts cover \(domains.count) deduplication domains (dates and/or dimension combinations); Apple deduplicates devices within each domain only, so summing them would double-count devices"
            )
        }
        guard relevant.count == 1 else {
            return .unavailable(
                reason: "multiple rows report unique counts for the same deduplication domain; the report layout is not understood well enough to combine them"
            )
        }
        return .supported
    }

    /// Computes metrics over the given records.
    public init(records: [ASCDiscoveryRecord]) {
        var impressions = 0
        var pageViews = 0
        var taps = 0
        var other = 0
        var otherValues = Set<String>()
        var impressionsBySource: [String: Int] = [:]
        var impressionsByPage: [String: Int] = [:]
        var pageViewsByPage: [String: Int] = [:]
        var uniqueEntries: [ASCUniqueCountEntry] = []
        var total = 0

        for record in records {
            total += record.counts
            switch record.event {
            case .impression:
                impressions += record.counts
                if let source = record.sourceType {
                    impressionsBySource[source, default: 0] += record.counts
                }
                if let page = record.pageType {
                    impressionsByPage[page, default: 0] += record.counts
                }
            case .pageView:
                pageViews += record.counts
                if let page = record.pageType {
                    pageViewsByPage[page, default: 0] += record.counts
                }
            case .tap:
                taps += record.counts
            case .other(let raw):
                other += record.counts
                otherValues.insert(raw)
            }
            if let unique = record.uniqueCounts {
                uniqueEntries.append(
                    ASCUniqueCountEntry(
                        deduplicationKey: record.uniqueCountsDeduplicationKey,
                        date: record.date,
                        rawEvent: record.rawEvent,
                        uniqueCounts: unique
                    )
                )
            }
        }

        self.impressionCounts = impressions
        self.pageViewCounts = pageViews
        self.tapCounts = taps
        self.otherEventCounts = other
        self.otherEventValues = otherValues.sorted()
        self.totalEventCounts = total
        self.impressionCountsBySourceType = impressionsBySource
            .map { ASCOtherDownloadTypeCounts(rawDownloadType: $0.key, counts: $0.value) }
            .sorted { $0.rawDownloadType < $1.rawDownloadType }
        self.impressionCountsByPageType = impressionsByPage
            .map { ASCOtherDownloadTypeCounts(rawDownloadType: $0.key, counts: $0.value) }
            .sorted { $0.rawDownloadType < $1.rawDownloadType }
        self.pageViewCountsByPageType = pageViewsByPage
            .map { ASCOtherDownloadTypeCounts(rawDownloadType: $0.key, counts: $0.value) }
            .sorted { $0.rawDownloadType < $1.rawDownloadType }
        self.uniqueCountEntries = uniqueEntries.sorted {
            ($0.deduplicationKey, $0.rawEvent) < ($1.deduplicationKey, $1.rawEvent)
        }
        self.recordCount = records.count
    }
}
