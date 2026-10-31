import Foundation

/// Thread-safe, fully in-memory `ASCAnalyticsStore`.
///
/// This is the reference implementation for offline use, tests, and
/// previews. It enforces the full transaction contract: mutations are
/// staged inside the transaction, become visible to readers only on
/// `commit`, and are completely discarded on `rollback`. One unfinished
/// transaction is active at a time; a second `beginTransaction` fails with
/// `ASCAnalyticsError.storeInconsistentState` while the first transaction
/// object is still alive and unfinished. A transaction that is committed,
/// rolled back, **or simply dropped by the caller** (for example when a
/// task is cancelled between begin and commit) releases its slot, so a
/// dropped transaction can never permanently block later syncs.
public final class ASCInMemoryAnalyticsStore: ASCAnalyticsStore, @unchecked Sendable {
    private let lock = NSLock()
    /// Weak reference to the live transaction. When the caller drops an
    /// unfinished transaction, the object deallocates, this becomes `nil`,
    /// and the slot is free again — no stale flag can remain behind.
    private weak var activeTransaction: Transaction?

    // Committed state.
    private var ingestions: [ASCIngestionKey: ASCIngestionEntry] = [:]
    private var salesByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCSalesRecord>]] = [:]
    private var downloadsByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCDownloadRecord>]] = [:]
    private var discoveryByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCDiscoveryRecord>]] = [:]

    public init() {}

    public func beginTransaction() async throws -> any ASCAnalyticsStoreTransaction {
        try beginTransactionLocked()
    }

    private func beginTransactionLocked() throws -> any ASCAnalyticsStoreTransaction {
        lock.lock()
        defer { lock.unlock() }
        if let current = activeTransaction, !current.isFinished {
            throw ASCAnalyticsError.storeInconsistentState(
                reason: "another transaction is already active on this store"
            )
        }
        let transaction = Transaction(store: self)
        activeTransaction = transaction
        return transaction
    }

    /// Clears the active-transaction slot when the given transaction
    /// finishes (commit or rollback).
    fileprivate func transactionDidFinish(_ transaction: Transaction) {
        lock.lock()
        defer { lock.unlock() }
        if activeTransaction === transaction {
            activeTransaction = nil
        }
    }

    // MARK: - Transaction

    /// Stages mutations and applies them under the store lock on commit.
    ///
    /// A transaction is intended for a single owner; concurrent mutation
    /// of one transaction from multiple tasks is not supported. The
    /// finished flag is a set-once leaf lock so the store can inspect it
    /// without ordering hazards against its own lock.
    fileprivate final class Transaction: ASCAnalyticsStoreTransaction, @unchecked Sendable {
        private unowned let store: ASCInMemoryAnalyticsStore

        private let finishedLock = NSLock()
        private var finishedStorage = false

        /// Whether the transaction has been committed or rolled back.
        /// Safe to read while holding the store lock (leaf lock, no
        /// ordering with the store lock).
        fileprivate var isFinished: Bool {
            finishedLock.lock()
            defer { finishedLock.unlock() }
            return finishedStorage
        }

        /// Marks the transaction finished exactly once; returns `false`
        /// when it was already finished.
        private func finishOnce() -> Bool {
            finishedLock.lock()
            defer { finishedLock.unlock() }
            if finishedStorage { return false }
            finishedStorage = true
            return true
        }

        private func ensureActive() throws {
            if isFinished {
                throw ASCAnalyticsError.storeInconsistentState(
                    reason: "transaction already finished"
                )
            }
        }

        private var ingestions: [ASCIngestionKey: ASCIngestionEntry] = [:]
        private var superseded: [ASCIngestionKey: ASCIngestionEntry] = [:]
        private var sales: [ASCIngestionKey: [ASCProvenancedRecord<ASCSalesRecord>]] = [:]
        private var downloads: [ASCIngestionKey: [ASCProvenancedRecord<ASCDownloadRecord>]] = [:]
        private var discovery: [ASCIngestionKey: [ASCProvenancedRecord<ASCDiscoveryRecord>]] = [:]

        fileprivate init(store: ASCInMemoryAnalyticsStore) {
            self.store = store
        }

        func commit() async throws {
            guard finishOnce() else {
                throw ASCAnalyticsError.storeInconsistentState(
                    reason: "transaction already finished"
                )
            }
            store.applyTransaction(self)
            store.transactionDidFinish(self)
        }

        func rollback() async throws {
            guard finishOnce() else {
                throw ASCAnalyticsError.storeInconsistentState(
                    reason: "transaction already finished"
                )
            }
            // Staged mutations are simply never applied.
            store.transactionDidFinish(self)
        }

        func upsertIngestion(_ entry: ASCIngestionEntry) async throws {
            try ensureActive()
            ingestions[entry.key] = entry
        }

        func ingestion(matching key: ASCIngestionKey) async throws -> ASCIngestionEntry? {
            try ensureActive()
            if let staged = ingestions[key] ?? superseded[key] {
                return staged
            }
            return store.lookupIngestion(matching: key)
        }

        func ingestionEntries(state: ASCIngestionState?) async throws -> [ASCIngestionEntry] {
            try ensureActive()
            let staged = Array(ingestions.values) + Array(superseded.values)
            let committedEntries = store.allIngestionEntries()
            return (committedEntries + staged)
                .filter { state == nil || $0.state == state }
                .reduce(into: [ASCIngestionKey: ASCIngestionEntry]()) {
                    $0[$1.key] = $1
                }
                .map(\.value)
                .sorted { $0.importedAt < $1.importedAt }
        }

        func markSuperseded(keys: [ASCIngestionKey], by: ASCIngestionKey) async throws {
            try ensureActive()
            for key in keys {
                let entry = ingestions[key] ?? store.lookupIngestion(matching: key)
                guard let entry else { continue }
                var supersededEntry = entry
                if supersededEntry.state == .imported {
                    supersededEntry = ASCIngestionEntry(
                        key: supersededEntry.key,
                        state: .superseded,
                        processingDate: supersededEntry.processingDate,
                        granularity: supersededEntry.granularity,
                        reportName: supersededEntry.reportName,
                        category: supersededEntry.category,
                        appAppleIdentifier: supersededEntry.appAppleIdentifier,
                        segmentIDs: supersededEntry.segmentIDs,
                        segmentChecksums: supersededEntry.segmentChecksums,
                        schemaFingerprint: supersededEntry.schemaFingerprint,
                        contentChecksum: supersededEntry.contentChecksum,
                        recordCount: supersededEntry.recordCount,
                        importedAt: supersededEntry.importedAt,
                        pendingReason: supersededEntry.pendingReason,
                        supersededBy: by
                    )
                }
                superseded[key] = supersededEntry
                ingestions[key] = nil
            }
        }

        func insertSales(
            _ records: [ASCProvenancedRecord<ASCSalesRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            try ensureActive()
            sales[ingestionKey, default: []].append(contentsOf: records)
        }

        func insertDownloads(
            _ records: [ASCProvenancedRecord<ASCDownloadRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            try ensureActive()
            downloads[ingestionKey, default: []].append(contentsOf: records)
        }

        func insertDiscovery(
            _ records: [ASCProvenancedRecord<ASCDiscoveryRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            try ensureActive()
            discovery[ingestionKey, default: []].append(contentsOf: records)
        }

        func salesRecords(
            appAppleIdentifiers: Set<String>?,
            parentIdentifiers: Set<String>?,
            in range: ASCDateRange?,
            scope: ASCIngestionQueryScope
        ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>] {
            // A transaction's queries see committed state only: staged
            // mutations are invisible until commit.
            try ensureActive()
            return try await store.salesRecords(
                appAppleIdentifiers: appAppleIdentifiers,
                parentIdentifiers: parentIdentifiers,
                in: range,
                scope: scope
            )
        }

        func downloadRecords(
            appIdentifiers: Set<String>?,
            in range: ASCDateRange?,
            scope: ASCIngestionQueryScope
        ) async throws -> [ASCProvenancedRecord<ASCDownloadRecord>] {
            try ensureActive()
            return try await store.downloadRecords(
                appIdentifiers: appIdentifiers,
                in: range,
                scope: scope
            )
        }

        func discoveryRecords(
            appIdentifiers: Set<String>?,
            in range: ASCDateRange?,
            scope: ASCIngestionQueryScope
        ) async throws -> [ASCProvenancedRecord<ASCDiscoveryRecord>] {
            try ensureActive()
            return try await store.discoveryRecords(
                appIdentifiers: appIdentifiers,
                in: range,
                scope: scope
            )
        }

        fileprivate func applyInto(
            ingestions: inout [ASCIngestionKey: ASCIngestionEntry],
            sales: inout [ASCIngestionKey: [ASCProvenancedRecord<ASCSalesRecord>]],
            downloads: inout [ASCIngestionKey: [ASCProvenancedRecord<ASCDownloadRecord>]],
            discovery: inout [ASCIngestionKey: [ASCProvenancedRecord<ASCDiscoveryRecord>]]
        ) {
            for (key, entry) in self.superseded {
                ingestions[key] = entry
            }
            for (key, entry) in self.ingestions {
                ingestions[key] = entry
            }
            for (key, records) in self.sales {
                sales[key, default: []].append(contentsOf: records)
            }
            for (key, records) in self.downloads {
                downloads[key, default: []].append(contentsOf: records)
            }
            for (key, records) in self.discovery {
                discovery[key, default: []].append(contentsOf: records)
            }
        }
    }

    // MARK: - Commit application (store-locked)

    private func applyTransaction(_ transaction: Transaction) {
        lock.lock()
        defer { lock.unlock() }
        transaction.applyInto(
            ingestions: &ingestions,
            sales: &salesByIngestion,
            downloads: &downloadsByIngestion,
            discovery: &discoveryByIngestion
        )
    }

    // MARK: - Committed-state readers (store-locked)

    fileprivate func lookupIngestion(matching key: ASCIngestionKey) -> ASCIngestionEntry? {
        lock.lock()
        defer { lock.unlock() }
        return primaryIngestionLocked(matching: key)
    }

    /// Returns the best match for a lookup key. Several entries can match
    /// (the primary import plus delivery-keyed re-deliveries); the primary
    /// import (`deliveryID == nil`) always wins.
    private func primaryIngestionLocked(matching key: ASCIngestionKey) -> ASCIngestionEntry? {
        let candidates = ingestions.filter { (entryKey, _) in entryKey.matches(key) }.map(\.value)
        if let primary = candidates.first(where: { $0.key.deliveryID == nil }) {
            return primary
        }
        return candidates.first
    }

    fileprivate func allIngestionEntries() -> [ASCIngestionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ingestions.values)
    }

    /// Queries committed sales records.
    public func salesRecords(
        appAppleIdentifiers: Set<String>? = nil,
        parentIdentifiers: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>] {
        querySalesLocked(
            appAppleIdentifiers: appAppleIdentifiers,
            parentIdentifiers: parentIdentifiers,
            in: range,
            scope: scope
        )
    }

    /// Queries committed download records.
    public func downloadRecords(
        appIdentifiers: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCDownloadRecord>] {
        queryDownloadsLocked(
            appIdentifiers: appIdentifiers,
            in: range,
            scope: scope
        )
    }

    /// Queries committed discovery records.
    public func discoveryRecords(
        appIdentifiers: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCDiscoveryRecord>] {
        queryDiscoveryLocked(
            appIdentifiers: appIdentifiers,
            in: range,
            scope: scope
        )
    }

    // MARK: - Synchronous locked helpers

    private func querySalesLocked(
        appAppleIdentifiers: Set<String>?,
        parentIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) -> [ASCProvenancedRecord<ASCSalesRecord>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ASCProvenancedRecord<ASCSalesRecord>] = []
        for (key, records) in salesByIngestion {
            guard isIncludedLocked(key, scope: scope) else { continue }
            for entry in records {
                let record = entry.record
                // Same attribution semantics as `ASCSalesFilter`: a record
                // matches when its Apple Identifier is in the direct set
                // OR its Parent Identifier SKU is in the parent set, so
                // one app's direct sales and its in-app purchases are
                // retrievable together.
                guard record.appAttribution.matches(
                    appAppleIdentifiers: appAppleIdentifiers,
                    parentIdentifiers: parentIdentifiers
                ) else { continue }
                if let range {
                    guard range.contains(record.beginDate) || range.contains(record.endDate) else {
                        continue
                    }
                }
                result.append(entry)
            }
        }
        return result
    }

    private func queryDownloadsLocked(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) -> [ASCProvenancedRecord<ASCDownloadRecord>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ASCProvenancedRecord<ASCDownloadRecord>] = []
        for (key, records) in downloadsByIngestion {
            guard isIncludedLocked(key, scope: scope) else { continue }
            for entry in records {
                let record = entry.record
                if let appIdentifiers, !appIdentifiers.contains(record.appAppleIdentifier) {
                    continue
                }
                if let range, !range.contains(record.date) { continue }
                result.append(entry)
            }
        }
        return result
    }

    private func queryDiscoveryLocked(
        appIdentifiers: Set<String>?,
        in range: ASCDateRange?,
        scope: ASCIngestionQueryScope
    ) -> [ASCProvenancedRecord<ASCDiscoveryRecord>] {
        lock.lock()
        defer { lock.unlock() }
        var result: [ASCProvenancedRecord<ASCDiscoveryRecord>] = []
        for (key, records) in discoveryByIngestion {
            guard isIncludedLocked(key, scope: scope) else { continue }
            for entry in records {
                let record = entry.record
                if let appIdentifiers, !appIdentifiers.contains(record.appAppleIdentifier) {
                    continue
                }
                if let range, !range.contains(record.date) { continue }
                result.append(entry)
            }
        }
        return result
    }

    /// Lock-free inclusion check; callers must hold the store lock.
    private func isIncludedLocked(
        _ key: ASCIngestionKey, scope: ASCIngestionQueryScope
    ) -> Bool {
        guard let entry = primaryIngestionLocked(matching: key) else { return false }
        switch scope {
        case .current: return entry.state == .imported
        case .all: return true
        }
    }
}

extension ASCIngestionKey {
    /// Whether this entry key matches a lookup key. Every non-nil field of
    /// the lookup must be equal; `reportVersion` matching is **exact** — a
    /// `nil` lookup version only matches `nil` entry versions, never an
    /// explicitly versioned import. A lookup `sourceKind` of `.unknown`
    /// acts as a wildcard, because the sync engine looks up analytics
    /// ingestions by instance identity before parsing determines the
    /// report family.
    func matches(_ lookup: ASCIngestionKey) -> Bool {
        if lookup.sourceKind != .unknown && lookup.sourceKind != sourceKind { return false }
        if let instanceID = lookup.instanceID, instanceID != self.instanceID { return false }
        if let vendorNumber = lookup.vendorNumber, vendorNumber != self.vendorNumber { return false }
        if let salesReportKind = lookup.salesReportKind, salesReportKind != self.salesReportKind { return false }
        if let reportDate = lookup.reportDate, reportDate != self.reportDate { return false }
        if lookup.reportVersion != self.reportVersion { return false }
        if let deliveryID = lookup.deliveryID, deliveryID != self.deliveryID { return false }
        return true
    }
}
