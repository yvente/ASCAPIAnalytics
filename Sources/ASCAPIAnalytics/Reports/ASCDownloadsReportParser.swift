import Foundation

/// Classification of the App Downloads report `Download Type` dimension,
/// per Apple's official glossary
/// (developer.apple.com/documentation/analytics-reports/app-download).
///
/// A first-time download is defined by Apple as the first time a *user*
/// downloaded the app, "based on the user's Apple ID account" — it is not a
/// device-level first install. Unknown download types are preserved with
/// their raw value.
public enum ASCDownloadType: Hashable, Codable, Sendable {
    /// `First-time Download` — counted when a user taps "Buy" or "Get",
    /// keyed on the Apple ID account.
    case firstTimeDownload
    /// `Redownload` — a subsequent installation of the app onto a device by
    /// an Apple ID account.
    case redownload
    /// `Manual update` — the user tapped "Update" on the App Store.
    case manualUpdate
    /// `Auto-update` — the device replaced the app with another version
    /// automatically.
    case autoUpdate
    /// `Restore` — the app was restored onto a device from iCloud Backup.
    case restore
    /// Any other value; preserved verbatim and surfaced separately by
    /// metrics.
    case other(raw: String)

    /// Classifies a raw `Download Type` value (case-insensitive against
    /// Apple's published glossary values).
    public static func classify(_ raw: String) -> ASCDownloadType {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "first-time download": return .firstTimeDownload
        case "redownload": return .redownload
        case "manual update": return .manualUpdate
        case "auto-update": return .autoUpdate
        case "restore": return .restore
        default: return .other(raw: raw)
        }
    }
}

/// One parsed App Downloads report record.
public struct ASCDownloadRecord:
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// Event date (`Date` column, ISO `YYYY-MM-DD`; for weekly and monthly
    /// instances the first day of the week or month).
    public let date: ASCCalendarDate
    /// `App Apple Identifier`.
    public let appAppleIdentifier: String
    /// Raw `Download Type` value.
    public let rawDownloadType: String
    /// Classified download type; unknown values remain `other`.
    public let downloadType: ASCDownloadType
    /// `Territory` (App Store country or region code).
    public let territory: String
    /// `Counts` — the total number of downloads for this dimension
    /// combination.
    public let counts: Int
    /// `Pre-Order` flag, `nil` when blank or absent. Apple's definition of
    /// conversion rate counts downloads and pre-orders, so this flag must
    /// never be folded away silently.
    public let isPreOrder: Bool?
    /// All other columns, preserved verbatim by header name (App Name, App
    /// Version, Device, Platform Version, Source Type, Source Info,
    /// Campaign, Page Type, Page Title, …).
    public let extraFields: [String: String]

    public var description: String {
        "ASCDownloadRecord(\(date.iso8601Day), \(rawDownloadType), counts: \(counts), \(territory))"
    }
}

/// Result of parsing an App Downloads report segment.
public struct ASCDownloadsParseResult: Sendable {
    public let records: [ASCDownloadRecord]
    public let schemaFingerprint: String
    public let contentChecksum: String
    public let headerFields: [String]
}

/// How the segment delimiter is chosen.
public enum ASCSegmentDelimiter: Sendable {
    /// Detect from the header line: tab if the header contains tabs,
    /// comma if it contains commas, otherwise an error. Tabs take
    /// precedence because a tab-delimited header may legitimately contain
    /// quoted commas while the reverse is unambiguous.
    case automatic
    /// Force tab-delimited parsing.
    case tab
    /// Force comma-delimited parsing.
    case comma
}

/// Parser for Apple's App Downloads report from the Analytics Reports API.
///
/// Field names and the Download Type glossary are verified against Apple's
/// official report page
/// (developer.apple.com/documentation/analytics-reports/app-download).
/// Standard and detailed report variants share the required core columns;
/// detailed-only columns and any future additions are preserved verbatim in
/// `extraFields`.
public struct ASCDownloadsReportParser: Sendable {
    /// Report name used in diagnostics.
    public static let reportName = "App Downloads Report"

    /// Columns required to interpret the report.
    public static let requiredColumns = [
        "Date",
        "App Apple Identifier",
        "Download Type",
        "Territory",
        "Counts",
    ]

    /// Columns parsed into typed fields; everything else lands in
    /// `extraFields` untouched.
    public static let knownColumns = requiredColumns + ["Pre-Order"]

    private let gzipDecoder: ASCGzipDecoder
    private let segmentDelimiter: ASCSegmentDelimiter
    private let tsvConfiguration: ASCTSVParserConfiguration

    public init(
        segmentDelimiter: ASCSegmentDelimiter = .automatic,
        tsvConfiguration: ASCTSVParserConfiguration = .init(),
        gzipConfiguration: ASCGzipDecoder.Configuration = .init()
    ) {
        self.segmentDelimiter = segmentDelimiter
        self.tsvConfiguration = tsvConfiguration
        self.gzipDecoder = ASCGzipDecoder(configuration: gzipConfiguration)
    }

    /// Parses a segment (or an uncompressed TSV/CSV file) of the App
    /// Downloads report.
    public func parse(_ data: Data) throws -> ASCDownloadsParseResult {
        let contentChecksum = ASCFingerprint.sha256Hex(data)
        let tsvData = try ASCSalesReportParser.decompressedIfGzipped(data, decoder: gzipDecoder)

        let delimiter = try Self.resolveDelimiter(
            segmentDelimiter, data: tsvData, report: Self.reportName
        )
        var configuration = tsvConfiguration
        configuration.delimiter = delimiter
        let parser = ASCTSVParser(configuration: configuration)

        let table = try parser.parse(tsvData).withReportName(Self.reportName)

        for column in Self.requiredColumns where table.columnIndex(named: column) == nil {
            throw ASCAnalyticsError.missingRequiredColumn(report: Self.reportName, column: column)
        }

        var records: [ASCDownloadRecord] = []
        records.reserveCapacity(table.rows.count)
        for row in table.rows {
            records.append(try Self.parseRecord(from: table, row: row))
        }

        return ASCDownloadsParseResult(
            records: records,
            schemaFingerprint: ASCFingerprint.schemaFingerprint(header: table.header),
            contentChecksum: contentChecksum,
            headerFields: table.header
        )
    }

    static func resolveDelimiter(
        _ choice: ASCSegmentDelimiter, data: Data, report: String
    ) throws -> ASCDelimiter {
        switch choice {
        case .tab: return .tab
        case .comma: return .comma
        case .automatic:
            guard let headerLine = firstLine(of: data) else {
                throw ASCAnalyticsError.tsvEmptyInput
            }
            let tabs = headerLine.filter { $0 == UInt8(ascii: "\t") }.count
            let commas = headerLine.filter { $0 == UInt8(ascii: ",") }.count
            if tabs > 0 { return .tab }
            if commas > 0 { return .comma }
            throw ASCAnalyticsError.ambiguousDelimiter(
                report: report, headerTabs: tabs, headerCommas: commas
            )
        }
    }

    static func firstLine(of data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard let newlineIndex = bytes.firstIndex(of: UInt8(ascii: "\n")) else {
            return bytes.isEmpty ? nil : Array(bytes)
        }
        var line = Array(bytes[..<newlineIndex])
        if line.last == UInt8(ascii: "\r") {
            line.removeLast()
        }
        return line
    }

    static func parseRecord(
        from table: ASCReportTable, row: ASCReportRow
    ) throws -> ASCDownloadRecord {
        let dateRaw = try table.requiredString("Date", row: row)
        guard let date = ASCCalendarDate(iso8601Day: dateRaw) else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: Self.reportName, column: "Date", value: dateRaw,
                line: row.lineNumber, reason: "expected YYYY-MM-DD"
            )
        }

        let appIdentifier = try table.requiredString("App Apple Identifier", row: row)
        guard appIdentifier.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: Self.reportName, column: "App Apple Identifier",
                value: appIdentifier, line: row.lineNumber,
                reason: "expected a numeric Apple identifier"
            )
        }

        let rawDownloadType = try table.requiredString("Download Type", row: row)
        let territory = try table.requiredString("Territory", row: row)
        let counts = try table.integer("Counts", row: row)

        let isPreOrder: Bool?
        if table.columnIndex(named: "Pre-Order") != nil {
            let raw = (try table.optionalString("Pre-Order", row: row))?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch raw {
            case "true", "1", "yes": isPreOrder = true
            case "false", "0", "no": isPreOrder = false
            case nil: isPreOrder = nil
            case .some(let value):
                throw ASCAnalyticsError.invalidFieldValue(
                    report: Self.reportName, column: "Pre-Order",
                    value: value, line: row.lineNumber,
                    reason: "expected a boolean flag"
                )
            }
        } else {
            isPreOrder = nil
        }

        var extraFields: [String: String] = [:]
        for (index, name) in table.header.enumerated()
        where !Self.knownColumnSet.contains(name.lowercased()) {
            extraFields[name] = row.field(at: index) ?? ""
        }

        return ASCDownloadRecord(
            date: date,
            appAppleIdentifier: appIdentifier,
            rawDownloadType: rawDownloadType,
            downloadType: ASCDownloadType.classify(rawDownloadType),
            territory: territory,
            counts: counts,
            isPreOrder: isPreOrder,
            extraFields: extraFields
        )
    }

    static let knownColumnSet: Set<String> = Set(
        knownColumns.map { $0.lowercased() }
    )
}

extension ASCDownloadRecord: ASCEventDated {
    public var eventDate: ASCCalendarDate { date }
}
