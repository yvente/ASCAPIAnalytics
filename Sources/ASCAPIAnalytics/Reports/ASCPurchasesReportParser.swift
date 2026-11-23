import Foundation

public struct ASCPurchaseRecord: Equatable, Sendable {
    public let date: ASCCalendarDate
    public let appAppleIdentifier: String
    public let purchaseType: String
    public let purchases: Int
    public let proceedsUSD: Decimal
    public let payingUsers: Int?
}

public struct ASCPurchasesDay: Equatable, Sendable {
    public let date: ASCCalendarDate
    /// Positive purchase events. Refund rows still contribute to proceeds.
    public fileprivate(set) var inAppPurchases: Int? = nil
    public fileprivate(set) var proceedsUSD: Decimal = 0
}

public struct ASCPurchasesReportParser: Sendable {
    public static let reportName = "App Store Purchases"

    public init() {}

    public func parse(_ data: Data) throws -> [ASCPurchaseRecord] {
        let decoded = try ASCSalesReportParser.decompressedIfGzipped(data, decoder: ASCGzipDecoder())
        let delimiter = try ASCDownloadsReportParser.resolveDelimiter(.automatic, data: decoded, report: Self.reportName)
        let table = try ASCTSVParser(configuration: .init(delimiter: delimiter)).parse(decoded)
        return try parse(table)
    }

    /// Accept decoded tabular data from a host that already reads report segments.
    public func parse(columns: [String], rows: [[String]]) throws -> [ASCPurchaseRecord] {
        let header = ASCReportRow(lineNumber: 1, fields: columns)
        let data = rows.enumerated().map { ASCReportRow(lineNumber: $0.offset + 2, fields: $0.element) }
        return try parse(ASCReportTable(rows: [header] + data))
    }

    public func parse(_ input: ASCReportTable) throws -> [ASCPurchaseRecord] {
        let table = input.withReportName(Self.reportName)
        for column in ["Date", "App Apple Identifier", "Purchase Type", "Purchases", "Proceeds in USD"] {
            _ = try table.requireColumn(named: column)
        }
        return try table.rows.map { row in
            let rawDate = try table.requiredString("Date", row: row)
            guard let date = ASCCalendarDate(iso8601Day: rawDate) else {
                throw ASCAnalyticsError.invalidFieldValue(
                    report: Self.reportName, column: "Date", value: rawDate,
                    line: row.lineNumber, reason: "expected YYYY-MM-DD"
                )
            }
            let payerColumn = "Paying Users"
            let payingUsers = if table.columnIndex(named: payerColumn) != nil,
                                 try table.optionalString(payerColumn, row: row) != nil {
                try table.integer(payerColumn, row: row)
            } else {
                nil as Int?
            }
            return ASCPurchaseRecord(
                date: date,
                appAppleIdentifier: try table.requiredString("App Apple Identifier", row: row),
                purchaseType: try table.requiredString("Purchase Type", row: row),
                purchases: try table.integer("Purchases", row: row),
                proceedsUSD: try table.decimal("Proceeds in USD", row: row),
                payingUsers: payingUsers
            )
        }
    }
}

public struct ASCPurchasesAggregator: Sendable {
    public init() {}

    /// Aggregate one non-overlapping set of purchase rows. Paying users are
    /// scoped to individual rows and cannot be deduplicated at app/day level.
    public func daily(_ records: [ASCPurchaseRecord], appID: String) -> [ASCPurchasesDay] {
        var byDate: [ASCCalendarDate: ASCPurchasesDay] = [:]
        for record in records where record.appAppleIdentifier == appID {
            var day = byDate[record.date] ?? ASCPurchasesDay(date: record.date)
            day.proceedsUSD += record.proceedsUSD
            switch record.purchaseType.lowercased() {
            case "in-app purchases", "in-app purchase":
                day.inAppPurchases = (day.inAppPurchases ?? 0) + max(0, record.purchases)
            case "app purchase":
                day.inAppPurchases = day.inAppPurchases ?? 0
            default:
                break
            }
            byDate[record.date] = day
        }
        return byDate.values.sorted { $0.date < $1.date }
    }
}
