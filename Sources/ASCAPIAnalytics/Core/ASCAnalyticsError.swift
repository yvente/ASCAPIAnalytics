import Foundation

/// Errors raised by ASCAPIAnalytics.
///
/// Every case carries enough context (column names, line numbers, expected
/// versus actual values) to diagnose malformed or unsupported input without
/// inspecting the original report, in line with the provenance and
/// diagnostics rules of this package.
public enum ASCAnalyticsError: Error, Equatable, Sendable {

    // MARK: - GZIP decoding

    /// The input does not start with the gzip magic bytes `0x1F 0x8B`.
    case gzipInvalidMagic

    /// The gzip compression method byte is not 8 (deflate).
    case gzipUnsupportedCompressionMethod(rawMethod: UInt8)

    /// The gzip header sets flag bits that RFC 1952 requires to be zero.
    case gzipUnsupportedHeaderFlags(rawFlags: UInt8)

    /// The gzip member ends in the middle of its header or optional fields.
    case gzipHeaderTruncated

    /// A header checksum (FHCRC) present in the header does not match.
    case gzipHeaderChecksumMismatch(expected: UInt16, actual: UInt16)

    /// A quoted optional header field (FEXTRA, FNAME, FCOMMENT) is not
    /// terminated inside the member.
    case gzipOptionalFieldTruncated(field: String)

    /// The deflate stream ends before a complete member (CRC32 and ISIZE)
    /// could be read.
    case gzipStreamTruncated

    /// Data follows the last complete gzip member that is neither another
    /// gzip member nor empty.
    case gzipTrailingData(offset: Int)

    /// The inflate stage failed to produce a valid deflate stream.
    case gzipDeflateFailed(status: Int)

    /// Decompressed output would exceed the configured limit.
    case gzipOutputLimitExceeded(limit: Int)

    /// The CRC32 of the decompressed bytes does not match the footer.
    case gzipCRC32Mismatch(expected: UInt32, actual: UInt32)

    /// The ISIZE (decompressed size modulo 2^32) does not match the actual
    /// decompressed byte count.
    case gzipISIZEMismatch(expected: Int, actual: Int)

    /// The gzip member count exceeds the configured limit.
    case gzipMemberLimitExceeded(limit: Int)

    // MARK: - TSV / CSV parsing

    /// The input is not valid UTF-8.
    case tsvInvalidUTF8

    /// The input contains no bytes at all; a report header is required.
    case tsvEmptyInput

    /// The input consists only of blank lines; a report header is required.
    case tsvBlankInput

    /// A header column name is empty; column lookup relies on names.
    case tsvEmptyHeaderName(line: Int, column: Int)

    /// A bare carriage return was found outside a quoted field; supported
    /// report formats use LF or CRLF line endings only.
    case tsvBareCarriageReturn(line: Int)

    /// Two columns in the header share the same name (compared
    /// case-insensitively, because Apple instructs consumers to rely on
    /// column names rather than positions).
    case tsvDuplicateHeader(name: String, firstColumn: Int, duplicateColumn: Int)

    /// A data row has a different field count than the header.
    case tsvInconsistentFieldCount(line: Int, expected: Int, actual: Int)

    /// A quoted field was opened but never closed on the same logical record.
    case tsvUnterminatedQuote(line: Int)

    /// Text follows the closing quote of a quoted field (for example
    /// `"abc"def`), which no supported report format produces.
    case tsvTextAfterClosingQuote(line: Int, column: Int)

    /// The row count exceeds the configured limit.
    case tsvRowLimitExceeded(limit: Int)

    /// The input size exceeds the configured limit.
    case tsvSizeLimitExceeded(limit: Int)

    /// A single record declares more fields than the configured limit.
    case tsvFieldCountLimitExceeded(limit: Int, line: Int)

    // MARK: - Report parsing

    /// A column the report format requires is missing from the header.
    case missingRequiredColumn(report: String, column: String)

    /// A required field is present in the header but blank in a data row.
    case missingRequiredField(report: String, column: String, line: Int)

    /// A field value cannot be parsed or validated.
    case invalidFieldValue(report: String, column: String, value: String, line: Int, reason: String)

    /// The header does not match the known signature of the requested report,
    /// so parsing is refused instead of guessing field semantics.
    case unsupportedReportHeader(report: String, header: [String], reason: String)

    /// A delimiter could not be determined unambiguously.
    case ambiguousDelimiter(report: String, headerTabs: Int, headerCommas: Int)

    // MARK: - Storage and sync

    /// The store rejected an operation or violated its contract.
    case storeInconsistentState(reason: String)

    /// An instance could not be completed because one or more segments were
    /// missing, failed to download, or failed validation. No data from this
    /// instance was committed.
    case instanceIncomplete(instanceID: String, reason: String)

    /// A report instance or sales report was previously imported with the
    /// same identity but different content, and the update semantics cannot
    /// be proven. The data is retained for review and excluded from queries.
    case ingestionPendingReview(identity: String, reason: String)

    /// The provider returned data that cannot be processed.
    case providerInvalidData(reason: String)

    /// An aggregation input spans multiple report granularities (daily +
    /// weekly) or multiple logical report variants (standard + detailed)
    /// for the same event scope. Summing them would double count the same
    /// underlying events; select one granularity/variant (see
    /// `ASCAnalyticsStore.effectiveDownloadRecords` /
    /// `effectiveDiscoveryRecords`) and aggregate again.
    case ambiguousMetricScope(reason: String)
}
