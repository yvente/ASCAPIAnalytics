import Foundation

/// Classification of the App Store Discovery and Engagement report `Event`
/// dimension, per Apple's official glossary
/// (developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement).
public enum ASCDiscoveryEvent: Hashable, Codable, Sendable {
    /// `Impression` — a user viewed the app icon in a list alongside other
    /// apps (search results, charts, Today/Apps/Games tabs). Page views are
    /// not included in these counts.
    case impression
    /// `Page view` — the user was presented with a dedicated page for the
    /// app or an in-app event.
    case pageView
    /// `Tap` — the user tapped on an impression or page.
    case tap
    /// Any other value; preserved verbatim.
    case other(raw: String)

    public static func classify(_ raw: String) -> ASCDiscoveryEvent {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "impression": return .impression
        case "page view": return .pageView
        case "tap": return .tap
        default: return .other(raw: raw)
        }
    }
}

/// One parsed App Store Discovery and Engagement report record.
public struct ASCDiscoveryRecord:
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
    /// Raw `Event` value.
    public let rawEvent: String
    /// Classified event; unknown values remain `other`.
    public let event: ASCDiscoveryEvent
    /// Raw `Page Type` value, `nil` when blank or absent.
    public let pageType: String?
    /// Raw `Source Type` value, `nil` when blank or absent.
    public let sourceType: String?
    /// Raw `Engagement Type` value, `nil` when blank or absent.
    public let engagementType: String?
    /// `Territory` (App Store country or region code).
    public let territory: String
    /// `Counts` — the total number of events for this dimension
    /// combination.
    public let counts: Int
    /// `Unique Counts` — the total number of unique users that performed
    /// the event *within this row's date and dimension combination*.
    /// `nil` when the column is absent.
    ///
    /// Unique counts are deduplicated by Apple per device within a single
    /// date and dimension set; they must never be summed across dates or
    /// across dimension values (see `uniqueCountsDeduplicationKey`).
    public let uniqueCounts: Int?
    /// All other columns, preserved verbatim by header name (App Name,
    /// Page Title, Source Info, Campaign, Device, Platform Version, …).
    public let extraFields: [String: String]

    /// The deduplication domain this row's `Unique Counts` value belongs
    /// to: the event date plus every dimension value of the row. Two rows
    /// with different keys describe devices deduplicated within different
    /// scopes; summing their unique counts would double-count devices.
    public var uniqueCountsDeduplicationKey: String {
        var parts: [String] = [date.iso8601Day]
        parts.append(pageType ?? "")
        parts.append(sourceType ?? "")
        parts.append(engagementType ?? "")
        let extraKeys = extraFields.keys.sorted()
        for key in extraKeys {
            parts.append("\(key)=\(extraFields[key] ?? "")")
        }
        return parts.joined(separator: "\u{1F}")
    }

    public var description: String {
        "ASCDiscoveryRecord(\(date.iso8601Day), \(rawEvent), counts: \(counts), unique: \(uniqueCounts.map(String.init) ?? "-"))"
    }
}

/// Result of parsing an App Store Discovery and Engagement report segment.
public struct ASCDiscoveryParseResult: Sendable {
    public let records: [ASCDiscoveryRecord]
    public let schemaFingerprint: String
    public let contentChecksum: String
    public let headerFields: [String]
}

/// Parser for Apple's App Store Discovery and Engagement report from the
/// Analytics Reports API.
///
/// Field names and the Event glossary are verified against Apple's official
/// report page
/// (developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement).
/// Counts and Unique Counts are stored separately; unique counts are never
/// treated as additive across their deduplication domains.
public struct ASCDiscoveryReportParser: Sendable {
    /// Report name used in diagnostics.
    public static let reportName = "App Store Discovery and Engagement Report"

    /// Columns required to interpret the report.
    public static let requiredColumns = [
        "Date",
        "App Apple Identifier",
        "Event",
        "Territory",
        "Counts",
    ]

    /// Columns parsed into typed fields; everything else lands in
    /// `extraFields` untouched.
    public static let knownColumns = requiredColumns + [
        "Page Type",
        "Source Type",
        "Engagement Type",
        "Unique Counts",
    ]

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

    /// Parses a segment (or an uncompressed TSV/CSV file) of the report.
    public func parse(_ data: Data) throws -> ASCDiscoveryParseResult {
        let contentChecksum = ASCFingerprint.sha256Hex(data)
        let tsvData = try ASCSalesReportParser.decompressedIfGzipped(data, decoder: gzipDecoder)

        let delimiter = try ASCDownloadsReportParser.resolveDelimiter(
            segmentDelimiter, data: tsvData, report: Self.reportName
        )
        var configuration = tsvConfiguration
        configuration.delimiter = delimiter
        let parser = ASCTSVParser(configuration: configuration)

        let table = try parser.parse(tsvData).withReportName(Self.reportName)

        for column in Self.requiredColumns where table.columnIndex(named: column) == nil {
            throw ASCAnalyticsError.missingRequiredColumn(report: Self.reportName, column: column)
        }

        var records: [ASCDiscoveryRecord] = []
        records.reserveCapacity(table.rows.count)
        for row in table.rows {
            records.append(try Self.parseRecord(from: table, row: row))
        }

        return ASCDiscoveryParseResult(
            records: records,
            schemaFingerprint: ASCFingerprint.schemaFingerprint(header: table.header),
            contentChecksum: contentChecksum,
            headerFields: table.header
        )
    }

    static func parseRecord(
        from table: ASCReportTable, row: ASCReportRow
    ) throws -> ASCDiscoveryRecord {
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

        let rawEvent = try table.requiredString("Event", row: row)
        let territory = try table.requiredString("Territory", row: row)
        let counts = try table.integer("Counts", row: row)

        let uniqueCounts: Int?
        if table.columnIndex(named: "Unique Counts") != nil {
            uniqueCounts = try table.integer("Unique Counts", row: row)
        } else {
            uniqueCounts = nil
        }

        let pageType = table.columnIndex(named: "Page Type") != nil
            ? try table.optionalString("Page Type", row: row)
            : nil
        let sourceType = table.columnIndex(named: "Source Type") != nil
            ? try table.optionalString("Source Type", row: row)
            : nil
        let engagementType = table.columnIndex(named: "Engagement Type") != nil
            ? try table.optionalString("Engagement Type", row: row)
            : nil

        var extraFields: [String: String] = [:]
        for (index, name) in table.header.enumerated()
        where !Self.knownColumnSet.contains(name.lowercased()) {
            extraFields[name] = row.field(at: index) ?? ""
        }

        return ASCDiscoveryRecord(
            date: date,
            appAppleIdentifier: appIdentifier,
            rawEvent: rawEvent,
            event: ASCDiscoveryEvent.classify(rawEvent),
            pageType: pageType,
            sourceType: sourceType,
            engagementType: engagementType,
            territory: territory,
            counts: counts,
            uniqueCounts: uniqueCounts,
            extraFields: extraFields
        )
    }

    static let knownColumnSet: Set<String> = Set(
        knownColumns.map { $0.lowercased() }
    )
}

extension ASCDiscoveryRecord: ASCEventDated {
    public var eventDate: ASCCalendarDate { date }
}
