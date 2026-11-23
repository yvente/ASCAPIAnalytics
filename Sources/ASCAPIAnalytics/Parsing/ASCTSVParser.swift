import Foundation

/// Field delimiter of a delimited report file.
public enum ASCDelimiter: String, CaseIterable, Sendable {
    /// Tab-delimited (Apple's TSV report exports).
    case tab = "\t"
    /// Comma-delimited (quoted CSV, as used by Analytics report segments).
    case comma = ","
}

/// Configuration for `ASCTSVParser`.
public struct ASCTSVParserConfiguration: Sendable {
    /// Delimiter between fields. Defaults to tab; Analytics report segments
    /// can be parsed by passing `ASCDelimiter.comma`.
    public var delimiter: ASCDelimiter
    /// Maximum accepted input size in bytes.
    public var maximumInputSize: Int
    /// Maximum number of data rows (the header row is not counted).
    public var maximumRows: Int
    /// Maximum number of fields in a single record.
    public var maximumFieldCount: Int

    public init(
        delimiter: ASCDelimiter = .tab,
        maximumInputSize: Int = 512 * 1024 * 1024,
        maximumRows: Int = 1_000_000,
        maximumFieldCount: Int = 1024
    ) {
        self.delimiter = delimiter
        self.maximumInputSize = maximumInputSize
        self.maximumRows = maximumRows
        self.maximumFieldCount = maximumFieldCount
    }
}

/// A strict parser for Apple's delimited report files (TSV and CSV).
///
/// This is a full single-pass byte-level state machine, not a naive
/// split-by-newline-then-split-by-delimiter implementation:
///
/// - Strict UTF-8 decoding; invalid UTF-8 is an error.
/// - A leading UTF-8 byte order mark is skipped.
/// - Both LF and CRLF line endings are supported; the final line break is
///   optional.
/// - Fields that *begin* with a quote character are quoted: they may span
///   lines and contain delimiters and line breaks, and `""` decodes to a
///   literal quote. Quote characters inside unquoted fields are preserved
///   as literal data (Apple TSV titles and SKUs may contain them).
/// - Empty fields are preserved as empty strings, including an empty last
///   column.
/// - Unknown columns and raw field values are preserved; column lookup is
///   by header name (case-insensitive, per Apple's guidance to rely on
///   column names rather than positions).
/// - Duplicate header names, inconsistent field counts, unterminated
///   quotes, and limit violations are hard errors with line numbers.
public struct ASCTSVParser: Sendable {
    private let configuration: ASCTSVParserConfiguration

    public init(configuration: ASCTSVParserConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Parses report bytes into an `ASCReportTable`.
    public func parse(_ data: Data) throws -> ASCReportTable {
        guard !data.isEmpty else {
            throw ASCAnalyticsError.tsvEmptyInput
        }
        guard data.count <= configuration.maximumInputSize else {
            throw ASCAnalyticsError.tsvSizeLimitExceeded(limit: configuration.maximumInputSize)
        }

        var bytes = [UInt8](data)
        // UTF-8 BOM: EF BB BF.
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            bytes.removeFirst(3)
        }
        guard !bytes.isEmpty else {
            throw ASCAnalyticsError.tsvEmptyInput
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else {
            throw ASCAnalyticsError.tsvInvalidUTF8
        }
        _ = decoded // Validity check only; parsing operates on bytes.

        let delimiter = configuration.delimiter.delimiterByte

        enum State {
            case fieldStart
            case unquoted
            case quoted
            case quoteInQuoted
        }

        var state = State.fieldStart
        var fields: [String] = []
        var fieldBuffer = [UInt8]()
        var rows: [ASCReportRow] = []
        var currentLine = 1
        var recordStartLine = 1

        func finishField() throws {
            guard fields.count < configuration.maximumFieldCount else {
                throw ASCAnalyticsError.tsvFieldCountLimitExceeded(
                    limit: configuration.maximumFieldCount,
                    line: recordStartLine
                )
            }
            fields.append(String(decoding: fieldBuffer, as: UTF8.self))
            fieldBuffer.removeAll(keepingCapacity: true)
        }

        func finishRecord() throws {
            try finishField()
            // Every record after the header must match the header's field
            // count (Apple report files are rectangular).
            if let header = rows.first, fields.count != header.fields.count {
                throw ASCAnalyticsError.tsvInconsistentFieldCount(
                    line: recordStartLine,
                    expected: header.fields.count,
                    actual: fields.count
                )
            }
            rows.append(ASCReportRow(lineNumber: recordStartLine, fields: fields))
            if rows.count > 1, rows.count - 1 > configuration.maximumRows {
                throw ASCAnalyticsError.tsvRowLimitExceeded(limit: configuration.maximumRows)
            }
            fields.removeAll(keepingCapacity: true)
        }

        /// Ends the current record on a line terminator and advances the
        /// physical line counter.
        func finishRecordOnLineBreak() throws {
            try finishRecord()
            currentLine += 1
            recordStartLine = currentLine
        }

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            switch state {
            case .fieldStart:
                switch byte {
                case delimiter:
                    try finishField()
                case UInt8(ascii: "\n"):
                    try finishRecordOnLineBreak()
                case UInt8(ascii: "\r"):
                    guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") else {
                        throw ASCAnalyticsError.tsvBareCarriageReturn(line: currentLine)
                    }
                    try finishRecordOnLineBreak()
                    index += 1
                case UInt8(ascii: "\""):
                    state = .quoted
                default:
                    fieldBuffer.append(byte)
                    state = .unquoted
                }

            case .unquoted:
                switch byte {
                case delimiter:
                    try finishField()
                    state = .fieldStart
                case UInt8(ascii: "\n"):
                    try finishRecordOnLineBreak()
                    state = .fieldStart
                case UInt8(ascii: "\r"):
                    guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") else {
                        throw ASCAnalyticsError.tsvBareCarriageReturn(line: currentLine)
                    }
                    try finishRecordOnLineBreak()
                    state = .fieldStart
                    index += 1
                default:
                    // Quote characters inside unquoted fields are literal
                    // data.
                    fieldBuffer.append(byte)
                }

            case .quoted:
                switch byte {
                case UInt8(ascii: "\""):
                    state = .quoteInQuoted
                case UInt8(ascii: "\n"):
                    // Line break inside a quoted field is data.
                    fieldBuffer.append(byte)
                    currentLine += 1
                case UInt8(ascii: "\r"):
                    // CRLF inside a quoted field is data (kept verbatim).
                    fieldBuffer.append(byte)
                    if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") {
                        fieldBuffer.append(UInt8(ascii: "\n"))
                        index += 1
                    }
                    currentLine += 1
                default:
                    fieldBuffer.append(byte)
                }

            case .quoteInQuoted:
                switch byte {
                case UInt8(ascii: "\""):
                    // Escaped quote: "" inside a quoted field.
                    fieldBuffer.append(UInt8(ascii: "\""))
                    state = .quoted
                case delimiter:
                    try finishField()
                    state = .fieldStart
                case UInt8(ascii: "\n"):
                    try finishRecordOnLineBreak()
                    state = .fieldStart
                case UInt8(ascii: "\r"):
                    guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") else {
                        throw ASCAnalyticsError.tsvBareCarriageReturn(line: currentLine)
                    }
                    try finishRecordOnLineBreak()
                    state = .fieldStart
                    index += 1
                default:
                    throw ASCAnalyticsError.tsvTextAfterClosingQuote(
                        line: currentLine,
                        column: fields.count + 1
                    )
                }
            }

            index += 1
        }

        // End of input.
        switch state {
        case .quoted:
            throw ASCAnalyticsError.tsvUnterminatedQuote(line: recordStartLine)
        case .quoteInQuoted:
            // File ends directly after a closing quote: finalize.
            try finishRecord()
        case .unquoted:
            try finishRecord()
        case .fieldStart:
            if !fields.isEmpty || !fieldBuffer.isEmpty {
                // Unreachable: .fieldStart implies both are empty.
                try finishRecord()
            }
        }

        guard !rows.isEmpty else {
            // Input contained only line breaks; no header was found.
            throw ASCAnalyticsError.tsvBlankInput
        }

        return try ASCReportTable(rows: rows)
    }
}

extension ASCDelimiter {
    var delimiterByte: UInt8 {
        switch self {
        case .tab: return UInt8(ascii: "\t")
        case .comma: return UInt8(ascii: ",")
        }
    }
}
