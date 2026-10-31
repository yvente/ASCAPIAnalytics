# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Core value types**: `ASCCalendarDate` (ISO and `MM/DD/YYYY` parsing,
  Monday-anchored weeks), `ASCDateRange`, `ASCReportGranularity`,
  `ASCReportProvenance` (schema fingerprint + content checksum + full
  report identity), `ASCSupportStatus`, `ASCDataCompleteness` with Apple's
  published completeness thresholds, `ASCQualityNote`, and the structured
  `ASCAnalyticsError` enum with column/line diagnostics.
- **GZIP decoder** (`ASCGzipDecoder`): RFC 1952 strict decoder built on the
  system Compression framework — full header validation including optional
  fields and `FHCRC`, CRC32/ISIZE trailer verification, concatenated
  members, incremental decompression-bomb limits, and distinct errors for
  truncation, corruption, and unsupported streams.
- **Delimited report parsing** (`ASCTSVParser`, `ASCReportTable`): strict
  UTF-8 (with BOM), LF/CRLF, quoted fields with escaped quotes, empty
  fields, case-insensitive name-based column lookup, per-row line numbers,
  duplicate-header / inconsistent-field-count / invalid-UTF-8 errors, and
  configurable size/row limits. Handles TSV and CSV delimiters with
  automatic header-based detection for Analytics segments.
- **Summary Sales report parsing** (`ASCSalesReportParser`): Apple's
  documented field set, product type classification from Apple's published
  identifier table with unknown types preserved, refund and CMB/CMB-C sign
  conventions verified against Apple's examples, per-unit Developer
  Proceeds (multiplied by units per row, never summed as row totals),
  `Decimal` money throughout, gzip and plain input.
- **App Downloads report parsing** (`ASCDownloadsReportParser`) with the
  documented Download Type glossary (first-time download based on Apple ID
  account, redownload, manual update, auto-update, restore) and pre-order
  flag preservation.
- **App Store Discovery and Engagement report parsing**
  (`ASCDiscoveryReportParser`) with Counts and Unique Counts stored
  separately and per-row deduplication-domain keys.
- **Metrics**: `ASCSalesMetrics` (units by product type, gross sales per
  customer currency, proceeds per proceeds currency, refund/credit and
  zero-price visibility), `ASCDownloadMetrics` (including Apple's
  "Total Downloads" definition), `ASCDiscoveryMetrics` (additive counts
  plus per-domain unique counts that are never summed), and
  `ASCMetricCatalog` documenting every metric's source, additivity, and
  support status.
- **Conversion rate evaluation** (`ASCConversionRateEvaluator`) with
  Apple's corrected definition (downloads and pre-orders over unique
  device impressions), comparability gates (same app, same window,
  single-day, single deduplication domain), `unavailable` reasons, an
  explicitly labeled lower-bound `estimated` path, and the D1/D7/D35
  download-to-paid family marked unsupported.
- **Aggregation** (`ASCSalesAggregator`, `ASCAnalyticsAggregator`): date /
  app / parent-SKU / territory / currency / product-type filters with
  separated attribution namespaces, per-day and per-territory breakdowns,
  and `ASCInstanceSelection` implementing Apple's latest-processing-date
  overwrite rule.
- **Storage** (`ASCAnalyticsStore` protocol, `ASCInMemoryAnalyticsStore`
  reference implementation): atomic transaction commit/rollback, ingestion
  ledger with report identity and checksums, `imported` /
  `pendingReview` / `superseded` states, delivery-keyed conflicting
  re-deliveries, and current vs. audit query scopes.
- **Sync** (`ASCReportSyncEngine`, `ASCReportProvider` protocol): idempotent
  Analytics instance sync (all segments parsed and verified before one
  atomic commit), Sales sync with version supersession, offline stub
  provider, and a production adapter delegating to ASCAPIKit `0.5.x`.
- Documentation: `docs/USAGE.md` (compiled-example verified) and
  `docs/SYNC_SEMANTICS.md`; `docs/METRIC_DEFINITIONS.md`,
  `docs/REPORT_FORMATS.md`, and `docs/ARCHITECTURE.md` updated to the
  implemented state.
- 155 offline tests covering gzip validity and corruption, TSV edge cases,
  all ten documented sales scenarios, money and refund math against
  Apple's published examples, downloads/discovery classification,
  conversion-rate comparability gates, aggregation and currency rules,
  store atomicity, idempotent sync, correction supersession, and offline
  guarantees.

### Notes

- The package is still in **initial development** with no published
  release. The public API may change before a release is prepared.
- Known limitations are documented in `README.md` and
  `docs/METRIC_DEFINITIONS.md` (unsupported cohort metrics, multi-day
  conversion rate, non-SQLite storage).
