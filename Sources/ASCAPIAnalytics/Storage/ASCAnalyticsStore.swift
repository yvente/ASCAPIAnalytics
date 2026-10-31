import Foundation

/// Identity of one ingested report file set, used for idempotent syncing
/// and for supersession of corrected data.
///
/// For Sales and Trends the identity is the full tuple: vendor number,
/// report type, report subtype, frequency (together in
/// `salesReportKind`), report date, and the version. `reportVersion`
/// participates in matching **exactly**: `nil` means "an import fetched as
/// the latest available version, whose version number Apple does not echo
/// back", and it only ever matches another `nil` — it is never a wildcard,
/// so an unversioned latest import can never be conflated with an
/// explicitly versioned one.
///
/// For Analytics the identity is the report instance id; a lookup key with
/// only `instanceID` set finds an analytics ingestion regardless of its
/// source kind (the kind is only known after parsing).
public struct ASCIngestionKey: Hashable, Codable, Sendable {
    /// The report family.
    public let sourceKind: ASCReportSourceKind
    /// Analytics report instance identifier.
    public let instanceID: String?
    /// Sales and Trends vendor number.
    public let vendorNumber: String?
    /// Sales report kind — the composite `"TYPE/SUBTYPE/FREQUENCY"` that
    /// distinguishes, for example, a daily Summary Sales report from a
    /// weekly one for the same report date.
    public let salesReportKind: String?
    /// Sales and Trends report date filter value.
    public let reportDate: String?
    /// Sales and Trends report version. An explicit string pins that
    /// version; `nil` identifies an import fetched as "latest available"
    /// whose version number is unknown. Matching is exact, never a
    /// wildcard.
    public let reportVersion: String?
    /// Distinguishes a conflicting re-delivery of the same identity (same
    /// instance or report version, different content). The primary import
    /// has `nil`; each unproven re-delivery is keyed by its content
    /// checksum so it can be retained for review without touching the
    /// counted import.
    public let deliveryID: String?

    public init(
        sourceKind: ASCReportSourceKind,
        instanceID: String? = nil,
        vendorNumber: String? = nil,
        salesReportKind: String? = nil,
        reportDate: String? = nil,
        reportVersion: String? = nil,
        deliveryID: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.instanceID = instanceID
        self.vendorNumber = vendorNumber
        self.salesReportKind = salesReportKind
        self.reportDate = reportDate
        self.reportVersion = reportVersion
        self.deliveryID = deliveryID
    }

    /// Returns a copy keyed to a specific conflicting delivery.
    public func withDeliveryID(_ deliveryID: String) -> ASCIngestionKey {
        ASCIngestionKey(
            sourceKind: sourceKind,
            instanceID: instanceID,
            vendorNumber: vendorNumber,
            salesReportKind: salesReportKind,
            reportDate: reportDate,
            reportVersion: reportVersion,
            deliveryID: deliveryID
        )
    }
}

/// Lifecycle state of one ingestion.
public enum ASCIngestionState: String, Codable, Hashable, Sendable {
    /// Parsed, verified, and committed; the records participate in
    /// queries and aggregation.
    case imported
    /// Data was retained but excluded from queries because the update
    /// semantics could not be proven (for example the same instance or
    /// report arriving again with different content). Nothing is counted
    /// twice while data waits here.
    case pendingReview
    /// Superseded by a newer version of the same report (Sales and Trends
    /// corrections). Retained for audit, excluded from queries by default.
    case superseded
}

/// Ledger entry for one ingested report: its identity, state, source
/// metadata, fingerprints, and checksums. Every stored result can be
/// audited back to the exact files it came from.
public struct ASCIngestionEntry: Hashable, Codable, Sendable {
    /// Identity of the ingestion.
    public let key: ASCIngestionKey
    /// Current lifecycle state.
    public let state: ASCIngestionState
    /// Apple processing date of the instance (`YYYY-MM-DD`), when
    /// applicable.
    public let processingDate: String?
    /// Instance granularity, when applicable.
    public let granularity: ASCReportGranularity?
    /// Report name attribute, when applicable.
    public let reportName: String?
    /// Report category attribute raw value, when applicable.
    public let category: String?
    /// App Apple Identifier the report belongs to, when known.
    public let appAppleIdentifier: String?
    /// Segment identifiers of the instance, in API order.
    public let segmentIDs: [String]
    /// SHA-256 content checksum per segment identifier.
    public let segmentChecksums: [String: String]
    /// Schema fingerprint (header hash) verified before commit.
    public let schemaFingerprint: String
    /// SHA-256 over the raw bytes of every segment, combined.
    public let contentChecksum: String
    /// Number of records committed from this ingestion.
    public let recordCount: Int
    /// Time the ingestion was committed.
    public let importedAt: Date
    /// Why the entry is in `pendingReview` state, when it is.
    public let pendingReason: String?
    /// Key of the ingestion that superseded this one, when superseded.
    public let supersededBy: ASCIngestionKey?

    public init(
        key: ASCIngestionKey,
        state: ASCIngestionState,
        processingDate: String? = nil,
        granularity: ASCReportGranularity? = nil,
        reportName: String? = nil,
        category: String? = nil,
        appAppleIdentifier: String? = nil,
        segmentIDs: [String] = [],
        segmentChecksums: [String: String] = [:],
        schemaFingerprint: String,
        contentChecksum: String,
        recordCount: Int,
        importedAt: Date,
        pendingReason: String? = nil,
        supersededBy: ASCIngestionKey? = nil
    ) {
        self.key = key
        self.state = state
        self.processingDate = processingDate
        self.granularity = granularity
        self.reportName = reportName
        self.category = category
        self.appAppleIdentifier = appAppleIdentifier
        self.segmentIDs = segmentIDs
        self.segmentChecksums = segmentChecksums
        self.schemaFingerprint = schemaFingerprint
        self.contentChecksum = contentChecksum
        self.recordCount = recordCount
        self.importedAt = importedAt
        self.pendingReason = pendingReason
        self.supersededBy = supersededBy
    }
}

/// Which records a query returns with respect to ingestion state.
public enum ASCIngestionQueryScope: Hashable, Codable, Sendable {
    /// Only records from `.imported` ingestions — the default for metric
    /// computation.
    case current
    /// All records, including superseded and pending-review data, for
    /// audit purposes.
    case all
}

/// Protocol every transaction implementation must uphold: mutations become
/// visible to readers only after `commit` succeeds, and are fully
/// discarded after `rollback`. Partial commits are impossible.
public protocol ASCAnalyticsStoreTransaction: AnyObject, Sendable {
    /// Atomically publishes every mutation performed on this transaction.
    func commit() async throws
    /// Discards every mutation performed on this transaction.
    func rollback() async throws

    // MARK: - Ingestion ledger

    /// Inserts or replaces the ledger entry for the entry's key.
    func upsertIngestion(_ entry: ASCIngestionEntry) async throws
    /// Returns the ledger entry matching all non-nil fields of `key`.
    func ingestion(matching key: ASCIngestionKey) async throws -> ASCIngestionEntry?
    /// Lists ledger entries, optionally filtered by state.
    func ingestionEntries(state: ASCIngestionState?) async throws -> [ASCIngestionEntry]
    /// Marks the given keys as superseded by `by`.
    func markSuperseded(keys: [ASCIngestionKey], by: ASCIngestionKey) async throws

    // MARK: - Normalized record insertion

    /// Inserts sales records under the given ingestion key.
    func insertSales(
        _ records: [ASCProvenancedRecord<ASCSalesRecord>],
        ingestionKey: ASCIngestionKey
    ) async throws
    /// Inserts download records under the given ingestion key.
    func insertDownloads(
        _ records: [ASCProvenancedRecord<ASCDownloadRecord>],
        ingestionKey: ASCIngestionKey
    ) async throws
    /// Inserts discovery records under the given ingestion key.
    func insertDiscovery(
        _ records: [ASCProvenancedRecord<ASCDiscoveryRecord>],
        ingestionKey: ASCIngestionKey
    ) async throws

    // MARK: - Queries

    /// Queries stored sales records.
    /// - Parameters:
    ///   - appAppleIdentifiers: restrict to records attributed to these
    ///     Apple identifiers (direct rows) — `nil` disables the filter.
    ///   - parentIdentifiers: restrict to in-app purchase rows attributed
    ///     to these parent identifiers — `nil` disables the filter.
    ///   - range: restrict to records whose Begin Date intersects the
    ///     range — `nil` disables the filter.
    ///   - scope: which ingestion states to include.
    func salesRecords(
        appAppleIdentifiers: Set<String>?,
        parentIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>]

    /// Queries stored download records.
    func downloadRecords(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCDownloadRecord>]

    /// Queries stored discovery records.
    func discoveryRecords(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCDiscoveryRecord>]
}

/// Persistence boundary of ASCAPIAnalytics.
///
/// The package defines the protocol only — no database driver ships with
/// the library (repository rule 5). Host apps provide concrete
/// implementations; `ASCInMemoryAnalyticsStore` is a reference
/// implementation for tests and offline use.
///
/// Contract:
/// - Every mutation goes through a transaction; mutations are visible
///   only after a successful commit (atomicity).
/// - Records are stored with full provenance and are tied to an
///   ingestion key, so superseded and pending-review data can be
///   excluded without losing it.
public protocol ASCAnalyticsStore: Sendable {
    /// Begins a transaction. Implementations may reject concurrent
    /// transactions with `ASCAnalyticsError.storeInconsistentState`, and
    /// must release the slot when a transaction is committed, rolled
    /// back, or dropped unfinished — a cancelled or abandoned transaction
    /// must never block later syncs.
    func beginTransaction() async throws -> any ASCAnalyticsStoreTransaction

    /// Queries committed sales records.
    /// - Parameters:
    ///   - appAppleIdentifiers: restrict to records attributed to these
    ///     Apple identifiers (direct rows) — `nil` disables the filter.
    ///   - parentIdentifiers: restrict to in-app purchase rows attributed
    ///     to these parent identifiers — `nil` disables the filter.
    ///     A record matches when either filter applies to it (OR across
    ///     the two namespaces), so one app's direct sales and its
    ///     in-app purchases are retrievable together.
    ///   - range: restrict to records whose Begin Date intersects the
    ///     range — `nil` disables the filter.
    ///   - scope: which ingestion states to include.
    func salesRecords(
        appAppleIdentifiers: Set<String>?,
        parentIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>]

    /// Queries stored download records.
    func downloadRecords(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCDownloadRecord>]

    /// Queries stored discovery records.
    func discoveryRecords(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) async throws -> [ASCProvenancedRecord<ASCDiscoveryRecord>]

    /// Runs `body` in a transaction: commits on success, rolls back and
    /// rethrows on failure. This is the recommended way to obtain atomic
    /// all-or-nothing ingestion.
    func withTransaction<T>(
        _ body: (any ASCAnalyticsStoreTransaction) async throws -> T
    ) async throws -> T
}

extension ASCAnalyticsStore {
    public func withTransaction<T>(
        _ body: (any ASCAnalyticsStoreTransaction) async throws -> T
    ) async throws -> T {
        let transaction = try await beginTransaction()
        do {
            let result = try await body(transaction)
            try await transaction.commit()
            return result
        } catch {
            try? await transaction.rollback()
            throw error
        }
    }
}
