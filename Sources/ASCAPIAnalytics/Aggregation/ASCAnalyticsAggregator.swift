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
    /// redownloads). Pre-order rows of the downloads report are **not**
    /// added again: the `Pre-Order` flag marks downloads that came from a
    /// pre-order and they are already inside the download counts; true
    /// pre-order placements live in the Pre-orders report, which this
    /// helper does not consume.
    ///
    /// The denominator would be the unique count of impression rows — but
    /// Apple's dashboard denominator ("Impressions (Unique Devices)")
    /// *includes unique product page views*, and the Discovery report
    /// splits impressions and page views into separate events whose
    /// per-device overlap is not published. A report-derived denominator
    /// therefore cannot be proven to match Apple's basis, and this helper
    /// returns `unavailable` with an explicit reason. Use
    /// `ASCConversionRateEvaluator` directly with
    /// `ASCImpressionBasis.assertedDashboardUniqueDevices` when a
    /// dashboard-derived denominator is available.
    public func conversionRate(
        downloads: [ASCDownloadRecord],
        impressions: [ASCDiscoveryRecord],
        filter: ASCAnalyticsFilter = ASCAnalyticsFilter(),
        allowingEstimate: Bool = false
    ) -> ASCConversionRateResult {
        let downloadRecords = filter.apply(downloads)
        let impressionRecords = filter.apply(impressions)

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

        // Basis check first: whatever else holds, a denominator derived
        // from the Discovery report's impression events cannot be proven
        // to match Apple's dashboard impressions basis.
        let hasPageViewEvents = impressionRecords.contains {
            ASCDiscoveryEvent.classify($0.rawEvent) == .pageView
        }
        let basisReason = hasPageViewEvents
            ? "the filtered discovery records contain both impression and page view events; Apple's dashboard Impressions include unique product page views, and the per-device overlap between the two event types is not published, so the denominator cannot be deduplicated into Apple's basis"
            : "the filtered discovery records contain impression events only; Apple's dashboard Impressions also include unique product page views, so this denominator is narrower than Apple's basis by an unknowable amount"

        let uniqueImpressionEntries = discoveryMetrics.uniqueCountEntries.filter {
            ASCDiscoveryEvent.classify($0.rawEvent) == .impression
        }
        let domainCount = Set(uniqueImpressionEntries.map(\.deduplicationKey)).count
        let impressionsSum = uniqueImpressionEntries.map(\.uniqueCounts).reduce(0, +)

        let inputs = ASCConversionRateInputs(
            numeratorAppIdentifier: appIdentifier,
            numeratorWindow: window,
            downloadsAndPreOrders: ASCDownloadMetrics(records: downloadRecords).appleTotalDownloads,
            denominatorAppIdentifier: appIdentifier,
            denominatorWindow: window,
            uniqueDeviceImpressions: uniqueImpressionEntries.isEmpty ? nil : impressionsSum,
            impressionsDeduplicationDomainCount: max(domainCount, 1),
            denominatorBasis: .discoveryReportImpressionEventsOnly
        )

        // Both evaluators refuse a report-derived basis; surface the
        // basis reason explicitly either way.
        if case .unavailable(let evaluatorReason) = allowingEstimate
            ? ASCConversionRateEvaluator.evaluateAllowingEstimate(inputs)
            : ASCConversionRateEvaluator.evaluate(inputs) {
            return .unavailable(reason: "\(basisReason). \(evaluatorReason)")
        }
        return .unavailable(reason: basisReason)
    }

    // MARK: - Provenance-aware aggregation (granularity/variant safe)

    /// Aggregates download records that carry provenance, safely:
    /// Apple's latest-processing-date overwrite rule is applied first,
    /// then the scope is verified — an input spanning multiple logical
    /// report variants (standard/detailed) or multiple granularities
    /// (daily/weekly) for the same event scope throws
    /// `ASCAnalyticsError.ambiguousMetricScope` instead of producing
    /// totals that double count the same underlying events.
    public func downloads(
        _ records: [ASCProvenancedRecord<ASCDownloadRecord>],
        filter: ASCAnalyticsFilter = ASCAnalyticsFilter()
    ) throws -> ASCDownloadSummary {
        // 1. Scope-level filters first — they operate on whole overwrite
        //    groups (the app identifier is part of the selection key), so
        //    they cannot change which instance is the latest.
        var scoped = records
        if let appIdentifiers = filter.appIdentifiers {
            scoped = scoped.filter {
                appIdentifiers.contains($0.record.appAppleIdentifier)
            }
        }
        // 2. The overwrite rule on the FULL scope, BEFORE any row-level
        //    display filtering such as territory: a corrected instance may
        //    have dropped a territory entirely, and filtering by territory
        //    first would leave the older instance's retracted rows as the
        //    only records of their group and wrongly resurrect them.
        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(scoped)
        // 3. Display filters on the effective records.
        var displayFiltered = selected
        if let territories = filter.territories {
            displayFiltered = displayFiltered.filter {
                territories.contains($0.record.territory)
            }
        }
        if let range = filter.dateRange {
            displayFiltered = displayFiltered.filter { range.contains($0.record.date) }
        }
        try Self.verifySingleMetricScope(
            displayFiltered.map { ($0.record, $0.provenance) }
        )
        var effectiveFilter = filter
        effectiveFilter.territories = nil
        effectiveFilter.dateRange = nil
        return downloads(displayFiltered.map(\.record), filter: effectiveFilter)
    }

    /// Same as `downloads(_:_:)` for discovery records: the overwrite
    /// rule is applied on the full scope before territory and date
    /// display filters.
    public func discovery(
        _ records: [ASCProvenancedRecord<ASCDiscoveryRecord>],
        filter: ASCAnalyticsFilter = ASCAnalyticsFilter()
    ) throws -> ASCDiscoverySummary {
        var scoped = records
        if let appIdentifiers = filter.appIdentifiers {
            scoped = scoped.filter {
                appIdentifiers.contains($0.record.appAppleIdentifier)
            }
        }
        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(scoped)
        var displayFiltered = selected
        if let territories = filter.territories {
            displayFiltered = displayFiltered.filter {
                territories.contains($0.record.territory)
            }
        }
        if let range = filter.dateRange {
            displayFiltered = displayFiltered.filter { range.contains($0.record.date) }
        }
        try Self.verifySingleMetricScope(
            displayFiltered.map { ($0.record, $0.provenance) }
        )
        var effectiveFilter = filter
        effectiveFilter.territories = nil
        effectiveFilter.dateRange = nil
        return discovery(displayFiltered.map(\.record), filter: effectiveFilter)
    }

    /// Throws `ambiguousMetricScope` when the records span more than one
    /// (logical report variant, granularity) scope.
    static func verifySingleMetricScope<Record: ASCAnalyticsEventRecord>(
        _ entries: [(record: Record, provenance: ASCReportProvenance)]
    ) throws {
        var scopes: [String: (identity: String, granularity: String)] = [:]
        for entry in entries {
            let identity = ASCInstanceSelection.logicalReportIdentity(of: entry.provenance)
            let granularity = entry.provenance.granularity?.rawValue ?? "unspecified"
            scopes["\(identity)|\(granularity)"] = (identity, granularity)
        }
        guard scopes.count > 1 else { return }
        let described = scopes.values
            .sorted { ($0.identity, $0.granularity) < ($1.identity, $1.granularity) }
            .map { "\($0.identity) [\($0.granularity)]" }
            .joined(separator: ", ")
        throw ASCAnalyticsError.ambiguousMetricScope(
            reason: "the records span \(scopes.count) report scopes (\(described)); summing daily and weekly instances, or standard and detailed variants, would double count the same underlying events — select one scope via ASCAnalyticsStore.effectiveDownloadRecords/effectiveDiscoveryRecords(granularities:reportIdentities:) or aggregate each scope separately"
        )
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
///
/// Overwriting is applied **within one logical report variant only**. The
/// variant identity is stable and independent of column order: the API
/// report id when present, else the report name, else — for inputs with
/// no API identity at all — the order-insensitive canonical column-set
/// hash (`canonicalSchemaIdentity`). Apple reordering columns or adding a
/// compatible column therefore stays the same variant (the overwrite rule
/// applies across such instances), while the standard and detailed
/// variants — different reports with different ids/names/column sets —
/// never merge. The original order-sensitive `schemaFingerprint` is kept
/// untouched on every record as audit evidence.
public enum ASCInstanceSelection {
    /// The deduplication scope of one overwrite group: an app's records
    /// for one logical report variant, one granularity, and one event
    /// date.
    public struct SelectionKey: Hashable, Sendable {
        public let appIdentifier: String
        public let logicalReportIdentity: String
        public let granularity: ASCReportGranularity?
        public let eventDate: ASCCalendarDate
    }

    /// The stable logical report identity of a record: the API report id,
    /// else the report name, else the order-insensitive canonical column
    /// set identity.
    public static func logicalReportIdentity(of provenance: ASCReportProvenance) -> String {
        if let reportID = provenance.reportID {
            return "id:\(reportID)"
        }
        if let reportName = provenance.reportName {
            return "name:\(reportName)"
        }
        if let canonical = provenance.canonicalSchemaIdentity {
            return "schema:\(canonical)"
        }
        // Legacy provenance without a canonical identity: fall back to the
        // order-sensitive fingerprint rather than merging everything.
        return "schema:\(provenance.schemaFingerprint)"
    }

    /// Builds the selection key of a record.
    public static func selectionKey<Record: ASCAnalyticsEventRecord>(
        _ entry: ASCProvenancedRecord<Record>
    ) -> SelectionKey {
        SelectionKey(
            appIdentifier: entry.record.appAppleIdentifier,
            logicalReportIdentity: logicalReportIdentity(of: entry.provenance),
            granularity: entry.provenance.granularity,
            eventDate: entry.record.eventDate
        )
    }

    /// Keeps, for every (app, logical report variant, granularity, event
    /// date) group, only records whose instance has the latest processing
    /// date among the records of that group.
    ///
    /// Records without a processing date (for example hand-parsed files)
    /// count as the oldest: they are kept only when no dated instance
    /// covers the same group.
    public static func latestProcessingDatePerEventDate<Record: ASCAnalyticsEventRecord>(
        _ records: [ASCProvenancedRecord<Record>]
    ) -> [ASCProvenancedRecord<Record>] {
        var maxProcessingDateByKey: [SelectionKey: String] = [:]
        for entry in records {
            guard let processingDate = entry.provenance.processingDate else { continue }
            let key = selectionKey(entry)
            if let existing = maxProcessingDateByKey[key] {
                if processingDate > existing {
                    maxProcessingDateByKey[key] = processingDate
                }
            } else {
                maxProcessingDateByKey[key] = processingDate
            }
        }

        return records.filter { entry in
            guard let latest = maxProcessingDateByKey[selectionKey(entry)] else {
                // No dated instance covers this group; keep the record.
                return true
            }
            return entry.provenance.processingDate == latest
        }
    }
}

extension ASCAnalyticsStore {
    /// Returns download records after applying Apple's latest-processing-
    /// date overwrite rule *within* each (app, logical report variant,
    /// granularity, event date) group. This is the reliable "currently
    /// effective data" path: callers never need to apply
    /// `ASCInstanceSelection` by hand or guess when it applies.
    ///
    /// With the default `scope: .current`, superseded and pending-review
    /// ingestions are excluded before selection. Records from different
    /// apps, logical report variants (standard/detailed), or granularities
    /// are never overwritten by each other. To aggregate a single scope,
    /// pass `granularities` / `reportIdentities` — summing across variants
    /// or granularities would double count the same underlying events.
    public func effectiveDownloadRecords(
        appIdentifiers: Set<String>? = nil,
        granularities: Set<ASCReportGranularity>? = nil,
        reportIdentities: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCDownloadRecord>] {
        var records = ASCInstanceSelection.latestProcessingDatePerEventDate(
            try await downloadRecords(
                appIdentifiers: appIdentifiers,
                in: range,
                scope: scope
            )
        )
        if let granularities {
            records = records.filter { entry in
                entry.provenance.granularity.map { granularities.contains($0) } ?? false
            }
        }
        if let reportIdentities {
            records = records.filter { entry in
                reportIdentities.contains(
                    ASCInstanceSelection.logicalReportIdentity(of: entry.provenance)
                )
            }
        }
        return records
    }

    /// Same as `effectiveDownloadRecords` for discovery records.
    public func effectiveDiscoveryRecords(
        appIdentifiers: Set<String>? = nil,
        granularities: Set<ASCReportGranularity>? = nil,
        reportIdentities: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCDiscoveryRecord>] {
        var records = ASCInstanceSelection.latestProcessingDatePerEventDate(
            try await discoveryRecords(
                appIdentifiers: appIdentifiers,
                in: range,
                scope: scope
            )
        )
        if let granularities {
            records = records.filter { entry in
                entry.provenance.granularity.map { granularities.contains($0) } ?? false
            }
        }
        if let reportIdentities {
            records = records.filter { entry in
                reportIdentities.contains(
                    ASCInstanceSelection.logicalReportIdentity(of: entry.provenance)
                )
            }
        }
        return records
    }
}
