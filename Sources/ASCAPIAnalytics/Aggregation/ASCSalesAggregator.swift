import Foundation

/// Filter applied to Summary Sales records before aggregation.
///
/// Date filtering uses the record's Begin Date (Apple's transaction window
/// start). App filtering is split into two explicit key sets because the
/// two attribution namespaces must never be mixed: direct rows are keyed
/// by `Apple Identifier`, in-app purchase rows by `Parent Identifier`
/// (Apple: the SKU of the associated app).
public struct ASCSalesFilter: Hashable, Codable, Sendable {
    /// Keeps records whose Begin Date falls inside the range.
    public var dateRange: ASCDateRange?
    /// Keeps direct rows (apps, bundles, updates, re-downloads) whose
    /// `Apple Identifier` is in the set. `nil` disables the filter.
    public var appAppleIdentifiers: Set<String>?
    /// Keeps in-app purchase rows whose `Parent Identifier` is in the set.
    /// `nil` disables the filter.
    public var parentIdentifiers: Set<String>?
    /// Keeps records whose `Country Code` is in the set. `nil` disables
    /// the filter.
    public var territories: Set<String>?
    /// Keeps records whose `Customer Currency` is in the set
    /// (case-insensitive). `nil` disables the filter.
    public var customerCurrencies: Set<String>?
    /// Keeps records whose classified product type is in the set.
    /// `nil` disables the filter.
    public var productTypes: Set<ASCSalesProductType>?

    public init(
        dateRange: ASCDateRange? = nil,
        appAppleIdentifiers: Set<String>? = nil,
        parentIdentifiers: Set<String>? = nil,
        territories: Set<String>? = nil,
        customerCurrencies: Set<String>? = nil,
        productTypes: Set<ASCSalesProductType>? = nil
    ) {
        self.dateRange = dateRange
        self.appAppleIdentifiers = appAppleIdentifiers
        self.parentIdentifiers = parentIdentifiers
        self.territories = territories
        self.customerCurrencies = customerCurrencies
        self.productTypes = productTypes
    }

    /// Whether the record passes the filter.
    public func matches(_ record: ASCSalesRecord) -> Bool {
        if let range = dateRange, !range.contains(record.beginDate) {
            return false
        }
        if let identifiers = appAppleIdentifiers {
            var matches = false
            if case .appleIdentifier(let id) = record.appAttribution,
               identifiers.contains(id) {
                matches = true
            }
            if let parents = parentIdentifiers,
               case .parentIdentifierSKU(let sku) = record.appAttribution,
               parents.contains(sku) {
                matches = true
            }
            if !matches { return false }
        } else if let parents = parentIdentifiers {
            guard case .parentIdentifierSKU(let sku) = record.appAttribution,
                  parents.contains(sku)
            else { return false }
        }
        if let territories, !territories.contains(record.countryCode) {
            return false
        }
        if let customerCurrencies {
            let normalized = Set(customerCurrencies.map { $0.uppercased() })
            if !normalized.contains(record.customerCurrency.uppercased()) {
                return false
            }
        }
        if let productTypes, !productTypes.contains(record.productType) {
            return false
        }
        return true
    }

    /// Applies the filter to records.
    public func apply(_ records: [ASCSalesRecord]) -> [ASCSalesRecord] {
        records.filter { matches($0) }
    }
}

/// Metrics grouped by report day (Begin Date).
public struct ASCSalesDaySummary: Hashable, Codable, Sendable {
    public let date: ASCCalendarDate
    public let metrics: ASCSalesMetrics
}

/// The key an app group was formed on.
public enum ASCSalesAppKey: Hashable, Codable, Sendable {
    /// Grouped by the row's `Apple Identifier` (apps, bundles, updates,
    /// re-downloads).
    case appleIdentifier(String)
    /// Grouped by `Parent Identifier` (Apple: the SKU of the associated
    /// app) for in-app purchase rows.
    case parentSKU(String)
    /// Rows that could not be attributed.
    case unattributed
}

/// Metrics grouped by app attribution.
public struct ASCSalesAppSummary: Hashable, Codable, Sendable {
    public let key: ASCSalesAppKey
    public let metrics: ASCSalesMetrics
}

/// Account-level aggregation of Summary Sales records.
///
/// Totals, per-day, and per-app views all respect the currency rules:
/// amounts are bucketed per currency, and no cross-currency total exists.
public struct ASCSalesSummary: Hashable, Codable, Sendable {
    /// The filter that produced this summary.
    public let filter: ASCSalesFilter
    /// Metrics over all filtered records.
    public let totals: ASCSalesMetrics
    /// Per-day breakdown (by Begin Date), sorted by date.
    public let byDay: [ASCSalesDaySummary]
    /// Per-app breakdown by attribution key, sorted by key.
    public let byApp: [ASCSalesAppSummary]
}

/// Aggregates Summary Sales records under the package's currency and
/// additivity rules.
public struct ASCSalesAggregator: Sendable {
    public init() {}

    /// Aggregates records that pass `filter`.
    public func summary(
        _ records: [ASCSalesRecord], filter: ASCSalesFilter = ASCSalesFilter()
    ) -> ASCSalesSummary {
        let filtered = filter.apply(records)

        let totals = ASCSalesMetrics(records: filtered)

        var byDate: [ASCCalendarDate: [ASCSalesRecord]] = [:]
        var byApp: [ASCSalesAppKey: [ASCSalesRecord]] = [:]
        for record in filtered {
            byDate[record.beginDate, default: []].append(record)
            switch record.appAttribution {
            case .appleIdentifier(let id):
                byApp[.appleIdentifier(id), default: []].append(record)
            case .parentIdentifierSKU(let sku):
                byApp[.parentSKU(sku), default: []].append(record)
            case .unattributed:
                byApp[.unattributed, default: []].append(record)
            }
        }

        let byDay = byDate
            .map { ASCSalesDaySummary(date: $0.key, metrics: ASCSalesMetrics(records: $0.value)) }
            .sorted { $0.date < $1.date }

        let appSummaries = byApp
            .map { ASCSalesAppSummary(key: $0.key, metrics: ASCSalesMetrics(records: $0.value)) }
            .sorted { lhs, rhs in
                switch (lhs.key, rhs.key) {
                case (.appleIdentifier(let a), .appleIdentifier(let b)): return a < b
                case (.parentSKU(let a), .parentSKU(let b)): return a < b
                case (.appleIdentifier, _): return true
                case (_, .appleIdentifier): return false
                case (.parentSKU, _): return true
                case (_, .parentSKU): return false
                case (.unattributed, .unattributed): return false
                }
            }

        return ASCSalesSummary(
            filter: filter,
            totals: totals,
            byDay: byDay,
            byApp: appSummaries
        )
    }
}
