import Foundation

/// Filter applied to Analytics report records before aggregation.
public struct ASCAnalyticsFilter: Hashable, Codable, Sendable {
    /// Keeps records whose `App Apple Identifier` is in the set. `nil`
    /// disables the filter.
    public var appIdentifiers: Set<String>?
    /// Keeps records whose `Territory` is in the set. `nil` disables the
    /// filter.
    public var territories: Set<String>?
    /// Keeps records whose event date falls inside the range. `nil`
    /// disables the filter.
    public var dateRange: ASCDateRange?

    public init(
        appIdentifiers: Set<String>? = nil,
        territories: Set<String>? = nil,
        dateRange: ASCDateRange? = nil
    ) {
        self.appIdentifiers = appIdentifiers
        self.territories = territories
        self.dateRange = dateRange
    }

    public func matches(_ record: ASCDownloadRecord) -> Bool {
        matchesBase(app: record.appAppleIdentifier, territory: record.territory, date: record.date)
    }

    public func matches(_ record: ASCDiscoveryRecord) -> Bool {
        matchesBase(app: record.appAppleIdentifier, territory: record.territory, date: record.date)
    }

    private func matchesBase(app: String, territory: String, date: ASCCalendarDate) -> Bool {
        if let appIdentifiers, !appIdentifiers.contains(app) { return false }
        if let territories, !territories.contains(territory) { return false }
        if let dateRange, !dateRange.contains(date) { return false }
        return true
    }

    public func apply(_ records: [ASCDownloadRecord]) -> [ASCDownloadRecord] {
        records.filter { matches($0) }
    }

    public func apply(_ records: [ASCDiscoveryRecord]) -> [ASCDiscoveryRecord] {
        records.filter { matches($0) }
    }
}

/// Per-day downloads summary.
public struct ASCDownloadDaySummary: Hashable, Codable, Sendable {
    public let date: ASCCalendarDate
    public let metrics: ASCDownloadMetrics
}

/// Per-territory downloads summary.
public struct ASCDownloadTerritorySummary: Hashable, Codable, Sendable {
    public let territory: String
    public let metrics: ASCDownloadMetrics
}

/// Aggregated view of App Downloads records. Counts are additive across
/// time, territory, and app, so every level here sums counts directly.
public struct ASCDownloadSummary: Hashable, Codable, Sendable {
    public let filter: ASCAnalyticsFilter
    public let totals: ASCDownloadMetrics
    /// Per-day breakdown, sorted by date.
    public let byDay: [ASCDownloadDaySummary]
    /// Per-territory breakdown, sorted by territory.
    public let byTerritory: [ASCDownloadTerritorySummary]
}

/// Per-day discovery summary.
public struct ASCDiscoveryDaySummary: Hashable, Codable, Sendable {
    public let date: ASCCalendarDate
    public let metrics: ASCDiscoveryMetrics
}

/// Aggregated view of App Store Discovery and Engagement records.
///
/// `Counts` are summed additively. `Unique Counts` stay per
/// deduplication domain inside each `ASCDiscoveryMetrics`; they are never
/// summed across dates or dimension values.
public struct ASCDiscoverySummary: Hashable, Codable, Sendable {
    public let filter: ASCAnalyticsFilter
    public let totals: ASCDiscoveryMetrics
    /// Per-day breakdown, sorted by date.
    public let byDay: [ASCDiscoveryDaySummary]
}

/// Aggregates Analytics report records.
public struct ASCAnalyticsAggregator: Sendable {
    public init() {}

    /// Aggregates download records that pass `filter`.
    public func downloads(
        _ records: [ASCDownloadRecord], filter: ASCAnalyticsFilter = ASCAnalyticsFilter()
    ) -> ASCDownloadSummary {
        let filtered = filter.apply(records)
        let totals = ASCDownloadMetrics(records: filtered)

        var byDate: [ASCCalendarDate: [ASCDownloadRecord]] = [:]
        var byTerritory: [String: [ASCDownloadRecord]] = [:]
        for record in filtered {
            byDate[record.date, default: []].append(record)
            byTerritory[record.territory, default: []].append(record)
        }

        return ASCDownloadSummary(
            filter: filter,
            totals: totals,
            byDay: byDate
                .map { ASCDownloadDaySummary(date: $0.key, metrics: ASCDownloadMetrics(records: $0.value)) }
                .sorted { $0.date < $1.date },
            byTerritory: byTerritory
                .map { ASCDownloadTerritorySummary(territory: $0.key, metrics: ASCDownloadMetrics(records: $0.value)) }
                .sorted { $0.territory < $1.territory }
        )
    }

    /// Aggregates discovery records that pass `filter`.
    public func discovery(
        _ records: [ASCDiscoveryRecord], filter: ASCAnalyticsFilter = ASCAnalyticsFilter()
    ) -> ASCDiscoverySummary {
        let filtered = filter.apply(records)
        let totals = ASCDiscoveryMetrics(records: filtered)

        var byDate: [ASCCalendarDate: [ASCDiscoveryRecord]] = [:]
        for record in filtered {
            byDate[record.date, default: []].append(record)
        }

        return ASCDiscoverySummary(
            filter: filter,
            totals: totals,
            byDay: byDate
                .map { ASCDiscoveryDaySummary(date: $0.key, metrics: ASCDiscoveryMetrics(records: $0.value)) }
                .sorted { $0.date < $1.date }
        )
    }

    /// Evaluates Apple's conversion rate over one window from download and
    /// discovery records.
    ///
    /// The numerator is Apple's "Total Downloads" (first-time downloads +
    /// redownloads) plus pre-order rows of the downloads report. The
    /// denominator is the unique count of impression rows. Exactness
    /// requires a single-day window and a single impression deduplication
    /// domain; otherwise the result is `unavailable` — or `estimated` when
    /// `allowingEstimate` is set and the only obstacle is the multi-day
    /// window.
    public func conversionRate(
        downloads: [ASCDownloadRecord],
        impressions: [ASCDiscoveryRecord],
        filter: ASCAnalyticsFilter = ASCAnalyticsFilter(),
        allowingEstimate: Bool = false
    ) -> ASCConversionRateResult {
        let downloadRecords = filter.apply(downloads)
        let impressionRecords = filter.apply(impressions)

        let downloadMetrics = ASCDownloadMetrics(records: downloadRecords)
        let discoveryMetrics = ASCDiscoveryMetrics(records: impressionRecords)

        guard let window = filter.dateRange else {
            return .unavailable(
                reason: "the filter has no date range; set filter.dateRange to the window the conversion rate should cover"
            )
        }

        let apps = Set(downloadRecords.map(\.appAppleIdentifier))
        let impressionApps = Set(impressionRecords.map(\.appAppleIdentifier))
        guard let appIdentifier = apps.onlyElement(),
              impressionApps.onlyElement() == appIdentifier
        else {
            return .unavailable(
                reason: "the filtered records cover multiple apps; conversion rate must be evaluated per app"
            )
        }

        let uniqueImpressionEntries = discoveryMetrics.uniqueCountEntries.filter {
            ASCDiscoveryEvent.classify($0.rawEvent) == .impression
        }
        let domainCount = Set(uniqueImpressionEntries.map(\.deduplicationKey)).count
        let impressionsSum = uniqueImpressionEntries.map(\.uniqueCounts).reduce(0, +)

        let inputs = ASCConversionRateInputs(
            numeratorAppIdentifier: appIdentifier,
            numeratorWindow: window,
            downloadsAndPreOrders: downloadMetrics.downloadsAndPreOrders,
            denominatorAppIdentifier: appIdentifier,
            denominatorWindow: window,
            uniqueDeviceImpressions: uniqueImpressionEntries.isEmpty ? nil : impressionsSum,
            impressionsDeduplicationDomainCount: max(domainCount, 1)
        )

        return allowingEstimate
            ? ASCConversionRateEvaluator.evaluateAllowingEstimate(inputs)
            : ASCConversionRateEvaluator.evaluate(inputs)
    }
}

extension Set {
    /// The single element of the set, or `nil` when it does not contain
    /// exactly one element.
    fileprivate func onlyElement() -> Element? {
        count == 1 ? first : nil
    }
}

/// Implements Apple's documented overwrite rule for Analytics report
/// instances: "Instances from a more recent processing date overwrite
/// instances with an earlier processing date … Don't merge records for a
/// Date across two report instances to avoid double counting. Use the
/// latest instance."
public enum ASCInstanceSelection {
    /// Keeps, for every event date, only records whose instance has the
    /// latest processing date among the records for that date.
    ///
    /// Records without a processing date (for example hand-parsed files)
    /// count as the oldest: they are kept only when no dated instance
    /// covers the same event date.
    public static func latestProcessingDatePerEventDate<Record: ASCEventDated>(
        _ records: [ASCProvenancedRecord<Record>]
    ) -> [ASCProvenancedRecord<Record>] {
        var maxProcessingDateByDate: [ASCCalendarDate: String] = [:]
        for entry in records {
            guard let processingDate = entry.provenance.processingDate else { continue }
            let date = entry.record.eventDate
            if let existing = maxProcessingDateByDate[date] {
                if processingDate > existing {
                    maxProcessingDateByDate[date] = processingDate
                }
            } else {
                maxProcessingDateByDate[date] = processingDate
            }
        }

        return records.filter { entry in
            guard let latest = maxProcessingDateByDate[entry.record.eventDate] else {
                // No dated instance covers this date; keep the record.
                return true
            }
            return entry.provenance.processingDate == latest
        }
    }
}
