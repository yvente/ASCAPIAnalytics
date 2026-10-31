import Foundation

/// Thread-safe, fully in-memory `ASCAnalyticsStore`.
///
/// This is the reference implementation for offline use, tests, and
/// previews. It enforces the full transaction contract: mutations are
/// staged inside the transaction, become visible to readers only on
/// `commit`, and are completely discarded on `rollback`.
///
/// ## Transaction scheduling
///
/// At most **one** unfinished transaction is active per store. Additional
/// `beginTransaction` calls **wait asynchronously in FIFO order** for the
/// slot instead of failing — no retry loops are needed by callers. The
/// scheduling guarantees are:
///
/// - **FIFO, no starvation**: the slot is handed to the longest-waiting
///   non-cancelled waiter.
/// - **Cancellation-safe**: a waiter whose task is cancelled while queued
///   is removed from the grant order and ends with `CancellationError`;
///   the slot is never lost and never double-granted. Cancellation and
///   grant are serialized through the waiter's own lock.
/// - **Abandoned transactions cannot stall the store forever**: the active
///   transaction is held weakly; when the owner drops an unfinished
///   transaction, the next queued (or newly arriving) begin reclaims the
///   slot. A transaction deliberately parked forever by a live task still
///   blocks the slot — that is ordinary mutex semantics — but a *dropped*
///   one never does.
/// - **Error propagation**: `commit`/`rollback` misuse and use-after-finish
///   raise `ASCAnalyticsError.storeInconsistentState`, which now only ever
///   describes a real programming error — never transient contention.
public final class ASCInMemoryAnalyticsStore: ASCAnalyticsStore, @unchecked Sendable {
    private let lock = NSLock()
    /// Weak reference to the live transaction. When the caller drops an
    /// unfinished transaction, the object deallocates, this becomes `nil`,
    /// and the next queued (or new) begin reclaims the slot.
    private weak var activeTransaction: Transaction?
    /// Whether the single write slot is currently taken.
    private var slotOccupied = false
    /// FIFO queue of tasks waiting for the slot.
    private var waiters: [SlotRequest] = []

    // Committed state.
    private var ingestions: [ASCIngestionKey: ASCIngestionEntry] = [:]
    private var salesByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCSalesRecord>]] = [:]
    private var downloadsByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCDownloadRecord>]] = [:]
    private var discoveryByIngestion: [ASCIngestionKey: [ASCProvenancedRecord<ASCDiscoveryRecord>]] = [:]

    public init() {}

    // MARK: - Slot acquisition (FIFO, cancellation-safe)

    /// Suspends until the single write slot is granted to `bound`, or
    /// returns `false` when the waiting task is cancelled first. The
    /// transaction is bound to the slot **atomically under the store
    /// lock**, so no window exists in which a second begin could mistake
    /// the slot for abandoned and double-grant it.
    private func acquireSlot(bound: Transaction) async -> Bool {
        // Fast cancellation check before enqueueing.
        if Task.isCancelled { return false }

        let request = SlotRequest(bound: bound)
        let grantedImmediately: Bool = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                // Synchronous registration under the store lock. Resumes
                // happen strictly outside this lock.
                let acquiredNow: Bool = lock.withLock {
                    if slotIsEffectivelyFree() {
                        slotOccupied = true
                        activeTransaction = bound
                        if let hook = onBeginScheduled { hook(0) }
                        return true
                    }
                    waiters.append(request)
                    if let hook = onBeginScheduled { hook(waiters.count) }
                    return false
                }
                let resumeNow = request.register(
                    continuation, acquiredImmediately: acquiredNow
                )
                if resumeNow {
                    continuation.resume(returning: !request.wasCancelled)
                }
            }
        } onCancel: {
            // Marks the request cancelled and resumes it (outside any
            // store lock) if it was queued. Does not touch the store's
            // lock, so no lock-ordering deadlock is possible.
            request.cancel()
        }
        return grantedImmediately || request.wasGranted
    }

    /// Whether the write slot can be granted right now: either free, or
    /// held by a transaction object that no longer exists (dropped by its
    /// owner) or has already finished (commit/rollback released the slot
    /// but the caller kept the reference).
    private func slotIsEffectivelyFree() -> Bool {
        guard slotOccupied else { return true }
        guard let current = activeTransaction else { return true } // abandoned
        return current.isFinished
    }

    /// Releases the slot and hands it to the longest-waiting
    /// non-cancelled waiter (FIFO, no starvation). Called on commit and
    /// rollback.
    fileprivate func releaseSlotAndGrantNext() {
        let resumeList: [(CheckedContinuation<Bool, Never>, Bool)] = lock.withLock {
            var resumes: [(CheckedContinuation<Bool, Never>, Bool)] = []
            slotOccupied = false
            activeTransaction = nil
            while !waiters.isEmpty {
                let next = waiters.removeFirst()
                if let continuation = next.grantIfWaiting() {
                    slotOccupied = true
                    activeTransaction = next.bound
                    resumes.append((continuation, true))
                    break
                }
                // Cancelled waiter: drop it and keep granting.
            }
            return resumes
        }
        // Resume strictly outside the store lock.
        for (continuation, value) in resumeList {
            continuation.resume(returning: value)
        }
    }

    /// Number of tasks currently queued for the slot (test visibility).
    var queuedWaiterCount: Int {
        lock.withLock { waiters.count }
    }

    /// Test instrumentation: invoked synchronously when a begin either
    /// queues (argument = queue depth after enqueue) or acquires the slot
    /// immediately (argument = 0). Tests use it to observe enqueue order
    /// without polling. Never set in production.
    var onBeginScheduled: ((Int) -> Void)?

    // MARK: - ASCAnalyticsStore

    public func beginTransaction() async throws -> any ASCAnalyticsStoreTransaction {
        // Fast cancellation check before enqueueing.
        try Task.checkCancellation()
        let transaction = Transaction(store: self)
        let granted = await acquireSlot(bound: transaction)
        guard granted else {
            // The waiting task was cancelled: never acquired, nothing to
            // release.
            throw CancellationError()
        }
        return transaction
    }

    /// Clears the active-transaction reference when the given transaction
    /// finishes (commit or rollback) and hands the slot to the next
    /// waiter.
    fileprivate func transactionDidFinish(_ transaction: Transaction) {
        lock.withLock {
            if activeTransaction === transaction {
                activeTransaction = nil
            }
        }
        releaseSlotAndGrantNext()
    }

    // MARK: - Slot request (single-resume invariant)

    /// One task's request for the write slot. The phase state machine
    /// guarantees the continuation is resumed exactly once, and that
    /// cancellation racing with a grant cannot lose the slot or double
    /// resume.
    private final class SlotRequest: @unchecked Sendable {
        /// The transaction this request will bind to the slot on grant.
        /// Strong here: a queued request keeps its transaction alive until
        /// it becomes the active one.
        fileprivate let bound: Transaction
        private let stateLock = NSLock()
        private enum Phase {
            case idle
            case queued(CheckedContinuation<Bool, Never>)
            case granted
            case cancelled
        }
        private var phase: Phase = .idle

        fileprivate init(bound: Transaction) {
            self.bound = bound
        }

        /// Registers the continuation. Returns `true` when the caller must
        /// resume it immediately (already granted or already cancelled);
        /// `false` when the request is now queued and the continuation
        /// will be resumed by `grantIfWaiting`/`cancel`.
        func register(
            _ continuation: CheckedContinuation<Bool, Never>,
            acquiredImmediately: Bool
        ) -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            if acquiredImmediately {
                phase = .granted
                return true
            }
            switch phase {
            case .idle:
                phase = .queued(continuation)
                return false
            case .cancelled:
                return true // resume with cancelled
            case .granted, .queued:
                // Unreachable: register runs exactly once per request.
                return true
            }
        }

        /// Cancellation callback. Marks the request cancelled and, if it
        /// was queued, hands the continuation back for a resume with
        /// `false`.
        func cancel() {
            stateLock.lock()
            let continuation: CheckedContinuation<Bool, Never>?
            switch phase {
            case .queued(let cont):
                phase = .cancelled
                continuation = cont
            case .idle:
                phase = .cancelled
                continuation = nil
            case .granted:
                // The transaction was already granted; the owner is
                // responsible for finishing it. Cancellation arriving here
                // must not release the slot for anyone else.
                continuation = nil
            case .cancelled:
                continuation = nil
            }
            stateLock.unlock()
            continuation?.resume(returning: false)
        }

        /// Called by the releaser (holding the store lock). Returns the
        /// continuation to resume with `true`, or `nil` when the request
        /// was cancelled and must be skipped.
        func grantIfWaiting() -> CheckedContinuation<Bool, Never>? {
            stateLock.lock()
            defer { stateLock.unlock() }
            switch phase {
            case .queued(let cont):
                phase = .granted
                return cont
            case .cancelled, .granted, .idle:
                return nil
            }
        }

        var wasCancelled: Bool {
            stateLock.withLock {
                if case .cancelled = phase { return true }
                return false
            }
        }

        var wasGranted: Bool {
            stateLock.withLock {
                if case .granted = phase { return true }
                return false
            }
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
            salesReportKinds: Set<String>?,
            in range: ASCDateRange?,
            scope: ASCIngestionQueryScope
        ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>] {
            // A transaction's queries see committed state only: staged
            // mutations are invisible until commit.
            try ensureActive()
            return try await store.salesRecords(
                appAppleIdentifiers: appAppleIdentifiers,
                parentIdentifiers: parentIdentifiers,
                salesReportKinds: salesReportKinds,
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
        salesReportKinds: Set<String>? = nil,
        in range: ASCDateRange? = nil,
        scope: ASCIngestionQueryScope = .current
    ) async throws -> [ASCProvenancedRecord<ASCSalesRecord>] {
        querySalesLocked(
            appAppleIdentifiers: appAppleIdentifiers,
            parentIdentifiers: parentIdentifiers,
            salesReportKinds: salesReportKinds,
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
        salesReportKinds: Set<String>?,
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
                if let salesReportKinds {
                    guard let kind = entry.provenance.salesReportKind,
                          salesReportKinds.contains(kind)
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
