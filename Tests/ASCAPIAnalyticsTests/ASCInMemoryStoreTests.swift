import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCInMemoryStoreTests: XCTestCase {
    private var store: ASCInMemoryAnalyticsStore!

    override func setUp() {
        super.setUp()
        store = ASCInMemoryAnalyticsStore()
    }

    private func makeSalesRecord(units: Decimal, app: String = "1001") -> ASCSalesRecord {
        ASCSalesRecord(
            beginDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            endDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            appleIdentifier: app,
            sku: "SKU1",
            parentIdentifier: nil,
            rawProductType: "1F",
            productType: .app,
            units: units,
            customerPrice: 0.99,
            customerCurrency: "USD",
            developerProceeds: 0.70,
            proceedsCurrency: "USD",
            countryCode: "US",
            cmb: .none,
            extraFields: [:]
        )
    }

    private func makeProvenance(checksum: String) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: .summarySales,
            vendorNumber: "80000",
            reportDate: "2025-10-01",
            reportVersion: "1",
            schemaFingerprint: "fp",
            contentChecksum: checksum,
            fetchedAt: Date(),
            recordCount: 1
        )
    }

    private func makeKey(version: String) -> ASCIngestionKey {
        ASCIngestionKey(
            sourceKind: .summarySales,
            vendorNumber: "80000",
            reportDate: "2025-10-01",
            reportVersion: version
        )
    }

    func testCommitMakesRecordsVisible() async throws {
        let key = makeKey(version: "1")
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [ASCProvenancedRecord(record: self.makeSalesRecord(units: 5), provenance: self.makeProvenance(checksum: "a"))],
                ingestionKey: key
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key,
                state: .imported,
                schemaFingerprint: "fp",
                contentChecksum: "a",
                recordCount: 1,
                importedAt: Date()
            ))
        }
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].record.units, 5)
    }

    func testRollbackDiscardsEverything() async throws {
        let transaction = try await store.beginTransaction()
        try await transaction.insertSales(
            [ASCProvenancedRecord(record: makeSalesRecord(units: 5), provenance: makeProvenance(checksum: "a"))],
            ingestionKey: makeKey(version: "1")
        )
        try await transaction.rollback()

        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 0)
    }

    func testFailureInsideWithTransactionRollsBackAtomically() async {
        struct Boom: Error {}
        let key = makeKey(version: "1")
        do {
            try await store.withTransaction { transaction in
                try await transaction.insertSales(
                    [ASCProvenancedRecord(record: self.makeSalesRecord(units: 5), provenance: self.makeProvenance(checksum: "a"))],
                    ingestionKey: key
                )
                // Simulate a verification failure after the insert: the
                // whole transaction must roll back.
                throw Boom()
            }
            XCTFail("expected Boom to propagate")
        } catch {
            // Expected.
        }

        let records = (try? await store.salesRecords()) ?? []
        XCTAssertEqual(records.count, 0, "partial writes must not survive a failed transaction")
    }

    func testStagedDataIsInvisibleUntilCommit() async throws {
        let key = makeKey(version: "1")
        let transaction = try await store.beginTransaction()
        try await transaction.insertSales(
            [ASCProvenancedRecord(record: makeSalesRecord(units: 7), provenance: makeProvenance(checksum: "a"))],
            ingestionKey: key
        )
        try await transaction.upsertIngestion(ASCIngestionEntry(
            key: key, state: .imported,
            schemaFingerprint: "fp", contentChecksum: "a",
            recordCount: 1, importedAt: Date()
        ))
        // Committed-state queries do not see staged data.
        let before = try await transaction.salesRecords(
            appAppleIdentifiers: nil, parentIdentifiers: nil, in: nil, scope: .current
        )
        XCTAssertEqual(before.count, 0)
        try await transaction.commit()
        let after = try await store.salesRecords()
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].record.units, 7)
    }

    func testConcurrentTransactionQueuesInsteadOfFailing() async throws {
        // The second beginTransaction waits FIFO for the slot instead of
        // failing with a contention error; it proceeds as soon as the
        // first transaction finishes, whichever way it finishes.
        let active = try await store.beginTransaction()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let queued = try await self.store.beginTransaction()
                try await queued.rollback()
            }
            // Roll the first transaction back: the queued begin resumes
            // and completes either way (queued-before or begun-after).
            try await active.rollback()
            try await group.waitForAll()
        }

        // The store stays fully usable afterwards.
        try await store.withTransaction { _ in }
    }

    func testWaiterCancellationReleasesQueueSlot() async throws {
        // A cancelled waiter is skipped in the grant order; the next
        // waiter proceeds and the slot is never lost.
        let active = try await store.beginTransaction()

        let waiterCancelled = expectation(description: "waiter cancelled")
        let waiterStarted = expectation(description: "waiter started")
        let secondDone = expectation(description: "second waiter finished")

        let waiterTask = Task {
            await waiterStarted.fulfill()
            do {
                let tx = try await store.beginTransaction()
                // Unexpected grant: finish cleanly.
                try await tx.rollback()
                await waiterCancelled.fulfill()
            } catch is CancellationError {
                await waiterCancelled.fulfill()
            } catch {
                XCTFail("unexpected error \(error)")
            }
            await secondDone.fulfill()
        }
        await fulfillment(of: [waiterStarted], timeout: 10)
        waiterTask.cancel()

        // Rollback releases the slot; the cancelled waiter is skipped, so
        // this third transaction is granted directly.
        try await active.rollback()
        let third = try await store.beginTransaction()
        try await third.commit()
        await fulfillment(of: [waiterCancelled, secondDone], timeout: 10)
    }

    func testConsistencyErrorPropagatesFromTransaction() async throws {
        // Misusing a transaction (commit twice) surfaces the real
        // consistency error — it is never swallowed as contention.
        let tx = try await store.beginTransaction()
        try await tx.commit()
        do {
            try await tx.commit()
            XCTFail("expected storeInconsistentState")
        } catch let error as ASCAnalyticsError {
            guard case .storeInconsistentState = error else {
                return XCTFail("expected storeInconsistentState, got \(error)")
            }
        }
        // The store remains usable.
        try await store.withTransaction { _ in }
    }

    func testDroppedTransactionReleasesSlotForLaterSyncs() async throws {
        // Simulates cancellation: a transaction is begun and then simply
        // dropped without commit or rollback. The slot must be released
        // when the object deallocates — later syncs must never see a
        // permanent "another transaction is already active".
        do {
            _ = try await store.beginTransaction()
        }
        // `tx` went out of scope above.
        let next = try await store.beginTransaction()
        try await next.rollback()

        try await store.withTransaction { _ in }
    }

    func testSupersededRecordsExcludedByDefaultIncludedInAuditScope() async throws {
        let key1 = makeKey(version: "1")
        let key2 = makeKey(version: "2")
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [ASCProvenancedRecord(record: self.makeSalesRecord(units: 1), provenance: self.makeProvenance(checksum: "v1"))],
                ingestionKey: key1
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key1, state: .imported,
                schemaFingerprint: "fp", contentChecksum: "v1",
                recordCount: 1, importedAt: Date()
            ))
        }
        // A corrected version arrives: supersede version 1 atomically.
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [ASCProvenancedRecord(record: self.makeSalesRecord(units: 2), provenance: self.makeProvenance(checksum: "v2"))],
                ingestionKey: key2
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key2, state: .imported,
                schemaFingerprint: "fp", contentChecksum: "v2",
                recordCount: 1, importedAt: Date()
            ))
            try await transaction.markSuperseded(keys: [key1], by: key2)
        }

        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 2)

        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2, "superseded data stays queryable for audit")

        let entries = try await store.beginTransaction().ingestionEntries(state: .superseded)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].supersededBy, key2)
    }

    func testPendingReviewRecordsExcludedFromCurrentScope() async throws {
        let key = makeKey(version: "1")
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [ASCProvenancedRecord(record: makeSalesRecord(units: 3), provenance: makeProvenance(checksum: "a"))],
                ingestionKey: key
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key, state: .pendingReview,
                schemaFingerprint: "fp", contentChecksum: "a",
                recordCount: 1, importedAt: Date(),
                pendingReason: "semantics unproven"
            ))
        }
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 0, "pending-review data must never be counted")
        let all = try await store.salesRecords(scope: .all)
        XCTAssertEqual(all.count, 1, "pending-review data is retained for review")
    }

    func testPaidAppAndItsIAPRetrievableTogetherWithoutCrossAppLeakage() async throws {
        // One paid app's direct sales plus its own IAP must be retrievable
        // with a single query naming both identities — and another app's
        // IAP must never leak in.
        func record(app: String, parent: String?, productType: String, units: Decimal) -> ASCSalesRecord {
            ASCSalesRecord(
                beginDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                endDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                appleIdentifier: app,
                sku: productType == "1F" ? "APP-\(app)" : "IAP-\(app)",
                parentIdentifier: parent,
                rawProductType: productType,
                productType: ASCSalesProductType.classify(productType),
                units: units,
                customerPrice: 0.99,
                customerCurrency: "USD",
                developerProceeds: 0.70,
                proceedsCurrency: "USD",
                countryCode: "US",
                cmb: .none,
                extraFields: [:]
            )
        }

        let paidAppRow = record(app: "1001", parent: nil, productType: "1F", units: 10)
        let ownIAPRow = record(app: "8888", parent: "com.example.app", productType: "IA1", units: 4)
        let otherIAPRow = record(app: "9999", parent: "com.other.app", productType: "IA1", units: 7)

        let key = makeKey(version: "1")
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [paidAppRow, ownIAPRow, otherIAPRow].map {
                    ASCProvenancedRecord(record: $0, provenance: self.makeProvenance(checksum: "a"))
                },
                ingestionKey: key
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key, state: .imported,
                schemaFingerprint: "fp", contentChecksum: "a",
                recordCount: 3, importedAt: Date()
            ))
        }

        // Store query with both identity sets: direct sales + own IAP.
        let together = try await store.salesRecords(
            appAppleIdentifiers: ["1001"],
            parentIdentifiers: ["com.example.app"]
        )
        XCTAssertEqual(together.count, 2)
        XCTAssertEqual(Set(together.map(\.record.units)), [10, 4])
        XCTAssertFalse(together.contains { $0.record.units == 7 }, "the other app's IAP must not leak")

        // The same semantics through ASCSalesFilter.
        let filtered = ASCSalesFilter(
            appAppleIdentifiers: ["1001"],
            parentIdentifiers: ["com.example.app"]
        ).apply([paidAppRow, ownIAPRow, otherIAPRow])
        XCTAssertEqual(filtered.count, 2)

        // Parent SKU alone: only the matching IAP row.
        let parentsOnly = try await store.salesRecords(parentIdentifiers: ["com.example.app"])
        XCTAssertEqual(parentsOnly.count, 1)
        XCTAssertEqual(parentsOnly[0].record.units, 4)

        // Apple identifier alone: only the direct row (IAP rows live in
        // the parent-SKU namespace).
        let directOnly = try await store.salesRecords(appAppleIdentifiers: ["1001"])
        XCTAssertEqual(directOnly.count, 1)
        XCTAssertEqual(directOnly[0].record.units, 10)

        // The other app's IAP stays isolated.
        let otherOnly = try await store.salesRecords(parentIdentifiers: ["com.other.app"])
        XCTAssertEqual(otherOnly.count, 1)
        XCTAssertEqual(otherOnly[0].record.units, 7)
    }

    // MARK: - Ownership atomicity (installed from architecture review)

    func testAbandonedOwnerWakesExistingWaiter() async throws {
        let localStore = ASCInMemoryAnalyticsStore()

        var active: (any ASCAnalyticsStoreTransaction)?
            = try await localStore.beginTransaction()

        let queued = expectation(
            description: "waiting transaction queued"
        )

        localStore.onBeginScheduled = { depth in
            if depth == 1 {
                queued.fulfill()
            }
        }

        let waiter = Task {
            let tx = try await localStore.beginTransaction()
            try await tx.rollback()
            return true
        }

        await fulfillment(of: [queued], timeout: 10)

        // A is dropped without an explicit commit or rollback.
        active = nil

        let completed = try await waiter.value

        XCTAssertTrue(completed)

        // Confirm the store remains usable.
        try await localStore.withTransaction { _ in }
    }

    func testQueuedTransactionSeesCompletedCommit()
        async throws {

        let localStore = ASCInMemoryAnalyticsStore()

        let key = ASCIngestionKey(
            sourceKind: .summarySales,
            vendorNumber: "80000",
            reportDate: "2025-10-01",
            reportVersion: "1"
        )

        let active = try await localStore.beginTransaction()

        try await active.upsertIngestion(
            ASCIngestionEntry(
                key: key,
                state: .imported,
                schemaFingerprint: "test-schema",
                contentChecksum: "committed",
                recordCount: 0,
                importedAt: Date()
            )
        )

        let queued = expectation(
            description: "reader queued behind writer"
        )

        localStore.onBeginScheduled = { depth in
            if depth == 1 {
                queued.fulfill()
            }
        }

        let reader = Task {
            let tx = try await localStore.beginTransaction()
            let entry = try await tx.ingestion(matching: key)
            try await tx.rollback()
            return entry
        }

        await fulfillment(of: [queued], timeout: 10)

        try await active.commit()

        let entry = try await reader.value

        XCTAssertEqual(entry?.contentChecksum, "committed")
    }

    func testFinishedOldOwnerCannotReleaseNewOwner()
        async throws {

        let localStore = ASCInMemoryAnalyticsStore()

        let first = try await localStore.beginTransaction()

        let secondQueued = expectation(
            description: "second transaction queued"
        )

        localStore.onBeginScheduled = { depth in
            if depth == 1 {
                secondQueued.fulfill()
            }
        }

        let secondTask = Task {
            try await localStore.beginTransaction()
        }

        await fulfillment(
            of: [secondQueued],
            timeout: 10
        )

        try await first.commit()

        let second = try await secondTask.value

        // A double-finish must fail without changing ownership.
        do {
            try await first.rollback()
            XCTFail("old owner must not finish again")
        } catch let error as ASCAnalyticsError {
            guard case .storeInconsistentState = error else {
                XCTFail("unexpected error: \(error)")
                return
            }
        }

        let thirdQueued = expectation(
            description: "third transaction queued"
        )

        localStore.onBeginScheduled = { depth in
            if depth == 1 {
                thirdQueued.fulfill()
            }
        }

        let thirdTask = Task {
            try await localStore.beginTransaction()
        }

        await fulfillment(
            of: [thirdQueued],
            timeout: 10
        )

        // The third task remains queued until the actual
        // current owner, second, releases its slot.
        try await second.rollback()

        let third = try await thirdTask.value
        try await third.rollback()
    }

    func testAbandonmentPreservesFIFOOrder() async throws {
        let localStore = ASCInMemoryAnalyticsStore()
        let recorder = ASCTransactionOrderRecorder()

        var first: (any ASCAnalyticsStoreTransaction)?
            = try await localStore.beginTransaction()

        let secondQueued = expectation(
            description: "second queued"
        )
        let thirdQueued = expectation(
            description: "third queued"
        )

        localStore.onBeginScheduled = { depth in
            if depth == 1 {
                secondQueued.fulfill()
            }
            if depth == 2 {
                thirdQueued.fulfill()
            }
        }

        let secondTask = Task {
            let tx = try await localStore.beginTransaction()
            await recorder.record(2)
            try await tx.rollback()
        }

        await fulfillment(
            of: [secondQueued],
            timeout: 10
        )

        let thirdTask = Task {
            let tx = try await localStore.beginTransaction()
            await recorder.record(3)
            try await tx.rollback()
        }

        await fulfillment(
            of: [thirdQueued],
            timeout: 10
        )

        // Releases ownership through deinit, not an explicit rollback.
        first = nil

        try await secondTask.value
        try await thirdTask.value

        let order = await recorder.snapshot()

        XCTAssertEqual(order, [2, 3])
    }

    func testDateAndAppQueries() async throws {
        let key = makeKey(version: "1")
        var october = makeSalesRecord(units: 1)
        october = ASCSalesRecord(
            beginDate: ASCCalendarDate(iso8601Day: "2025-10-05")!,
            endDate: ASCCalendarDate(iso8601Day: "2025-10-05")!,
            appleIdentifier: "1001",
            sku: "SKU1",
            parentIdentifier: nil,
            rawProductType: "1F",
            productType: .app,
            units: 1,
            customerPrice: 0.99,
            customerCurrency: "USD",
            developerProceeds: 0.70,
            proceedsCurrency: "USD",
            countryCode: "US",
            cmb: .none,
            extraFields: [:]
        )
        try await store.withTransaction { transaction in
            try await transaction.insertSales(
                [ASCProvenancedRecord(record: october, provenance: self.makeProvenance(checksum: "a"))],
                ingestionKey: key
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key, state: .imported,
                schemaFingerprint: "fp", contentChecksum: "a",
                recordCount: 1, importedAt: Date()
            ))
        }
        let inRange = try await store.salesRecords(
            in: ASCDateRange(start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                             end: ASCCalendarDate(iso8601Day: "2025-10-31")!)
        )
        XCTAssertEqual(inRange.count, 1)
        let outOfRange = try await store.salesRecords(
            in: ASCDateRange(start: ASCCalendarDate(iso8601Day: "2025-11-01")!,
                             end: ASCCalendarDate(iso8601Day: "2025-11-30")!)
        )
        XCTAssertEqual(outOfRange.count, 0)
        let byApp = try await store.salesRecords(appAppleIdentifiers: ["1001"])
        XCTAssertEqual(byApp.count, 1)
        let byWrongApp = try await store.salesRecords(appAppleIdentifiers: ["9999"])
        XCTAssertEqual(byWrongApp.count, 0)
    }
}

private actor ASCTransactionOrderRecorder {
    private var grants: [Int] = []

    func record(_ number: Int) {
        grants.append(number)
    }

    func snapshot() -> [Int] {
        grants
    }
}
