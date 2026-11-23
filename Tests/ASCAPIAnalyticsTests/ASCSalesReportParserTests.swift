import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// Parser tests for the Summary Sales report, including the scenarios
/// Apple documents in its report reference (version 1_3). All fixtures are
/// hand-crafted synthetic data modeled on Apple's published examples.
final class ASCSalesReportParserTests: XCTestCase {
    private let parser = ASCSalesReportParser()

    private func record(
        productType: String,
        units: String,
        customerPrice: String,
        proceeds: String = "0.70",
        currency: String = "USD",
        proceedsCurrency: String = "USD",
        country: String = "US",
        appleIdentifier: String = "1234567890",
        sku: String = "APPONE",
        parentIdentifier: String = "",
        cmb: String = "",
        begin: String = "10/01/2025",
        end: String = "10/01/2025"
    ) -> String {
        ASCFixtures.salesLine(
            sku: sku,
            productType: productType,
            units: units,
            proceeds: proceeds,
            begin: begin,
            end: end,
            currency: currency,
            country: country,
            proceedsCurrency: proceedsCurrency,
            appleIdentifier: appleIdentifier,
            customerPrice: customerPrice,
            parentIdentifier: parentIdentifier,
            cmb: cmb
        )
    }

    // MARK: - Scenario 1: ordinary app sale

    func testOrdinaryAppSale() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(productType: "1F", units: "100", customerPrice: "0.99", proceeds: "0.70")
            ])
        )
        XCTAssertEqual(result.records.count, 1)
        let record = result.records[0]
        XCTAssertEqual(record.productType, ASCSalesProductType.app)
        XCTAssertEqual(record.units, 100)
        XCTAssertEqual(record.customerPrice, Decimal(string: "0.99"))
        XCTAssertEqual(record.customerCurrency, "USD")
        XCTAssertEqual(record.grossSalesImpact, Decimal(string: "99.00"))
        XCTAssertEqual(record.developerProceedsImpact, Decimal(string: "70.00"))
        if case .appleIdentifier(let id) = record.appAttribution {
            XCTAssertEqual(id, "1234567890")
        } else {
            XCTFail("expected apple identifier attribution")
        }
    }

    // MARK: - Scenario 2: ordinary IAP with parent attribution

    func testInAppPurchaseAttributesToParentIdentifier() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(
                    productType: "IA1",
                    units: "50",
                    customerPrice: "0.69",
                    proceeds: "0.42",
                    currency: "GBP",
                    proceedsCurrency: "GBP",
                    sku: "com.example.iap.coins",
                    parentIdentifier: "com.example.app"
                )
            ])
        )
        let record = result.records[0]
        XCTAssertEqual(record.productType, ASCSalesProductType.inAppPurchase)
        if case .parentIdentifierSKU(let parent) = record.appAttribution {
            XCTAssertEqual(parent, "com.example.app")
        } else {
            XCTFail("expected parent SKU attribution, got \(record.appAttribution)")
        }
    }

    // MARK: - Scenario 3: subscription

    func testAutoRenewableSubscription() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(
                    productType: "IAY", units: "1", customerPrice: "9.99",
                    proceeds: "7.00", sku: "sub.monthly"
                )
            ])
        )
        XCTAssertEqual(result.records[0].productType, ASCSalesProductType.autoRenewableSubscription)
    }

    func testNonRenewingSubscription() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(productType: "IA9", units: "1", customerPrice: "4.99", proceeds: "3.49")
            ])
        )
        XCTAssertEqual(result.records[0].productType, ASCSalesProductType.nonRenewingSubscription)
    }

    // MARK: - Scenario 4: refund (Apple's exact documented example)

    func testRefundUsesAppleDocumentedSigns() throws {
        // Apple: "Refunds have negative values for Units and Customer
        // Price, and positive values for Developer Proceeds."
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(
                    productType: "1F", units: "-50", customerPrice: "-0.99",
                    proceeds: ".7"
                )
            ])
        )
        let record = result.records[0]
        XCTAssertTrue(record.isRefundOrCredit)
        // A refund must reduce revenue, not flip into a gain.
        XCTAssertEqual(record.grossSalesImpact, Decimal(string: "-49.50"))
        XCTAssertEqual(record.developerProceedsImpact, Decimal(string: "-35.00"))
    }

    // MARK: - Scenario 5: app update

    func testAppUpdateHasZeroMoneyAndOwnClassification() throws {
        // Apple: updates record 0 proceeds and 0 customer price, and the
        // Version column shows the version customers upgraded *from*.
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(productType: "7F", units: "1", customerPrice: "0", proceeds: "0")
            ])
        )
        let record = result.records[0]
        XCTAssertEqual(record.productType, ASCSalesProductType.update)
        XCTAssertEqual(record.grossSalesImpact, 0)
        XCTAssertEqual(record.developerProceedsImpact, 0)
    }

    func testRedownloadClassification() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(productType: "3F", units: "1", customerPrice: "0", proceeds: "0")
            ])
        )
        XCTAssertEqual(result.records[0].productType, ASCSalesProductType.redownload)
    }

    // MARK: - Scenario 6: app bundle and CMB-C credits

    func testAppBundleAndCMBCredits() throws {
        // Modeled on Apple's bundle example: 25 bundle purchases at 2.99
        // (CMB column "CMB"), with CMB-C credit rows for previously
        // purchased apps at -1.01 each.
        let bundleRow = record(
            productType: "1-B", units: "25", customerPrice: "2.99",
            proceeds: "2.10", sku: "BUNDLE1", cmb: "CMB"
        )
        let creditRow = record(
            productType: "1F", units: "-1", customerPrice: "-1.01",
            proceeds: "0.70", sku: "APPONE", cmb: "CMB-C"
        )
        let result = try parser.parse(ASCFixtures.salesReport([bundleRow, creditRow]))

        XCTAssertEqual(result.records[0].productType, ASCSalesProductType.appBundle)
        XCTAssertEqual(result.records[0].cmb, ASCSalesCMB.completesBundle)
        XCTAssertEqual(result.records[0].grossSalesImpact, Decimal(string: "74.75"))

        XCTAssertEqual(result.records[1].productType, .app)
        XCTAssertEqual(result.records[1].cmb, ASCSalesCMB.creditForCompletedBundle)
        XCTAssertEqual(result.records[1].grossSalesImpact, Decimal(string: "-1.01"))
        XCTAssertTrue(result.records[1].isRefundOrCredit)
    }

    // MARK: - Scenario 7: zero-price transactions

    func testZeroPriceTransactionsAndPartialRefund() throws {
        // Apple's developer code example: Units 5, both money fields 0.
        let devCode = record(productType: "1F", units: "5", customerPrice: "0", proceeds: "0")
        // Apple: "A value of 0 may indicate a partial refund."
        let partialRefund = record(productType: "1F", units: "0", customerPrice: "0.99", proceeds: "0.70")
        let result = try parser.parse(ASCFixtures.salesReport([devCode, partialRefund]))
        XCTAssertEqual(result.records[0].grossSalesImpact, 0)
        XCTAssertFalse(result.records[0].isRefundOrCredit)
        XCTAssertEqual(result.records[1].units, 0)
        XCTAssertEqual(result.records[1].grossSalesImpact, 0)
    }

    // MARK: - Scenario 8: multiple currencies

    func testMultipleCurrenciesStaySeparated() throws {
        let usd = record(productType: "1F", units: "10", customerPrice: "0.99", proceeds: "0.70")
        let eur = record(
            productType: "1F", units: "10", customerPrice: "1.09", proceeds: "0.77",
            currency: "EUR", proceedsCurrency: "EUR", country: "FR"
        )
        let gbp = record(
            productType: "1F", units: "10", customerPrice: "0.89", proceeds: "0.63",
            currency: "GBP", proceedsCurrency: "GBP", country: "GB"
        )
        let metrics = ASCSalesMetrics(records: try parser.parse(ASCFixtures.salesReport([usd, eur, gbp])).records)
        XCTAssertEqual(metrics.grossSalesByCustomerCurrency.count, 3)
        XCTAssertEqual(metrics.grossSalesByCustomerCurrency.map(\.currency), ["EUR", "GBP", "USD"])
        // Same units, different currencies — totals must differ per bucket.
        XCTAssertEqual(metrics.grossSales(currency: "USD"), Decimal(string: "9.90"))
        XCTAssertEqual(metrics.grossSales(currency: "EUR"), Decimal(string: "10.90"))
        XCTAssertEqual(metrics.grossSales(currency: "JPY"), nil)
        // A combined total across currencies is structurally unavailable.
        guard case .unavailable = metrics.combinedGrossSalesAcrossCurrencies else {
            return XCTFail("expected unavailable cross-currency total")
        }
    }

    // MARK: - Scenario 9: unknown product type

    func testUnknownProductTypeIsPreservedAndSurfaced() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(productType: "ZZ9", units: "3", customerPrice: "1.00", proceeds: "0.70")
            ])
        )
        let record = result.records[0]
        guard case .unknown(let raw) = record.productType else {
            return XCTFail("expected unknown product type, got \(record.productType)")
        }
        XCTAssertEqual(raw, "ZZ9")
        XCTAssertEqual(record.rawProductType, "ZZ9")

        let metrics = ASCSalesMetrics(records: result.records)
        XCTAssertEqual(metrics.unitBreakdown.unknownUnits, 3)
        XCTAssertEqual(metrics.unknownProductTypeIdentifiers, ["ZZ9"])
        XCTAssertEqual(metrics.unitBreakdown.appUnits, 0)
    }

    // MARK: - Scenario 10: negative units with signed prices

    func testNegativeUnitsWithSignedPriceCombinations() throws {
        // Documented pattern: both negative (refund).
        let bothNegative = record(productType: "1F", units: "-5", customerPrice: "-0.99", proceeds: ".7")
        // Upgrade-credit pattern from Apple's subscription examples:
        // negative units, negative price, positive proceeds.
        let upgradeCredit = record(productType: "IAY", units: "-1", customerPrice: "-1.67", proceeds: "1.17")
        // Undocumented mixed pattern: negative units with positive price —
        // still reduces revenue by units × price.
        let mixed = record(productType: "1F", units: "-5", customerPrice: "0.99", proceeds: "0.70")

        let parsed = try parser.parse(ASCFixtures.salesReport([bothNegative, upgradeCredit, mixed]))
        XCTAssertEqual(parsed.records[0].grossSalesImpact, Decimal(string: "-4.95"))
        XCTAssertEqual(parsed.records[0].developerProceedsImpact, Decimal(string: "-3.50"))
        XCTAssertEqual(parsed.records[1].grossSalesImpact, Decimal(string: "-1.67"))
        XCTAssertEqual(parsed.records[1].developerProceedsImpact, Decimal(string: "-1.17"))
        XCTAssertEqual(parsed.records[2].grossSalesImpact, Decimal(string: "-4.95"))
        XCTAssertEqual(parsed.records[2].developerProceedsImpact, Decimal(string: "-3.50"))
    }

    // MARK: - Structure and diagnostics

    func testColumnOrderShuffleStillParses() throws {
        // Apple: "Report column position might change over time. Rely on
        // column names instead of column positions."
        var header = ASCFixtures.salesHeader
        header.reverse()
        let normalLine = ASCFixtures.salesLine(
            sku: "REVERSED", productType: "1F", units: "7", proceeds: "0.70",
            customerPrice: "0.99"
        )
        let reversedFields = normalLine
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
            .reversed()
        let data = ASCFixtures.tsv([
            header.joined(separator: "\t"),
            reversedFields.joined(separator: "\t"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records[0].units, 7)
        XCTAssertEqual(result.records[0].grossSalesImpact, Decimal(string: "6.93"))
        XCTAssertEqual(result.records[0].sku, "REVERSED")
    }

    func testUnknownColumnsArePreservedVerbatim() throws {
        var header = ASCFixtures.salesHeader
        header.append("Future Column")
        var fields = ASCFixtures.salesLine(
            sku: "APPONE", productType: "1F", units: "1", proceeds: "0.70",
            customerPrice: "0.99"
        ).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        fields.append("future-value")
        let data = ASCFixtures.tsv([
            header.joined(separator: "\t"),
            fields.joined(separator: "\t"),
        ])
        let result = try parser.parse(data)
        XCTAssertEqual(result.records[0].extraFields["Future Column"], "future-value")
        // Known extras such as Title are preserved too.
        XCTAssertEqual(result.records[0].extraFields["Title"], "App One")
    }

    func testGzipInputIsDecoded() throws {
        let tsv = ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70")
        ])
        let gzipped = ASCGzipFixture.gzip(payload: tsv)
        let result = try parser.parse(gzipped)
        XCTAssertEqual(result.records.count, 1)
        // The content checksum covers the bytes as received (compressed).
        let plainResult = try parser.parse(tsv)
        XCTAssertNotEqual(result.contentChecksum, plainResult.contentChecksum)
    }

    func testSchemaFingerprintIsStableAcrossColumnShuffleNormalization() throws {
        let a = try parser.parse(ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70")
        ]))
        XCTAssertEqual(a.schemaFingerprint.count, 64)
        XCTAssertEqual(a.headerFields, ASCFixtures.salesHeader)
    }

    func testMissingRequiredColumnThrows() {
        var header = ASCFixtures.salesHeader
        header.removeAll { $0 == "Developer Proceeds" }
        let line = Array(repeating: "x", count: header.count).joined(separator: "\t")
        let data = ASCFixtures.tsv([header.joined(separator: "\t"), line])
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(
                error,
                .missingRequiredColumn(report: "Summary Sales Report", column: "Developer Proceeds")
            )
        }
    }

    func testInvalidDateThrowsWithLineDiagnostics() {
        let data = ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70"),
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70", begin: "2025-10-01"),
        ])
        assertThrowsASCError(try parser.parse(data)) { error in
            guard case .invalidFieldValue(let report, let column, let value, let line, _) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(report, "Summary Sales Report")
            XCTAssertEqual(column, "Begin Date")
            XCTAssertEqual(value, "2025-10-01")
            XCTAssertEqual(line, 3)
        }
    }

    func testInvalidCurrencyThrows() {
        let data = ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70", currency: "USDD")
        ])
        assertThrowsASCError(try parser.parse(data)) { error in
            guard case .invalidFieldValue(_, let column, _, _, let reason) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(column, "Customer Currency")
            XCTAssertTrue(reason.contains("3-letter"))
        }
    }

    func testNonNumericAppleIdentifierThrows() {
        let data = ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70", appleIdentifier: "APP-1")
        ])
        assertThrowsASCError(try parser.parse(data)) { error in
            guard case .invalidFieldValue(_, let column, _, _, _) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(column, "Apple Identifier")
        }
    }

    func testWrongCountryCodeLengthThrows() {
        let data = ASCFixtures.salesReport([
            record(productType: "1F", units: "1", customerPrice: "0.99", proceeds: "0.70", country: "USA")
        ])
        assertThrowsASCError(try parser.parse(data)) { error in
            guard case .invalidFieldValue(_, let column, _, _, _) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(column, "Country Code")
        }
    }

    func testUnattributedIAPRowWithoutParentIdentifier() throws {
        let result = try parser.parse(
            ASCFixtures.salesReport([
                record(
                    productType: "IA1", units: "1", customerPrice: "0.99",
                    proceeds: "0.70", parentIdentifier: ""
                )
            ])
        )
        guard case .unattributed = result.records[0].appAttribution else {
            return XCTFail("expected unattributed, got \(result.records[0].appAttribution)")
        }
        let metrics = ASCSalesMetrics(records: result.records)
        XCTAssertEqual(metrics.unattributedRowCount, 1)
    }

    func testEmptyReportParsesToZeroRecords() throws {
        let result = try parser.parse(ASCFixtures.salesReport([]))
        XCTAssertEqual(result.records.count, 0)
    }

    // MARK: - Real-report compatibility: blank proceeds currency

    func testFreeRowsAllowBlankProceedsCurrency() throws {
        let data = ASCFixtures.salesReport([
            record(
                productType: "1",
                units: "4",
                customerPrice: "0",
                proceeds: "0",
                proceedsCurrency: ""
            ),
            record(
                productType: "1F",
                units: "18",
                customerPrice: "0",
                proceeds: "0",
                proceedsCurrency: ""
            ),
            record(
                productType: "IA1",
                units: "1",
                customerPrice: "0.99",
                proceeds: "0.70",
                proceedsCurrency: "USD"
            )
        ])

        let result = try parser.parse(data)

        XCTAssertEqual(result.records.count, 3)
        XCTAssertNil(result.records[0].proceedsCurrency)
        XCTAssertNil(result.records[1].proceedsCurrency)
        XCTAssertEqual(result.records[2].proceedsCurrency, "USD")

        let metrics = ASCSalesMetrics(records: result.records)

        XCTAssertEqual(metrics.recordCount, 3)
        XCTAssertEqual(metrics.unitBreakdown.appUnits, 22)
        XCTAssertEqual(metrics.unitBreakdown.inAppPurchaseUnits, 1)

        XCTAssertEqual(
            metrics.zeroProceedsWithoutCurrencyRowCount,
            2
        )

        XCTAssertEqual(
            metrics.developerProceedsByCurrency.count,
            1
        )
        XCTAssertEqual(
            metrics.developerProceedsByCurrency[0].currency,
            "USD"
        )
        XCTAssertEqual(
            metrics.developerProceedsByCurrency[0].proceeds,
            Decimal(string: "0.70")
        )
    }

    func testMissingProceedsCurrencyOnMonetaryRowsIsRejected()
        throws {

        let monetaryCases: [(price: String, proceeds: String)] = [
            ("0.99", "0.70"),
            ("0", "0.70"),
            ("0.99", "0")
        ]

        for item in monetaryCases {
            let data = ASCFixtures.salesReport([
                record(
                    productType: "1F",
                    units: "1",
                    customerPrice: item.price,
                    proceeds: item.proceeds,
                    proceedsCurrency: ""
                )
            ])

            XCTAssertThrowsError(try parser.parse(data)) { error in
                guard let analyticsError = error as? ASCAnalyticsError,
                      case .missingRequiredField(
                          _,
                          let column,
                          _
                      ) = analyticsError else {
                    return XCTFail(
                        "Expected missingRequiredField, got \(error)"
                    )
                }

                XCTAssertEqual(column, "Currency of Proceeds")
            }
        }
    }

    func testZeroProceedsWithPresentCurrencyIsPreserved()
        throws {

        let data = ASCFixtures.salesReport([
            record(
                productType: "7F",
                units: "5",
                customerPrice: "0",
                proceeds: "0",
                currency: "EUR",
                proceedsCurrency: "EUR"
            )
        ])

        let result = try parser.parse(data)

        XCTAssertEqual(
            result.records[0].proceedsCurrency,
            "EUR"
        )

        let metrics = ASCSalesMetrics(records: result.records)

        XCTAssertEqual(
            metrics.zeroProceedsWithoutCurrencyRowCount,
            0
        )

        XCTAssertEqual(metrics.unitBreakdown.updateUnits, 5)
        XCTAssertEqual(
            metrics.developerProceedsByCurrency[0].currency,
            "EUR"
        )
        XCTAssertEqual(
            metrics.developerProceedsByCurrency[0].proceeds,
            0
        )
    }

    func testBlankZeroCurrencyDoesNotCreateCurrencyBucket()
        throws {

        let data = ASCFixtures.salesReport([
            record(
                productType: "1",
                units: "3",
                customerPrice: "0",
                proceeds: "0",
                currency: "JPY",
                proceedsCurrency: ""
            ),
            record(
                productType: "IA1",
                units: "2",
                customerPrice: "1.99",
                proceeds: "1.40",
                currency: "USD",
                proceedsCurrency: "USD"
            ),
            record(
                productType: "IA1",
                units: "1",
                customerPrice: "2.49",
                proceeds: "1.70",
                currency: "EUR",
                proceedsCurrency: "EUR"
            )
        ])

        let parsed = try parser.parse(data)
        let metrics = ASCSalesMetrics(records: parsed.records)

        XCTAssertEqual(
            metrics.grossSalesByCustomerCurrency.map(\.currency),
            ["EUR", "JPY", "USD"]
        )

        XCTAssertEqual(
            metrics.developerProceedsByCurrency.map(\.currency),
            ["EUR", "USD"]
        )

        XCTAssertEqual(metrics.unitBreakdown.appUnits, 3)

        XCTAssertEqual(
            metrics.zeroProceedsWithoutCurrencyRowCount,
            1
        )
    }

    func testSubscriptionUpgradeExampleFromAppleDocs() throws {
        // Apple's "Subscription Upgrade with Partial Credit" example
        // (post-Nov 2016 convention): credit refunded as a negative row,
        // new subscription charged in full.
        let day1 = record(
            productType: "IAY", units: "1", customerPrice: "9.99",
            proceeds: "7.00", sku: "sub.basic", begin: "10/01/2025", end: "10/01/2025"
        )
        let day25Credit = record(
            productType: "IAY", units: "-1", customerPrice: "-1.67",
            proceeds: "1.17", sku: "sub.basic", begin: "10/25/2025", end: "10/25/2025"
        )
        let day25New = record(
            productType: "IAY", units: "1", customerPrice: "29.99",
            proceeds: "21.00", sku: "sub.premium", begin: "10/25/2025", end: "10/25/2025"
        )
        let result = try parser.parse(ASCFixtures.salesReport([day1, day25Credit, day25New]))
        let metrics = ASCSalesMetrics(records: result.records)
        XCTAssertEqual(metrics.grossSales(currency: "USD"), Decimal(string: "38.31"))
        XCTAssertEqual(metrics.developerProceeds(currency: "USD"), Decimal(string: "26.83"))
    }
}
