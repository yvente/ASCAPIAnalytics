import Foundation

/// Thread-safe, fully in-memory `ASCAnalyticsStore`.
///
/// This is the reference implementation for offline use, tests, and
/// previews. It enforces the full transaction contract: mutations are
/// staged inside the transaction, become visible to readers only on
/// `commit`, and are completely discarded on `rollback`. One transaction
/// is active at a time; a second `beginTransaction` fails with
/// `ASCAnalyticsError.storeInconsistentState`.
public final class ASCInMemoryAnalyticsStore: ASCAnalyticsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var transactionActive = false

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
        guard !transactionActive else {
            throw ASCAnalyticsError.storeInconsistentState(
                reason: "another transaction is already active on this store"
            )
        }
        transactionActive = true
        return Transaction(store: self)
    }

    // MARK: - Transaction

    /// Stages mutations and applies them under the store lock.
    private final class Transaction: ASCAnalyticsStoreTransaction, @unchecked Sendable {
        private unowned let store: ASCInMemoryAnalyticsStore
        private let lock = NSLock()
        private var committed = false
        private var rolledBack = false

        private var ingestions: [ASCIngestionKey: ASCIngestionEntry] = [:]
        private var superseded: [ASCIngestionKey: ASCIngestionEntry] = [:]
        private var sales: [ASCIngestionKey: [ASCProvenancedRecord<ASCSalesRecord>]] = [:]
        private var downloads: [ASCIngestionKey: [ASCProvenancedRecord<ASCDownloadRecord>]] = [:]
        private var discovery: [ASCIngestionKey: [ASCProvenancedRecord<ASCDiscoveryRecord>]] = [:]

        fileprivate init(store: ASCInMemoryAnalyticsStore) {
            self.store = store
        }

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }

        func commit() async throws {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
                committed = true
            }
            store.applyTransaction(self)
        }

        func rollback() async throws {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
                rolledBack = true
                ingestions = [:]
                superseded = [:]
                sales = [:]
                downloads = [:]
                discovery = [:]
            }
            // Release the store's single-transaction slot.
            store.discardTransaction()
        }

        func upsertIngestion(_ entry: ASCIngestionEntry) async throws {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
                ingestions[entry.key] = entry
            }
        }

        func ingestion(matching key: ASCIngestionKey) async throws -> ASCIngestionEntry? {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
                if let staged = ingestions[key] ?? superseded[key] {
                    return staged
                }
                return store.lookupIngestion(matching: key)
            }
        }

        func ingestionEntries(state: ASCIngestionState?) async throws -> [ASCIngestionEntry] {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
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
        }

        func markSuperseded(keys: [ASCIngestionKey], by: ASCIngestionKey) async throws {
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
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
        }

        func insertSales(
            _ records: [ASCProvenancedRecord<ASCSalesRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            withLock {
                sales[ingestionKey, default: []].append(contentsOf: records)
            }
        }

        func insertDownloads(
            _ records: [ASCProvenancedRecord<ASCDownloadRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            withLock {
                downloads[ingestionKey, default: []].append(contentsOf: records)
            }
        }

        func insertDiscovery(
            _ records: [ASCProvenancedRecord<ASCDiscoveryRecord>],
            ingestionKey: ASCIngestionKey
        ) async throws {
            withLock {
                discovery[ingestionKey, default: []].append(contentsOf: records)
            }
        }

        func salesRecords(
            appAppleIdentifiers: Set<String>?,
            parentIdentifiers: Set<String>?,
            in range: ASCDateRange?,
            scope: ASCIngestionQueryScope
        ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>] {
            // A transaction's queries see committed state only: staged
            // mutations are invisible until commit.
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
            }
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
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
            }
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
            try withLock {
                guard !committed, !rolledBack else {
                    throw ASCAnalyticsError.storeInconsistentState(
                        reason: "transaction already finished"
                    )
                }
            }
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
        transactionActive = false
    }

    /// Aborts an active transaction without touching committed state; used
    /// when a caller drops a transaction. Not part of the public protocol.
    func discardTransaction() {
        lock.lock()
        defer { lock.unlock() }
        transactionActive = false
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
                if let identifiers = appAppleIdentifiers {
                    guard case .appleIdentifier(let id) = record.appAttribution,
                          identifiers.contains(id)
                    else { continue }
                }
                if let parents = parentIdentifiers {
                    guard case .parentIdentifierSKU(let sku) = record.appAttribution,
                          parents.contains(sku)
                    else { continue }
                }
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
    /// the lookup must be equal; nil lookup fields match anything. A
    /// lookup `sourceKind` of `.unknown` acts as a wildcard, because the
    /// sync engine looks up analytics ingestions by instance identity
    /// before parsing determines the report family.
    func matches(_ lookup: ASCIngestionKey) -> Bool {
        if lookup.sourceKind != .unknown && lookup.sourceKind != sourceKind { return false }
        if let instanceID = lookup.instanceID, instanceID != self.instanceID { return false }
        if let vendorNumber = lookup.vendorNumber, vendorNumber != self.vendorNumber { return false }
        if let reportDate = lookup.reportDate, reportDate != self.reportDate { return false }
        if let reportVersion = lookup.reportVersion, reportVersion != self.reportVersion { return false }
        if let deliveryID = lookup.deliveryID, deliveryID != self.deliveryID { return false }
        return true
    }
}
