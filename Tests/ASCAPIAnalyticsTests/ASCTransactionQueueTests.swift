import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// Deterministic concurrency tests for the `ASCInMemoryAnalyticsStore`
/// FIFO transaction queue: fairness, no starvation, cancellation safety,
/// error propagation, and write visibility. All tests are offline and use
/// continuation-based signals — no sleeps, no scheduler luck.
final class ASCTransactionQueueTests: XCTestCase {
    private var store: ASCInMemoryAnalyticsStore!

    override func setUp() {
        super.setUp()
        store = ASCInMemoryAnalyticsStore()
    }

    override func tearDown() {
        store.onBeginScheduled = nil
        store = nil
        super.tearDown()
    }

    /// A latch that releases every waiting task at once.
    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var continuations: [CheckedContinuation<Void, Never>] = []

        private func register(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if opened { return true }
            continuations.append(continuation)
            return false
        }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if register(continuation) {
                    continuation.resume()
                }
            }
        }

        func open() {
            let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
                opened = true
                let waiting = continuations
                continuations = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }
    }

    // MARK: 1 + 2. High concurrency: every task succeeds, no starvation

    func testHundredTwentyEightConcurrentTransactionsAllSucceed() async throws {
        // 128 tasks queue for one slot; every one of them must acquire,
        // commit, and have its write visible. No fixed retry cap exists in
        // the design, so none can fail.
        let tasks = 128
        let group = DispatchGroup() // unused placeholder to keep shape clear
        _ = group

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<tasks {
                group.addTask {
                    let tx = try await self.store.beginTransaction()
                    let record = ASCProvenancedRecord(
                        record: Self.downloadRecord(tag: index),
                        provenance: Self.provenance(tag: index)
                    )
                    let key = ASCIngestionKey(
                        sourceKind: .analyticsDownloads,
                        instanceID: "inst-\(index)"
                    )
                    try await tx.insertDownloads([record], ingestionKey: key)
                    try await tx.upsertIngestion(ASCIngestionEntry(
                        key: key, state: .imported,
                        schemaFingerprint: "fp-\(index)",
                        contentChecksum: "cc-\(index)",
                        recordCount: 1,
                        importedAt: Date()
                    ))
                    try await tx.commit()
                }
            }
            try await group.waitForAll()
        }

        let records = try await store.downloadRecords(scope: .all)
        XCTAssertEqual(records.count, tasks, "every concurrent transaction's write must be visible")
        XCTAssertEqual(Set(records.map { $0.provenance.contentChecksum }).count, tasks)
    }

    // MARK: 3. FIFO fairness

    func testGrantOrderFollowsEnqueueOrderExactly() async throws {
        // Deterministic FIFO proof: the onBeginScheduled hook fires
        // synchronously under the store lock when a begin queues, so the
        // test observes the exact enqueue order without polling.
        let holder = try await store.beginTransaction() // occupies the slot

        let queueDepthStream = AsyncStream<Int> { continuation in
            store.onBeginScheduled = { depth in
                continuation.yield(depth)
            }
        }
        var depthIterator = queueDepthStream.makeAsyncIterator()

        let waiters = 8
        var tasks: [Task<Void, Error>] = []
        var acquiredOrder: [Int] = []
        let orderLock = NSLock()

        for index in 0..<waiters {
            tasks.append(Task {
                let tx = try await store.beginTransaction()
                orderLock.lock()
                acquiredOrder.append(index)
                orderLock.unlock()
                try await tx.rollback()
            })
            // Deterministically wait until THIS waiter is enqueued before
            // starting the next one.
            let depth = await depthIterator.next()
            XCTAssertEqual(depth, index + 1, "waiter \(index) must be enqueued in launch order")
        }

        store.onBeginScheduled = nil
        try await holder.commit() // release → grants in enqueue order
        for task in tasks {
            try await task.value
        }

        XCTAssertEqual(acquiredOrder, Array(0..<waiters), "grant order must equal enqueue order (FIFO, no starvation)")
    }

    // MARK: 4. Simultaneous commits never lose writes

    func testSimultaneousCommitsDoNotLoseWrites() async throws {
        let writes = 64
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writes {
                group.addTask {
                    let tx = try await self.store.beginTransaction()
                    let record = ASCProvenancedRecord(
                        record: Self.downloadRecord(tag: 1_000 + index),
                        provenance: Self.provenance(tag: 1_000 + index)
                    )
                    let key = ASCIngestionKey(
                        sourceKind: .analyticsDownloads,
                        instanceID: "inst-commit-\(index)"
                    )
                    try await tx.insertDownloads([record], ingestionKey: key)
                    try await tx.upsertIngestion(ASCIngestionEntry(
                        key: key, state: .imported,
                        schemaFingerprint: "fp",
                        contentChecksum: "cc-\(index)",
                        recordCount: 1,
                        importedAt: Date()
                    ))
                    try await tx.commit()
                }
            }
            try await group.waitForAll()
        }
        let records = try await store.downloadRecords(scope: .all)
        XCTAssertEqual(records.count, writes, "no write lost under concurrent commits")
    }

    // MARK: 5. Waiter cancellation keeps the queue working

    func testCancelledWaitersAreSkippedAndQueueContinues() async throws {
        let holder = try await store.beginTransaction()

        // Arm the observation hook BEFORE starting the waiter: the hook
        // fires synchronously when the waiter's begin enqueues.
        let enqueueStream = AsyncStream<Void> { continuation in
            store.onBeginScheduled = { _ in continuation.yield() }
        }
        var enqueueIterator = enqueueStream.makeAsyncIterator()

        let cancellable = Task {
            do {
                let tx = try await store.beginTransaction()
                // Unexpected grant: finish cleanly to avoid blocking.
                try await tx.rollback()
                XCTFail("a cancelled waiter must never acquire the slot")
            } catch is CancellationError {
                // Expected when cancelled while queued.
            }
        }
        // Deterministically observe the waiter's enqueue.
        _ = await enqueueIterator.next()
        store.onBeginScheduled = nil

        cancellable.cancel()

        let good = Task {
            let tx = try await store.beginTransaction()
            try await tx.rollback()
        }
        try await holder.rollback()
        _ = try await good.value // must not hang: the cancelled waiter is skipped
        _ = try await cancellable.value
    }

    // MARK: 6. Rollback hands the slot to waiting transactions

    func testRollbackHandsSlotToNextWaiter() async throws {
        let holder = try await store.beginTransaction()
        let granted = expectation(description: "waiter granted after rollback")

        let waiter = Task {
            let tx = try await store.beginTransaction()
            granted.fulfill()
            try await tx.commit()
        }
        try await holder.rollback()
        await fulfillment(of: [granted], timeout: 10)
        try await waiter.value
    }

    // MARK: 7. Cancellation racing with grant never deadlocks

    func testCancellationRacingGrantDoesNotDeadlockOrLeakSlot() async throws {
        // Hammer begin/cancel rounds: some tasks cancel before acquiring,
        // some after; afterwards the slot must be intact for a plain
        // begin/commit.
        let rounds = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<rounds {
                group.addTask {
                    let tx = try await self.store.beginTransaction()
                    if index % 2 == 0 {
                        try await tx.rollback()
                    } else {
                        try await tx.commit()
                    }
                }
                // Cancel a fresh task in the same round: it either gets a
                // cancelled fast path or is skipped in the queue.
                let doomed = Task {
                    _ = try await self.store.beginTransaction()
                    XCTFail("a cancelled waiter must never acquire the slot")
                }
                doomed.cancel()
                _ = await doomed.result
            }
            try await group.waitForAll()
        }
        try await store.withTransaction { _ in }
    }

    // MARK: 8. Real consistency errors propagate untouched

    func testStoreInconsistentStatePropagatesWithoutSwallowing() async throws {
        let tx = try await store.beginTransaction()
        try await tx.commit()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await tx.commit()
                    XCTFail("expected the real consistency error to propagate")
                } catch let error as ASCAnalyticsError {
                    guard case .storeInconsistentState = error else {
                        XCTFail("expected storeInconsistentState, got \\(error)")
                        return
                    }
                } catch {
                    XCTFail("unexpected error type \\(error)")
                }
            }
            try await group.waitForAll()
        }
    }

    // MARK: 12. The store stays usable after a failed transaction

    func testStoreUsableAfterFailedTransaction() async throws {
        struct Boom: Error {}
        do {
            try await store.withTransaction { (_: any ASCAnalyticsStoreTransaction) in
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch {}
        try await store.withTransaction { _ in }
        let tx = try await store.beginTransaction()
        try await tx.commit()
    }

    // MARK: Abandoned (dropped) transactions cannot stall new begins

    func testDroppedUnfinishedTransactionIsReclaimedByNextBegin() async throws {
        do {
            _ = try await store.beginTransaction() // dropped, never finished
        }
        // The transaction object is deallocated; the next begin must
        // reclaim the slot instead of waiting forever.
        let tx = try await store.beginTransaction()
        try await tx.commit()
    }

    func testFinishedButRetainedTransactionDoesNotBlockNewBegins() async throws {
        let finished = try await store.beginTransaction()
        try await finished.commit()
        // The caller keeps the (finished) reference: the slot must still
        // be grantable.
        let next = try await store.beginTransaction()
        try await next.rollback()
    }

    // MARK: Fixtures

    private static func downloadRecord(tag: Int) -> ASCDownloadRecord {
        ASCDownloadRecord(
            date: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            appAppleIdentifier: "1001",
            rawDownloadType: "First-time Download",
            downloadType: .firstTimeDownload,
            territory: "US",
            counts: tag,
            isPreOrder: nil,
            extraFields: [:]
        )
    }

    private static func provenance(tag: Int) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: .analyticsDownloads,
            instanceID: "inst-\(tag)",
            processingDate: "2025-10-02",
            granularity: .daily,
            schemaFingerprint: "fp-\(tag)",
            contentChecksum: "cc-\(tag)",
            fetchedAt: Date(),
            recordCount: 1
        )
    }
}
