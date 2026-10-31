import CryptoKit
import Foundation

/// Identifies which Apple report family a record or ingestion originated
/// from. Values are stable identifiers used in storage and provenance
/// records; they are not Apple's own enum values.
public enum ASCReportSourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    /// Sales and Trends Summary Sales report (`/v1/salesReports`,
    /// `SALES` / `SUMMARY` / `DAILY`).
    case summarySales
    /// App Downloads report from the Analytics Reports API
    /// (`APP_STORE_ENGAGEMENT` / `COMMERCE` category, standard or detailed).
    case analyticsDownloads
    /// App Store Discovery and Engagement report from the Analytics Reports
    /// API (`APP_STORE_ENGAGEMENT` category, standard or detailed).
    case analyticsDiscoveryAndEngagement
    /// Any other report whose content is retained verbatim but not
    /// interpreted.
    case unknown
}

/// Provenance for a batch of parsed records: which Apple report produced
/// the data, through which API objects, with which schema and content
/// fingerprints. Every stored result carries one of these so numbers can be
/// audited back to their source (repository rule 12).
public struct ASCReportProvenance:
    Hashable,
    Codable,
    Sendable,
    CustomStringConvertible
{
    /// The report family.
    public let sourceKind: ASCReportSourceKind
    /// Report `name` attribute as returned by the Analytics Reports API, or
    /// a descriptive name for Sales and Trends reports.
    public let reportName: String?
    /// Report `category` attribute raw value (for example
    /// `APP_STORE_ENGAGEMENT`), when sourced from the Analytics Reports API.
    public let category: String?
    /// Analytics report request identifier, when applicable.
    public let reportRequestID: String?
    /// Analytics report identifier, when applicable.
    public let reportID: String?
    /// Analytics report instance identifier, when applicable.
    public let instanceID: String?
    /// Identifier of the individual segment file this batch came from.
    public let segmentID: String?
    /// Apple's processing date (`YYYY-MM-DD`) of the instance this batch
    /// came from, when applicable. Later processing dates supersede earlier
    /// ones for the same event dates (Apple, Data Completeness and
    /// Corrections).
    public let processingDate: String?
    /// Instance granularity, when applicable.
    public let granularity: ASCReportGranularity?
    /// Sales and Trends vendor number, when applicable.
    public let vendorNumber: String?
    /// Sales and Trends report date filter value, when applicable.
    public let reportDate: String?
    /// Sales and Trends report version; a later version is Apple's
    /// correction of the same report date.
    public let reportVersion: String?
    /// SHA-256 over the canonicalized header row of the parsed file.
    /// Identifies the exact column set that was verified.
    public let schemaFingerprint: String
    /// SHA-256 over the raw (still compressed, as-downloaded) bytes of the
    /// segment or report file.
    public let contentChecksum: String
    /// Time the bytes were fetched or the fixture was created. For parsed
    /// inputs without a fetch step this is the parse time.
    public let fetchedAt: Date
    /// Number of records parsed from the source file.
    public let recordCount: Int

    public init(
        sourceKind: ASCReportSourceKind,
        reportName: String? = nil,
        category: String? = nil,
        reportRequestID: String? = nil,
        reportID: String? = nil,
        instanceID: String? = nil,
        segmentID: String? = nil,
        processingDate: String? = nil,
        granularity: ASCReportGranularity? = nil,
        vendorNumber: String? = nil,
        reportDate: String? = nil,
        reportVersion: String? = nil,
        schemaFingerprint: String,
        contentChecksum: String,
        fetchedAt: Date,
        recordCount: Int
    ) {
        self.sourceKind = sourceKind
        self.reportName = reportName
        self.category = category
        self.reportRequestID = reportRequestID
        self.reportID = reportID
        self.instanceID = instanceID
        self.segmentID = segmentID
        self.processingDate = processingDate
        self.granularity = granularity
        self.vendorNumber = vendorNumber
        self.reportDate = reportDate
        self.reportVersion = reportVersion
        self.schemaFingerprint = schemaFingerprint
        self.contentChecksum = contentChecksum
        self.fetchedAt = fetchedAt
        self.recordCount = recordCount
    }

    public var description: String {
        "ASCReportProvenance(\(sourceKind.rawValue), instance: \(instanceID ?? "-"), segment: \(segmentID ?? "-"), processingDate: \(processingDate ?? "-"), version: \(reportVersion ?? "-"))"
    }

    /// Returns a copy with the given segment identifier.
    public func withSegmentID(_ segmentID: String?) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: sourceKind,
            reportName: reportName,
            category: category,
            reportRequestID: reportRequestID,
            reportID: reportID,
            instanceID: instanceID,
            segmentID: segmentID,
            processingDate: processingDate,
            granularity: granularity,
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: reportVersion,
            schemaFingerprint: schemaFingerprint,
            contentChecksum: contentChecksum,
            fetchedAt: fetchedAt,
            recordCount: recordCount
        )
    }

    /// Returns a copy with the given report/instance context filled in.
    public func withAnalyticsContext(
        reportName: String?,
        category: String?,
        reportRequestID: String?,
        reportID: String?,
        instanceID: String?,
        processingDate: String?,
        granularity: ASCReportGranularity?
    ) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: sourceKind,
            reportName: reportName ?? self.reportName,
            category: category ?? self.category,
            reportRequestID: reportRequestID ?? self.reportRequestID,
            reportID: reportID ?? self.reportID,
            instanceID: instanceID ?? self.instanceID,
            segmentID: segmentID,
            processingDate: processingDate ?? self.processingDate,
            granularity: granularity ?? self.granularity,
            vendorNumber: vendorNumber,
            reportDate: reportDate,
            reportVersion: reportVersion,
            schemaFingerprint: schemaFingerprint,
            contentChecksum: contentChecksum,
            fetchedAt: fetchedAt,
            recordCount: recordCount
        )
    }

    /// Returns a copy with the given Sales and Trends context filled in.
    public func withSalesContext(
        vendorNumber: String?,
        reportDate: String?,
        reportVersion: String?
    ) -> ASCReportProvenance {
        ASCReportProvenance(
            sourceKind: sourceKind,
            reportName: reportName,
            category: category,
            reportRequestID: reportRequestID,
            reportID: reportID,
            instanceID: instanceID,
            segmentID: segmentID,
            processingDate: processingDate,
            granularity: granularity,
            vendorNumber: vendorNumber ?? self.vendorNumber,
            reportDate: reportDate ?? self.reportDate,
            reportVersion: reportVersion ?? self.reportVersion,
            schemaFingerprint: schemaFingerprint,
            contentChecksum: contentChecksum,
            fetchedAt: fetchedAt,
            recordCount: recordCount
        )
    }
}

/// Fingerprinting helpers shared by parsers and the sync engine.
public enum ASCFingerprint {
    /// SHA-256 hex digest of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 hex digest of the canonicalized header row: fields joined
    /// with tabs, case preserved, surrounding whitespace of each field
    /// trimmed. Column *positions* may change over time per Apple's
    /// guidance; the fingerprint pins the column *set* that was verified.
    public static func schemaFingerprint(header: [String]) -> String {
        let canonical = header
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\t")
        return sha256Hex(Data(canonical.utf8))
    }
}
