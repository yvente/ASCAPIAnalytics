import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCConversionRateTests: XCTestCase {
    private func inputs(
        window: ASCDateRange = .singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!),
        denominatorWindow: ASCDateRange? = nil,
        downloads: Int = 12,
        impressions: Int? = 100,
        domains: Int = 1,
        numeratorApp: String = "1234567890",
        denominatorApp: String = "1234567890"
    ) -> ASCConversionRateInputs {
        ASCConversionRateInputs(
            numeratorAppIdentifier: numeratorApp,
            numeratorWindow: window,
            downloadsAndPreOrders: downloads,
            denominatorAppIdentifier: denominatorApp,
            denominatorWindow: denominatorWindow ?? window,
            uniqueDeviceImpressions: impressions,
            impressionsDeduplicationDomainCount: domains
        )
    }

    func testExactSingleDaySingleDomain() {
        let result = ASCConversionRateEvaluator.evaluate(inputs())
        XCTAssertEqual(
            result,
            ASCConversionRateResult.available(
                rate: Decimal(string: "0.12")!, numerator: 12, denominator: 100
            )
        )
        XCTAssertEqual(result.ratePercent, Decimal(string: "12"))
    }

    func testWindowMismatchIsUnavailable() {
        let window = ASCDateRange(
            start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            end: ASCCalendarDate(iso8601Day: "2025-10-07")!
        )!
        let denominatorWindow = ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
        let result = ASCConversionRateEvaluator.evaluate(
            inputs(window: window, denominatorWindow: denominatorWindow)
        )
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("window"), reason)
    }

    func testAppMismatchIsUnavailable() {
        let result = ASCConversionRateEvaluator.evaluate(
            inputs(numeratorApp: "1", denominatorApp: "2")
        )
        guard case .unavailable = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
    }

    func testMissingImpressionsIsUnavailable() {
        let result = ASCConversionRateEvaluator.evaluate(inputs(impressions: nil))
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testZeroImpressionsIsUnavailableNotZeroRate() {
        let result = ASCConversionRateEvaluator.evaluate(inputs(impressions: 0))
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testMultiDomainIsUnavailable() {
        let result = ASCConversionRateEvaluator.evaluate(inputs(domains: 3))
        guard case .unavailable(let reason) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(reason.contains("deduplication domains"), reason)
    }

    func testMultiDayIsUnavailableForExactEvaluation() {
        let window = ASCDateRange(
            start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            end: ASCCalendarDate(iso8601Day: "2025-10-07")!
        )!
        let result = ASCConversionRateEvaluator.evaluate(inputs(window: window))
        guard case .unavailable(let reason) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(reason.contains("7 days"), reason)
    }

    func testMultiDayEstimateIsExplicitlyLabeled() {
        let window = ASCDateRange(
            start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            end: ASCCalendarDate(iso8601Day: "2025-10-07")!
        )!
        let result = ASCConversionRateEvaluator.evaluateAllowingEstimate(
            inputs(window: window, downloads: 7, impressions: 700)
        )
        guard case .estimated(let rate, let numerator, let denominator, let note) = result else {
            return XCTFail("expected estimated, got \(result)")
        }
        XCTAssertEqual(rate, Decimal(string: "0.01")!)
        XCTAssertEqual(numerator, 7)
        XCTAssertEqual(denominator, 700)
        XCTAssertTrue(note.contains("upper bound"), note)
        XCTAssertTrue(note.contains("7 days"), note)
    }

    func testEstimateRefusedForDimensionSplits() {
        // A dimension split cannot be fixed by an estimate: even the
        // direction of the error is unknown.
        let result = ASCConversionRateEvaluator.evaluateAllowingEstimate(inputs(domains: 4))
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testEstimateRefusedForWindowMismatch() {
        let window = ASCDateRange(
            start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            end: ASCCalendarDate(iso8601Day: "2025-10-07")!
        )!
        let result = ASCConversionRateEvaluator.evaluateAllowingEstimate(
            inputs(window: window, denominatorWindow: .singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!))
        )
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testDownloadToPaidFamilyIsUnsupported() {
        for day in [1, 7, 35] {
            let status = ASCDownloadToPaidStatus.status(day: day)
            guard case .unsupported(let reason) = status else {
                return XCTFail("expected unsupported, got \(status)")
            }
            XCTAssertTrue(reason.contains("cohort"), reason)
        }
    }

    func testConversionRateViaAggregator() throws {
        // Single day, single impression row: exactly computable.
        let downloads = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "2"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Auto-update", counts: "100"),
        ]))
        let discovery = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
        ]))

        let aggregator = ASCAnalyticsAggregator()
        let window = ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
        let filter = ASCAnalyticsFilter(dateRange: window)
        let result = aggregator.conversionRate(
            downloads: downloads.records,
            impressions: discovery.records,
            filter: filter
        )
        // Numerator: first-time (10) + redownload (2); auto-updates are
        // excluded by Apple's Total Downloads definition.
        XCTAssertEqual(
            result,
            ASCConversionRateResult.available(
                rate: Decimal(string: "0.08")!, numerator: 12, denominator: 150
            )
        )
    }

    func testConversionRateViaAggregatorRefusedWithoutDateRange() throws {
        let downloads = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
        ]))
        let discovery = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
        ]))
        let aggregator = ASCAnalyticsAggregator()
        let result = aggregator.conversionRate(
            downloads: downloads.records, impressions: discovery.records
        )
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testMetricCatalogDocumentsCorrectionOfConversionRateDefinition() {
        // The catalog pins the corrected definition: downloads and
        // pre-orders over unique device impressions — NOT downloads over
        // product page views.
        XCTAssertTrue(ASCMetricCatalog.conversionRate.definition.contains("unique device impressions"))
        XCTAssertFalse(ASCMetricCatalog.conversionRate.definition.contains("product page views divided"))
    }
}
