import Foundation

/// Per-currency gross customer sales, in `customerCurrency` of the
/// underlying rows. Amounts are `Decimal` and are only ever summed within
/// one currency.
public struct ASCGrossSalesByCurrency: Hashable, Codable, Sendable {
    /// Three-letter ISO currency code (uppercased for grouping).
    public let currency: String
    /// Σ (units × |customer price|) over rows in this currency; refunds and
    /// CMB-C credits contribute negative amounts.
    public let grossSales: Decimal
    /// Σ units over rows in this currency (signed: refunds are negative).
    public let units: Decimal
    /// Number of contributing records.
    public let recordCount: Int
}

/// Per-currency developer proceeds, in `Currency of Proceeds` of the
/// underlying rows.
public struct ASCDeveloperProceedsByCurrency: Hashable, Codable, Sendable {
    /// Three-letter ISO currency code (uppercased for grouping).
    public let currency: String
    /// Σ (units × |developer proceeds per unit|). Apple publishes proceeds
    /// as a per-unit value; it is multiplied by units per row, never summed
    /// as if it were a row total.
    public let proceeds: Decimal
    /// Σ units over rows in this proceeds currency (signed).
    public let units: Decimal
    /// Number of contributing records.
    public let recordCount: Int
}

/// Units by product classification. Unknown product types keep their own
/// bucket and raw identifiers; they are never folded into a known type.
public struct ASCSalesUnitBreakdown: Hashable, Codable, Sendable {
    public let appUnits: Decimal
    public let appBundleUnits: Decimal
    public let updateUnits: Decimal
    public let redownloadUnits: Decimal
    public let inAppPurchaseUnits: Decimal
    public let autoRenewableSubscriptionUnits: Decimal
    public let nonRenewingSubscriptionUnits: Decimal
    public let restoredInAppPurchaseUnits: Decimal
    /// Units of rows whose `Product Type Identifier` is not in Apple's
    /// published table. Always inspect this alongside
    /// `unknownProductTypeIdentifiers` — a non-zero value means Apple
    /// introduced a type this package version does not know.
    public let unknownUnits: Decimal

    /// Σ of all buckets (units are counts and additive across types).
    public var totalUnits: Decimal {
        appUnits + appBundleUnits + updateUnits + redownloadUnits
            + inAppPurchaseUnits + autoRenewableSubscriptionUnits
            + nonRenewingSubscriptionUnits + restoredInAppPurchaseUnits
            + unknownUnits
    }

    public static let zero = ASCSalesUnitBreakdown(
        appUnits: 0, appBundleUnits: 0, updateUnits: 0, redownloadUnits: 0,
        inAppPurchaseUnits: 0, autoRenewableSubscriptionUnits: 0,
        nonRenewingSubscriptionUnits: 0, restoredInAppPurchaseUnits: 0,
        unknownUnits: 0
    )
}

/// Metrics computed over a set of Summary Sales report records.
///
/// Money arithmetic uses `Decimal` only. Gross sales are grouped by
/// Customer Currency and proceeds by Currency of Proceeds — the two are
/// different currency spaces and are never combined. There is deliberately
/// no cross-currency total.
public struct ASCSalesMetrics: Hashable, Codable, Sendable {
    /// Gross customer sales per Customer Currency, sorted by currency.
    public let grossSalesByCustomerCurrency: [ASCGrossSalesByCurrency]
    /// Developer proceeds per Currency of Proceeds, sorted by currency.
    public let developerProceedsByCurrency: [ASCDeveloperProceedsByCurrency]
    /// Units by product classification.
    public let unitBreakdown: ASCSalesUnitBreakdown
    /// Signed sum of units on refund and CMB-C credit rows (negative).
    public let refundAndCreditUnits: Decimal
    /// Units on rows whose customer price is 0 (free apps, developer
    /// codes, partial refunds).
    public let zeroPriceUnits: Decimal
    /// Sorted unique raw product type identifiers that were classified as
    /// unknown.
    public let unknownProductTypeIdentifiers: [String]
    /// Rows that could not be attributed to an app (for example in-app
    /// purchases with a blank Parent Identifier). They contribute to
    /// currency totals but not to any app grouping.
    public let unattributedRowCount: Int
    /// Count of zero-price, zero-proceeds rows for which
    /// Apple did not provide Currency of Proceeds.
    ///
    /// These rows still contribute to units and product
    /// breakdowns, but cannot be assigned to any proceeds
    /// currency bucket.
    public let zeroProceedsWithoutCurrencyRowCount: Int
    /// Number of records this metrics value was computed from.
    public let recordCount: Int

    /// Computes metrics over the given records.
    public init(records: [ASCSalesRecord]) {
        var grossByCurrency: [String: (amount: Decimal, units: Decimal, count: Int)] = [:]
        var proceedsByCurrency: [String: (amount: Decimal, units: Decimal, count: Int)] = [:]
        var appUnits = Decimal(0)
        var appBundleUnits = Decimal(0)
        var updateUnits = Decimal(0)
        var redownloadUnits = Decimal(0)
        var inAppPurchaseUnits = Decimal(0)
        var autoRenewableSubscriptionUnits = Decimal(0)
        var nonRenewingSubscriptionUnits = Decimal(0)
        var restoredInAppPurchaseUnits = Decimal(0)
        var unknownUnits = Decimal(0)
        var unknownIdentifiers = Set<String>()
        var refundUnits = Decimal(0)
        var zeroPriceUnits = Decimal(0)
        var unattributed = 0
        var zeroProceedsWithoutCurrencyRows = 0

        for record in records {
            let customerKey = record.customerCurrency.uppercased()

            // Customer Currency is required for every row.
            let gross = grossByCurrency[customerKey] ?? (0, 0, 0)

            grossByCurrency[customerKey] = (
                gross.amount + record.grossSalesImpact,
                gross.units + record.units,
                gross.count + 1
            )

            // Currency of Proceeds can be absent only on a
            // validated zero-price / zero-proceeds transaction.
            //
            // Do not invent a currency, and do not group such
            // records under an empty-string key.
            if let proceedsKey = record.proceedsCurrency?.uppercased() {
                let proceeds = proceedsByCurrency[proceedsKey] ?? (0, 0, 0)

                proceedsByCurrency[proceedsKey] = (
                    proceeds.amount + record.developerProceedsImpact,
                    proceeds.units + record.units,
                    proceeds.count + 1
                )
            } else {
                zeroProceedsWithoutCurrencyRows += 1
            }

            switch record.productType {
            case .app: appUnits += record.units
            case .appBundle: appBundleUnits += record.units
            case .update: updateUnits += record.units
            case .redownload: redownloadUnits += record.units
            case .inAppPurchase: inAppPurchaseUnits += record.units
            case .autoRenewableSubscription:
                autoRenewableSubscriptionUnits += record.units
            case .nonRenewingSubscription:
                nonRenewingSubscriptionUnits += record.units
            case .restoredInAppPurchase:
                restoredInAppPurchaseUnits += record.units
            case .unknown(let raw):
                unknownUnits += record.units
                unknownIdentifiers.insert(raw)
            }

            if record.isRefundOrCredit {
                refundUnits += record.units
            }
            if record.customerPrice == 0 {
                zeroPriceUnits += record.units
            }
            if case .unattributed = record.appAttribution {
                unattributed += 1
            }
        }

        self.grossSalesByCustomerCurrency = grossByCurrency
            .map { currency, values in
                ASCGrossSalesByCurrency(
                    currency: currency,
                    grossSales: values.amount,
                    units: values.units,
                    recordCount: values.count
                )
            }
            .sorted { $0.currency < $1.currency }

        self.developerProceedsByCurrency = proceedsByCurrency
            .map { currency, values in
                ASCDeveloperProceedsByCurrency(
                    currency: currency,
                    proceeds: values.amount,
                    units: values.units,
                    recordCount: values.count
                )
            }
            .sorted { $0.currency < $1.currency }

        self.unitBreakdown = ASCSalesUnitBreakdown(
            appUnits: appUnits,
            appBundleUnits: appBundleUnits,
            updateUnits: updateUnits,
            redownloadUnits: redownloadUnits,
            inAppPurchaseUnits: inAppPurchaseUnits,
            autoRenewableSubscriptionUnits: autoRenewableSubscriptionUnits,
            nonRenewingSubscriptionUnits: nonRenewingSubscriptionUnits,
            restoredInAppPurchaseUnits: restoredInAppPurchaseUnits,
            unknownUnits: unknownUnits
        )

        self.refundAndCreditUnits = refundUnits
        self.zeroPriceUnits = zeroPriceUnits
        self.unknownProductTypeIdentifiers = unknownIdentifiers.sorted()
        self.unattributedRowCount = unattributed
        self.recordCount = records.count
        self.zeroProceedsWithoutCurrencyRowCount =
            zeroProceedsWithoutCurrencyRows
    }

    /// Gross sales in exactly one Customer Currency.
    /// - Returns `nil` when no records in that currency are present —
    ///   deliberately not a fabricated zero.
    public func grossSales(currency: String) -> Decimal? {
        grossSalesByCustomerCurrency.first { $0.currency == currency.uppercased() }?.grossSales
    }

    /// Developer proceeds in exactly one Currency of Proceeds.
    /// - Returns `nil` when no records in that currency are present.
    public func developerProceeds(currency: String) -> Decimal? {
        developerProceedsByCurrency.first { $0.currency == currency.uppercased() }?.proceeds
    }

    /// A total across all currencies is structurally unavailable: summing
    /// amounts across currencies requires an explicit, recorded conversion
    /// step that this package does not perform.
    public var combinedGrossSalesAcrossCurrencies: ASCSupportStatus {
        if grossSalesByCustomerCurrency.count <= 1 {
            return .supported
        }
        return .unavailable(
            reason: "gross sales exist in \(grossSalesByCustomerCurrency.count) customer currencies; summing across currencies requires an explicit conversion step that ASCAPIAnalytics does not perform"
        )
    }
}
