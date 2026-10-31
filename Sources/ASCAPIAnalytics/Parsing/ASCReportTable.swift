import Foundation

/// One parsed record of a delimited report file.
public struct ASCReportRow: Sendable {
    /// 1-based physical line number where this record starts in the source
    /// file, for diagnostics.
    public let lineNumber: Int
    /// Raw field values, in file order. Quoted fields are decoded;
    /// everything else is preserved verbatim.
    public let fields: [String]

    public init(lineNumber: Int, fields: [String]) {
        self.lineNumber = lineNumber
        self.fields = fields
    }

    /// Value at the given field index, or `nil` when out of range.
    public func field(at index: Int) -> String? {
        guard index >= 0, index < fields.count else { return nil }
        return fields[index]
    }
}

/// A parsed delimited report: header names plus rows with line numbers.
///
/// Column lookup is by header name (case-insensitive) because Apple
/// explicitly advises relying on column names instead of positions — report
/// column order can change over time.
public struct ASCReportTable: Sendable {
    /// Human-facing report name used in diagnostics.
    public let reportName: String
    /// Header names exactly as they appear in the file (BOM stripped,
    /// whitespace trimmed).
    public let header: [String]
    /// Data rows (the header row is not included).
    public let rows: [ASCReportRow]

    private let columnIndexByName: [String: Int]

    /// Creates a table from parsed rows. The first row must be the header.
    init(rows: [ASCReportRow], reportName: String = "report") throws {
        guard let headerRow = rows.first else {
            throw ASCAnalyticsError.tsvBlankInput
        }

        var header: [String] = []
        var indexByName: [String: Int] = [:]
        for (index, name) in headerRow.fields.enumerated() {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ASCAnalyticsError.tsvEmptyHeaderName(
                    line: headerRow.lineNumber,
                    column: index + 1
                )
            }
            let key = trimmed.lowercased()
            if let existing = indexByName[key] {
                throw ASCAnalyticsError.tsvDuplicateHeader(
                    name: trimmed,
                    firstColumn: existing + 1,
                    duplicateColumn: index + 1
                )
            }
            indexByName[key] = index
            header.append(trimmed)
        }

        self.reportName = reportName
        self.header = header
        self.rows = Array(rows.dropFirst())
        self.columnIndexByName = indexByName
    }

    /// Returns a copy of the table with a different report name for
    /// diagnostics, reusing the already validated header index.
    public func withReportName(_ name: String) -> ASCReportTable {
        ASCReportTable(
            reportName: name,
            header: header,
            rows: rows,
            columnIndexByName: columnIndexByName
        )
    }

    private init(
        reportName: String,
        header: [String],
        rows: [ASCReportRow],
        columnIndexByName: [String: Int]
    ) {
        self.reportName = reportName
        self.header = header
        self.rows = rows
        self.columnIndexByName = columnIndexByName
    }

    /// Number of data rows.
    public var rowCount: Int { rows.count }

    /// Case-insensitive column index lookup by header name.
    public func columnIndex(named name: String) -> Int? {
        columnIndexByName[name.lowercased()]
    }

    /// Case-insensitive lookup that fails with `missingRequiredColumn` when
    /// the column is absent.
    public func requireColumn(named name: String) throws -> Int {
        guard let index = columnIndex(named: name) else {
            throw ASCAnalyticsError.missingRequiredColumn(report: reportName, column: name)
        }
        return index
    }

    // MARK: - Typed value access with diagnostics

    /// Raw string value of a column in a row.
    public func string(_ column: String, row: ASCReportRow) throws -> String {
        let index = try requireColumn(named: column)
        guard let value = row.field(at: index) else {
            throw ASCAnalyticsError.missingRequiredField(
                report: reportName,
                column: column,
                line: row.lineNumber
            )
        }
        return value
    }

    /// String value of a column, or `nil` when blank.
    public func optionalString(_ column: String, row: ASCReportRow) throws -> String? {
        let value = try string(column, row: row)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whitespace-trimmed required string; blank values are an error.
    public func requiredString(_ column: String, row: ASCReportRow) throws -> String {
        guard let value = try optionalString(column, row: row) else {
            throw ASCAnalyticsError.missingRequiredField(
                report: reportName,
                column: column,
                line: row.lineNumber
            )
        }
        return value
    }

    /// `Decimal` value parsed with Apple report number rules: optional sign,
    /// digits, optional fractional part; a leading `.` is allowed (Apple's
    /// documentation examples show values like `.7`). Thousands separators
    /// and other formats are rejected.
    public func decimal(_ column: String, row: ASCReportRow) throws -> Decimal {
        let raw = try requiredString(column, row: row)
        guard let value = ASCReportNumber.parseDecimal(raw) else {
            throw ASCAnalyticsError.invalidFieldValue(
                report: reportName,
                column: column,
                value: raw,
                line: row.lineNumber,
                reason: "not a decimal number in Apple report format"
            )
        }
        return value
    }

    /// Integral value parsed from a decimal-shaped column (Apple defines
    /// counts with decimal data types even when values are whole numbers).
    public func integer(_ column: String, row: ASCReportRow) throws -> Int {
        let value = try decimal(column, row: row)
        guard let integral = ASCReportNumber.intFromDecimal(value) else {
            let raw = try requiredString(column, row: row)
            throw ASCAnalyticsError.invalidFieldValue(
                report: reportName,
                column: column,
                value: raw,
                line: row.lineNumber,
                reason: "expected a whole number"
            )
        }
        return integral
    }
}

/// Number parsing shared by report parsers.
enum ASCReportNumber {
    /// Parses Apple report decimal syntax: `[+-]?(\d+(\.\d*)?|\.\d+)`.
    static func parseDecimal(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var rest = Substring(trimmed)
        var negative = false
        if rest.hasPrefix("+") {
            rest = rest.dropFirst()
        } else if rest.hasPrefix("-") {
            negative = true
            rest = rest.dropFirst()
        }

        var digits = Substring()
        var fraction = Substring()
        if let dotIndex = rest.firstIndex(of: ".") {
            digits = rest[..<dotIndex]
            fraction = rest[rest.index(after: dotIndex)...]
        } else {
            digits = rest
            fraction = Substring()
        }

        guard !digits.isEmpty || !fraction.isEmpty else { return nil }
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        guard fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        var text = digits.isEmpty ? "0" : String(digits)
        if !fraction.isEmpty {
            text += "." + String(fraction)
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return negative ? -value : value
    }

    /// Returns the integer value of a `Decimal` when it is exact.
    static func intFromDecimal(_ value: Decimal) -> Int? {
        var rounded = value
        var result = Decimal()
        NSDecimalRound(&result, &rounded, 0, .plain)
        guard result == value else { return nil }
        let converted = NSDecimalNumber(decimal: result)
        let intValue = converted.intValue
        guard NSDecimalNumber(decimal: Decimal(intValue)) == converted else { return nil }
        return intValue
    }
}
