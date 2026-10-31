# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed (architecture review round 2)

- **Sales version order independence**: importing v1 after v2 never
  demotes v2 — a provably older version is stored as `superseded` on
  arrival (`importedForAuditOnly` outcome, retained for audit) or skipped
  when the content is identical, and an older version never supersedes a
  newer one. A newer version supersedes **all** older current versions;
  incomparable explicit versions are quarantined as `pendingReview`
  instead of coexisting as two current versions with different content.
- **Sales report frequency isolation**: daily, weekly, and monthly
  reports are stored and queryable independently
  (`salesReportKinds` on store queries, `ASCReportProvenance.salesReportKind`);
  the provenance-aware `ASCSalesAggregator.summary` throws
  `ambiguousMetricScope` when its input mixes report kinds instead of
  producing double-counted totals.
- **Analytics correction grouping**: the overwrite rule now keys on a
  **stable logical report identity** (API report id → report name →
  order-insensitive canonical column-set identity), so Apple reordering
  columns or adding a compatible column no longer blocks corrections,
  while standard and detailed variants never merge. The original
  order-sensitive schema fingerprint is retained untouched as audit
  evidence (`ASCReportProvenance.canonicalSchemaIdentity` added).
- **Analytics scope safety**: provenance-aware
  `ASCAnalyticsAggregator.downloads/discovery` apply the overwrite rule
  and throw `ambiguousMetricScope` when asked to sum daily + weekly or
  standard + detailed data;
  `effectiveDownloadRecords/effectiveDiscoveryRecords` gained
  `granularities`/`reportIdentities` selection parameters.
- Documentation: SYNC_SEMANTICS duplicate-segment wording corrected
  (segment-identity dedup), current-data query usage added, no claims of
  exact Apple dashboard alignment.

### Fixed (architecture review round 1)

- **Analytics instance overwrite rule**: `ASCInstanceSelection` now groups
  by (app Apple Identifier, report identity, schema-variant fingerprint,
  granularity, event date) — corrections can no longer overwrite another
  app's, another report's, another standard/detailed variant's, or another
  granularity's data. New `ASCAnalyticsStore.effectiveDownloadRecords` /
  `effectiveDiscoveryRecords` provide the reliable "currently effective
  data" query path so callers never apply the rule by hand.
- **Sales identity**: the ingestion key now carries vendor, report
  type/subtype/frequency (as `salesReportKind`), report date, and version
  with **exact** version matching — a `nil` (unversioned "latest") import
  is a distinct identity, never a wildcard. Unversioned latest downloads
  are recognized by actual content: identical content skips; changed
  content is quarantined as `pendingReview` for manual resolution instead
  of silently replacing counted statistics. An explicit version whose
  content was already imported identifies and supersedes the redundant
  entry; an explicit version against an unversioned import with different
  content is quarantined (order unknowable).
- **Segment handling**: deduplication now trusts segment identity — the
  same segment id is parsed once; different segment ids are both kept even
  when their content is byte-identical. The declared-checksum idempotency
  shortcut only fires when Apple declares a checksum for every segment;
  otherwise idempotency falls back to verified content checksums.
- **Sync defaults**: instances whose headers match no supported report are
  skipped with explicit `skippedUnsupported` diagnostics (never counted,
  never failing the default run); strict mode (`failsOnUnsupportedReports`)
  restores failure semantics. Segment download errors surface as
  per-instance failures instead of thrown errors.
- **Conversion rate semantics**: the downloads report's `Pre-Order` flag
  marks downloads that came from a pre-order (already inside the download
  counts) and is no longer added to Total Downloads
  (`ASCDownloadMetrics.downloadsAndPreOrders` removed as a double count).
  Apple's dashboard denominator ("Impressions (Unique Devices)") includes
  unique product page views, which the Discovery report splits into
  separate events of unpublished overlap — report-derived denominators are
  refused; a rate requires an asserted dashboard basis
  (`ASCImpressionBasis`). Estimates no longer claim a mathematical bound
  direction.
- **Sales app filtering**: `ASCInMemoryAnalyticsStore.salesRecords` now
  uses the same OR attribution semantics as `ASCSalesFilter` — one query
  retrieves an app's direct sales together with its in-app purchases
  without cross-app leakage.
- **GZIP safety**: bounds-checked member-magic reads (a trailing lone
  `0x1F` byte is a structured `gzipTrailingData` error, not a crash);
  zero/negative output limits handled safely.
- **Store transactions**: the active-transaction slot is tracked by a weak
  reference — a transaction dropped unfinished (for example on task
  cancellation) releases it, so later syncs can never hit a permanent
  "another transaction is already active".
- `mostRecentInstancesPerReport` limits ≤ 0 select no instances instead of
  crashing in `prefix`.

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
