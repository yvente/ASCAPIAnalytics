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
    /// only reports this package officially parses (App Downloads and App
    /// Store Discovery and Engagement). Reports whose headers do not match
    /// a supported signature are skipped with explicit diagnostics and are
    /// never counted; see `failsOnUnsupportedReports`.
    public var categories: [ASCAnalyticsReportCategory]
    /// Granularities to include.
    public var granularities: [ASCAnalyticsReportGranularity]
    /// Maximum number of instances synced per report, most recent
    /// processing dates first. Apple keeps report instances available for
    /// 35 days. Values less than or equal to zero select no instances.
    public var maximumInstancesPerReport: Int
    /// When `false` (the default), an instance whose header matches no
    /// supported report signature is **skipped** with an explicit
    /// `skippedUnsupported` diagnostic — an unsupported report neither
    /// counts nor fails the run. When `true`, such instances fail the run
    /// instead (strict mode).
    public var failsOnUnsupportedReports: Bool

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
        maximumInstancesPerReport: Int = 35,
        failsOnUnsupportedReports: Bool = false
    ) {
        self.appID = appID
        self.accessType = accessType
        self.createReportRequestIfMissing = createReportRequestIfMissing
        self.reportNameFilters = reportNameFilters
        self.categories = categories
        self.granularities = granularities
        self.maximumInstancesPerReport = maximumInstancesPerReport
        self.failsOnUnsupportedReports = failsOnUnsupportedReports
    }
}

/// Configuration for one Sales and Trends sync run.
public struct ASCSalesSyncConfiguration: Sendable {
    /// Vendor number of the account.
    public let vendorNumber: String
    /// Report type. Defaults to `SALES`; part of the ingestion identity.
    public var reportType: ASCSalesReportType
    /// Report subtype. Defaults to `SUMMARY` (the only subtype this
    /// package parses); part of the ingestion identity.
    public var reportSubType: ASCSalesReportSubType
    /// Report frequency; part of the ingestion identity, so a daily and a
    /// weekly report for the same report date never share data.
    public var frequency: ASCSalesReportFrequency
    /// Report dates to sync, in Apple's `filter[reportDate]` format
    /// (`YYYY-MM-DD` for daily reports). Late-arriving data is synced by
    /// including older report dates here.
    public var reportDates: [String]
    /// Report versions to sync. The default `[nil]` downloads the latest
    /// available version; the fetched content is then matched against
    /// already-imported versions by actual content, because Apple does not
    /// echo the version of an unversioned download. Explicit versions
    /// fetch Apple's corrected restatements and are identified by their
    /// version string.
    public var versions: [String?]

    public init(
        vendorNumber: String,
        reportType: ASCSalesReportType = .sales,
        reportSubType: ASCSalesReportSubType = .summary,
        frequency: ASCSalesReportFrequency = .daily,
        reportDates: [String],
        versions: [String?] = [nil]
    ) {
        self.vendorNumber = vendorNumber
        self.reportType = reportType
        self.reportSubType = reportSubType
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
        /// Already imported with identical declared segment checksums
        /// (or, when Apple declares none, identical verified content);
        /// nothing was re-counted.
        case skippedAlreadyImported
        /// The instance's header matches no report this package officially
        /// parses. Nothing was counted; the run is not failed. Default
        /// behavior — see
        /// `ASCAnalyticsSyncConfiguration.failsOnUnsupportedReports`.
        case skippedUnsupported(reason: String)
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

    public var skippedUnsupportedCount: Int {
        outcomes.filter {
            if case .skippedUnsupported = $0.outcome { return true }
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

    /// True when no instance failed. Pending-review and skipped-
    /// unsupported instances do not make a run unsuccessful; they are
    /// surfaced explicitly.
    public var succeeded: Bool { failedCount == 0 }
}

/// Outcome of one sales report download in a sync run.
public struct ASCSalesSyncOutcome: Sendable {
    /// What happened to the report file.
    public enum ReportOutcome: Equatable, Sendable {
        case imported(recordCount: Int)
        /// The delivery was parsed and **retained for audit**, but it does
        /// not contribute to current queries: a provably newer version of
        /// the same report date is already the current one. Version order
        /// is direction-independent — importing v1 after v2 never demotes
        /// v2, even when the contents are identical.
        case importedForAuditOnly(recordCount: Int, supersededBy: String)
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
/// - Only report instances whose headers match the officially supported
///   App Downloads / App Store Discovery and Engagement signatures are
///   parsed and counted; anything else is skipped with explicit
///   diagnostics (or fails, in strict mode).
/// - An instance is committed only after every segment was downloaded,
///   parsed, and cross-verified; a failure aborts the whole instance.
/// - Segment identity is trusted: identical segment *ids* are parsed
///   once; two different segment ids are both kept even when their
///   content happens to be byte-identical.
/// - Idempotency uses declared segment checksums when Apple provides
///   them, and falls back to verified content checksums when it does not
///   — an empty declared checksum never short-circuits a download.
/// - The same identity arriving with different content is retained as
///   pending review, never merged or double-counted.
/// - Sales and Trends identity is the full (vendor, type, subtype,
///   frequency, report date, version) tuple; an unversioned "latest"
///   download is matched to already-imported data by actual content, and
///   a changed latest content is quarantined for manual review instead of
///   silently replacing anything.
/// - The engine performs no scheduling; the host app decides when to run
///   it.
public struct ASCReportSyncEngine: Sendable {
    private let provider: any ASCReportProvider

    public init(provider: any ASCReportProvider) {
        self.provider = provider
    }

    /// Runs a post-download decision inside one atomic store transaction.
    ///
    /// The decision body re-reads the ledger **inside** the transaction and
    /// performs all writes there, so two engines sharing one store can
    /// never both decide "not imported" and both commit: the store
    /// serializes the decision windows, and the loser's re-read observes
    /// the winner's commit. When another engine holds the store's
    /// transaction slot, the attempt is retried (bounded) after a
    /// cooperative yield — no network I/O ever happens inside the
    /// transaction, so retries are cheap and deterministic under test
    /// gates.
    private func withDecisionTransaction<T: Sendable>(
        store: any ASCAnalyticsStore,
        _ body: (any ASCAnalyticsStoreTransaction) async throws -> T
    ) async throws -> T {
        var attempts = 0
        while true {
            do {
                return try await store.withTransaction(body)
            } catch let error as ASCAnalyticsError {
                guard case .storeInconsistentState = error, attempts < 64 else {
                    throw error
                }
                attempts += 1
                await Task.yield()
            }
        }
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
                        configuration: configuration,
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
    /// Limits less than or equal to zero select no instances — they must
    /// never reach `prefix` with a negative count.
    static func mostRecentInstances(
        _ instances: [ASCAnalyticsReportInstance], limit: Int
    ) -> [ASCAnalyticsReportInstance] {
        guard limit > 0 else { return [] }
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
        configuration: ASCAnalyticsSyncConfiguration,
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
        // instance is already imported; skip without re-downloading. This
        // shortcut is only trustworthy when Apple declared a checksum for
        // every segment — an empty string is "no checksum", and treating
        // empty == empty as "unchanged" would skip revalidation forever.
        // Without complete declared checksums the instance is
        // re-downloaded and idempotency falls back to verified content.
        let declared = Self.declaredChecksums(of: segments)
        let allDeclaredChecksumsPresent = segments.allSatisfy {
            ($0.attributes.checksum ?? "").isEmpty == false
        }
        // Cheap pre-download fast path. It is advisory only: under
        // concurrent syncs the store's transaction slot may be held by
        // another engine (probe fails → fast path disabled) and the state
        // may be stale either way — the authoritative decision re-reads
        // the ledger inside the commit transaction below.
        let lookupKey = ASCIngestionKey(sourceKind: .unknown, instanceID: instance.id)
        var probedExisting: ASCIngestionEntry?
        do {
            let probe = try await store.beginTransaction()
            probedExisting = try await probe.ingestion(matching: lookupKey)
            try await probe.rollback()
        } catch {
            probedExisting = nil
        }
        if let probedExisting, probedExisting.state == .imported,
           allDeclaredChecksumsPresent,
           declared == probedExisting.segmentChecksums {
            return outcome(.skippedAlreadyImported)
        }

        // Download all segments. Duplicates are decided by trusted
        // segment identity: the same segment id listed twice is downloaded
        // and parsed once, but two different segment ids are both kept
        // even when their content happens to be identical — dropping one
        // by content alone would silently discard a partition.
        var segmentData: [(segment: ASCAnalyticsReportSegment, data: Data, checksum: String)] = []
        var seenSegmentIDs = Set<String>()
        for segment in segments {
            guard seenSegmentIDs.insert(segment.id).inserted else {
                // Duplicate segment id: parse once, never twice.
                continue
            }
            let data: Data
            do {
                data = try await provider.downloadAnalyticsReportSegment(segment)
            } catch {
                // A segment download failure aborts the whole instance as
                // an outcome; nothing was committed.
                return outcome(.failed(
                    reason: "segment \(segment.id) download failed: \(error)"
                ))
            }
            guard !data.isEmpty else {
                return outcome(.failed(
                    reason: "segment \(segment.id) downloaded empty content; nothing was committed"
                ))
            }
            segmentData.append((segment, data, ASCFingerprint.sha256Hex(data)))
        }

        // Classify and parse every distinct segment.
        enum ParsedSegment {
            case downloads(ASCDownloadsParseResult)
            case discovery(ASCDiscoveryParseResult)
        }

        var parsed: [ParsedSegment] = []
        var fingerprints = Set<String>()
        var canonicalIdentities = Set<String>()
        var kind: String?

        for entry in segmentData {
            do {
                if kind == nil {
                    do {
                        kind = try Self.segmentKind(
                            of: entry.data,
                            instanceID: instance.id
                        )
                    } catch let error as ASCAnalyticsError {
                        if case .unsupportedReportHeader = error,
                           !configuration.failsOnUnsupportedReports {
                            // Not one of the reports this package
                            // officially parses: skip with diagnostics,
                            // count nothing, fail nothing.
                            return outcome(.skippedUnsupported(
                                reason: "\(error)"
                            ))
                        }
                        throw error
                    }
                }
                switch kind {
                case "downloads":
                    let result = try ASCDownloadsReportParser().parse(entry.data)
                    fingerprints.insert(result.schemaFingerprint)
                    canonicalIdentities.insert(result.canonicalSchemaIdentity)
                    parsed.append(.downloads(result))
                case "discovery":
                    let result = try ASCDiscoveryReportParser().parse(entry.data)
                    fingerprints.insert(result.schemaFingerprint)
                    canonicalIdentities.insert(result.canonicalSchemaIdentity)
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
        let canonicalSchemaIdentity = canonicalIdentities.first

        let combinedChecksum = Self.combinedChecksum(
            segmentData.map { ($0.segment.id, $0.checksum) }
        )
        let ingestionKey = ASCIngestionKey(
            sourceKind: kind == "downloads"
                ? .analyticsDownloads
                : .analyticsDiscoveryAndEngagement,
            instanceID: instance.id
        )
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
            canonicalSchemaIdentity: canonicalSchemaIdentity,
            contentChecksum: combinedChecksum,
            fetchedAt: now,
            recordCount: 0
        )

        var provenancedDownloads: [ASCProvenancedRecord<ASCDownloadRecord>] = []
        var provenancedDiscovery: [ASCProvenancedRecord<ASCDiscoveryRecord>] = []
        for (index, item) in parsed.enumerated() {
            let entry = segmentData[index]
            let segmentProvenance = context.withSegmentID(entry.segment.id)
            switch item {
            case .downloads(let result):
                provenancedDownloads.append(
                    contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    }
                )
            case .discovery(let result):
                provenancedDiscovery.append(
                    contentsOf: result.records.map {
                        ASCProvenancedRecord(record: $0, provenance: segmentProvenance)
                    }
                )
            }
        }
        let totalRecords = provenancedDownloads.count + provenancedDiscovery.count

        // Authoritative decision, atomically: concurrent engines sharing
        // one store serialize here, and the ledger is **re-read inside the
        // transaction** — after the network download — closing the
        // probe-commit gap that let two syncs of the same instance both
        // import. No Apple network call happens inside the transaction.
        return try await withDecisionTransaction(store: store) { transaction in
            let existing = try await transaction.ingestion(matching: lookupKey)

            // Same content as before (any state): already processed, skip.
            // This is the revalidation strategy when Apple declares no
            // checksums: the actual bytes decide.
            if let existing, existing.contentChecksum == combinedChecksum {
                return outcome(.skippedAlreadyImported)
            }

            // Same identity, different content: semantics unproven. The
            // previously imported data stays untouched and counted; the
            // conflicting delivery is recorded under its own delivery key
            // and excluded from queries until reviewed.
            if let existing {
                let pendingKey = ingestionKey.withDeliveryID(combinedChecksum)
                let entry = ASCIngestionEntry(
                    key: pendingKey,
                    state: .pendingReview,
                    processingDate: instance.attributes.processingDate,
                    granularity: granularity,
                    reportName: report.attributes.name,
                    category: report.attributes.category?.rawValue,
                    segmentIDs: segments.map(\.id),
                    segmentChecksums: declared,
                    schemaFingerprint: schemaFingerprint,
                    contentChecksum: combinedChecksum,
                    recordCount: provenancedDownloads.count + provenancedDiscovery.count,
                    importedAt: now,
                    pendingReason: "instance \(instance.id) was previously imported with different content (\(existing.contentChecksum)); Apple's update semantics for mutated instances are not documented, so this delivery is retained but excluded until reviewed"
                )
                try await transaction.insertDownloads(provenancedDownloads, ingestionKey: pendingKey)
                try await transaction.insertDiscovery(provenancedDiscovery, ingestionKey: pendingKey)
                try await transaction.upsertIngestion(entry)
                return outcome(.pendingReview(reason: entry.pendingReason ?? "content changed"))
            }

            // First import of this identity: ledger entry plus all records
            // in the same transaction.
            let ledgerEntry = ASCIngestionEntry(
                key: ingestionKey,
                state: .imported,
                processingDate: instance.attributes.processingDate,
                granularity: granularity,
                reportName: report.attributes.name,
                category: report.attributes.category?.rawValue,
                segmentIDs: segments.map(\.id),
                segmentChecksums: declared,
                schemaFingerprint: schemaFingerprint,
                contentChecksum: combinedChecksum,
                recordCount: totalRecords,
                importedAt: now
            )
            try await transaction.insertDownloads(provenancedDownloads, ingestionKey: ingestionKey)
            try await transaction.insertDiscovery(provenancedDiscovery, ingestionKey: ingestionKey)
            try await transaction.upsertIngestion(ledgerEntry)
            return outcome(.imported(recordCount: totalRecords))
        }
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
    ///
    /// Version semantics:
    /// - An **explicit** version pins the identity; a later, numerically
    ///   comparable explicit version of the same report date supersedes
    ///   older imported versions (Apple's correction flow) in the same
    ///   transaction. Incomparable versions are retained side by side
    ///   with a review note.
    /// - An **unversioned** download ("latest available") is recognized by
    ///   its actual content: identical content to any already-imported
    ///   version for the report date is a skip. Content that differs from
    ///   everything already imported has unproven replacement semantics —
    ///   it is quarantined as `pendingReview` for manual resolution and
    ///   never silently replaces or adds to counted data.
    public func syncSales(
        _ configuration: ASCSalesSyncConfiguration,
        store: any ASCAnalyticsStore
    ) async throws -> ASCSalesSyncResult {
        var outcomes: [ASCSalesSyncOutcome] = []

        for reportDate in configuration.reportDates {
            for version in configuration.versions {
                let outcome = try await syncSalesReport(
                    configuration: configuration,
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
        configuration: ASCSalesSyncConfiguration,
        reportDate: String,
        version: String?,
        store: any ASCAnalyticsStore
    ) async throws -> ASCSalesSyncOutcome {
        let request = ASCSalesReportRequest(
            reportType: configuration.reportType,
            reportSubType: configuration.reportSubType,
            frequency: configuration.frequency,
            vendorNumber: configuration.vendorNumber,
            reportDate: reportDate,
            version: version
        )
        let reportKind = ASCReportSyncEngine.salesReportKind(
            reportType: configuration.reportType,
            reportSubType: configuration.reportSubType,
            frequency: configuration.frequency
        )
        let vendorNumber = configuration.vendorNumber

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

        // Authoritative decision, atomically: the entire post-download
        // decision table runs inside ONE store transaction, re-reading the
        // ledger there. Concurrent engines sharing one store serialize at
        // the transaction slot, so two syncs of the same report can never
        // both decide that nothing was imported and both commit, and an
        // older version can never reverse-supersede a newer one. No Apple
        // network call happens inside the transaction.
        return try await withDecisionTransaction(store: store) { transaction in
                // All candidate entries for the full identity minus version:
                // (source kind, vendor, type/subtype/frequency, report date).
                // Read **inside** the transaction so the decision is based on
                // the latest committed state, not on a pre-download probe.
                let allEntries = try await transaction.ingestionEntries(state: nil)
                let identityCandidates = allEntries.filter { entry in
                entry.key.sourceKind == .summarySales
                    && entry.key.vendorNumber == vendorNumber
                    && entry.key.salesReportKind == reportKind
                    && entry.key.reportDate == reportDate
            }

            if let requestedVersion = version {
                // Explicit version: exact identity, with **order-independent**
                // semantics — importing v1 after v2 never demotes v2, and an
                // older version never supersedes a newer one, even when the
                // contents are identical.
                let key = ASCIngestionKey(
                    sourceKind: .summarySales,
                    vendorNumber: vendorNumber,
                    salesReportKind: reportKind,
                    reportDate: reportDate,
                    reportVersion: requestedVersion
                )
                let existing = identityCandidates.first { $0.key.reportVersion == requestedVersion }

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
                if let existing {
                    let reason = "sales report \(reportDate) version \(requestedVersion) was previously imported with different content; correction semantics inside one version are not documented, so this delivery is retained but excluded until reviewed"
                    return try await quarantineSalesDelivery(
                        reason: reason,
                        key: key,
                        vendorNumber: vendorNumber,
                        reportDate: reportDate,
                        version: version,
                        parseResult: parseResult,
                        transaction: transaction
                    )
                }

                let importedSiblings = identityCandidates.filter {
                    $0.state == .imported && $0.key.deliveryID == nil
                }

                // Content already imported under a different version label.
                // Version order decides, regardless of arrival order:
                // - a provably newer version already carries this content →
                //   nothing to do (never demote it, even with identical
                //   bytes);
                // - all matches are provably older → the requested version
                //   identifies the same content and supersedes **every**
                //   matching older entry;
                // - any match with unresolvable order → manual review.
                let contentMatches = importedSiblings.filter {
                    $0.key.reportVersion != requestedVersion
                        && $0.contentChecksum == parseResult.contentChecksum
                }
                if !contentMatches.isEmpty {
                    let newerMatches = contentMatches.filter {
                        ASCSalesVersionOrder.compare(requestedVersion, $0.key.reportVersion) == .older
                    }
                    let incomparableMatches = contentMatches.filter {
                        ASCSalesVersionOrder.compare(requestedVersion, $0.key.reportVersion) == .incomparable
                    }
                    if let newest = newerMatches.sorted(by: {
                        ASCSalesVersionOrder.compare($0.key.reportVersion, $1.key.reportVersion) == .newer
                    }).first {
                        return ASCSalesSyncOutcome(
                            reportDate: reportDate,
                            version: version,
                            outcome: .skippedAlreadyImported,
                            supersededVersions: [],
                            notes: ["content of version \(requestedVersion) is already imported as the newer version \(newest.key.reportVersion ?? "nil"); the older version is not imported as current"]
                        )
                    }
                    if let incomparable = incomparableMatches.first {
                        let reason = "sales report \(reportDate): version \(requestedVersion) has content identical to version \(incomparable.key.reportVersion ?? "nil") but the two versions cannot be ordered; the existing import stays current and manual review of the version labeling is required"
                        return try await quarantineSalesDelivery(
                            reason: reason,
                            key: key,
                            vendorNumber: vendorNumber,
                            reportDate: reportDate,
                            version: version,
                            parseResult: parseResult,
                            transaction: transaction
                        )
                    }
                    // All matches are provably older: import under the
                    // requested version and supersede every one of them.
                    let provenance = Self.salesProvenance(
                        parseResult: parseResult,
                        vendorNumber: vendorNumber,
                        reportDate: reportDate,
                        reportVersion: version,
                        reportKind: reportKind
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
                    try await transaction.insertSales(provenanced, ingestionKey: key)
                    try await transaction.upsertIngestion(entry)
                    try await transaction.markSuperseded(
                        keys: contentMatches.map(\.key), by: key
                    )
                    return ASCSalesSyncOutcome(
                        reportDate: reportDate,
                        version: version,
                        outcome: .imported(recordCount: parseResult.records.count),
                        supersededVersions: contentMatches.compactMap(\.key.reportVersion),
                        notes: ["content was already imported under older version(s); all of them are superseded by version \(requestedVersion)"]
                    )
                }

                let currentSiblings = importedSiblings

                // An unversioned (latest) import with DIFFERENT content: the
                // relation between the explicit version and that content is
                // unknowable (older? newer? unrelated correction?) — manual
                // resolution instead of guessing which one is current.
                if let unversioned = currentSiblings.first(where: { $0.key.reportVersion == nil }) {
                    let reason = "sales report \(reportDate): an unversioned (latest) import with different content exists, so version \(requestedVersion) cannot be ordered against it; manual review is required before either can be treated as current"
                    return try await quarantineSalesDelivery(
                        reason: reason,
                        key: key,
                        vendorNumber: vendorNumber,
                        reportDate: reportDate,
                        version: version,
                        parseResult: parseResult,
                        transaction: transaction
                    )
                }

                // Explicit versions only. Any current sibling with unresolvable
                // order blocks the import: two current versions with different
                // content must never coexist silently.
                let incomparableSiblings = currentSiblings.filter {
                    ASCSalesVersionOrder.compare(requestedVersion, $0.key.reportVersion) == .incomparable
                }
                if let incomparable = incomparableSiblings.first {
                    let reason = "sales report \(reportDate): version \(requestedVersion) cannot be ordered against the imported version \(incomparable.key.reportVersion ?? "nil"); both contents differ and manual review is required before either can be treated as current"
                    return try await quarantineSalesDelivery(
                        reason: reason,
                        key: key,
                        vendorNumber: vendorNumber,
                        reportDate: reportDate,
                        version: version,
                        parseResult: parseResult,
                        transaction: transaction
                    )
                }

                // Provably newer current siblings: the requested version is
                // older. It never supersedes them; it is retained for audit
                // only so the current statistics do not change and nothing is
                // double-counted.
                let newerSiblings = currentSiblings.filter {
                    ASCSalesVersionOrder.compare(requestedVersion, $0.key.reportVersion) == .older
                }
                if let newest = newerSiblings.sorted(by: {
                    ASCSalesVersionOrder.compare($0.key.reportVersion, $1.key.reportVersion) == .newer
                }).first {
                    let supersededBy = newest.key.reportVersion ?? "latest(unversioned)"
                    let provenance = Self.salesProvenance(
                        parseResult: parseResult,
                        vendorNumber: vendorNumber,
                        reportDate: reportDate,
                        reportVersion: version,
                        reportKind: reportKind
                    )
                    let provenanced = parseResult.records.map {
                        ASCProvenancedRecord(record: $0, provenance: provenance)
                    }
                    let entry = ASCIngestionEntry(
                        key: key,
                        state: .superseded,
                        reportName: "Summary Sales Report",
                        segmentChecksums: [:],
                        schemaFingerprint: parseResult.schemaFingerprint,
                        contentChecksum: parseResult.contentChecksum,
                        recordCount: parseResult.records.count,
                        importedAt: Date(),
                        supersededBy: newest.key
                    )
                    try await transaction.insertSales(provenanced, ingestionKey: key)
                    try await transaction.upsertIngestion(entry)
                    return ASCSalesSyncOutcome(
                        reportDate: reportDate,
                        version: version,
                        outcome: .importedForAuditOnly(
                            recordCount: parseResult.records.count,
                            supersededBy: supersededBy
                        ),
                        supersededVersions: [],
                        notes: ["version \(requestedVersion) is older than the already imported version \(supersededBy); it is retained for audit only and does not contribute to current queries"]
                    )
                }

                // All current explicit siblings are provably older: import and
                // supersede **all** of them.
                let supersededVersions = currentSiblings.compactMap(\.key.reportVersion)
                let provenance = Self.salesProvenance(
                    parseResult: parseResult,
                    vendorNumber: vendorNumber,
                    reportDate: reportDate,
                    reportVersion: version,
                    reportKind: reportKind
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

                try await transaction.insertSales(provenanced, ingestionKey: key)
                try await transaction.upsertIngestion(entry)
                if !supersededVersions.isEmpty {
                    try await transaction.markSuperseded(
                        keys: currentSiblings.map(\.key), by: key
                    )
                }

                return ASCSalesSyncOutcome(
                    reportDate: reportDate,
                    version: version,
                    outcome: .imported(recordCount: parseResult.records.count),
                    supersededVersions: supersededVersions,
                    notes: []
                )
            }

            // Unversioned "latest available" download. Apple does not echo the
            // version of this content, so it is recognized by actual content
            // against the already-imported versions of the report date.
            let importedCandidates = identityCandidates.filter {
                $0.state == .imported && $0.key.deliveryID == nil
            }

            if let matching = importedCandidates.first(where: {
                $0.contentChecksum == parseResult.contentChecksum
            }) {
                // The latest content is byte-identical to an already imported
                // version: nothing new.
                return ASCSalesSyncOutcome(
                    reportDate: reportDate,
                    version: version,
                    outcome: .skippedAlreadyImported,
                    supersededVersions: [],
                    notes: ["latest content matches the already imported version \(matching.key.reportVersion ?? "nil")"]
                )
            }

            if !importedCandidates.isEmpty {
                // A latest download whose content differs from everything
                // imported: replacement semantics cannot be proven (is this a
                // correction? which version does it correspond to?). Never
                // keep serving old statistics silently and never treat it as
                // the same version — quarantine for manual resolution.
                let key = ASCIngestionKey(
                    sourceKind: .summarySales,
                    vendorNumber: vendorNumber,
                    salesReportKind: reportKind,
                    reportDate: reportDate,
                    reportVersion: nil
                )
                let reason = "unversioned latest download of sales report \(reportDate) differs from all imported versions (\(importedCandidates.map { $0.key.reportVersion ?? "nil" }.joined(separator: ", "))); replacement semantics cannot be proven and manual review is required"
                return try await quarantineSalesDelivery(
                    reason: reason,
                    key: key,
                    vendorNumber: vendorNumber,
                    reportDate: reportDate,
                    version: version,
                    parseResult: parseResult,
                    transaction: transaction
                )
            }

            // First import of this report date: store as an unversioned
            // (latest) import with its own identity.
            let key = ASCIngestionKey(
                sourceKind: .summarySales,
                vendorNumber: vendorNumber,
                salesReportKind: reportKind,
                reportDate: reportDate,
                reportVersion: nil
            )
            let provenance = Self.salesProvenance(
                parseResult: parseResult,
                vendorNumber: vendorNumber,
                reportDate: reportDate,
                reportVersion: nil,
                reportKind: reportKind
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
            try await transaction.insertSales(provenanced, ingestionKey: key)
            try await transaction.upsertIngestion(entry)
            return ASCSalesSyncOutcome(
                reportDate: reportDate,
                version: version,
                outcome: .imported(recordCount: parseResult.records.count),
                supersededVersions: []
            )
        }
    }

    /// Sales provenance with the full report identity: kind, order-
    /// sensitive schema fingerprint (audit), and the order-insensitive
    /// canonical schema identity.
    static func salesProvenance(
        parseResult: ASCSalesParseResult,
        vendorNumber: String,
        reportDate: String,
        reportVersion: String?,
        reportKind: String
    ) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: .summarySales,
            reportName: "Summary Sales Report",
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: reportVersion,
            salesReportKind: reportKind,
            schemaFingerprint: parseResult.schemaFingerprint,
            canonicalSchemaIdentity: parseResult.canonicalSchemaIdentity,
            contentChecksum: parseResult.contentChecksum,
            fetchedAt: Date(),
            recordCount: parseResult.records.count
        )
    }

    /// Records a conflicting sales delivery as pending review under its
    /// own delivery key, keeping the counted imports untouched. Writes go
    /// through the **caller's transaction** — part of the same atomic
    /// decision, never a separate commit.
    private func quarantineSalesDelivery(
        reason: String,
        key: ASCIngestionKey,
        vendorNumber: String,
        reportDate: String,
        version: String?,
        parseResult: ASCSalesParseResult,
        transaction: any ASCAnalyticsStoreTransaction
    ) async throws -> ASCSalesSyncOutcome {
        let pendingKey = key.withDeliveryID(parseResult.contentChecksum)
        let provenance = ASCReportProvenance(
            sourceKind: .summarySales,
            reportName: "Summary Sales Report",
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: key.reportVersion,
            salesReportKind: key.salesReportKind,
            schemaFingerprint: parseResult.schemaFingerprint,
            canonicalSchemaIdentity: parseResult.canonicalSchemaIdentity,
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
        try await transaction.insertSales(provenanced, ingestionKey: pendingKey)
        try await transaction.upsertIngestion(entry)
        return ASCSalesSyncOutcome(
            reportDate: reportDate,
            version: version,
            outcome: .pendingReview(reason: reason),
            supersededVersions: []
        )
    }

    /// The Sales and Trends report kind component of an ingestion key:
    /// `"TYPE/SUBTYPE/FREQUENCY"`.
    static func salesReportKind(
        reportType: ASCSalesReportType,
        reportSubType: ASCSalesReportSubType,
        frequency: ASCSalesReportFrequency
    ) -> String {
        "\(reportType.rawValue)/\(reportSubType.rawValue)/\(frequency.rawValue)"
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
