import ASCAPIKit
import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// A deterministic one-shot gate: the first `pass()` caller proceeds
/// immediately; every later caller suspends until `open()`. Used to stage
/// exact concurrent interleavings (two engines that both probe "not yet
/// imported" before either commits) without sleeps or luck.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved = false
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// The first caller passes immediately; every later caller suspends
    /// until `open()`.
    func pass() async {
        if tryReserve() { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if register(continuation) {
                continuation.resume()
            }
        }
    }

    private func tryReserve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !reserved {
            reserved = true
            return true
        }
        return false
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if opened { return true } // resume immediately
        continuations.append(continuation)
        return false
    }

    /// Releases every suspended caller.
    func open() {
        lock.lock()
        opened = true
        let waiting = continuations
        continuations = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

/// Final integrity review regressions:
/// 1. The overwrite rule runs on the full scope BEFORE territory filters,
///    so a correction that drops a territory retracts the old statistics.
/// 2. Concurrent syncs of the same report on one shared store are atomic:
///    decisions re-read the ledger inside the commit transaction.
final class ASCIntegrityRegressionTests: XCTestCase {

    // MARK: - 1. Territory correction ordering

    private func analyticsEntry(
        date: String,
        processingDate: String?,
        territory: String,
        counts: Int,
        app: String = "1001",
        reportID: String = "rep-1",
        granularity: ASCReportGranularity = .daily
    ) -> ASCProvenancedRecord<ASCDownloadRecord> {
        let record = ASCDownloadRecord(
            date: ASCCalendarDate(iso8601Day: date)!,
            appAppleIdentifier: app,
            rawDownloadType: "First-time Download",
            downloadType: .firstTimeDownload,
            territory: territory,
            counts: counts,
            isPreOrder: nil,
            extraFields: [:]
        )
        let provenance = ASCReportProvenance(
            sourceKind: .analyticsDownloads,
            reportName: "app-download",
            reportID: reportID,
            instanceID: "inst-\(processingDate ?? "none")-\(territory)-\(counts)",
            processingDate: processingDate,
            granularity: granularity,
            schemaFingerprint: "fp-\(reportID)",
            contentChecksum: "cc-\(counts)-\(territory)",
            fetchedAt: Date(),
            recordCount: 1
        )
        return ASCProvenancedRecord(record: record, provenance: provenance)
    }

    private func discoveryEntry(
        date: String,
        processingDate: String?,
        territory: String,
        counts: Int,
        unique: Int,
        app: String = "1001",
        reportID: String = "rep-1"
    ) -> ASCProvenancedRecord<ASCDiscoveryRecord> {
        let record = ASCDiscoveryRecord(
            date: ASCCalendarDate(iso8601Day: date)!,
            appAppleIdentifier: app,
            rawEvent: "Impression",
            event: .impression,
            pageType: nil,
            sourceType: nil,
            engagementType: nil,
            territory: territory,
            counts: counts,
            uniqueCounts: unique,
            extraFields: [:]
        )
        let provenance = ASCReportProvenance(
            sourceKind: .analyticsDiscoveryAndEngagement,
            reportName: "discovery",
            reportID: reportID,
            instanceID: "inst-\(processingDate ?? "none")-\(territory)-\(counts)",
            processingDate: processingDate,
            granularity: .daily,
            schemaFingerprint: "fp-\(reportID)",
            contentChecksum: "cc-\(counts)-\(territory)",
            fetchedAt: Date(),
            recordCount: 1
        )
        return ASCProvenancedRecord(record: record, provenance: provenance)
    }

    func testCorrectionDroppingTerritoryRetractsStaleUSStatisticsForDownloads() throws {
        // Old instance: US + DE. Corrected instance: DE only — Apple's
        // correction retracted the US rows entirely.
        let oldInstance = [
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "US", counts: 10),
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "DE", counts: 5),
        ]
        let correction = [
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-02", territory: "DE", counts: 7),
        ]
        let aggregator = ASCAnalyticsAggregator()
        let records = oldInstance + correction

        // Querying US must NOT resurrect the retracted rows from the old
        // instance.
        let us = try aggregator.downloads(records, filter: ASCAnalyticsFilter(territories: ["US"]))
        XCTAssertEqual(us.totals.firstTimeDownloads, 0)
        XCTAssertEqual(us.totals.recordCount, 0)

        // DE returns the corrected instance's data.
        let de = try aggregator.downloads(records, filter: ASCAnalyticsFilter(territories: ["DE"]))
        XCTAssertEqual(de.totals.firstTimeDownloads, 7)

        // No territory filter: the corrected instance wins for the date.
        let unfiltered = try aggregator.downloads(records)
        XCTAssertEqual(unfiltered.totals.firstTimeDownloads, 7)
    }

    func testOtherDatesAndAppsAndVariantsSurviveTerritoryCorrection() throws {
        let records = [
            // The corrected day (US retracted).
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "US", counts: 10),
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "DE", counts: 5),
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-02", territory: "DE", counts: 7),
            // Other days of the same app: untouched by the correction.
            analyticsEntry(date: "2025-10-02", processingDate: "2024-04-01", territory: "US", counts: 3),
            // Another app: untouched.
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "US", counts: 9, app: "2002"),
            // Another report variant: untouched.
            analyticsEntry(date: "2025-10-01", processingDate: "2024-04-03", territory: "US", counts: 11, reportID: "rep-detailed"),
        ]
        let aggregator = ASCAnalyticsAggregator()

        // Same app, another date: still served by its own latest instance.
        let otherDay = try aggregator.downloads(
            records,
            filter: ASCAnalyticsFilter(
                appIdentifiers: ["1001"],
                territories: ["US"],
                dateRange: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-02")!)
            )
        )
        XCTAssertEqual(otherDay.totals.firstTimeDownloads, 3)

        // Another app, US: unaffected.
        let otherApp = try aggregator.downloads(
            records,
            filter: ASCAnalyticsFilter(appIdentifiers: ["2002"], territories: ["US"])
        )
        XCTAssertEqual(otherApp.totals.firstTimeDownloads, 9)

        // Other variant, US: unaffected (per-scope aggregation).
        let otherVariant = try aggregator.downloads(
            records.filter { $0.provenance.reportID == "rep-detailed" },
            filter: ASCAnalyticsFilter(territories: ["US"])
        )
        XCTAssertEqual(otherVariant.totals.firstTimeDownloads, 11)
    }

    func testCorrectionDroppingTerritoryRetractsStaleStatisticsForDiscovery() throws {
        let oldInstance = [
            discoveryEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "US", counts: 100, unique: 80),
            discoveryEntry(date: "2025-10-01", processingDate: "2024-04-01", territory: "DE", counts: 50, unique: 40),
        ]
        let correction = [
            discoveryEntry(date: "2025-10-01", processingDate: "2024-04-02", territory: "DE", counts: 60, unique: 48),
        ]
        let aggregator = ASCAnalyticsAggregator()
        let records = oldInstance + correction

        let us = try aggregator.discovery(records, filter: ASCAnalyticsFilter(territories: ["US"]))
        XCTAssertEqual(us.totals.impressionCounts, 0, "retracted US data must not be served")
        XCTAssertEqual(us.totals.recordCount, 0)

        let de = try aggregator.discovery(records, filter: ASCAnalyticsFilter(territories: ["DE"]))
        XCTAssertEqual(de.totals.impressionCounts, 60)
        XCTAssertEqual(de.totals.uniqueCountEntries.first?.uniqueCounts, 48)
    }

    // MARK: - 2. Concurrent sync atomicity

    private func makeConcurrentSalesSetup() -> (
        store: ASCInMemoryAnalyticsStore,
        engineA: ASCReportSyncEngine,
        engineB: ASCReportSyncEngine,
        providerA: ASCStubReportProvider,
        providerB: ASCStubReportProvider
    ) {
        let store = ASCInMemoryAnalyticsStore()
        let providerA = ASCStubReportProvider()
        let providerB = ASCStubReportProvider()
        return (
            store,
            ASCReportSyncEngine(provider: providerA),
            ASCReportSyncEngine(provider: providerB),
            providerA,
            providerB
        )
    }

    private func salesResult(
        _ outcomes: [ASCSalesSyncOutcome]
    ) -> ASCSalesSyncOutcome {
        XCTAssertEqual(outcomes.count, 1, "one report date per run")
        return outcomes[0]
    }

    func testConcurrentSameVersionSalesSyncImportsExactlyOnce() async throws {
        let (store, engineA, engineB, providerA, providerB) = makeConcurrentSalesSetup()
        let gate = AsyncGate()
        let payload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(
                sku: "APPONE", productType: "1F", units: "5",
                proceeds: "0.70", customerPrice: "0.99"
            )
        ])

        // Deterministic interleaving: whichever engine downloads first
        // proceeds and commits; the second engine's download is held until
        // the first has fully committed. No sleeps, no luck.
        for provider in [providerA, providerB] {
            provider.downloadSalesReportHandler = { [gate] _ in
                await gate.pass()
                return payload
            }
        }

        let config = ASCSalesSyncConfiguration(
            vendorNumber: "80000",
            reportDates: ["2025-10-01"],
            versions: [nil]
        )

        let outcomes = try await withThrowingTaskGroup(
            of: ASCSalesSyncOutcome.self
        ) { group -> [ASCSalesSyncOutcome] in
            group.addTask {
                try await self.salesResult(
                    engineA.syncSales(config, store: store).outcomes
                )
            }
            group.addTask {
                try await self.salesResult(
                    engineB.syncSales(config, store: store).outcomes
                )
            }
            // The first task to finish is exactly the ungated engine,
            // already committed.
            let first = try await group.next()!
            gate.open()
            let second = try await group.next()!
            return [first, second]
        }

        // Exactly one import, one skip, one record — no duplicates.
        let imported = outcomes.filter { $0.outcome.isSuccessfulImport }
        let skipped = outcomes.filter {
            if case .skippedAlreadyImported = $0.outcome { return true }
            return false
        }
        XCTAssertEqual(imported.count, 1, "outcomes: \(outcomes)")
        XCTAssertEqual(skipped.count, 1, "outcomes: \(outcomes)")
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1, "same version must never double count")
        XCTAssertEqual(records[0].record.units, 5)
    }

    func testConcurrentDifferentVersionSalesSyncNeverReverseSupersedes() async throws {
        let (store, engineA, engineB, providerA, providerB) = makeConcurrentSalesSetup()
        let gate = AsyncGate()

        let v2Payload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "20", proceeds: "0.70", customerPrice: "0.99")
        ])
        let v1Payload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "8", proceeds: "0.70", customerPrice: "0.99")
        ])

        // Engine A downloads v2 and proceeds; engine B downloads v1 and is
        // held until A has fully committed, so B's decision sees v2 as the
        // current version.
        providerA.downloadSalesReportHandler = { _ in await gate.pass(); return v2Payload }
        providerB.downloadSalesReportHandler = { _ in await gate.pass(); return v1Payload }

        func config(version: String?) -> ASCSalesSyncConfiguration {
            ASCSalesSyncConfiguration(
                vendorNumber: "80000",
                reportDates: ["2025-10-01"],
                versions: [version]
            )
        }

        try await withThrowingTaskGroup(of: ASCSalesSyncOutcome.self) { group in
            group.addTask {
                try await self.salesResult(
                    engineA.syncSales(config(version: "2"), store: store).outcomes
                )
            }
            group.addTask {
                try await self.salesResult(
                    engineB.syncSales(config(version: "1"), store: store).outcomes
                )
            }
            _ = try await group.next()! // v2 fully committed
            gate.open()
            _ = try await group.next()! // v1 decided afterwards
        }

        // v2 stays the only current version; v1 never reverse-supersedes.
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 20)
        XCTAssertEqual(current[0].provenance.reportVersion, "2")
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2, "v1 retained for audit")
    }

    func testConcurrentSameInstanceAnalyticsSyncImportsExactlyOnce() async throws {
        let store = ASCInMemoryAnalyticsStore()
        let gate = AsyncGate()
        let providerA = ASCStubReportProvider()
        let providerB = ASCStubReportProvider()
        let engineA = ASCReportSyncEngine(provider: providerA)
        let engineB = ASCReportSyncEngine(provider: providerB)

        let instance = ASCAnalyticsReportInstance(
            id: "i1",
            attributes: .init(granularity: .daily, processingDate: "2025-10-02")
        )
        let payload = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "2"),
        ])

        for provider in [providerA, providerB] {
            provider.listAnalyticsReportRequestsHandler = { _, _ in
                [ASCAnalyticsReportRequest(
                    id: "req-1",
                    attributes: .init(accessType: .ongoing, stoppedDueToInactivity: false)
                )]
            }
            provider.listAnalyticsReportsHandler = { _, _, _ in
                [ASCAnalyticsReport(
                    id: "rep-1",
                    attributes: .init(name: "app-download-detailed", category: .appStoreEngagement)
                )]
            }
            provider.listAnalyticsReportInstancesHandler = { _, _, _ in [instance] }
            provider.listAnalyticsReportSegmentsHandler = { _ in
                [ASCAnalyticsReportSegment(
                    id: "seg-i1",
                    attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.invalid/seg")
                )]
            }
        }
        // Whoever downloads first proceeds; the other waits until the
        // first engine has fully committed.
        for provider in [providerA, providerB] {
            provider.downloadAnalyticsReportSegmentHandler = { [gate] _ in
                await gate.pass()
                return payload
            }
        }

        let config = ASCAnalyticsSyncConfiguration(appID: "app-1")

        let outcomes = try await withThrowingTaskGroup(
            of: ASCAnalyticsSyncOutcome.self
        ) { group -> [ASCAnalyticsSyncOutcome] in
            group.addTask {
                try await engineA.syncAnalytics(config, store: store).outcomes[0]
            }
            group.addTask {
                try await engineB.syncAnalytics(config, store: store).outcomes[0]
            }
            // The first task to finish is exactly the ungated engine,
            // already committed.
            let first = try await group.next()!
            gate.open()
            let second = try await group.next()!
            return [first, second]
        }

        let imported = outcomes.filter {
            if case .imported = $0.outcome { return true }
            return false
        }
        let skipped = outcomes.filter {
            if case .skippedAlreadyImported = $0.outcome { return true }
            return false
        }
        XCTAssertEqual(imported.count, 1, "outcomes: \(outcomes)")
        XCTAssertEqual(skipped.count, 1, "outcomes: \(outcomes)")
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 2, "one instance worth of records, never two")
    }

    func testConcurrentFailureLeavesNoPartialData() async throws {
        let (store, engineA, engineB, providerA, providerB) = makeConcurrentSalesSetup()
        let gate = AsyncGate()

        let goodPayload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "5", proceeds: "0.70", customerPrice: "0.99")
        ])
        let corruptPayload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "not-a-number", proceeds: "0.70", customerPrice: "0.99")
        ])

        // Engine A succeeds; engine B is held until A committed, then
        // receives corrupt content and must fail without leaving anything.
        providerA.downloadSalesReportHandler = { _ in await gate.pass(); return goodPayload }
        providerB.downloadSalesReportHandler = { _ in await gate.pass(); return corruptPayload }

        let config = ASCSalesSyncConfiguration(
            vendorNumber: "80000",
            reportDates: ["2025-10-01"],
            versions: [nil]
        )

        try await withThrowingTaskGroup(of: ASCSalesSyncOutcome.self) { group in
            group.addTask {
                try await self.salesResult(
                    engineA.syncSales(config, store: store).outcomes
                )
            }
            group.addTask {
                try await self.salesResult(
                    engineB.syncSales(config, store: store).outcomes
                )
            }
            _ = try await group.next()! // A committed
            gate.open()
            _ = try await group.next()! // B failed cleanly
        }

        let records = try await store.salesRecords(scope: .all)
        XCTAssertEqual(records.count, 1, "only A's good record; B left nothing")
        XCTAssertEqual(records[0].record.units, 5)
        let entries = try await store.beginTransaction().ingestionEntries(state: nil)
        XCTAssertEqual(entries.count, 1, "no ledger trace from the failed engine")
    }
}
