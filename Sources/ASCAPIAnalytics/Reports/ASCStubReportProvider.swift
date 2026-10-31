import ASCAPIKit
import Foundation

/// Offline, scriptable `ASCReportProvider` for tests, previews, and demos.
///
/// The stub never performs network I/O: every operation either consults a
/// caller-installed handler or returns a deterministic default (an empty
/// list, or an error for downloads). All calls are recorded so tests can
/// assert exactly what was requested — including that *nothing* was
/// requested.
public final class ASCStubReportProvider: ASCReportProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var callLogStorage: [String] = []

    /// Every operation invoked on this stub, in order, with arguments.
    public var callLog: [String] {
        lock.withLock { callLogStorage }
    }

    private func record(_ entry: String) {
        lock.withLock { callLogStorage.append(entry) }
    }

    // MARK: - Scripted handlers

    public var listAnalyticsReportRequestsHandler:
        (@Sendable (String, ASCAnalyticsReportAccessType) async throws -> [ASCAnalyticsReportRequest])?
    public var createAnalyticsReportRequestHandler:
        (@Sendable (String, ASCAnalyticsReportAccessType) async throws -> ASCAnalyticsReportRequest)?
    public var listAnalyticsReportsHandler:
        (@Sendable (String, [ASCAnalyticsReportCategory], [String]) async throws -> [ASCAnalyticsReport])?
    public var listAnalyticsReportInstancesHandler:
        (@Sendable (String, [ASCAnalyticsReportGranularity], [String]) async throws -> [ASCAnalyticsReportInstance])?
    public var listAnalyticsReportSegmentsHandler:
        (@Sendable (String) async throws -> [ASCAnalyticsReportSegment])?
    public var downloadAnalyticsReportSegmentHandler:
        (@Sendable (ASCAnalyticsReportSegment) async throws -> Data)?
    public var downloadSalesReportHandler:
        (@Sendable (ASCSalesReportRequest) async throws -> Data)?

    public init() {}

    // MARK: - ASCReportProvider

    public func listAnalyticsReportRequests(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> [ASCAnalyticsReportRequest] {
        record("listAnalyticsReportRequests(appID: \(appID), accessType: \(accessType.rawValue))")
        if let handler = listAnalyticsReportRequestsHandler {
            return try await handler(appID, accessType)
        }
        return []
    }

    public func createAnalyticsReportRequest(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> ASCAnalyticsReportRequest {
        record("createAnalyticsReportRequest(appID: \(appID), accessType: \(accessType.rawValue))")
        if let handler = createAnalyticsReportRequestHandler {
            return try await handler(appID, accessType)
        }
        throw ASCAnalyticsError.providerInvalidData(
            reason: "ASCStubReportProvider: no createAnalyticsReportRequest handler configured"
        )
    }

    public func listAnalyticsReports(
        reportRequestID: String,
        categories: [ASCAnalyticsReportCategory],
        names: [String]
    ) async throws -> [ASCAnalyticsReport] {
        record("listAnalyticsReports(reportRequestID: \(reportRequestID), categories: \(categories.map(\.rawValue)), names: \(names))")
        if let handler = listAnalyticsReportsHandler {
            return try await handler(reportRequestID, categories, names)
        }
        return []
    }

    public func listAnalyticsReportInstances(
        reportID: String,
        granularities: [ASCAnalyticsReportGranularity],
        processingDates: [String]
    ) async throws -> [ASCAnalyticsReportInstance] {
        record("listAnalyticsReportInstances(reportID: \(reportID), granularities: \(granularities.map(\.rawValue)), processingDates: \(processingDates))")
        if let handler = listAnalyticsReportInstancesHandler {
            return try await handler(reportID, granularities, processingDates)
        }
        return []
    }

    public func listAnalyticsReportSegments(
        instanceID: String
    ) async throws -> [ASCAnalyticsReportSegment] {
        record("listAnalyticsReportSegments(instanceID: \(instanceID))")
        if let handler = listAnalyticsReportSegmentsHandler {
            return try await handler(instanceID)
        }
        return []
    }

    public func downloadAnalyticsReportSegment(
        _ segment: ASCAnalyticsReportSegment
    ) async throws -> Data {
        record("downloadAnalyticsReportSegment(segmentID: \(segment.id))")
        if let handler = downloadAnalyticsReportSegmentHandler {
            return try await handler(segment)
        }
        throw ASCAnalyticsError.providerInvalidData(
            reason: "ASCStubReportProvider: no segment data configured for segment \(segment.id)"
        )
    }

    public func downloadSalesReport(
        _ request: ASCSalesReportRequest
    ) async throws -> Data {
        record("downloadSalesReport(vendor: \(request.vendorNumber), type: \(request.reportType.rawValue), subType: \(request.reportSubType.rawValue), frequency: \(request.frequency.rawValue), reportDate: \(request.reportDate ?? "nil"), version: \(request.version ?? "nil"))")
        if let handler = downloadSalesReportHandler {
            return try await handler(request)
        }
        throw ASCAnalyticsError.providerInvalidData(
            reason: "ASCStubReportProvider: no sales report data configured"
        )
    }
}
