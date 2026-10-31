import ASCAPIKit
import CryptoKit
import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// Sync engine tests against the offline stub provider and the in-memory
/// store. No test touches the network: the stub is the only provider.
final class ASCReportSyncEngineTests: XCTestCase {
    private var store: ASCInMemoryAnalyticsStore!
    private var provider: ASCStubReportProvider!
    private var engine: ASCReportSyncEngine!

    override func setUp() {
        super.setUp()
        store = ASCInMemoryAnalyticsStore()
        provider = ASCStubReportProvider()
        engine = ASCReportSyncEngine(provider: provider)
    }

    // MARK: - Scripting helpers

    private let appID = "app-1"
    private let requestID = "req-1"
    private let reportID = "rep-1"

    private func scriptAnalytics(
        reportName: String = "app-download-detailed",
        category: ASCAnalyticsReportCategory = .appStoreEngagement,
        instances: [ASCAnalyticsReportInstance],
        segmentPayloads: [(segmentID: String, payload: Data)]
    ) {
        provider.listAnalyticsReportRequestsHandler = { app, _ in
            [ASCAnalyticsReportRequest(
                id: "req-1",
                attributes: .init(accessType: .ongoing, stoppedDueToInactivity: false)
            )]
        }
        provider.listAnalyticsReportsHandler = { [requestID, reportName, category] _, _, _ in
            [ASCAnalyticsReport(
                id: self.reportID,
                attributes: .init(name: reportName, category: category)
            )]
        }
        provider.listAnalyticsReportInstancesHandler = { [reportID] _, _, _ in instances }
        // Each instance lists exactly its own segment, keyed by instance
        // id, so multi-instance scenarios keep their payloads separate.
        provider.listAnalyticsReportSegmentsHandler = { instanceID in
            guard let instance = instances.first(where: { $0.id == instanceID }) else {
                return []
            }
            return [
                ASCAnalyticsReportSegment(
                    id: "seg-\(instance.id)",
                    attributes: .init(
                        checksum: "md5-\(instance.id)",
                        sizeInBytes: nil,
                        url: "https://example.com/\(instance.id)"
                    )
                )
            ]
        }
        provider.downloadAnalyticsReportSegmentHandler = { segment in
            let instanceID = segment.id.hasPrefix("seg-")
                ? String(segment.id.dropFirst("seg-".count))
                : segment.id
            let match = segmentPayloads.first { $0.segmentID == instanceID }
            return match?.payload ?? Data()
        }
    }

    private func downloadsInstance(
        id: String, processingDate: String
    ) -> ASCAnalyticsReportInstance {
        ASCAnalyticsReportInstance(
            id: id,
            attributes: .init(granularity: .daily, processingDate: processingDate)
        )
    }

    private func downloadsPayload(
        date: String, firstTime: Int, redownload: Int = 0
    ) -> Data {
        ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: date, downloadType: "First-time Download", counts: String(firstTime)),
            ASCFixtures.downloadsLine(date: date, downloadType: "Redownload", counts: String(redownload)),
        ])
    }

    private func sync() async throws -> ASCAnalyticsSyncResult {
        try await engine.syncAnalytics(
            ASCAnalyticsSyncConfiguration(appID: appID),
            store: store
        )
    }

    // MARK: - Analytics sync

    func testFullSyncImportsAllSegmentsAtomically() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", downloadsPayload(date: "2025-10-01", firstTime: 10, redownload: 2)),
            ]
        )
        let result = try await sync()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.importedCount, 1)

        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 2)
        // Provenance: every record carries report, instance, segment, and
        // processing date.
        let provenance = records[0].provenance
        XCTAssertEqual(provenance.sourceKind, .analyticsDownloads)
        XCTAssertEqual(provenance.instanceID, "i1")
        XCTAssertEqual(provenance.segmentID, "seg-i1")
        XCTAssertEqual(provenance.processingDate, "2025-10-02")
        XCTAssertEqual(provenance.reportRequestID, requestID)
        XCTAssertEqual(provenance.reportID, reportID)
        XCTAssertEqual(provenance.schemaFingerprint.count, 64)
        XCTAssertEqual(provenance.contentChecksum.count, 64)
    }

    func testMultiSegmentInstanceIsParsedAndCommittedTogether() async throws {
        let instance = downloadsInstance(id: "i1", processingDate: "2025-10-02")
        scriptAnalytics(
            instances: [instance],
            segmentPayloads: [
                ("a", downloadsPayload(date: "2025-10-01", firstTime: 5)),
                ("b", downloadsPayload(date: "2025-10-02", firstTime: 6)),
            ]
        )
        // Both segments share one instance: listAnalyticsReportSegments
        // must return both.
        provider.listAnalyticsReportSegmentsHandler = { [instance] _ in
            [
                ASCAnalyticsReportSegment(id: "seg-a", attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.com/a")),
                ASCAnalyticsReportSegment(id: "seg-b", attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.com/b")),
            ]
        }
        let result = try await sync()
        XCTAssertEqual(result.importedCount, 1)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map { $0.provenance.segmentID ?? "" }), ["seg-a", "seg-b"])
    }

    func testRepeatedSyncIsIdempotent() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 10))]
        )
        let first = try await sync()
        XCTAssertEqual(first.importedCount, 1)
        let second = try await sync()
        XCTAssertEqual(second.outcomes.first?.outcome, .skippedAlreadyImported)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 2, "re-sync must not re-count")
    }

    func testInstanceWithoutSegmentsFailsAndCommitsNothing() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: []
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in [] }
        let result = try await sync()
        XCTAssertFalse(result.succeeded)
        guard case .failed(let reason) = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("no segments"), reason)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 0, "incomplete instances must not be marked successful")
    }

    func testCorruptSegmentAbortsInstanceWithoutCommit() async throws {
        // A segment that matches a supported header but contains garbage
        // values is a real parse failure: the instance fails and nothing
        // is committed. (Foreign headers are skipped as unsupported by
        // default — see the dedicated tests.)
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", ASCFixtures.downloadsReport([
                    ASCFixtures.downloadsLine(date: "not-a-date", downloadType: "First-time Download", counts: "1"),
                ])),
            ]
        )
        let result = try await sync()
        XCTAssertFalse(result.succeeded)
        guard case .failed(let reason) = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("failed to parse"), reason)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 0, "a failed parse must leave the store untouched")
    }

    func testSameInstanceWithChangedContentGoesToPendingReview() async throws {
        let instance = downloadsInstance(id: "i1", processingDate: "2025-10-02")
        scriptAnalytics(
            instances: [instance],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 10))]
        )
        _ = try await sync()

        // Same identity, different content: Apple's declared checksum
        // changes with the content, so the idempotency check re-downloads.
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [ASCAnalyticsReportSegment(
                id: "seg-i1",
                attributes: .init(checksum: "md5-i1-CHANGED", sizeInBytes: nil, url: "https://example.com/i1")
            )]
        }
        provider.downloadAnalyticsReportSegmentHandler = { _ in
            ASCFixtures.downloadsReport([
                ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "999"),
            ])
        }
        let second = try await sync()
        guard case .pendingReview(let reason) = second.outcomes[0].outcome else {
            return XCTFail("expected pendingReview, got \(second.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("different content"), reason)

        // The originally imported data is still the only counted data.
        let records = try await store.downloadRecords(scope: .current)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.record.counts).max(), 10)
        // And the review data is retained (1 conflicting record).
        let audit = try await store.downloadRecords(scope: .all)
        XCTAssertEqual(audit.count, 3)
        let pending = try await store.beginTransaction().ingestionEntries(state: .pendingReview)
        XCTAssertEqual(pending.count, 1)
    }

    func testDifferentProcessingDatesCoexistAndSelectionUsesLatest() async throws {
        scriptAnalytics(
            instances: [
                downloadsInstance(id: "early", processingDate: "2025-10-02"),
                downloadsInstance(id: "late", processingDate: "2025-10-03"),
            ],
            segmentPayloads: [
                ("early", downloadsPayload(date: "2025-10-01", firstTime: 10)),
                ("late", downloadsPayload(date: "2025-10-01", firstTime: 14)),
            ]
        )
        let result = try await sync()
        XCTAssertEqual(result.importedCount, 2, "both instances are imported with provenance")

        // Aggregation applies Apple's overwrite rule: the latest
        // processing date wins per event date; no merging.
        let records = try await store.downloadRecords()
        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(records)
        let firstTime = ASCDownloadMetrics(records: selected.map(\.record)).firstTimeDownloads
        XCTAssertEqual(firstTime, 14, "late instance overwrites early one; no double counting")
    }

    func testDiscoveryReportIsClassifiedByHeader() async throws {
        scriptAnalytics(
            reportName: "app-store-discovery-and-engagement-detailed",
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", ASCFixtures.discoveryReport([
                    ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "100", uniqueCounts: "80"),
                ]))
            ]
        )
        let result = try await sync()
        XCTAssertTrue(result.succeeded)
        let records = try await store.discoveryRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provenance.sourceKind, .analyticsDiscoveryAndEngagement)
        let metrics = ASCDiscoveryMetrics(records: records.map(\.record))
        XCTAssertEqual(metrics.impressionCounts, 100)
    }

    func testUnknownReportHeaderIsSkippedWithDiagnosticsByDefault() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", ASCFixtures.tsv(["Some\tOther\tReport", "a\tb\tc"])),
            ]
        )
        let result = try await sync()
        XCTAssertTrue(result.succeeded, "an unsupported report must not fail the default run")
        XCTAssertEqual(result.skippedUnsupportedCount, 1)
        guard case .skippedUnsupported(let reason) = result.outcomes[0].outcome else {
            return XCTFail("expected skippedUnsupported, got \(result.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("neither the App Downloads"), reason)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 0, "unsupported reports must never be counted")
    }

    func testUnknownReportHeaderFailsInStrictMode() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", ASCFixtures.tsv(["Some\tOther\tReport", "a\tb\tc"])),
            ]
        )
        let result = try await engine.syncAnalytics(
            ASCAnalyticsSyncConfiguration(appID: appID, failsOnUnsupportedReports: true),
            store: store
        )
        XCTAssertFalse(result.succeeded)
        guard case .failed(let reason) = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("neither the App Downloads"), reason)
    }

    func testCreatesReportRequestWhenMissing() async throws {
        provider.listAnalyticsReportRequestsHandler = { app, _ in [] }
        provider.createAnalyticsReportRequestHandler = { [appID] app, _ in
            XCTAssertEqual(app, appID)
            return ASCAnalyticsReportRequest(
                id: "created",
                attributes: .init(accessType: .ongoing, stoppedDueToInactivity: false)
            )
        }
        // After creation the list is still empty in this scripted scenario:
        // the run completes with nothing to do.
        let result = try await sync()
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(provider.callLog.contains { $0.contains("createAnalyticsReportRequest") })
    }

    // MARK: - Sales sync

    private func salesPayload(units: String, price: String) -> Data {
        ASCFixtures.salesReport([
            ASCFixtures.salesLine(
                sku: "APPONE", productType: "1F", units: units,
                proceeds: "0.70", customerPrice: price
            )
        ])
    }

    private func syncSales(reportDate: String, version: String? = nil, payload: Data) async throws -> ASCSalesSyncResult {
        provider.downloadSalesReportHandler = { _ in payload }
        return try await engine.syncSales(
            ASCSalesSyncConfiguration(
                vendorNumber: "80000",
                reportDates: [reportDate],
                versions: [version]
            ),
            store: store
        )
    }

    func testSalesSyncImportsRecords() async throws {
        let result = try await syncSales(reportDate: "2025-10-01", payload: salesPayload(units: "5", price: "0.99"))
        XCTAssertTrue(result.succeeded)
        guard case .imported(let count) = result.outcomes[0].outcome else {
            return XCTFail("expected imported, got \(result.outcomes[0].outcome)")
        }
        XCTAssertEqual(count, 1)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].provenance.vendorNumber, "80000")
        XCTAssertEqual(records[0].provenance.reportDate, "2025-10-01")
        XCTAssertEqual(records[0].record.units, 5)
    }

    func testSalesRepeatSyncIsIdempotent() async throws {
        _ = try await syncSales(reportDate: "2025-10-01", payload: salesPayload(units: "5", price: "0.99"))
        let second = try await syncSales(reportDate: "2025-10-01", payload: salesPayload(units: "5", price: "0.99"))
        XCTAssertEqual(second.outcomes[0].outcome, .skippedAlreadyImported)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testNewerSalesVersionSupersedesOlderOne() async throws {
        _ = try await syncSales(reportDate: "2025-10-01", version: "1", payload: salesPayload(units: "5", price: "0.99"))
        let corrected = try await syncSales(reportDate: "2025-10-01", version: "2", payload: salesPayload(units: "3", price: "0.99"))
        XCTAssertTrue(corrected.succeeded)
        XCTAssertEqual(corrected.outcomes[0].supersededVersions, ["1"])

        // Queries default to the latest version only — no double counting.
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 3)
        // Audit queries still see both versions with provenance.
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2)
    }

    func testSalesDownloadFailureIsReported() async throws {
        provider.downloadSalesReportHandler = { _ in
            throw ASCAnalyticsError.providerInvalidData(reason: "network unavailable (stub)")
        }
        let result = try await syncSales(reportDate: "2025-10-01", payload: Data())
        guard case .failed = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        XCTAssertFalse(result.succeeded)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 0)
    }

    func testSalesParseFailureCommitsNothing() async throws {
        let result = try await syncSales(reportDate: "2025-10-01", payload: Data("garbage".utf8))
        guard case .failed(let reason) = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        XCTAssertTrue(reason.contains("parse failed"), reason)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 0)
    }

    func testLateArrivingSalesDataSyncsIndependently() async throws {
        // Day 10/02 arrives first; the older 10/01 arrives later. Each
        // report date is its own ingestion; neither overwrites the other.
        _ = try await syncSales(reportDate: "2025-10-02", payload: salesPayload(units: "7", price: "0.99"))
        _ = try await syncSales(reportDate: "2025-10-01", payload: salesPayload(units: "5", price: "0.99"))
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 2)
        let units = Set(records.map(\.record.units))
        XCTAssertEqual(units, [5, 7])
    }

    // MARK: - Segment identity and checksum strategy

    func testSegmentsWithoutDeclaredChecksumsRevalidateByContent() async throws {
        // Apple declares no checksums: the declared-checksum shortcut must
        // never fire; idempotency falls back to verified content.
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 10))]
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [ASCAnalyticsReportSegment(
                id: "seg-i1",
                attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.com/i1")
            )]
        }
        let first = try await sync()
        XCTAssertEqual(first.importedCount, 1)

        // Same content again: content compare recognizes it.
        let second = try await sync()
        XCTAssertEqual(second.outcomes.first?.outcome, .skippedAlreadyImported)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 2, "no double counting")

        // Content changes (still no declared checksums): quarantined, and
        // the originally imported data keeps counting.
        provider.downloadAnalyticsReportSegmentHandler = { _ in
            ASCFixtures.downloadsReport([
                ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "555"),
            ])
        }
        let third = try await sync()
        guard case .pendingReview = third.outcomes[0].outcome else {
            return XCTFail("expected pendingReview, got \(third.outcomes[0].outcome)")
        }
        let current = try await store.downloadRecords(scope: .current)
        XCTAssertEqual(current.count, 2)
        XCTAssertEqual(current.map(\.record.counts).max(), 10)
    }

    func testEmptyDeclaredChecksumsAreNeverTreatedAsUnchanged() async throws {
        // An empty string is "no checksum". Two deliveries with empty
        // declared checksums but different content must never be
        // collapsed into a skip.
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 10))]
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [ASCAnalyticsReportSegment(
                id: "seg-i1",
                attributes: .init(checksum: "", sizeInBytes: nil, url: "https://example.com/i1")
            )]
        }
        _ = try await sync()
        provider.downloadAnalyticsReportSegmentHandler = { _ in
            ASCFixtures.downloadsReport([
                ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "777"),
            ])
        }
        let second = try await sync()
        guard case .pendingReview = second.outcomes[0].outcome else {
            return XCTFail("expected pendingReview, got \(second.outcomes[0].outcome)")
        }
    }

    func testSameContentInDifferentSegmentIDsIsKeptTwice() async throws {
        // Segments are partitions identified by their segment id: two
        // different ids with byte-identical content are both kept —
        // dropping one by content would silently discard a partition.
        let payload = downloadsPayload(date: "2025-10-01", firstTime: 5)
        let instance = downloadsInstance(id: "i1", processingDate: "2025-10-02")
        scriptAnalytics(
            instances: [instance],
            segmentPayloads: [("a", payload)]
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [
                ASCAnalyticsReportSegment(id: "seg-a", attributes: .init(checksum: "x", sizeInBytes: nil, url: "https://example.com/a")),
                ASCAnalyticsReportSegment(id: "seg-b", attributes: .init(checksum: "x", sizeInBytes: nil, url: "https://example.com/b")),
            ]
        }
        provider.downloadAnalyticsReportSegmentHandler = { _ in payload }

        let result = try await sync()
        XCTAssertTrue(result.succeeded)
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 4, "both segments parsed: 2 rows each")
        XCTAssertEqual(Set(records.map { $0.provenance.segmentID ?? "" }), ["seg-a", "seg-b"])
    }

    func testDuplicateSegmentIDIsParsedOnce() async throws {
        // The same segment id listed twice: one download, one parse, no
        // double counting.
        let payload = downloadsPayload(date: "2025-10-01", firstTime: 5)
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", payload)]
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [
                ASCAnalyticsReportSegment(id: "seg-i1", attributes: .init(checksum: "x", sizeInBytes: nil, url: "https://example.com/1")),
                ASCAnalyticsReportSegment(id: "seg-i1", attributes: .init(checksum: "x", sizeInBytes: nil, url: "https://example.com/2")),
            ]
        }
        let downloadCounter = DownloadCounter()
        provider.downloadAnalyticsReportSegmentHandler = { _ in
            downloadCounter.increment()
            return payload
        }

        let result = try await sync()
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(downloadCounter.count, 1, "same segment id must be downloaded once")
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 2, "parsed once: 2 rows, not 4")
    }

    func testPartialSegmentFailureRollsBackWholeInstance() async throws {
        // Two segments; the second fails to download. Nothing from the
        // instance may be committed.
        let instance = downloadsInstance(id: "i1", processingDate: "2025-10-02")
        scriptAnalytics(
            instances: [instance],
            segmentPayloads: [("a", downloadsPayload(date: "2025-10-01", firstTime: 5))]
        )
        provider.listAnalyticsReportSegmentsHandler = { _ in
            [
                ASCAnalyticsReportSegment(id: "seg-a", attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.com/a")),
                ASCAnalyticsReportSegment(id: "seg-b", attributes: .init(checksum: nil, sizeInBytes: nil, url: "https://example.com/b")),
            ]
        }
        provider.downloadAnalyticsReportSegmentHandler = { [weak self] segment in
            if segment.id == "seg-b" {
                throw ASCAnalyticsError.providerInvalidData(reason: "download interrupted (stub)")
            }
            return self?.downloadsPayload(date: "2025-10-01", firstTime: 5) ?? Data()
        }

        let result = try await sync()
        XCTAssertFalse(result.succeeded)
        guard case .failed = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
        let records = try await store.downloadRecords()
        XCTAssertEqual(records.count, 0, "partial writes must never survive")
        let entries = try await store.beginTransaction().ingestionEntries(state: nil)
        XCTAssertEqual(entries.count, 0)
    }

    func testNegativeMaximumInstancesPerReportDoesNotCrash() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 1))]
        )
        // A nonsensical limit selects no instances instead of crashing in
        // `prefix`.
        for limit in [-1, 0] {
            let result = try await engine.syncAnalytics(
                ASCAnalyticsSyncConfiguration(appID: appID, maximumInstancesPerReport: limit),
                store: store
            )
            XCTAssertEqual(result.outcomes.count, 0)
            let records = try await store.downloadRecords()
            XCTAssertEqual(records.count, 0)
        }
        // A sane run still works afterwards on the same store.
        let result = try await sync()
        XCTAssertEqual(result.importedCount, 1)
    }

    // MARK: - Sales identity

    private func syncSalesVersion(
        reportDate: String, version: String?, payload: Data,
        frequency: ASCSalesReportFrequency = .daily
    ) async throws -> ASCSalesSyncOutcome {
        provider.downloadSalesReportHandler = { _ in payload }
        let result = try await engine.syncSales(
            ASCSalesSyncConfiguration(
                vendorNumber: "80000",
                frequency: frequency,
                reportDates: [reportDate],
                versions: [version]
            ),
            store: store
        )
        return result.outcomes[0]
    }

    func testDefaultVersionRepeatSyncIsIdempotent() async throws {
        let payload = salesPayload(units: "5", price: "0.99")
        let first = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: payload)
        guard case .imported = first.outcome else {
            return XCTFail("expected imported, got \(first.outcome)")
        }
        let second = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: payload)
        XCTAssertEqual(second.outcome, .skippedAlreadyImported)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testExplicitVersionsCoexistInLedgerWithSupersession() async throws {
        let v1 = salesPayload(units: "5", price: "0.99")
        let v2 = salesPayload(units: "3", price: "0.99")
        _ = try await syncSalesVersion(reportDate: "2025-10-01", version: "1", payload: v1)
        let second = try await syncSalesVersion(reportDate: "2025-10-01", version: "2", payload: v2)

        XCTAssertTrue(second.outcome.isSuccessfulImport)
        XCTAssertEqual(second.supersededVersions, ["1"], "explicit numeric correction overrides the older version")

        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 3)
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2, "both versions retained for audit")
    }

    func testUnversionedLatestConflictingContentRequiresManualResolution() async throws {
        // First an explicit import, then an unversioned latest download
        // with different content: replacement semantics cannot be proven,
        // so the outcome must demand manual review — never a silent
        // replace, never a double count, never "same version".
        _ = try await syncSalesVersion(reportDate: "2025-10-01", version: "1", payload: salesPayload(units: "5", price: "0.99"))
        let latest = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: salesPayload(units: "9", price: "0.99"))

        guard case .pendingReview(let reason) = latest.outcome else {
            return XCTFail("expected pendingReview, got \(latest.outcome)")
        }
        XCTAssertTrue(reason.contains("manual review"), reason)

        // Old statistics are still the counted ones, but the conflict is
        // visible and retained.
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 5)
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2)
        let pending = try await store.beginTransaction().ingestionEntries(state: .pendingReview)
        XCTAssertEqual(pending.count, 1)
    }

    func testUnversionedLatestMatchingImportedContentIsSkipped() async throws {
        // The unversioned latest download returns content byte-identical
        // to an already imported explicit version: recognized by content.
        let payload = salesPayload(units: "5", price: "0.99")
        _ = try await syncSalesVersion(reportDate: "2025-10-01", version: "1", payload: payload)
        let latest = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: payload)
        XCTAssertEqual(latest.outcome, .skippedAlreadyImported)
        let records = try await store.salesRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testExplicitVersionAfterUnversionedImportRequiresManualResolution() async throws {
        // An unversioned (latest) import exists with different content; an
        // explicit version cannot be ordered against it (older? newer?),
        // so the delivery is quarantined for manual review instead of
        // guessing which content is current.
        _ = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: salesPayload(units: "5", price: "0.99"))
        let explicit = try await syncSalesVersion(reportDate: "2025-10-01", version: "1", payload: salesPayload(units: "7", price: "0.99"))

        guard case .pendingReview(let reason) = explicit.outcome else {
            return XCTFail("expected pendingReview, got \(explicit.outcome)")
        }
        XCTAssertTrue(reason.contains("manual review"), reason)
        XCTAssertTrue(explicit.supersededVersions.isEmpty)

        // The unversioned import keeps counting; the conflict is retained.
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].record.units, 5)
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2)
        let pending = try await store.beginTransaction().ingestionEntries(state: .pendingReview)
        XCTAssertEqual(pending.count, 1)
    }

    func testExplicitVersionIdentifyingAlreadyImportedContentSupersedesUnversionedEntry() async throws {
        // The unversioned latest download returned some content; a later
        // explicit version download returns byte-identical content: the
        // version identifies what we already have. The unversioned entry
        // is superseded, and exactly one counted copy remains.
        let payload = salesPayload(units: "5", price: "0.99")
        _ = try await syncSalesVersion(reportDate: "2025-10-01", version: nil, payload: payload)
        let identified = try await syncSalesVersion(reportDate: "2025-10-01", version: "1", payload: payload)

        XCTAssertTrue(identified.outcome.isSuccessfulImport)
        XCTAssertEqual(identified.supersededVersions, ["latest(unversioned)"])
        let current = try await store.salesRecords()
        XCTAssertEqual(current.count, 1, "same content: no double counting")
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2)
    }

    func testDifferentFrequencySameDateAreDistinctIdentities() async throws {
        let daily = try await syncSalesVersion(
            reportDate: "2025-10-01", version: nil,
            payload: salesPayload(units: "5", price: "0.99"),
            frequency: .daily
        )
        let weekly = try await syncSalesVersion(
            reportDate: "2025-10-01", version: nil,
            payload: salesPayload(units: "30", price: "0.99"),
            frequency: .weekly
        )
        guard case .imported = daily.outcome else { return XCTFail("daily: \(daily.outcome)") }
        guard case .imported = weekly.outcome else {
            // The weekly content differs from the daily import; because
            // the identities are distinct, the weekly import is a fresh
            // import of its own identity — not a conflict.
            return XCTFail("weekly: \(weekly.outcome)")
        }
        let audit = try await store.salesRecords(scope: .all)
        XCTAssertEqual(audit.count, 2)
        let units = Set(audit.map(\.record.units))
        XCTAssertEqual(units, [5, 30])
        // And their identities differ in the kind component.
        let kinds = Set(audit.map { $0.provenance.sourceKind })
        XCTAssertEqual(kinds, [.summarySales])
    }

    func testSalesIdentityIncludesKindAcrossFrequencies() async throws {
        // The weekly report for the same date must not match the daily
        // report's ledger entry on repeat syncs.
        _ = try await syncSalesVersion(
            reportDate: "2025-10-01", version: nil,
            payload: salesPayload(units: "5", price: "0.99"),
            frequency: .daily
        )
        _ = try await syncSalesVersion(
            reportDate: "2025-10-01", version: nil,
            payload: salesPayload(units: "5", price: "0.99"),
            frequency: .daily
        )
        let weekly = try await syncSalesVersion(
            reportDate: "2025-10-01", version: nil,
            payload: salesPayload(units: "5", price: "0.99"),
            frequency: .weekly
        )
        guard case .imported = weekly.outcome else {
            return XCTFail("weekly with identical content must be its own import, got \(weekly.outcome)")
        }
    }

    // MARK: - Offline guarantees

    func testStubProviderNeverTouchesNetworkAndLogsEveryCall() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [("i1", downloadsPayload(date: "2025-10-01", firstTime: 1))]
        )
        _ = try await sync()
        // The stub records only scripted calls; it performs no HTTP.
        XCTAssertTrue(provider.callLog.contains { $0.contains("listAnalyticsReportRequests") })
        XCTAssertTrue(provider.callLog.contains { $0.contains("downloadAnalyticsReportSegment") })
        XCTAssertFalse(provider.callLog.contains { $0.contains("URLSession") })
    }
}

/// Verifies the production ASCAPIKit adapter stays a thin 1:1 mapping by
/// driving a real ASCClient over an offline recording transport.
final class ASCAPIClientReportProviderTests: XCTestCase {
    private struct RecordingTransport: ASCTransport {
        let respond: @Sendable (URLRequest) -> (Data, Int)
        var sent: [URLRequest] = []

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, status) = respond(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
    }

    private func makeClient(respond: @escaping @Sendable (URLRequest) -> (Data, Int)) throws -> ASCClient {
        // Offline ES256 key generation: no credentials leave the process
        // and no network is involved.
        let privateKey = P256.Signing.PrivateKey()
        let transport = RecordingTransport(respond: respond)
        return try ASCClient(
            configuration: ASCCredentialConfiguration(
                kind: .team,
                keyID: "test-key",
                issuerID: "test-issuer"
            ),
            privateKeyPEM: privateKey.pemRepresentation,
            transport: transport
        )
    }

    func testProviderMapsCallsToASCClientEndpoints() async throws {
        let client = try makeClient { request in
            (Data("{\"data\":[{\"id\":\"i1\",\"attributes\":{\"granularity\":\"DAILY\",\"processingDate\":\"2025-10-02\"}}]}".utf8), 200)
        }
        let provider = ASCAPIClientReportProvider(client: client)
        let instance = try await provider.listAnalyticsReportInstances(
            reportID: "rep-1", granularities: [.daily], processingDates: []
        )
        XCTAssertEqual(instance.count, 1)
        XCTAssertEqual(instance[0].id, "i1")
        XCTAssertEqual(instance[0].attributes.processingDate, "2025-10-02")
    }
}
