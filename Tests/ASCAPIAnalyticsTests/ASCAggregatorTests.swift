import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCSalesAggregatorTests: XCTestCase {
    private let aggregator = ASCSalesAggregator()

    private func makeRecord(
        appleIdentifier: String = "1001",
        parentIdentifier: String = "",
        productType: String = "1F",
        units: Decimal = 10,
        customerPrice: Decimal = 0.99,
        proceeds: Decimal = 0.70,
        currency: String = "USD",
        proceedsCurrency: String = "USD",
        country: String = "US",
        begin: ASCCalendarDate = ASCCalendarDate(iso8601Day: "2025-10-01")!
    ) -> ASCSalesRecord {
        ASCSalesRecord(
            beginDate: begin,
            endDate: begin,
            appleIdentifier: appleIdentifier,
            sku: "SKU-\(appleIdentifier)-\(productType)",
            parentIdentifier: parentIdentifier.isEmpty ? nil : parentIdentifier,
            rawProductType: productType,
            productType: ASCSalesProductType.classify(productType),
            units: units,
            customerPrice: customerPrice,
            customerCurrency: currency,
            developerProceeds: proceeds,
            proceedsCurrency: proceedsCurrency,
            countryCode: country,
            cmb: .none,
            extraFields: [:]
        )
    }

    func testDateAndTerritoryFilters() {
        let day1 = makeRecord()
        let day2 = makeRecord(begin: ASCCalendarDate(iso8601Day: "2025-10-02")!)
        let de = makeRecord(currency: "EUR", proceedsCurrency: "EUR", country: "DE")

        let range = ASCDateRange(start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
                                 end: ASCCalendarDate(iso8601Day: "2025-10-01")!)!
        let filtered = aggregator.summary([day1, day2, de], filter: ASCSalesFilter(
            dateRange: range, territories: ["US"]
        ))
        XCTAssertEqual(filtered.totals.recordCount, 1)
        XCTAssertEqual(filtered.totals.grossSales(currency: "USD"), Decimal(string: "9.90"))
    }

    func testAppFilterUsesAppleIdentifierForDirectRows() {
        let app1 = makeRecord(appleIdentifier: "1001")
        let app2 = makeRecord(appleIdentifier: "1002")
        let filtered = aggregator.summary([app1, app2], filter: ASCSalesFilter(
            appAppleIdentifiers: ["1001"]
        ))
        XCTAssertEqual(filtered.totals.recordCount, 1)
        XCTAssertEqual(filtered.byApp.count, 1)
        guard case .appleIdentifier(let id) = filtered.byApp[0].key else {
            return XCTFail("expected appleIdentifier key")
        }
        XCTAssertEqual(id, "1001")
    }

    func testParentIdentifierFilterForIAPRows() {
        let iap = makeRecord(appleIdentifier: "9999", parentIdentifier: "com.example.app", productType: "IA1")
        let filtered = aggregator.summary([iap], filter: ASCSalesFilter(
            parentIdentifiers: ["com.example.app"]
        ))
        XCTAssertEqual(filtered.totals.recordCount, 1)
        // Filtering by the app's own Apple identifier must NOT catch IAP
        // rows: the namespaces stay separated.
        let wrongFilter = aggregator.summary([iap], filter: ASCSalesFilter(
            appAppleIdentifiers: ["1001"]
        ))
        XCTAssertEqual(wrongFilter.totals.recordCount, 0)
    }

    func testByDayGrouping() {
        let day1 = makeRecord()
        let day1b = makeRecord(units: 1)
        let day2 = makeRecord(begin: ASCCalendarDate(iso8601Day: "2025-10-02")!)
        let summary = aggregator.summary([day1, day1b, day2])
        XCTAssertEqual(summary.byDay.count, 2)
        XCTAssertEqual(summary.byDay[0].metrics.recordCount, 2)
        XCTAssertEqual(summary.byDay[1].metrics.recordCount, 1)
    }

    func testUnknownProductTypesSurfaceInSummary() {
        let unknown = makeRecord(productType: "ZZ9")
        let summary = aggregator.summary([unknown])
        XCTAssertEqual(summary.totals.unknownProductTypeIdentifiers, ["ZZ9"])
        XCTAssertEqual(summary.totals.unitBreakdown.unknownUnits, 10)
    }

    func testRefundsNetAgainstSalesPerCurrency() {
        let sale = makeRecord(units: 100, customerPrice: 0.99, proceeds: 0.70)
        let refund = makeRecord(units: -50, customerPrice: -0.99, proceeds: 0.70)
        let summary = aggregator.summary([sale, refund])
        // 100 × 0.99 − 50 × 0.99 = 49.50; proceeds 100 × 0.70 − 50 × 0.70.
        XCTAssertEqual(summary.totals.grossSales(currency: "USD"), Decimal(string: "49.50"))
        XCTAssertEqual(summary.totals.developerProceeds(currency: "USD"), Decimal(string: "35"))
        XCTAssertEqual(summary.totals.refundAndCreditUnits, -50)
    }

    func testCurrencyFilterIsCaseInsensitive() {
        let record = makeRecord(currency: "USD")
        let filtered = aggregator.summary([record], filter: ASCSalesFilter(customerCurrencies: ["usd"]))
        XCTAssertEqual(filtered.totals.recordCount, 1)
    }

    func testProceedsBucketingFollowsProceedsCurrencyNotCustomerCurrency() {
        // A row where Apple reports proceeds in a different currency than
        // the customer price: the two spaces must not be merged.
        let record = makeRecord(
            customerPrice: 160, proceeds: 1.00,
            currency: "JPY", proceedsCurrency: "USD"
        )
        let summary = aggregator.summary([record])
        XCTAssertEqual(summary.totals.grossSalesByCustomerCurrency.map(\.currency), ["JPY"])
        XCTAssertEqual(summary.totals.developerProceedsByCurrency.map(\.currency), ["USD"])
        XCTAssertEqual(summary.totals.grossSales(currency: "JPY"), Decimal(string: "1600"))
        XCTAssertEqual(summary.totals.developerProceeds(currency: "USD"), Decimal(string: "10.00"))
    }
}

final class ASCAnalyticsAggregationTests: XCTestCase {
    private let aggregator = ASCAnalyticsAggregator()

    private func download(
        date: String, type: String, territory: String = "US", counts: Int,
        app: String = "1001", preOrder: Bool? = nil
    ) throws -> ASCDownloadRecord {
        let preOrderValue: String
        switch preOrder {
        case true: preOrderValue = "true"
        case false: preOrderValue = "false"
        case nil: preOrderValue = ""
        }
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(
                date: date, downloadType: type, territory: territory,
                counts: String(counts), appIdentifier: app, preOrder: preOrderValue
            )
        ])
        return try ASCDownloadsReportParser().parse(data).records[0]
    }

    private func discovery(
        date: String, event: String, counts: Int, unique: Int?,
        sourceType: String = "App Store browse", app: String = "1001"
    ) throws -> ASCDiscoveryRecord {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(
                date: date, event: event, sourceType: sourceType,
                counts: String(counts),
                uniqueCounts: unique.map(String.init) ?? "",
                appIdentifier: app
            )
        ])
        return try ASCDiscoveryReportParser().parse(data).records[0]
    }

    func testDownloadAggregationByDayAndTerritory() throws {
        let records = [
            try download(date: "2025-10-01", type: "First-time Download", counts: 10),
            try download(date: "2025-10-01", type: "First-time Download", territory: "DE", counts: 4),
            try download(date: "2025-10-02", type: "Redownload", counts: 2),
        ]
        let summary = aggregator.downloads(records)
        XCTAssertEqual(summary.totals.firstTimeDownloads, 14)
        XCTAssertEqual(summary.totals.redownloads, 2)
        XCTAssertEqual(summary.byDay.count, 2)
        XCTAssertEqual(summary.byDay[0].metrics.firstTimeDownloads, 14)
        XCTAssertEqual(summary.byTerritory.count, 2)
        XCTAssertEqual(summary.byTerritory.first?.territory, "DE")
        XCTAssertEqual(summary.byTerritory.first?.metrics.firstTimeDownloads, 4)
    }

    func testAppAndTerritoryFilters() throws {
        let records = [
            try download(date: "2025-10-01", type: "First-time Download", counts: 10, app: "1001"),
            try download(date: "2025-10-01", type: "First-time Download", counts: 3, app: "1002"),
            try download(date: "2025-10-01", type: "First-time Download", territory: "DE", counts: 5, app: "1003"),
        ]
        let byApp = aggregator.downloads(records, filter: ASCAnalyticsFilter(appIdentifiers: ["1001"]))
        XCTAssertEqual(byApp.totals.firstTimeDownloads, 10)
        let byTerritory = aggregator.downloads(records, filter: ASCAnalyticsFilter(territories: ["DE"]))
        XCTAssertEqual(byTerritory.totals.firstTimeDownloads, 5)
    }

    func testDiscoveryAggregationKeepsUniqueCountsPerDomain() throws {
        let records = [
            try discovery(date: "2025-10-01", event: "Impression", counts: 100, unique: 80),
            try discovery(date: "2025-10-02", event: "Impression", counts: 90, unique: 70),
        ]
        let summary = aggregator.discovery(records)
        XCTAssertEqual(summary.totals.impressionCounts, 190)
        XCTAssertEqual(summary.byDay.count, 2)
        XCTAssertEqual(summary.byDay[0].metrics.uniqueCountEntries.first?.uniqueCounts, 80)
        guard case .unavailable = summary.totals.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable across days")
        }
    }

    private func selectionEntry(
        app: String = "1001",
        date: String,
        processingDate: String?,
        counts: Int,
        reportID: String = "rep-1",
        fingerprint: String = "fp",
        granularity: ASCReportGranularity = .daily
    ) -> ASCProvenancedRecord<ASCDownloadRecord> {
        let record = ASCDownloadRecord(
            date: ASCCalendarDate(iso8601Day: date)!,
            appAppleIdentifier: app,
            rawDownloadType: "First-time Download",
            downloadType: .firstTimeDownload,
            territory: "US",
            counts: counts,
            isPreOrder: nil,
            extraFields: [:]
        )
        let provenance = ASCReportProvenance(
            sourceKind: .analyticsDownloads,
            reportName: "app-download",
            reportID: reportID,
            instanceID: "inst-\(processingDate ?? "none")-\(counts)",
            processingDate: processingDate,
            granularity: granularity,
            schemaFingerprint: fingerprint,
            contentChecksum: "cc-\(counts)",
            fetchedAt: Date(),
            recordCount: 1
        )
        return ASCProvenancedRecord(record: record, provenance: provenance)
    }

    func testLatestProcessingDateSelectionOverwritesPerEventDate() {
        // Apple: "Don't merge records for a Date across two report
        // instances to avoid double counting. Use the latest instance."
        let early = selectionEntry(date: "2025-10-01", processingDate: "2024-04-01", counts: 100)
        let late = selectionEntry(date: "2025-10-01", processingDate: "2024-04-02", counts: 120)
        let otherDay = selectionEntry(date: "2025-10-02", processingDate: "2024-04-01", counts: 50)

        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate([early, late, otherDay])
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.contains { $0.record.counts == 120 })
        XCTAssertTrue(selected.contains { $0.record.counts == 50 })
        XCTAssertFalse(selected.contains { $0.record.counts == 100 })

        // Records without a processing date lose against dated instances
        // but survive when nothing dated covers the day.
        let undated = selectionEntry(date: "2025-10-01", processingDate: nil, counts: 999)
        let withUndated = ASCInstanceSelection.latestProcessingDatePerEventDate([undated, late])
        XCTAssertEqual(withUndated.count, 1)
        XCTAssertEqual(withUndated[0].record.counts, 120)

        let onlyUndated = ASCInstanceSelection.latestProcessingDatePerEventDate([undated])
        XCTAssertEqual(onlyUndated.count, 1)
        XCTAssertEqual(onlyUndated[0].record.counts, 999)
    }

    func testSelectionNeverOverwritesAcrossApps() {
        // Same event date, same report, different apps: one app's later
        // correction must not overwrite the other app's data.
        let app1Early = selectionEntry(app: "1001", date: "2025-10-01", processingDate: "2024-04-01", counts: 10)
        let app1Late = selectionEntry(app: "1001", date: "2025-10-01", processingDate: "2024-04-02", counts: 12)
        let app2Early = selectionEntry(app: "2002", date: "2025-10-01", processingDate: "2024-04-01", counts: 30)
        let app2Late = selectionEntry(app: "2002", date: "2025-10-01", processingDate: "2024-04-05", counts: 33)

        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(
            [app1Early, app1Late, app2Early, app2Late]
        )
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.contains { $0.record.appAppleIdentifier == "1001" && $0.record.counts == 12 })
        XCTAssertTrue(selected.contains { $0.record.appAppleIdentifier == "2002" && $0.record.counts == 33 })
        XCTAssertFalse(selected.contains { $0.record.counts == 10 })
        XCTAssertFalse(selected.contains { $0.record.counts == 30 })
    }

    func testSelectionNeverOverwritesAcrossStandardAndDetailedVariants() {
        // Standard and detailed report variants describe the same events
        // with different schemas; a detailed correction must not overwrite
        // the standard data (callers pick one variant to aggregate).
        let standardEarly = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-01", counts: 10,
            fingerprint: "standard-header"
        )
        let standardLate = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-03", counts: 11,
            fingerprint: "standard-header"
        )
        let detailedEarly = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-01", counts: 10,
            reportID: "rep-1", fingerprint: "detailed-header"
        )
        let detailedLate = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-02", counts: 12,
            reportID: "rep-1", fingerprint: "detailed-header"
        )

        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(
            [standardEarly, standardLate, detailedEarly, detailedLate]
        )
        XCTAssertEqual(selected.count, 2, "each variant keeps its own latest instance")
        XCTAssertTrue(selected.contains { $0.provenance.schemaFingerprint == "standard-header" && $0.record.counts == 11 })
        XCTAssertTrue(selected.contains { $0.provenance.schemaFingerprint == "detailed-header" && $0.record.counts == 12 })
    }

    func testSelectionNeverOverwritesAcrossGranularities() {
        // Daily and weekly instances may share an anchor Date value; they
        // are different deduplication scopes.
        let dailyEarly = selectionEntry(
            date: "2025-09-30", processingDate: "2024-04-01", counts: 5,
            granularity: .daily
        )
        let dailyLate = selectionEntry(
            date: "2025-09-30", processingDate: "2024-04-02", counts: 6,
            granularity: .daily
        )
        let weekly = selectionEntry(
            date: "2025-09-30", processingDate: "2024-04-05", counts: 42,
            granularity: .weekly
        )

        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate(
            [dailyEarly, dailyLate, weekly]
        )
        XCTAssertEqual(selected.count, 2)
        XCTAssertTrue(selected.contains { $0.provenance.granularity == .daily && $0.record.counts == 6 })
        XCTAssertTrue(selected.contains { $0.provenance.granularity == .weekly && $0.record.counts == 42 })
    }

    func testSelectionNeverOverwritesAcrossReports() {
        // Two different reports (distinct report ids) with identical
        // schemas: corrections of one never overwrite the other.
        let reportA = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-01", counts: 7,
            reportID: "rep-A", fingerprint: "same-header"
        )
        let reportB = selectionEntry(
            date: "2025-10-01", processingDate: "2024-04-02", counts: 8,
            reportID: "rep-B", fingerprint: "same-header"
        )
        let selected = ASCInstanceSelection.latestProcessingDatePerEventDate([reportA, reportB])
        XCTAssertEqual(selected.count, 2)
    }

    func testEffectiveStoreQueriesApplySelectionPerGroup() async throws {
        let store = ASCInMemoryAnalyticsStore()
        let key = ASCIngestionKey(sourceKind: .analyticsDownloads, instanceID: "unused")

        func ingest(_ entry: ASCProvenancedRecord<ASCDownloadRecord>) async throws {
            try await store.withTransaction { transaction in
                try await transaction.insertDownloads([entry], ingestionKey: ASCIngestionKey(
                    sourceKind: .analyticsDownloads,
                    instanceID: entry.provenance.instanceID
                ))
                try await transaction.upsertIngestion(ASCIngestionEntry(
                    key: ASCIngestionKey(
                        sourceKind: .analyticsDownloads,
                        instanceID: entry.provenance.instanceID
                    ),
                    state: .imported,
                    processingDate: entry.provenance.processingDate,
                    granularity: entry.provenance.granularity,
                    schemaFingerprint: entry.provenance.schemaFingerprint,
                    contentChecksum: entry.provenance.contentChecksum,
                    recordCount: 1,
                    importedAt: Date()
                ))
            }
        }

        // Two apps, two processing dates each, plus a weekly record.
        try await ingest(selectionEntry(app: "1001", date: "2025-10-01", processingDate: "2024-04-01", counts: 10))
        try await ingest(selectionEntry(app: "1001", date: "2025-10-01", processingDate: "2024-04-02", counts: 12))
        try await ingest(selectionEntry(app: "2002", date: "2025-10-01", processingDate: "2024-04-01", counts: 30))
        try await ingest(selectionEntry(app: "2002", date: "2025-10-01", processingDate: "2024-04-05", counts: 33))
        try await ingest(selectionEntry(app: "2002", date: "2025-10-01", processingDate: "2024-04-06", counts: 99, granularity: .weekly))
        _ = key

        let effective = try await store.effectiveDownloadRecords()
        XCTAssertEqual(effective.count, 3, "latest per (app, report, variant, granularity, date)")
        XCTAssertTrue(effective.contains { $0.record.appAppleIdentifier == "1001" && $0.record.counts == 12 })
        XCTAssertTrue(effective.contains { $0.record.appAppleIdentifier == "2002" && $0.record.counts == 33 })
        XCTAssertTrue(effective.contains { $0.record.counts == 99 })

        // The per-app query path works too.
        let app1 = try await store.effectiveDownloadRecords(appIdentifiers: ["1001"])
        XCTAssertEqual(app1.count, 1)
        XCTAssertEqual(app1[0].record.counts, 12)
    }
}
