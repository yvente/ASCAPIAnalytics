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
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", Data("This is not a report".utf8)),
            ]
        )
        let result = try await sync()
        XCTAssertFalse(result.succeeded)
        guard case .failed = result.outcomes[0].outcome else {
            return XCTFail("expected failed, got \(result.outcomes[0].outcome)")
        }
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

    func testUnknownReportHeaderFailsTheInstance() async throws {
        scriptAnalytics(
            instances: [downloadsInstance(id: "i1", processingDate: "2025-10-02")],
            segmentPayloads: [
                ("i1", ASCFixtures.tsv(["Some\tOther\tReport", "a\tb\tc"])),
            ]
        )
        let result = try await sync()
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
