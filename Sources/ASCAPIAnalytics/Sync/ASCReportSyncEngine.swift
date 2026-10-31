import ASCAPIKit
import Foundation

/// Configuration for one Analytics Reports API sync run for a single app.
public struct ASCAnalyticsSyncConfiguration: Sendable {
    /// ASC app resource identifier (as used by the Analytics Reports API).
    public let appID: String
    /// Access type of the report request. Defaults to `ONGOING`, Apple's
    /// typical daily/weekly/monthly generation mode.
    public var accessType: ASCAnalyticsReportAccessType
    /// Creates a report request when the app has none. Apple generates no
    /// reports until a valid request exists.
    public var createReportRequestIfMissing: Bool
    /// Restricts sync to these report names (exact match against the
    /// report `name` attribute). Empty means all reports of the configured
    /// categories.
    public var reportNameFilters: [String]
    /// Categories to include. Defaults to the categories that carry the
    /// App Downloads and App Store Discovery and Engagement reports.
    public var categories: [ASCAnalyticsReportCategory]
    /// Granularities to include.
    public var granularities: [ASCAnalyticsReportGranularity]
    /// Maximum number of instances synced per report, most recent
    /// processing dates first. Apple keeps report instances available for
    /// 35 days.
    public var maximumInstancesPerReport: Int

    public init(
        appID: String,
        accessType: ASCAnalyticsReportAccessType = .ongoing,
        createReportRequestIfMissing: Bool = true,
        reportNameFilters: [String] = [],
        categories: [ASCAnalyticsReportCategory] = [
            .appStoreEngagement,
            .commerce,
        ],
        granularities: [ASCAnalyticsReportGranularity] = [.daily],
        maximumInstancesPerReport: Int = 35
    ) {
        self.appID = appID
        self.accessType = accessType
        self.createReportRequestIfMissing = createReportRequestIfMissing
        self.reportNameFilters = reportNameFilters
        self.categories = categories
        self.granularities = granularities
        self.maximumInstancesPerReport = maximumInstancesPerReport
    }
}

/// Configuration for one Sales and Trends sync run.
public struct ASCSalesSyncConfiguration: Sendable {
    /// Vendor number of the account.
    public let vendorNumber: String
    /// Report frequency.
    public var frequency: ASCSalesReportFrequency
    /// Report dates to sync, in Apple's `filter[reportDate]` format
    /// (`YYYY-MM-DD` for daily reports). Late-arriving data is synced by
    /// including older report dates here.
    public var reportDates: [String]
    /// Report versions to sync. The default `[nil]` downloads the latest
    /// available version; explicit versions fetch Apple's corrected
    /// restatements.
    public var versions: [String?]

    public init(
        vendorNumber: String,
        frequency: ASCSalesReportFrequency = .daily,
        reportDates: [String],
        versions: [String?] = [nil]
    ) {
        self.vendorNumber = vendorNumber
        self.frequency = frequency
        self.reportDates = reportDates
        self.versions = versions
    }
}

/// Outcome of one report instance in an Analytics sync run.
public struct ASCAnalyticsSyncOutcome: Sendable {
    /// What happened to the instance.
    public enum InstanceOutcome: Equatable, Sendable {
        /// All segments downloaded, parsed, verified, and committed
        /// atomically.
        case imported(recordCount: Int)
        /// Already imported with identical declared segment checksums;
        /// nothing was re-downloaded or re-counted.
        case skippedAlreadyImported
        /// Data retained for review but not counted: the same identity
        /// arrived again with different content, and the update semantics
        /// cannot be proven.
        case pendingReview(reason: String)
        /// The instance could not be completed; nothing from it was
        /// committed.
        case failed(reason: String)
    }

    public let reportName: String?
    public let category: String?
    public let instanceID: String
    public let processingDate: String?
    public let outcome: InstanceOutcome
}

/// Result of an Analytics sync run.
public struct ASCAnalyticsSyncResult: Sendable {
    public let outcomes: [ASCAnalyticsSyncOutcome]

    public var importedCount: Int {
        outcomes.filter {
            if case .imported = $0.outcome { return true }
            return false
        }.count
    }

    public var failedCount: Int {
        outcomes.filter {
            if case .failed = $0.outcome { return true }
            return false
        }.count
    }

    public var pendingReviewCount: Int {
        outcomes.filter {
            if case .pendingReview = $0.outcome { return true }
            return false
        }.count
    }

    /// True when no instance failed. Pending-review instances do not make
    /// a run unsuccessful; they are surfaced explicitly.
    public var succeeded: Bool { failedCount == 0 }
}

/// Outcome of one sales report download in a sync run.
public struct ASCSalesSyncOutcome: Sendable {
    /// What happened to the report file.
    public enum ReportOutcome: Equatable, Sendable {
        case imported(recordCount: Int)
        case skippedAlreadyImported
        case pendingReview(reason: String)
        case failed(reason: String)
    }

    public let reportDate: String
    public let version: String?
    public let outcome: ReportOutcome
    /// Versions of the same report date that were marked superseded by
    /// this import, when any.
    public let supersededVersions: [String]
    /// Review notes that do not change the outcome (for example versions
    /// that could not be ordered against this one).
    public let notes: [String]

    public init(
        reportDate: String,
        version: String?,
        outcome: ReportOutcome,
        supersededVersions: [String] = [],
        notes: [String] = []
    ) {
        self.reportDate = reportDate
        self.version = version
        self.outcome = outcome
        self.supersededVersions = supersededVersions
        self.notes = notes
    }
}

/// Result of a Sales and Trends sync run.
public struct ASCSalesSyncResult: Sendable {
    public let outcomes: [ASCSalesSyncOutcome]

    public var succeeded: Bool {
        !outcomes.contains {
            if case .failed = $0.outcome { return true }
            return false
        }
    }
}

/// Orchestrates report retrieval, parsing, verification, and atomic
/// ingestion. The engine holds no state between runs; all state lives in
/// the store, so repeated runs are idempotent.
///
/// Semantics implemented (see docs/SYNC_SEMANTICS.md):
/// - An instance is committed only after every segment was downloaded,
///   parsed, and cross-verified; a failure aborts the whole instance.
/// - Re-running a sync never re-counts data: instances with identical
///   declared segment checksums are skipped.
/// - The same identity arriving with different content is retained as
///   pending review, never merged or double-counted.
/// - Sales and Trends corrections (a newer report version for the same
///   report date) supersede the older version in the same transaction.
/// - The engine performs no scheduling; the host app decides when to run
///   it.
public struct ASCReportSyncEngine: Sendable {
    private let provider: any ASCReportProvider

    public init(provider: any ASCReportProvider) {
        self.provider = provider
    }

    // MARK: - Analytics sync

    /// Syncs Analytics report instances for one app.
    public func syncAnalytics(
        _ configuration: ASCAnalyticsSyncConfiguration,
        store: any ASCAnalyticsStore
    ) async throws -> ASCAnalyticsSyncResult {
        var requests = try await provider.listAnalyticsReportRequests(
            appID: configuration.appID,
            accessType: configuration.accessType
        )

        if requests.isEmpty && configuration.createReportRequestIfMissing {
            _ = try await provider.createAnalyticsReportRequest(
                appID: configuration.appID,
                accessType: configuration.accessType
            )
            requests = try await provider.listAnalyticsReportRequests(
                appID: configuration.appID,
                accessType: configuration.accessType
            )
        }

        var outcomes: [ASCAnalyticsSyncOutcome] = []

        for request in requests {
            let reports = try await provider.listAnalyticsReports(
                reportRequestID: request.id,
                categories: configuration.categories,
                names: configuration.reportNameFilters
            )

            for report in reports {
                var instances = try await provider.listAnalyticsReportInstances(
                    reportID: report.id,
                    granularities: configuration.granularities,
                    processingDates: []
                )
                instances = Self.mostRecentInstances(
                    instances, limit: configuration.maximumInstancesPerReport
                )

                for instance in instances {
                    let outcome = try await syncInstance(
                        instance,
                        report: report,
                        reportRequestID: request.id,
                        appID: configuration.appID,
                        store: store
                    )
                    outcomes.append(outcome)
                }
            }
        }

        return ASCAnalyticsSyncResult(outcomes: outcomes)
    }

    /// Keeps the `limit` most recent instances by processing date
    /// (descending); instances without a processing date sort last.
    static func mostRecentInstances(
        _ instances: [ASCAnalyticsReportInstance], limit: Int
    ) -> [ASCAnalyticsReportInstance] {
        guard limit < instances.count else { return instances }
        let sorted = instances.sorted { lhs, rhs in
            (lhs.attributes.processingDate ?? "") > (rhs.attributes.processingDate ?? "")
        }
        return Array(sorted.prefix(limit))
    }

    private func syncInstance(
        _ instance: ASCAnalyticsReportInstance,
        report: ASCAnalyticsReport,
        reportRequestID: String,
        appID: String,
        store: any ASCAnalyticsStore
    ) async throws -> ASCAnalyticsSyncOutcome {
        func outcome(
            _ result: ASCAnalyticsSyncOutcome.InstanceOutcome
        ) -> ASCAnalyticsSyncOutcome {
            ASCAnalyticsSyncOutcome(
                reportName: report.attributes.name,
                category: report.attributes.category?.rawValue,
                instanceID: instance.id,
                processingDate: instance.attributes.processingDate,
                outcome: result
            )
        }

        let segments = try await provider.listAnalyticsReportSegments(instanceID: instance.id)
        guard !segments.isEmpty else {
            return outcome(.failed(reason: "instance has no segments; nothing was committed"))
        }

        // Idempotency: identical declared segment checksums mean this
        // instance is already imported; skip without re-downloading.
        let lookupKey = ASCIngestionKey(sourceKind: .unknown, instanceID: instance.id)
        let probe = try await store.beginTransaction()
        let existing = try await probe.ingestion(matching: lookupKey)
        try await probe.rollback()
        if let existing, existing.state == .imported,
           Self.declaredChecksums(of: segments) == existing.segmentChecksums {
            return outcome(.skippedAlreadyImported)
        }

        // Download all segments, deduplicating identical content.
        var segmentData: [(segment: ASCAnalyticsReportSegment, data: Data, checksum: String)] = []
        var seenChecksums: Set<String> = []
        for segment in segments {
            let data = try await provider.downloadAnalyticsReportSegment(segment)
            guard !data.isEmpty else {
                return outcome(.failed(
                    reason: "segment \(segment.id) downloaded empty content; nothing was committed"
                ))
            }
            let checksum = ASCFingerprint.sha256Hex(data)
            if !seenChecksums.insert(checksum).inserted {
                // Duplicate segment content within one instance: parse
                // once, never twice.
                continue
            }
            segmentData.append((segment, data, checksum))
        }

        // Classify and parse every distinct segment.
        enum ParsedSegment {
            case downloads(ASCDownloadsParseResult)
            case discovery(ASCDiscoveryParseResult)
        }

        var parsed: [ParsedSegment] = []
        var fingerprints = Set<String>()
        var kind: String?

        for entry in segmentData {
            do {
                if kind == nil {
                    kind = try Self.segmentKind(
                        of: entry.data,
                        instanceID: instance.id
                    )
                }
                switch kind {
                case "downloads":
                    let result = try ASCDownloadsReportParser().parse(entry.data)
                    fingerprints.insert(result.schemaFingerprint)
                    parsed.append(.downloads(result))
                case "discovery":
                    let result = try ASCDiscoveryReportParser().parse(entry.data)
                    fingerprints.insert(result.schemaFingerprint)
                    parsed.append(.discovery(result))
                default:
                    return outcome(.failed(
                        reason: "segment \(entry.segment.id) does not match a supported analytics report header"
                    ))
                }
            } catch let error as ASCAnalyticsError {
                return outcome(.failed(reason: "segment \(entry.segment.id) failed to parse: \(error)"))
            } catch {
                return outcome(.failed(reason: "segment \(entry.segment.id) failed: \(error)"))
            }
        }

        // All segments of one instance must share one schema: they are
        // partitions of a single report variant.
        guard fingerprints.count == 1 else {
            return outcome(.failed(
                reason: "segments of instance \(instance.id) disagree on the report schema (\(fingerprints.count) distinct headers); nothing was committed"
            ))
        }
        guard let schemaFingerprint = fingerprints.first else {
            return outcome(.failed(reason: "no segment data was parsed"))
        }

        let combinedChecksum = Self.combinedChecksum(
            segmentData.map { ($0.segment.id, $0.checksum) }
        )
        let ingestionKey = ASCIngestionKey(
            sourceKind: kind == "downloads"
                ? .analyticsDownloads
                : .analyticsDiscoveryAndEngagement,
            instanceID: instance.id
        )

        // Same content as before (any state): already processed, skip.
        if let existing, existing.contentChecksum == combinedChecksum {
            return outcome(.skippedAlreadyImported)
        }

        // Same identity, different content: semantics unproven. The
        // previously imported data stays untouched and counted; the
        // conflicting delivery is recorded under its own delivery key and
        // excluded from queries until reviewed.
        if let existing {
            let pendingKey = ingestionKey.withDeliveryID(combinedChecksum)
            let granularity = instance.attributes.granularity.flatMap {
                ASCReportGranularity(rawValue: $0.rawValue)
            }
            var provenanced: [ASCProvenancedRecord<ASCDownloadRecord>] = []
            var provenancedDiscovery: [ASCProvenancedRecord<ASCDiscoveryRecord>] = []
            var recordCount = 0
            for (index, item) in parsed.enumerated() {
                let entry = segmentData[index]
                let segmentProvenance = ASCReportProvenance(
                    sourceKind: ingestionKey.sourceKind,
                    reportName: report.attributes.name,
                    category: report.attributes.category?.rawValue,
                    reportRequestID: reportRequestID,
                    reportID: report.id,
                    instanceID: instance.id,
                    segmentID: entry.segment.id,
                    processingDate: instance.attributes.processingDate,
                    granularity: granularity,
                    schemaFingerprint: schemaFingerprint,
                    contentChecksum: entry.checksum,
                    fetchedAt: Date(),
                    recordCount: 0
                )
                switch item {
                case .downloads(let result):
                    recordCount += result.records.count
                    provenanced.append(contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    })
                case .discovery(let result):
                    recordCount += result.records.count
                    provenancedDiscovery.append(contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    })
                }
            }
            let entry = ASCIngestionEntry(
                key: pendingKey,
                state: .pendingReview,
                processingDate: instance.attributes.processingDate,
                granularity: granularity,
                reportName: report.attributes.name,
                category: report.attributes.category?.rawValue,
                segmentIDs: segments.map(\.id),
                segmentChecksums: Self.declaredChecksums(of: segments),
                schemaFingerprint: schemaFingerprint,
                contentChecksum: combinedChecksum,
                recordCount: recordCount,
                importedAt: Date(),
                pendingReason: "instance \(instance.id) was previously imported with different content (\(existing.contentChecksum)); Apple's update semantics for mutated instances are not documented, so this delivery is retained but excluded until reviewed"
            )
            try await store.withTransaction { transaction in
                try await transaction.insertDownloads(provenanced, ingestionKey: pendingKey)
                try await transaction.insertDiscovery(provenancedDiscovery, ingestionKey: pendingKey)
                try await transaction.upsertIngestion(entry)
            }
            return outcome(.pendingReview(reason: entry.pendingReason ?? "content changed"))
        }

        // Atomic commit: ledger entry plus all records in one transaction.
        let now = Date()
        let granularity = instance.attributes.granularity.flatMap {
            ASCReportGranularity(rawValue: $0.rawValue)
        }
        let context = ASCReportProvenance(
            sourceKind: kind == "downloads" ? .analyticsDownloads : .analyticsDiscoveryAndEngagement,
            reportName: report.attributes.name,
            category: report.attributes.category?.rawValue,
            reportRequestID: reportRequestID,
            reportID: report.id,
            instanceID: instance.id,
            processingDate: instance.attributes.processingDate,
            granularity: granularity,
            schemaFingerprint: schemaFingerprint,
            contentChecksum: combinedChecksum,
            fetchedAt: now,
            recordCount: 0
        )

        var totalRecords = 0
        var provenancedDownloads: [ASCProvenancedRecord<ASCDownloadRecord>] = []
        var provenancedDiscovery: [ASCProvenancedRecord<ASCDiscoveryRecord>] = []

        for (index, item) in parsed.enumerated() {
            let entry = segmentData[index]
            let segmentProvenance = context.withSegmentID(entry.segment.id)
            switch item {
            case .downloads(let result):
                totalRecords += result.records.count
                provenancedDownloads.append(
                    contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    }
                )
            case .discovery(let result):
                totalRecords += result.records.count
                provenancedDiscovery.append(
                    contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    }
                )
            }
        }

        let ledgerEntry = ASCIngestionEntry(
            key: ingestionKey,
            state: .imported,
            processingDate: instance.attributes.processingDate,
            granularity: granularity,
            reportName: report.attributes.name,
            category: report.attributes.category?.rawValue,
            segmentIDs: segments.map(\.id),
            segmentChecksums: Self.declaredChecksums(of: segments),
            schemaFingerprint: schemaFingerprint,
            contentChecksum: combinedChecksum,
            recordCount: totalRecords,
            importedAt: now
        )

        try await store.withTransaction { transaction in
            try await transaction.insertDownloads(provenancedDownloads, ingestionKey: ingestionKey)
            try await transaction.insertDiscovery(provenancedDiscovery, ingestionKey: ingestionKey)
            try await transaction.upsertIngestion(ledgerEntry)
        }

        return outcome(.imported(recordCount: totalRecords))
    }

    /// Determines which supported analytics report a segment belongs to,
    /// from its header. Returns "downloads", "discovery", or throws.
    static func segmentKind(of data: Data, instanceID: String) throws -> String {
        let tsvData = try ASCSalesReportParser.decompressedIfGzipped(
            data, decoder: ASCGzipDecoder()
        )
        guard let header = ASCDownloadsReportParser.firstLine(of: tsvData) else {
            throw ASCAnalyticsError.tsvEmptyInput
        }
        let headerText = String(decoding: header, as: UTF8.self)
        let names = Set(
            headerText.split(separator: "\t").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }
        )
        if names.contains("download type") { return "downloads" }
        if names.contains("event") && names.contains("counts") { return "discovery" }
        throw ASCAnalyticsError.unsupportedReportHeader(
            report: "analytics segment (instance \(instanceID))",
            header: Array(names).sorted(),
            reason: "header matches neither the App Downloads nor the Discovery and Engagement report"
        )
    }

    static func declaredChecksums(
        of segments: [ASCAnalyticsReportSegment]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for segment in segments {
            result[segment.id] = segment.attributes.checksum ?? ""
        }
        return result
    }

    /// Deterministic combined content checksum: SHA-256 over
    /// `"<segmentID>:<checksum>\n"` lines sorted by segment identifier.
    static func combinedChecksum(_ entries: [(String, String)]) -> String {
        let canonical = entries
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: "\n")
        return ASCFingerprint.sha256Hex(Data(canonical.utf8))
    }

    // MARK: - Sales sync

    /// Syncs Sales and Trends Summary Sales reports.
    public func syncSales(
        _ configuration: ASCSalesSyncConfiguration,
        store: any ASCAnalyticsStore
    ) async throws -> ASCSalesSyncResult {
        var outcomes: [ASCSalesSyncOutcome] = []

        for reportDate in configuration.reportDates {
            for version in configuration.versions {
                let outcome = try await syncSalesReport(
                    vendorNumber: configuration.vendorNumber,
                    frequency: configuration.frequency,
                    reportDate: reportDate,
                    version: version,
                    store: store
                )
                outcomes.append(outcome)
            }
        }

        return ASCSalesSyncResult(outcomes: outcomes)
    }

    private func syncSalesReport(
        vendorNumber: String,
        frequency: ASCSalesReportFrequency,
        reportDate: String,
        version: String?,
        store: any ASCAnalyticsStore
    ) async throws -> ASCSalesSyncOutcome {
        let request = ASCSalesReportRequest(
            reportType: .sales,
            reportSubType: .summary,
            frequency: frequency,
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            version: version
        )

        let data: Data
        do {
            data = try await provider.downloadSalesReport(request)
        } catch {
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .failed(reason: "download failed: \(error)"),
                supersededVersions: []
            )
        }

        let parseResult: ASCSalesParseResult
        do {
            parseResult = try ASCSalesReportParser().parse(data)
        } catch let error as ASCAnalyticsError {
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .failed(reason: "parse failed: \(error)"),
                supersededVersions: []
            )
        } catch {
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .failed(reason: "parse failed: \(error)"),
                supersededVersions: []
            )
        }

        let key = ASCIngestionKey(
            sourceKind: .summarySales,
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: version
        )

        // Idempotency check.
        let probe = try await store.beginTransaction()
        let existing = try await probe.ingestion(matching: key)
        try await probe.rollback()
        if let existing, existing.state == .imported,
           existing.contentChecksum == parseResult.contentChecksum {
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .skippedAlreadyImported,
                supersededVersions: []
            )
        }

        // Same identity, different content: retain for review. The
        // previously imported version stays untouched and counted; the
        // conflicting delivery is recorded under its own delivery key.
        if let existing, existing.contentChecksum != parseResult.contentChecksum {
            let reason = "sales report \(reportDate) version \(version ?? "latest") was previously imported with different content; correction semantics inside one version are not documented, so this delivery is retained but excluded until reviewed"
            let pendingKey = key.withDeliveryID(parseResult.contentChecksum)
            let provenance = ASCReportProvenance(
                sourceKind: .summarySales,
                reportName: "Summary Sales Report",
                vendorNumber: vendorNumber,
                reportDate: reportDate,
                reportVersion: version,
                schemaFingerprint: parseResult.schemaFingerprint,
                contentChecksum: parseResult.contentChecksum,
                fetchedAt: Date(),
                recordCount: parseResult.records.count
            )
            let provenanced = parseResult.records.map {
                ASCProvenancedRecord(record: $0, provenance: provenance)
            }
            let entry = ASCIngestionEntry(
                key: pendingKey,
                state: .pendingReview,
                reportName: "Summary Sales Report",
                segmentChecksums: [:],
                schemaFingerprint: parseResult.schemaFingerprint,
                contentChecksum: parseResult.contentChecksum,
                recordCount: parseResult.records.count,
                importedAt: Date(),
                pendingReason: reason
            )
            try await store.withTransaction { transaction in
                try await transaction.insertSales(provenanced, ingestionKey: pendingKey)
                try await transaction.upsertIngestion(entry)
            }
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .pendingReview(reason: reason),
                supersededVersions: []
            )
        }

        // Determine supersession: newer versions of the same report date
        // replace older ones (Apple's corrections). Incomparable versions
        // are kept side by side with a note instead of guessing.
        let siblingLookup = ASCIngestionKey(
            sourceKind: .summarySales,
            vendorNumber: vendorNumber,
            reportDate: reportDate
        )
        let probe2 = try await store.beginTransaction()
        let allEntries = try await probe2.ingestionEntries(state: nil)
        try await probe2.rollback()
        let siblings = allEntries.filter { entry in
            entry.key.sourceKind == .summarySales
                && entry.key.vendorNumber == vendorNumber
                && entry.key.reportDate == reportDate
                && entry.key.reportVersion != version
                && entry.state == .imported
        }
        var supersededVersions: [String] = []
        var incomparableNote: String?
        for sibling in siblings {
            guard let siblingVersion = sibling.key.reportVersion else { continue }
            switch ASCSalesVersionOrder.compare(version, siblingVersion) {
            case .newer:
                supersededVersions.append(siblingVersion)
            case .incomparable:
                incomparableNote = "version \(version ?? "latest") could not be ordered against version \(siblingVersion); both are retained and must be reviewed manually"
            case .older, .equal:
                break
            }
        }

        let provenance = ASCReportProvenance(
            sourceKind: .summarySales,
            reportName: "Summary Sales Report",
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: version,
            schemaFingerprint: parseResult.schemaFingerprint,
            contentChecksum: parseResult.contentChecksum,
            fetchedAt: Date(),
            recordCount: parseResult.records.count
        )
        let provenanced = parseResult.records.map {
            ASCProvenancedRecord(record: $0, provenance: provenance)
        }

        let entry = ASCIngestionEntry(
            key: key,
            state: .imported,
            reportName: "Summary Sales Report",
            segmentChecksums: [:],
            schemaFingerprint: parseResult.schemaFingerprint,
            contentChecksum: parseResult.contentChecksum,
            recordCount: parseResult.records.count,
            importedAt: Date()
        )

        try await store.withTransaction { transaction in
            try await transaction.insertSales(provenanced, ingestionKey: key)
            try await transaction.upsertIngestion(entry)
            if !supersededVersions.isEmpty {
                let keys = siblings
                    .filter { supersededVersions.contains($0.key.reportVersion ?? "") }
                    .map(\.key)
                try await transaction.markSuperseded(keys: keys, by: key)
            }
        }

        if let incomparableNote {
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .imported(recordCount: parseResult.records.count),
                supersededVersions: supersededVersions,
                notes: [incomparableNote]
            )
        }

        return ASCSalesSyncOutcome(
            reportDate: reportDate,
            version: version,
            outcome: .imported(recordCount: parseResult.records.count),
            supersededVersions: supersededVersions
        )
    }
}

/// Ordering of Sales and Trends report versions. Numeric strings compare
/// numerically ("10" > "9"); dotted/dashed variants compare
/// component-wise; anything else is incomparable and must not drive
/// supersession.
enum ASCSalesVersionOrder {
    enum Ordering {
        case newer
        case older
        case equal
        case incomparable
    }

    static func compare(_ a: String?, _ b: String?) -> Ordering {
        switch (a, b) {
        case (nil, nil): return .equal
        case (nil, _): return .newer // "latest available" beats pinned versions
        case (_, nil): return .older
        case (let a?, let b?):
            if a == b { return .equal }
            if let ai = Int(a), let bi = Int(b) {
                return ai > bi ? .newer : .older
            }
            let aParts = a.split(separator: "_").compactMap { Int($0) }
            let bParts = b.split(separator: "_").compactMap { Int($0) }
            if aParts.count == bParts.count, !aParts.isEmpty,
               a.split(separator: "_").count == aParts.count,
               b.split(separator: "_").count == bParts.count {
                for (x, y) in zip(aParts, bParts) where x != y {
                    return x > y ? .newer : .older
                }
                return .equal
            }
            return .incomparable
        }
    }
}
