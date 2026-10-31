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
        denominatorApp: String = "1234567890",
        basis: ASCImpressionBasis = .assertedDashboardUniqueDevices
    ) -> ASCConversionRateInputs {
        ASCConversionRateInputs(
            numeratorAppIdentifier: numeratorApp,
            numeratorWindow: window,
            downloadsAndPreOrders: downloads,
            denominatorAppIdentifier: denominatorApp,
            denominatorWindow: denominatorWindow ?? window,
            uniqueDeviceImpressions: impressions,
            impressionsDeduplicationDomainCount: domains,
            denominatorBasis: basis
        )
    }

    func testExactSingleDaySingleDomainWithAssertedBasis() {
        let result = ASCConversionRateEvaluator.evaluate(inputs())
        XCTAssertEqual(
            result,
            ASCConversionRateResult.available(
                rate: Decimal(string: "0.12")!, numerator: 12, denominator: 100
            )
        )
        XCTAssertEqual(result.ratePercent, Decimal(string: "12"))
    }

    func testDiscoveryReportBasisIsRefusedEvenWhenEverythingElseHolds() {
        // A single day, a single domain, correct app and window — the rate
        // is still refused because the denominator comes from the
        // Discovery report's impression events, which are narrower than
        // Apple's dashboard Impressions (they include unique product page
        // views) by an unknowable amount.
        let result = ASCConversionRateEvaluator.evaluate(inputs(basis: .discoveryReportImpressionEventsOnly))
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("impression events"), reason)
        XCTAssertTrue(reason.contains("product page views"), reason)
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

    func testMultiDayEstimateIsExplicitlyLabeledWithoutBoundClaim() {
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
        // The note must describe the approximation without claiming a
        // provable mathematical bound direction.
        XCTAssertTrue(note.contains("cross-day"), note)
        XCTAssertTrue(note.contains("cannot be proven"), note)
        XCTAssertFalse(note.lowercased().contains("lower bound"), note)
        XCTAssertFalse(note.lowercased().contains("upper bound"), note)
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
            inputs(window: window, denominatorWindow: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!))
        )
        guard case .unavailable = result else { return XCTFail("got \(result)") }
    }

    func testEstimateRefusedForReportDerivedBasis() {
        let window = ASCDateRange(
            start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
            end: ASCCalendarDate(iso8601Day: "2025-10-07")!
        )!
        let result = ASCConversionRateEvaluator.evaluateAllowingEstimate(
            inputs(window: window, basis: .discoveryReportImpressionEventsOnly)
        )
        guard case .unavailable(let reason) = result else { return XCTFail("got \(result)") }
        XCTAssertTrue(reason.contains("impression events"), reason)
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

    // MARK: - Aggregator

    func testAggregatorRefusesReportDerivedDenominatorWithPageViewEvents() throws {
        let downloads = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "Redownload", counts: "2"),
        ]))
        let discovery = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Page view", counts: "80", uniqueCounts: "60"),
        ]))

        let aggregator = ASCAnalyticsAggregator()
        let window = ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
        let result = aggregator.conversionRate(
            downloads: downloads.records,
            impressions: discovery.records,
            filter: ASCAnalyticsFilter(dateRange: window)
        )
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        // Basis failure: dashboard impressions include page views; the
        // two event types cannot be deduplicated into one device set.
        XCTAssertTrue(reason.contains("page view events"), reason)
    }

    func testAggregatorRefusesImpressionOnlyDenominator() throws {
        // Even with no page-view rows in the filtered set, the
        // impression-event denominator is narrower than Apple's dashboard
        // basis by an unknowable amount.
        let downloads = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(date: "2025-10-01", downloadType: "First-time Download", counts: "10"),
        ]))
        let discovery = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
        ]))
        let aggregator = ASCAnalyticsAggregator()
        let result = aggregator.conversionRate(
            downloads: downloads.records,
            impressions: discovery.records,
            filter: ASCAnalyticsFilter(
                dateRange: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
            )
        )
        guard case .unavailable(let reason) = result else {
            return XCTFail("expected unavailable, got \(result)")
        }
        XCTAssertTrue(reason.contains("narrower than Apple's basis"), reason)
    }

    func testAggregatorRefusesWithoutDateRange() throws {
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

    // MARK: - Pre-order semantics

    func testPreOrderFlaggedRowsAreNotDoubleCountedAsPreOrderPlacements() throws {
        // Apple: pre-orders count towards the conversion rate when
        // PLACED and "not counted again when it downloads". The downloads
        // report's Pre-Order flag marks downloads that came from a
        // pre-order — they are already inside the download-type buckets.
        // The metrics deliberately expose no property that adds them a
        // second time.
        let records = try ASCDownloadsReportParser().parse(ASCFixtures.downloadsReport([
            ASCFixtures.downloadsLine(
                date: "2025-10-01", downloadType: "First-time Download",
                counts: "4", preOrder: "true"
            ),
            ASCFixtures.downloadsLine(
                date: "2025-10-01", downloadType: "First-time Download",
                counts: "6", preOrder: "false"
            ),
        ])).records
        let metrics = ASCDownloadMetrics(records: records)
        XCTAssertEqual(metrics.firstTimeDownloads, 10)
        XCTAssertEqual(metrics.preOrderCounts, 4)
        XCTAssertEqual(metrics.appleTotalDownloads, 10)
    }

    func testCrossEventUniqueCountsAreNeverSummed() throws {
        // Impression and Page view are different events; their unique
        // device sets overlap in ways Apple does not publish. Each event
        // keeps its own per-domain unique counts and no API combines the
        // two event types into one device set.
        let records = try ASCDiscoveryReportParser().parse(ASCFixtures.discoveryReport([
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Impression", counts: "200", uniqueCounts: "150"),
            ASCFixtures.discoveryLine(date: "2025-10-01", event: "Page view", counts: "80", uniqueCounts: "60"),
        ])).records
        let metrics = ASCDiscoveryMetrics(records: records)
        XCTAssertEqual(metrics.impressionCounts, 200)
        XCTAssertEqual(metrics.pageViewCounts, 80)
        // Both events' unique counts are retained separately, keyed by
        // their own deduplication domains.
        XCTAssertEqual(metrics.uniqueCountEntries.count, 2)
        let events = Set(metrics.uniqueCountEntries.map(\.rawEvent))
        XCTAssertEqual(events, ["Impression", "Page view"])
        // The impression-event unique count (150) is a NARROWER basis than
        // Apple's dashboard impressions; the conversion rate helper must
        // refuse it (covered in the aggregator tests below). Nothing in
        // the metrics offers a combined impression+page-view unique total.
        XCTAssertEqual(metrics.combinedUniqueImpressionCounts, ASCSupportStatus.supported,
                       "the impression event's own single-domain value stays available")
        XCTAssertEqual(metrics.combinedUniquePageViewCounts, ASCSupportStatus.supported,
                       "the page view event's own single-domain value stays available")
    }

    func testMetricCatalogDocumentsCorrectedConversionRateDefinition() {
        // The catalog pins the corrected definition: downloads and
        // pre-orders over unique device impressions — NOT downloads over
        // product page views — and names the dashboard-basis caveat.
        XCTAssertTrue(ASCMetricCatalog.conversionRate.definition.contains("unique device impressions"))
        XCTAssertTrue(ASCMetricCatalog.conversionRate.definition.contains("include unique product page views"))
        XCTAssertFalse(ASCMetricCatalog.conversionRate.definition.contains("product page views divided"))
    }
}
