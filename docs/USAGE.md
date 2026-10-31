# Usage

All examples below are compiled and executed by the offline test suite
(`ASCAPIAnalyticsUsageTests`), so they stay in sync with the real API.
Every fixture is hand-crafted synthetic data — nothing here contacts
App Store Connect.

## Parsing a Summary Sales report from `Data`

The parser accepts gzip (as returned by `ASCAPIKit.downloadSalesReport`)
or plain UTF-8 TSV; gzip is detected by magic bytes, never assumed.

```swift
import ASCAPIAnalytics

let salesData: Data = /* report bytes: from ASCAPIKit or a manual export */

let result = try ASCSalesReportParser().parse(salesData)

for record in result.records {
    // record.beginDate / endDate are Apple's MM/DD/YYYY report days
    // record.productType classifies the Product Type Identifier;
    // unknown identifiers stay .unknown(raw:) and are never counted
    // as a known sale.
    print(record.rawProductType, record.units, record.grossSalesImpact)
}

// result.schemaFingerprint  SHA-256 of the verified header
// result.contentChecksum    SHA-256 of the bytes as received
```

## Parsing an Analytics report segment from `Data`

Segment files from the Analytics Reports API (as downloaded by
`ASCAPIKit.downloadAnalyticsReportSegment`) may be gzip-compressed and
tab- or comma-delimited; the delimiter is detected from the header.

```swift
import ASCAPIAnalytics

let segmentData: Data = /* segment bytes */

let downloads = try ASCDownloadsReportParser().parse(segmentData)
// downloads.records: date, appAppleIdentifier, downloadType,
// territory, counts, isPreOrder (+ every other column preserved
// verbatim in extraFields)

let discovery = try ASCDiscoveryReportParser().parse(segmentData)
// discovery.records: event (impression/page view/tap), counts,
// uniqueCounts — kept separately; uniqueCounts carries its
// deduplication domain key
```

## Metrics and aggregation

```swift
import ASCAPIAnalytics

let metrics = ASCSalesMetrics(records: result.records)

// Money is Decimal and bucketed per currency:
metrics.grossSales(currency: "USD")          // Decimal? — nil when absent
metrics.developerProceeds(currency: "USD")   // Decimal? — nil when absent
metrics.unitBreakdown.appUnits
metrics.unitBreakdown.unknownUnits           // never folded into app units
metrics.unknownProductTypeIdentifiers        // raw identifiers to watch

// A total across currencies is structurally unavailable:
metrics.combinedGrossSalesAcrossCurrencies
// → .unavailable(reason: "…requires an explicit conversion step…")

// Account-level summaries with filters:
let summary = ASCSalesAggregator().summary(result.records, filter: ASCSalesFilter(
    dateRange: ASCDateRange(
        start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
        end: ASCCalendarDate(iso8601Day: "2025-10-31")!
    ),
    appAppleIdentifiers: ["1234567890"],   // direct app rows
    parentIdentifiers: nil,                // in-app purchase rows (parent SKU)
    territories: nil,
    customerCurrencies: nil
))
// summary.totals, summary.byDay, summary.byApp — same currency rules apply
```

```swift
// Analytics aggregation: counts are additive, unique counts are not.
let downloadSummary = ASCAnalyticsAggregator().downloads(downloadRecords)
downloadSummary.totals.firstTimeDownloads   // Apple ID account based
downloadSummary.totals.appleTotalDownloads  // first-time + redownloads
downloadSummary.byDay, downloadSummary.byTerritory

let discoverySummary = ASCAnalyticsAggregator().discovery(discoveryRecords)
discoverySummary.totals.impressionCounts            // additive
discoverySummary.totals.combinedUniqueImpressionCounts
// → .unavailable(reason: "…summing them would double-count devices")
// unless the input is a single date in a single dimension combination
```

## Conversion rate

Apple's definition (Analytics metric definitions): *"Total downloads and
pre-orders divided by unique device impressions."*

```swift
let aggregator = ASCAnalyticsAggregator()
let rate = aggregator.conversionRate(
    downloads: downloadRecords,
    impressions: discoveryRecords,
    filter: ASCAnalyticsFilter(
        appIdentifiers: ["1234567890"],
        dateRange: ASCDateRange.singleDay(ASCCalendarDate(iso8601Day: "2025-10-01")!)
    )
)

switch rate {
case .available(let rate, let numerator, let denominator):
    // exact, single-day, single deduplication domain
case .estimated(let rate, _, _, let note):
    // explicitly labeled lower bound (multi-day denominator)
case .unavailable(let reason):
    // windows differ, dimension splits, zero impressions, …
case .unsupported(let reason):
    // never produced for conversion rate; used for D1/D7/D35 cohorts
}
```

D1/D7/D35 download-to-paid and retention cohorts are unsupported and
reported as such — Apple's public reports do not carry cohort-level data.

## Listing and syncing reports

The sync engine talks to App Store Connect only through the injectable
`ASCReportProvider`. Production apps use the ASCAPIKit adapter with their
own client; tests and previews use the offline stub. The engine never
schedules work — the host app calls it.

```swift
import ASCAPIAnalytics
import ASCAPIKit

// The host app owns credentials and transport:
let client = try ASCClient(
    configuration: myCredentialConfiguration,   // host-owned
    privateKeyPEM: myPrivateKeyPEM              // host-owned
)
let provider = ASCAPIClientReportProvider(client: client)
let store: ASCAnalyticsStore = myStoreImplementation()
let engine = ASCReportSyncEngine(provider: provider)

// Analytics (App Downloads, Discovery and Engagement, …):
let analyticsResult = try await engine.syncAnalytics(
    ASCAnalyticsSyncConfiguration(appID: myAppResourceID),
    store: store
)
// analyticsResult.outcomes: imported / skippedAlreadyImported /
// pendingReview / failed per instance

// Sales and Trends (Summary Sales):
let salesResult = try await engine.syncSales(
    ASCSalesSyncConfiguration(
        vendorNumber: "80000",
        frequency: .daily,
        reportDates: ["2025-10-01", "2025-10-02"]
    ),
    store: store
)
```

Repeat runs are idempotent; see `docs/SYNC_SEMANTICS.md` for the exact
late-data, correction, and quarantine semantics.

## Querying stored data

```swift
// Current-scope queries exclude superseded and pending-review data.
let records = try await store.downloadRecords(
    appIdentifiers: ["1234567890"],
    in: ASCDateRange(
        start: ASCCalendarDate(iso8601Day: "2025-10-01")!,
        end: ASCCalendarDate(iso8601Day: "2025-10-31")!
    )
)
// every record carries full ASCReportProvenance for audit

// Apple's overwrite rule across processing dates:
let latest = ASCInstanceSelection.latestProcessingDatePerEventDate(records)
let metrics = ASCDownloadMetrics(records: latest.map(\.record))

// Data completeness against Apple's published thresholds:
let completeness = ASCReportCompletenessThreshold.assess(
    eventDate: ASCCalendarDate(iso8601Day: "2025-10-01")!,
    processingDate: ASCCalendarDate(iso8601Day: "2025-10-03")!,
    thresholdDays: ASCReportCompletenessThreshold.analyticsDownloadsDays
)
// .complete

// Metric support statuses (including what is NOT supported):
for metric in ASCMetricCatalog.allCases {
    print(metric.supportStatus, metric.additivity)
}
```

## Storage implementations

The package ships only the protocol and the in-memory reference
implementation (`ASCInMemoryAnalyticsStore`) — no database driver. Host
apps implement `ASCAnalyticsStore` (+ its transaction protocol) on their
own engine; the contract requires all-or-nothing commits, exactly as the
sync engine relies on.
