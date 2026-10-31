import ASCAPIKit
import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// The examples in docs/USAGE.md, compiled and executed offline. Keeping
/// them here guarantees the documentation stays buildable.
final class ASCAPIAnalyticsUsageTests: XCTestCase {
    func testParsingSalesReportExample() throws {
        // Synthetic Summary Sales content in Apple's documented layout.
        let salesData = ASCFixtures.salesReport([
            ASCFixtures.salesLine(
                sku: "APPONE", productType: "1F", units: "100",
                proceeds: "0.70", customerPrice: "0.99"
            ),
        ])

        let result = try ASCSalesReportParser().parse(salesData)

        for record in result.records {
            XCTAssertFalse(record.rawProductType.isEmpty)
            XCTAssertLessThanOrEqual(
                record.beginDate, ASCCalendarDate(iso8601Day: "9999-12-31")!
            )
        }
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].productType, ASCSalesProductType.app)
        XCTAssertEqual(result.schemaFingerprint.count, 64)
        XCTAssertEqual(result.contentChecksum.count, 64)
    }

    func testParsingAnalyticsSegmentsExample() throws {
        let segmentData = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
        ])
        let downloads = try ASCDownloadsReportParser().parse(segmentData)
        XCTAssertEqual(downloads.records.count, 1)
        XCTAssertEqual(downloads.records[0].downloadType, ASCDownloadType.firstTimeDownload)
        XCTAssertFalse(downloads.records[0].extraFields.isEmpty)

        let discoveryData = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "100", uniqueCounts: "80"),
        ])
        let discovery = try ASCDiscoveryReportParser().parse(discoveryData)
        XCTAssertEqual(discovery.records[0].event, ASCDiscoveryEvent.impression)
        XCTAssertEqual(discovery.records[0].counts, 100)
        XCTAssertEqual(discovery.records[0].uniqueCounts, 80)
    }

    func testMetricsAndAggregationExample() throws {
        let result = try ASCSalesReportParser().parse(ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "100", proceeds: "0.70", customerPrice: "0.99"),
        ]))
        let metrics = ASCSalesMetrics(records: result.records)

        XCTAssertEqual(metrics.grossSales(currency: "USD"), Decimal(string: "99.00"))
        XCTAssertEqual(metrics.developerProceeds(currency: "USD"), Decimal(string: "70.00"))
        XCTAssertEqual(metrics.unitBreakdown.appUnits, 100)
        XCTAssertEqual(metrics.unitBreakdown.unknownUnits, 0)
        XCTAssertTrue(metrics.unknownProductTypeIdentifiers.isEmpty)
        XCTAssertEqual(metrics.combinedGrossSalesAcrossCurrencies, ASCSupportStatus.supported)

        let summary = ASCSalesAggregator().summary(result.records, filter: ASCSalesFilter(
            dateRange: ASCDateRange(
                start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                end: ASCCalendarDate(iso8601Day: "2025-10-31")!
            ),
            appAppleIdentifiers: ["1234567890"],
            parentIdentifiers: nil,
            territories: nil,
            customerCurrencies: nil
        ))
        XCTAssertEqual(summary.totals.recordCount, 1)
        XCTAssertEqual(summary.byDay.count, 1)
        XCTAssertEqual(summary.byApp.count, 1)
    }

    func testAnalyticsAggregationExample() throws {
        let downloadRecords = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "3"),
        ])).records

        let downloadSummary = ASCAnalyticsAggregator().downloads(downloadRecords)
        XCTAssertEqual(downloadSummary.totals.firstTimeDownloads, 10)
        XCTAssertEqual(downloadSummary.totals.appleTotalDownloads, 13)
        XCTAssertEqual(downloadSummary.byDay.count, 1)
        XCTAssertEqual(downloadSummary.byTerritory.count, 1)

        let discoveryRecords = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "100", uniqueCounts: "80"),
        ])).records
        let discoverySummary = ASCAnalyticsAggregator().discovery(discoveryRecords)
        XCTAssertEqual(discoverySummary.totals.impressionCounts, 100)
        XCTAssertEqual(
            discoverySummary.totals.combinedUniqueImpressionCounts,
            ASCSupportStatus.supported
        )
    }

    func testConversionRateExample() throws {
        let downloadRecords = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "2"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Auto-update", counts: "100"),
        ])).records
        let discoveryRecords = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
        ])).records

        // A denominator derived from the Discovery report cannot be proven
        // to match Apple's dashboard impressions basis (which includes
        // unique product page views), so the report-based helper refuses.
        let reportBasedRate = ASCAnalyticsAggregator().conversionRate(
            downloads: downloadRecords,
            impressions: discoveryRecords,
            filter: ASCAnalyticsFilter(
                appIdentifiers: ["1234567890"],
                dateRange: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
            )
        )
        guard case .unavailable = reportBasedRate else {
            return XCTFail("expected unavailable, got \(reportBasedRate)")
        }

        // With a denominator asserted to be Apple's dashboard basis (for
        // example read from the dashboard itself), the evaluator computes
        // the exact single-day rate: numerator = first-time (10) +
        // redownload (2); auto-updates are excluded by Apple's Total
        // Downloads definition.
        let rate = ASCConversionRateEvaluator.evaluate(
            ASCConversionRateInputs(
                numeratorAppIdentifier: "1234567890",
                numeratorWindow: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!),
                downloadsAndPreOrders: 12,
                denominatorAppIdentifier: "1234567890",
                denominatorWindow: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!),
                uniqueDeviceImpressions: 150,
                impressionsDeduplicationDomainCount: 1,
                denominatorBasis: .assertedDashboardUniqueDevices
            )
        )
        XCTAssertEqual(
            rate,
            ASCConversionRateResult.available(
                rate: Decimal(string: "0.08")!, numerator: 12, denominator: 150
            )
        )
    }

    func testStoreQueryExample() async throws {
        let store = ASCInMemoryAnalyticsStore()
        let record = ASCDownloadRecord(
            date: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            appAppleIdentifier: "1234567890",
            rawDownloadType: "First-time Download",
            downloadType: .firstTimeDownload,
            territory: "US",
            counts: 10,
            isPreOrder: nil,
            extraFields: [:]
        )
        let provenance = ASCReportProvenance(
            sourceKind: .analyticsDownloads,
            instanceID: "i1",
            processingDate: "2025-10-02",
            granularity: .daily,
            schemaFingerprint: "fp",
            contentChecksum: "cc",
            fetchedAt: Date(),
            recordCount: 1
        )
        let key = ASCIngestionKey(sourceKind: .analyticsDownloads, instanceID: "i1")
        try await store.withTransaction { transaction in
            try await transaction.insertDownloads(
                [ASCProvenancedRecord(record: record, provenance: provenance)],
                ingestionKey: key
            )
            try await transaction.upsertIngestion(ASCIngestionEntry(
                key: key, state: .imported,
                processingDate: "2025-10-02", granularity: .daily,
                schemaFingerprint: "fp", contentChecksum: "cc",
                recordCount: 1, importedAt: Date()
            ))
        }

        let records = try await store.downloadRecords(
            appIdentifiers: ["1234567890"],
            in: ASCDateRange(
                start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                end: ASCCalendarDate(iso8601Day: "2025-10-31")!
            )
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertNotNil(records[0].provenance.instanceID)

        let latest = ASCInstanceSelection.latestProcessingDatePerEventDate(records)
        XCTAssertEqual(latest.count, 1)
        let metrics = ASCDownloadMetrics(records: latest.map(\.record))
        XCTAssertEqual(metrics.firstTimeDownloads, 10)

        let completeness = ASCReportCompletenessThreshold.assess(
            eventDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            processingDate: ASCCalendarDate(iso8601Day: "2025-10-03")!,
            thresholdDays: ASCReportCompletenessThreshold.analyticsDownloadsDays
        )
        XCTAssertEqual(completeness, .complete)

        for metric in ASCMetricCatalog.allCases {
            switch metric.supportStatus {
            case .supported, .estimated, .unavailable, .unsupported:
                continue // every metric declares an explicit status
            }
        }
    }

    func testOfflineStubSyncExample() async throws {
        // The sync example from USAGE.md, executed end-to-end against the
        // offline stub: no credentials, no network.
        let provider = ASCStubReportProvider()
        let store = ASCInMemoryAnalyticsStore()
        let engine = ASCReportSyncEngine(provider: provider)

        let instance = ASCAnalyticsReportInstance(
            id: "i1",
            attributes: .init(granularity: .daily, processingDate: "2025-10-02")
        )
        let payload = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
        ])
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
                attributes: .init(checksum: "md5", sizeInBytes: nil, url: "https://example.invalid/seg")
            )]
        }
        provider.downloadAnalyticsReportSegmentHandler = { _ in payload }

        let analyticsResult = try await engine.syncAnalytics(
            ASCAnalyticsSyncConfiguration(appID: "app-1"),
            store: store
        )
        XCTAssertEqual(analyticsResult.importedCount, 1)

        let salesPayload = ASCFixtures.salesReport([
            ASCFixtures.salesLine(sku: "APPONE", productType: "1F", units: "5", proceeds: "0.70", customerPrice: "0.99")
        ])
        provider.downloadSalesReportHandler = { _ in salesPayload }
        let salesResult = try await engine.syncSales(
            ASCSalesSyncConfiguration(
                vendorNumber: "80000",
                frequency: .daily,
                reportDates: ["2025-10-01", "2025-10-02"]
            ),
            store: store
        )
        XCTAssertEqual(salesResult.outcomes.count, 2)

        // One record per synced report date, each with full provenance.
        let storedSales = try await store.salesRecords()
        XCTAssertEqual(storedSales.count, 2)
        XCTAssertEqual(storedSales[0].provenance.vendorNumber, "80000")
        XCTAssertEqual(Set(storedSales.map { $0.provenance.reportDate ?? "" }), ["2025-10-01", "2025-10-02"])
    }
}
