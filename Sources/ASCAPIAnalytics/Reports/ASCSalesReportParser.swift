import Foundation

/// Classification of the Summary Sales report `Product Type Identifier`,
/// per Apple's official product type identifiers table
/// (developer.apple.com/help/app-store-connect/reference/product-type-identifiers).
///
/// Unknown identifiers are preserved with their raw value and are never
/// silently treated as a normal sale.
public enum ASCSalesProductType: Hashable, Codable, Sendable {
    /// Free or paid app purchases: `1`, `1F`, `1T`, `1E`, `1EP`, `1EU`, `F1`.
    case app
    /// App bundle purchases: `1-B` (iOS/iPadOS/visionOS), `F1-B` (Mac).
    case appBundle
    /// App updates: `7`, `7F`, `7T`, `F7`.
    case update
    /// Re-downloads: `3`, `3F` (Apple's table lists the type as
    /// "Re-download" with "App update" descriptions).
    case redownload
    /// One-time In-App Purchases: `IA1`, `IA1-M`, `FI1`.
    case inAppPurchase
    /// Auto-renewable subscriptions: `IAY`, `IAY-M`.
    case autoRenewableSubscription
    /// Non-renewing subscriptions: `IA9`, `IA9-M`.
    case nonRenewingSubscription
    /// Restored In-App Purchases: `IA3`.
    case restoredInAppPurchase
    /// Any identifier Apple's published table does not define. The raw
    /// value is preserved and surfaced by metrics instead of being counted
    /// as a known product type.
    case unknown(raw: String)

    /// The raw product type identifier string.
    public var rawIdentifier: String {
        switch self {
        case .app: return "1/1F/1T/1E/1EP/1EU/F1"
        case .appBundle: return "1-B/F1-B"
        case .update: return "7/7F/7T/F7"
        case .redownload: return "3/3F"
        case .inAppPurchase: return "IA1/IA1-M/FI1"
        case .autoRenewableSubscription: return "IAY/IAY-M"
        case .nonRenewingSubscription: return "IA9/IA9-M"
        case .restoredInAppPurchase: return "IA3"
        case .unknown(let raw): return raw
        }
    }

    /// Maps a raw `Product Type Identifier` value onto a classification.
    public static func classify(_ raw: String) -> ASCSalesProductType {
        switch raw.uppercased() {
        case "1", "1F", "1T", "1E", "1EP", "1EU", "F1":
            return .app
        case "1-B", "F1-B":
            return .appBundle
        case "7", "7F", "7T", "F7":
            return .update
        case "3", "3F":
            return .redownload
        case "IA1", "IA1-M", "FI1":
            return .inAppPurchase
        case "IAY", "IAY-M":
            return .autoRenewableSubscription
        case "IA9", "IA9-M":
            return .nonRenewingSubscription
        case "IA3":
            return .restoredInAppPurchase
        default:
            return .unknown(raw: raw)
        }
    }
}

/// Value of the Summary Sales report `CMB` column.
public enum ASCSalesCMB: Hashable, Codable, Sendable {
    /// Blank: an ordinary transaction.
    case none
    /// `CMB`: the transaction completes an app bundle.
    case completesBundle
    /// `CMB-C`: a credit for a previously purchased app that is part of the
    /// completed bundle (negative Units and Customer Price, positive
    /// Developer Proceeds).
    case creditForCompletedBundle
    /// Any other value; preserved verbatim.
    case other(raw: String)

    public static func classify(_ raw: String) -> ASCSalesCMB {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.uppercased() {
        case "": return .none
        case "CMB": return .completesBundle
        case "CMB-C": return .creditForCompletedBundle
        default: return .other(raw: trimmed)
        }
    }
}

/// Attribution of a sales record to an app.
///
/// Direct app rows (apps, bundles, updates, re-downloads) carry the app's
/// Apple Identifier in the `Apple Identifier` column. In-app purchase rows
/// carry their own product Apple Identifier and attribute to the parent app
/// through `Parent Identifier`, which Apple's current documentation defines
/// as the SKU of the associated app.
public enum ASCSalesAppAttribution: Hashable, Codable, Sendable {
    /// Attributed by the row's own `Apple Identifier` value.
    case appleIdentifier(String)
    /// Attributed by `Parent Identifier` (Apple: the SKU of the associated
    /// app) because in-app purchase rows carry the IAP product's own
    /// identifier.
    case parentIdentifierSKU(String)
    /// The row cannot be attributed (for example an in-app purchase row
    /// with a blank `Parent Identifier`); it is never silently assigned.
    case unattributed
}

/// One parsed Summary Sales report record.
public struct ASCSalesRecord:
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// Begin Date (Apple format `MM/DD/YYYY`).
    public let beginDate: ASCCalendarDate
    /// End Date (Apple format `MM/DD/YYYY`).
    public let endDate: ASCCalendarDate
    /// `Apple Identifier` (Apple data type `DECIMAL(18,0)`), kept as the
    /// raw numeric string.
    public let appleIdentifier: String
    /// `SKU`.
    public let sku: String
    /// `Parent Identifier`, `nil` when blank.
    public let parentIdentifier: String?
    /// Raw `Product Type Identifier` value.
    public let rawProductType: String
    /// Classified product type; unknown identifiers remain `unknown`.
    public let productType: ASCSalesProductType
    /// `Units` (`DECIMAL(18,2)`). Negative values indicate refunds or
    /// `CMB-C` credits; 0 may indicate a partial refund.
    public let units: Decimal
    /// `Customer Price` per unit, in `Customer Currency`. Negative values
    /// indicate refunds or `CMB-C` credits.
    public let customerPrice: Decimal
    /// `Customer Currency` (three-letter ISO code).
    public let customerCurrency: String
    /// `Developer Proceeds` per unit (Apple: "Amount you receive per
    /// unit"), in `Currency of Proceeds`. On refund and credit rows Apple
    /// reports a positive per-unit value while Units are negative.
    public let developerProceeds: Decimal
    /// `Currency of Proceeds` (three-letter ISO code).
    public let proceedsCurrency: String
    /// `Country Code` (two-letter ISO code of the App Store storefront).
    public let countryCode: String
    /// Classified `CMB` column value.
    public let cmb: ASCSalesCMB
    /// All other columns, preserved verbatim by header name (Provider,
    /// Title, Version, Promo Code, Device, …).
    public let extraFields: [String: String]

    /// Signed effect on gross customer sales in `customerCurrency`:
    /// `units × |customer price|`. Apple's refund convention (negative
    /// Units *and* negative Customer Price, positive Developer Proceeds)
    /// means plain multiplication would flip a refund into a gain; taking
    /// the price magnitude keeps sale rows positive and refund rows
    /// negative, matching Apple's published refund example
    /// (`Units: -50, Developer Proceeds: .7, Customer Price: -0.99`).
    public var grossSalesImpact: Decimal {
        units * abs(customerPrice)
    }

    /// Signed effect on developer proceeds in `proceedsCurrency`:
    /// `units × |developer proceeds|`. With Apple's convention (proceeds
    /// stay positive on refund rows) this nets refunds correctly.
    public var developerProceedsImpact: Decimal {
        units * abs(developerProceeds)
    }

    /// Whether the row reduces units (refund or `CMB-C` credit).
    public var isRefundOrCredit: Bool { units < 0 }

    /// Attribution of this row to an app.
    public var appAttribution: ASCSalesAppAttribution {
        switch productType {
        case .inAppPurchase, .autoRenewableSubscription,
             .nonRenewingSubscription, .restoredInAppPurchase:
            if let parent = parentIdentifier, !parent.isEmpty {
                return .parentIdentifierSKU(parent)
            }
            return .unattributed
        case .app, .appBundle, .update, .redownload, .unknown:
            return .appleIdentifier(appleIdentifier)
        }
    }

    public var description: String {
        "ASCSalesRecord(\(beginDate.iso8601Day), \(rawProductType), units: \(units), \(customerCurrency) \(customerPrice))"
    }
}

/// Result of parsing a Summary Sales report.
public struct ASCSalesParseResult: Sendable {
    /// Parsed records in file order.
    public let records: [ASCSalesRecord]
    /// SHA-256 over the canonicalized header row (in file order) — audit
    /// evidence of the parsed layout.
    public let schemaFingerprint: String
    /// SHA-256 over the parsed column set (order-insensitive) — the
    /// logical variant identity.
    public let canonicalSchemaIdentity: String
    /// SHA-256 over the raw input bytes as received (still compressed if
    /// the input was gzipped).
    public let contentChecksum: String
    /// Header names as parsed.
    public let headerFields: [String]
}

/// Parser for Apple's Summary Sales report (Sales and Trends).
///
/// Field names, data types, sign conventions, and the `CMB` semantics are
/// verified against Apple's official report reference (version 1_3) at
/// developer.apple.com/help/app-store-connect/reference/summary-sales-report.
/// The input may be gzip-compressed (as delivered by
/// `ASCAPIKit.downloadSalesReport`) or plain UTF-8 TSV; gzip is detected by
/// its magic bytes, never assumed.
public struct ASCSalesReportParser: Sendable {
    /// Report name used in diagnostics.
    public static let reportName = "Summary Sales Report"

    /// Columns this parser requires to be present in the header.
    static let requiredColumns = [
        "Begin Date",
        "End Date",
        "Apple Identifier",
        "SKU",
        "Product Type Identifier",
        "Units",
        "Customer Price",
        "Customer Currency",
        "Developer Proceeds",
        "Currency of Proceeds",
        "Country Code",
    ]

    /// Columns parsed into typed fields; everything else lands in
    /// `extraFields` untouched.
    static let knownColumns = requiredColumns + ["Parent Identifier", "CMB"]

    private let tsvParser: ASCTSVParser
    private let gzipDecoder: ASCGzipDecoder

    public init(
        tsvConfiguration: ASCTSVParserConfiguration = .init(),
        gzipConfiguration: ASCGzipDecoder.Configuration = .init()
    ) {
        self.tsvParser = ASCTSVParser(configuration: tsvConfiguration)
        self.gzipDecoder = ASCGzipDecoder(configuration: gzipConfiguration)
    }

    /// Parses a Summary Sales report from raw bytes.
    public func parse(_ data: Data) throws -> ASCSalesParseResult {
        let contentChecksum = ASCFingerprint.sha256Hex(data)

        let tsvData = try Self.decompressedIfGzipped(data, decoder: gzipDecoder)
        let table = try tsvParser.parse(tsvData).withReportName(Self.reportName)

        for column in Self.requiredColumns where table.columnIndex(named: column) == nil {
            throw ASCAnalyticsError.missingRequiredColumn(report: Self.reportName, column: column)
        }

        var records: [ASCSalesRecord] = []
        records.reserveCapacity(table.rows.count)

        for row in table.rows {
            let record = try Self.parseRecord(from: table, row: row)
            records.append(record)
        }

        return ASCSalesParseResult(
            records: records,
            schemaFingerprint: ASCFingerprint.schemaFingerprint(header: table.header),
            canonicalSchemaIdentity: ASCFingerprint.canonicalSchemaIdentity(header: table.header),
            contentChecksum: contentChecksum,
            headerFields: table.header
        )
    }

    /// Detects a gzip stream by its magic bytes and inflates it; plain
    /// UTF-8 input passes through unchanged.
    static func decompressedIfGzipped(
        _ data: Data, decoder: ASCGzipDecoder
    ) throws -> Data {
        if data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B {
            return try decoder.decode(data)
        }
        return data
    }

    static func parseRecord(
        from table: ASCReportTable, row: ASCReportRow
    ) throws -> ASCSalesRecord {
        let beginRaw = try table.requiredString("Begin Date", row: row)
        guard let beginDate = ASCCalendarDate(salesReportDate: beginRaw) else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: Self.reportName, column: "Begin Date", value: beginRaw,
                line: row.lineNumber, reason: "expected MM/DD/YYYY"
            )
        }
        let endRaw = try table.requiredString("End Date", row: row)
        guard let endDate = ASCCalendarDate(salesReportDate: endRaw) else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: Self.reportName, column: "End Date", value: endRaw,
                line: row.lineNumber, reason: "expected MM/DD/YYYY"
            )
        }

        let appleIdentifier = try table.requiredString("Apple Identifier", row: row)
        guard !appleIdentifier.isEmpty,
              appleIdentifier.allSatisfy({ $0.isASCII && $0.isNumber })
        else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: Self.reportName, column: "Apple Identifier",
                value: appleIdentifier, line: row.lineNumber,
                reason: "expected a numeric Apple identifier"
            )
        }

        let sku = try table.requiredString("SKU", row: row)
        let rawProductType = try table.requiredString("Product Type Identifier", row: row)
        let units = try table.decimal("Units", row: row)
        let customerPrice = try table.decimal("Customer Price", row: row)
        let customerCurrency = try table.requiredString("Customer Currency", row: row)
        let developerProceeds = try table.decimal("Developer Proceeds", row: row)
        let proceedsCurrency = try table.requiredString("Currency of Proceeds", row: row)
        let countryCode = try table.requiredString("Country Code", row: row)

        for (value, column, length) in [
            (customerCurrency, "Customer Currency", 3),
            (proceedsCurrency, "Currency of Proceeds", 3),
            (countryCode, "Country Code", 2),
        ] {
            guard value.count == length,
                  value.allSatisfy({ $0.isASCII && $0.isLetter })
            else {
                throw ASCAnalyticsError.invalidFieldValue(
                    report: Self.reportName, column: column, value: value,
                    line: row.lineNumber,
                    reason: "expected \(length)-letter ISO code"
                )
            }
        }

        // `Parent Identifier` and `CMB` are optional columns: blank values
        // are normal, and a future schema revision may drop them entirely.
        let parentIdentifier: String? = table.columnIndex(named: "Parent Identifier") != nil
            ? try table.optionalString("Parent Identifier", row: row)
            : nil
        let cmbRaw: String = table.columnIndex(named: "CMB") != nil
            ? (try table.optionalString("CMB", row: row) ?? "")
            : ""

        var extraFields: [String: String] = [:]
        for (index, name) in table.header.enumerated() where !Self.knownColumnSet.contains(name.lowercased()) {
            extraFields[name] = row.field(at: index) ?? ""
        }

        return ASCSalesRecord(
            beginDate: beginDate,
            endDate: endDate,
            appleIdentifier: appleIdentifier,
            sku: sku,
            parentIdentifier: parentIdentifier,
            rawProductType: rawProductType,
            productType: ASCSalesProductType.classify(rawProductType),
            units: units,
            customerPrice: customerPrice,
            customerCurrency: customerCurrency,
            developerProceeds: developerProceeds,
            proceedsCurrency: proceedsCurrency,
            countryCode: countryCode,
            cmb: ASCSalesCMB.classify(cmbRaw),
            extraFields: extraFields
        )
    }

    static let knownColumnSet: Set<String> = Set(
        knownColumns.map { $0.lowercased() }
    )
}

/// Sales records are dated by their Begin Date — Apple's transaction
/// window start. This is a different date basis from Analytics reports'
/// UTC event days.
extension ASCSalesRecord: ASCEventDated {
    public var eventDate: ASCCalendarDate { beginDate }
}

extension ASCSalesAppAttribution {
    /// Unified attribution matching shared by `ASCSalesFilter` and store
    /// queries.
    ///
    /// A record matches when its direct `Apple Identifier` is in
    /// `appAppleIdentifiers` (direct rows: apps, bundles, updates,
    /// re-downloads) **or** its `Parent Identifier` SKU is in
    /// `parentIdentifiers` (in-app purchase rows). `nil` sets impose no
    /// constraint of that kind. This OR semantics lets one query retrieve
    /// an app's direct sales together with its in-app purchases — the two
    /// identity fields are different namespaces and never exclude each
    /// other.
    public func matches(
        appAppleIdentifiers: Set<String>?,
        parentIdentifiers: Set<String>?
    ) -> Bool {
        var clauses: [Bool] = []
        if appAppleIdentifiers != nil {
            if case .appleIdentifier(let id) = self {
                clauses.append(appAppleIdentifiers!.contains(id))
            } else {
                clauses.append(false)
            }
        }
        if parentIdentifiers != nil {
            if case .parentIdentifierSKU(let sku) = self {
                clauses.append(parentIdentifiers!.contains(sku))
            } else {
                clauses.append(false)
            }
        }
        if clauses.isEmpty { return true }
        return clauses.contains(true)
    }
}
