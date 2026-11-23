import ASCAPIKit
import Foundation

/// Network boundary of ASCAPIAnalytics.
///
/// The sync engine talks to App Store Connect exclusively through this
/// protocol. The production adapter delegates every call to ASCAPIKit's
/// `ASCClient` (which owns authentication, JWT signing, and transport
/// security); the offline stub serves scripted data without touching the
/// network. Tests always run against injectable implementations — no test
/// may reach the network.
public protocol ASCReportProvider: Sendable {
    /// Lists the Analytics report requests of an app.
    func listAnalyticsReportRequests(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> [ASCAnalyticsReportRequest]

    /// Creates an Analytics report request for an app.
    func createAnalyticsReportRequest(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> ASCAnalyticsReportRequest

    /// Lists the reports generated for a report request.
    func listAnalyticsReports(
        reportRequestID: String,
        categories: [ASCAnalyticsReportCategory],
        names: [String]
    ) async throws -> [ASCAnalyticsReport]

    /// Lists the instances of a report.
    func listAnalyticsReportInstances(
        reportID: String,
        granularities: [ASCAnalyticsReportGranularity],
        processingDates: [String]
    ) async throws -> [ASCAnalyticsReportInstance]

    /// Lists the segments (physical files) of an instance.
    func listAnalyticsReportSegments(
        instanceID: String
    ) async throws -> [ASCAnalyticsReportSegment]

    /// Downloads one segment's bytes. Production adapters verify the
    /// segment's size and checksum before returning.
    func downloadAnalyticsReportSegment(
        _ segment: ASCAnalyticsReportSegment
    ) async throws -> Data

    /// Downloads a Sales and Trends report as raw (gzip) bytes.
    func downloadSalesReport(
        _ request: ASCSalesReportRequest
    ) async throws -> Data
}

/// Production adapter over ASCAPIKit. All App Store Connect
/// authentication and HTTP handling stays inside ASCAPIKit; this adapter
/// only forwards calls and results.
public struct ASCAPIClientReportProvider: ASCReportProvider {
    private let client: ASCClient

    /// - Parameter client: a configured ASCAPIKit client. The host app owns
    ///   credentials and transport; nothing here reads or stores them.
    public init(client: ASCClient) {
        self.client = client
    }

    public func listAnalyticsReportRequests(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> [ASCAnalyticsReportRequest] {
        try await client.listAnalyticsReportRequests(
            appID: appID,
            accessTypes: [accessType]
        )
    }

    public func createAnalyticsReportRequest(
        appID: String,
        accessType: ASCAnalyticsReportAccessType
    ) async throws -> ASCAnalyticsReportRequest {
        try await client.createAnalyticsReportRequest(
            appID: appID,
            accessType: accessType
        )
    }

    public func listAnalyticsReports(
        reportRequestID: String,
        categories: [ASCAnalyticsReportCategory],
        names: [String]
    ) async throws -> [ASCAnalyticsReport] {
        try await client.listAnalyticsReports(
            reportRequestID: reportRequestID,
            categories: categories,
            names: names
        )
    }

    public func listAnalyticsReportInstances(
        reportID: String,
        granularities: [ASCAnalyticsReportGranularity],
        processingDates: [String]
    ) async throws -> [ASCAnalyticsReportInstance] {
        try await client.listAnalyticsReportInstances(
            reportID: reportID,
            granularities: granularities,
            processingDates: processingDates
        )
    }

    public func listAnalyticsReportSegments(
        instanceID: String
    ) async throws -> [ASCAnalyticsReportSegment] {
        try await client.listAnalyticsReportSegments(instanceID: instanceID)
    }

    public func downloadAnalyticsReportSegment(
        _ segment: ASCAnalyticsReportSegment
    ) async throws -> Data {
        try await client.downloadAnalyticsReportSegment(segment)
    }

    public func downloadSalesReport(
        _ request: ASCSalesReportRequest
    ) async throws -> Data {
        try await client.downloadSalesReport(request)
    }
}
