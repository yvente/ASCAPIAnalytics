import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCDownloadsReportParserTests: XCTestCase {
    private let parser = ASCDownloadsReportParser()

    func testClassifiesDocumentedDownloadTypes() throws {
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "3"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Manual update", counts: "5"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Auto-update", counts: "20"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Restore", counts: "1"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records.count, 5)
        XCTAssertEqual(result.records[0].downloadType, ASCDownloadType.firstTimeDownload)
        XCTAssertEqual(result.records[1].downloadType, ASCDownloadType.redownload)
        XCTAssertEqual(result.records[2].downloadType, ASCDownloadType.manualUpdate)
        XCTAssertEqual(result.records[3].downloadType, ASCDownloadType.autoUpdate)
        XCTAssertEqual(result.records[4].downloadType, ASCDownloadType.restore)
    }

    func testUnknownDownloadTypeIsPreserved() throws {
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Some Future Type", counts: "2"),
        ])
        let result = try parser.parse(data)
        guard case .other(let raw) = result.records[0].downloadType else {
            return XCTFail("expected other, got \(result.records[0].downloadType)")
        }
        XCTAssertEqual(raw, "Some Future Type")
        XCTAssertEqual(result.records[0].rawDownloadType, "Some Future Type")

        let metrics = ASCDownloadMetrics(records: result.records)
        XCTAssertEqual(metrics.otherDownloadTypeCounts.first?.rawDownloadType, "Some Future Type")
        XCTAssertEqual(metrics.otherDownloadTypeCounts.first?.counts, 2)
        XCTAssertEqual(metrics.allCountsTotal, 2)
    }

    func testPreOrderFlagParsing() throws {
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "4", preOrder: "true"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "6", preOrder: "false"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "2"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records[0].isPreOrder, true)
        XCTAssertEqual(result.records[1].isPreOrder, false)
        XCTAssertEqual(result.records[2].isPreOrder, nil)

        let metrics = ASCDownloadMetrics(records: result.records)
        XCTAssertEqual(metrics.preOrderCounts, 4)
        XCTAssertEqual(metrics.firstTimeDownloads, 12)
        XCTAssertEqual(metrics.appleTotalDownloads, 12)
        XCTAssertEqual(metrics.downloadsAndPreOrders, 16)
    }

    func testExtraColumnsPreservedAndDetailColumnsTolerated() throws {
        var header = ASCFixtures.downloadsHeader
        header.append(contentsOf: ["Source Info", "Campaign", "Something New"])
        var fields = ASCFixtures.downloadsLine(
            date: "2025-10-01", downloadType: "First-time Download", counts: "1"
        ).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields.append(contentsOf: ["referral.app", "camp-1", "mystery"])
        let data = ASCFixtures.tsv([
            header.joined(separator: "\t"),
            fields.joined(separator: "\t"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records[0].extraFields["Source Info"], "referral.app")
        XCTAssertEqual(result.records[0].extraFields["Campaign"], "camp-1")
        XCTAssertEqual(result.records[0].extraFields["Something New"], "mystery")
    }

    func testCSVDelimiterAutoDetection() throws {
        let csv = "Date,App Apple Identifier,Download Type,Territory,Counts\n" +
            "2025-10-01,1234567890,First-time Download,US,7\n"
        let result = try parser.parse(Data(csv.utf8))
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].counts, 7)
    }

    func testGzipSegmentDecoded() throws {
        let tsv = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "9")
        ])
        let result = try parser.parse(ASCGzipFixture.gzip(payload: tsv))
        XCTAssertEqual(result.records[0].counts, 9)
    }

    func testMissingRequiredColumnThrows() {
        let csv = "Date,App Apple Identifier,Download Type,Territory\n2025-10-01,1,First-time Download,US\n"
        assertThrowsASCError(try parser.parse(Data(csv.utf8))) { error in
            XCTAssertEqual(error, .missingRequiredColumn(report: "App Downloads Report", column: "Counts"))
        }
    }

    func testAmbiguousDelimiterThrows() {
        let data = Data("no delimiters here\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .ambiguousDelimiter(report: "App Downloads Report", headerTabs: 0, headerCommas: 0))
        }
    }

    func testInvalidDateThrows() {
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "10/01/2025", downloadType: "First-time Download", counts: "1")
        ])
        assertThrowsASCError(try parser.parse(data)) { error in
            guard case .invalidFieldValue(_, let column, _, _, _) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(column, "Date")
        }
    }

    func testMetricsAcrossMixedRecords() throws {
        let data = ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", territory: "DE", counts: "5"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "3"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Auto-update", counts: "20"),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDownloadMetrics(records: result.records)
        XCTAssertEqual(metrics.firstTimeDownloads, 15)
        XCTAssertEqual(metrics.redownloads, 3)
        XCTAssertEqual(metrics.autoUpdates, 20)
        XCTAssertEqual(metrics.appleTotalDownloads, 18)
        XCTAssertEqual(metrics.recordCount, 4)
    }
}

final class ASCDiscoveryReportParserTests: XCTestCase {
    private let parser = ASCDiscoveryReportParser()

    func testEventClassification() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "100", uniqueCounts: "80"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Page view", counts: "60", uniqueCounts: "50"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Tap", counts: "12", uniqueCounts: "12"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Mystery Event", counts: "1", uniqueCounts: "1"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records[0].event, ASCDiscoveryEvent.impression)
        XCTAssertEqual(result.records[1].event, ASCDiscoveryEvent.pageView)
        XCTAssertEqual(result.records[2].event, ASCDiscoveryEvent.tap)
        guard case .other(let raw) = result.records[3].event else {
            return XCTFail("expected other")
        }
        XCTAssertEqual(raw, "Mystery Event")
    }

    func testCountsAndUniqueCountsStoredSeparately() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(
                date: "2025-10-01", event: "Impression", sourceType: "App Store search",
                counts: "100", uniqueCounts: "70"
            ),
            ASCFixtures.discoveryLine(
                date: "2025-10-01", event: "Impression", sourceType: "App Store browse",
                counts: "50", uniqueCounts: "40"
            ),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        // Counts are additive.
        XCTAssertEqual(metrics.impressionCounts, 150)
        XCTAssertEqual(metrics.totalEventCounts, 150)
        XCTAssertEqual(metrics.impressionCountsBySourceType.map(\.rawDownloadType), ["App Store browse", "App Store search"])
        XCTAssertEqual(metrics.impressionCountsBySourceType.first?.counts, 50)
        // Unique counts stay per domain and are never summed into a total.
        XCTAssertEqual(metrics.uniqueCountEntries.count, 2)
        guard case .unavailable(let reason) = metrics.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable combined unique counts")
        }
        XCTAssertTrue(reason.contains("2 deduplication domains"), reason)
    }

    func testUniqueCountsAbsentColumnIsNil() throws {
        var header = ASCFixtures.discoveryHeader.filter { $0 != "Unique Counts" }
        let line = [
            "2025-10-01", "App One", "1234567890", "Impression", "Product page",
            "App Store browse", "", "iPhone", "18.0", "US", "10",
        ].joined(separator: "\t")
        let data = ASCFixtures.tsv([header.joined(separator: "\t"), line])
        let result = try parser.parse(data)
        XCTAssertNil(result.records[0].uniqueCounts)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        guard case .unavailable = metrics.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable")
        }
    }

    func testSingleDomainUniqueCountsAreAvailable() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "100", uniqueCounts: "70"),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        XCTAssertEqual(metrics.combinedUniqueImpressionCounts, ASCSupportStatus.supported)
    }

    func testSameDateDifferentDimensionsAreDifferentDomains() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(
                date: "2025-10-01", event: "Impression", pageType: "Product page",
                counts: "10", uniqueCounts: "10"
            ),
            ASCFixtures.discoveryLine(
                date: "2025-10-01", event: "Impression", pageType: "Store sheet",
                counts: "10", uniqueCounts: "8"
            ),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        XCTAssertNotEqual(
            result.records[0].uniqueCountsDeduplicationKey,
            result.records[1].uniqueCountsDeduplicationKey
        )
        guard case .unavailable = metrics.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable across page types")
        }
    }

    func testDifferentDatesAreDifferentDomains() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "10", uniqueCounts: "10"),
            ASCFixtures.discoveryLine(date: "2025-10-02", event: "Impression", counts: "10", uniqueCounts: "9"),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        guard case .unavailable = metrics.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable across dates")
        }
    }

    func testDuplicateRowsInSameDomainAreNotCombined() throws {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "10", uniqueCounts: "10"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "10", uniqueCounts: "10"),
        ])
        let result = try parser.parse(data)
        let metrics = ASCDiscoveryMetrics(records: result.records)
        // Counts double (that is what the file says), but unique counts are
        // refused because combining identical-domain duplicates is not
        // understood well enough to be safe.
        XCTAssertEqual(metrics.impressionCounts, 20)
        guard case .unavailable = metrics.combinedUniqueImpressionCounts else {
            return XCTFail("expected unavailable for duplicate domain rows")
        }
    }

    func testMissingRequiredColumnThrows() {
        let data = ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "10", uniqueCounts: "5"),
        ])
        XCTAssertNoThrow(try parser.parse(data))

        var header = ASCFixtures.discoveryHeader
        header.removeAll { $0 == "Event" }
        let line = Array(repeating: "x", count: header.count).joined(separator: "\t")
        let badData = ASCFixtures.tsv([header.joined(separator: "\t"), line])
        assertThrowsASCError(try parser.parse(badData)) { error in
            XCTAssertEqual(error, .missingRequiredColumn(report: "App Store Discovery and Engagement Report", column: "Event"))
        }
    }
}
