# ASCAPIAnalytics

Swift package for retrieving, parsing, and aggregating App Store Connect
reporting data — the reporting companion to
[ASCAPIKit](https://github.com/yvente/ASCAPIKit).

## Status: initial development (core implemented, no release)

> ⚠️ **This package has no published release yet.** The first core
> implementation (report parsing, metrics, aggregation, storage protocol,
> sync engine) is complete and covered by an offline test suite, but the
> version below is still `0.1.0-dev` and the public API may still change
> before a real release is prepared by the maintainer.

### What is implemented and tested

- **GZIP decoding** (`ASCGzipDecoder`): strict RFC 1952 decoder on Apple's
  system Compression framework — header validation (magic, method, reserved
  flags, `FEXTRA`/`FNAME`/`FCOMMENT`/`FHCRC`), CRC32 and ISIZE trailer
  verification, concatenated members, incremental decompression-bomb
  protection, and hard errors for truncated or corrupt streams.
- **Delimited report parsing** (`ASCTSVParser`, `ASCReportTable`): strict
  UTF-8 TSV/CSV with BOM, LF/CRLF, quoting and escaped quotes, empty
  fields, name-based (not position-based) column lookup, line-number
  diagnostics, and limits. Column order changes and unknown columns are
  handled as Apple advises; unknown columns are preserved verbatim.
- **Summary Sales report** (`ASCSalesReportParser`): Apple's documented
  field set (version 1_3), product type classification from Apple's
  published table (unknown types preserved, never silently counted as
  sales), refunds and CMB/CMB-C credits with Apple's exact sign
  conventions, per-unit Developer Proceeds, `Decimal` money only.
- **App Downloads report** (`ASCDownloadsReportParser`): first-time
  downloads (Apple ID account based), redownloads, manual updates,
  auto-updates, restores; unknown download types preserved; pre-order flag
  kept separate.
- **App Store Discovery and Engagement report**
  (`ASCDiscoveryReportParser`): impressions, page views, taps with raw
  source/page/engagement dimensions; Counts and Unique Counts stored
  separately.
- **Metrics** with explicit semantics: units by product type, gross sales
  per Customer Currency, developer proceeds per Currency of Proceeds —
  never summed across currencies.
- **Conversion rate** (`ASCConversionRateEvaluator`): Apple's definition —
  total downloads and pre-orders divided by unique device impressions.
  Apple's dashboard denominator includes unique product page views, which
  the Discovery report splits into separate events whose device overlap is
  unpublished; a rate is therefore returned only for single-day windows
  with a single deduplication domain **and an explicitly asserted
  dashboard-basis denominator**, otherwise `unavailable` (or, for
  multi-day windows only, `estimated` without a claimed bound direction).
  D1/D7/D35 download-to-paid and retention cohorts are **unsupported** by
  design.
- **Aggregation** (`ASCSalesAggregator`, `ASCAnalyticsAggregator`):
  filtering by date/app/territory/currency, per-day and per-territory
  breakdowns, and Apple's documented overwrite rule for report instances
  (latest processing date wins per event date).
- **Storage protocol** (`ASCAnalyticsStore`) with atomic
  transaction/commit/rollback semantics, an ingestion ledger (report
  identity, instance and segment ids, processing date, granularity, schema
  fingerprint, content checksum, imported/pending-review/superseded
  state), and a thread-safe in-memory reference implementation.
- **Sync engine** (`ASCReportSyncEngine`): idempotent Analytics and Sales
  sync through the injectable `ASCReportProvider` (production adapter over
  ASCAPIKit + offline stub), all-or-nothing per instance, content-change
  quarantine as pending review, and Sales version supersession. No
  scheduler — the host app decides when to run it.
- **Transaction scheduling without retries**: `ASCInMemoryAnalyticsStore`
  queues `beginTransaction` callers **FIFO with asynchronous waiting** —
  no fixed retry caps, no `Task.yield` loops. Waiters are
  cancellation-safe; abandoned (dropped) transactions cannot stall the
  store. `storeInconsistentState` now only ever describes a real
  store-protocol misuse.
- **Offline report verification** (`ASCAnalyticsVerify` CLI): verifies
  local Apple report files against the official parsers — gzip/TSV/CSV,
  header identification, unknown-value surfacing, line-number
  diagnostics, optional single-currency reconciliation against a local
  expected-JSON file. **Fully offline, zero telemetry, never prints raw
  report rows.** See `docs/REAL_REPORT_VALIDATION.md` and
  `docs/VALIDATION_MATRIX.md`.

### Not implemented / not precisely reproducible

- **No SQLite or any database driver** — storage is a protocol; host apps
  provide implementations.
- **D1/D7/D35 download-to-paid** and **retention cohorts**: Apple's public
  reports do not publish cohort-level data; the package refuses to
  approximate them.
- **Conversion-rate denominators derived from the Discovery report**:
  Apple's dashboard denominator ("Impressions (Unique Devices)") includes
  unique product page views, which the report records as separate events
  whose per-device overlap is unpublished; report-derived denominators are
  always refused, and a rate requires an explicitly asserted dashboard
  basis.
- **Multi-day conversion rates**: unique devices are deduplicated per
  day, so multi-day rates cannot be recomputed exactly; on an asserted
  dashboard basis the evaluator returns an `estimated` value whose note
  claims no bound direction.
- **Pre-order placements**: the downloads report's `Pre-Order` flag marks
  downloads that came from a pre-order (already inside the download
  counts); pre-order placements minus cancellations live in the Pre-orders
  report, which is not consumed yet.
- **Apple's own dashboard numbers**: metrics here are recomputed from
  published report files; where a report basis differs from a dashboard
  metric, that is documented in `docs/METRIC_DEFINITIONS.md` rather than
  hidden.
- **Real-report verification**: a real Apple Daily Summary Sales report
  (2026-10-28) parses **64/64 rows** — Summary Sales is certified at
  **LEVEL 3 (REAL_REPORT_PARSED)** in `docs/VALIDATION_MATRIX.md`; the
  Analytics report families remain at LEVEL 2 (official format verified;
  no real reports available). Run the verification CLI locally with a
  private report to reach LEVEL 3/4 for those.
- Weekly/monthly Analytics instances and the remaining Analytics report
  families (usage, performance, commerce) parse only through the generic
  machinery; their dedicated models and metrics are future work.

## Relationship to ASCAPIKit

All App Store Connect authentication and API requests are delegated to
[ASCAPIKit](https://github.com/yvente/ASCAPIKit). ASCAPIAnalytics **never**
re-implements ES256 JWT signing, Apple's HTTP API client, or App Store
Connect models. It depends on `ASCAPIKit` `0.5.x` only
(`.upToNextMinor(from: "0.5.0")`).

## What this package is not

- **No UI.** No SwiftUI, UIKit, or AppKit.
- **No database driver.** Storage is a protocol abstraction; host apps choose
  the concrete implementation (e.g. SQLite, GRDB, Core Data).
- **No telemetry.** Report data and credentials never leave the host app.
- **No third-party runtime dependencies** beyond ASCAPIKit and Apple system
  frameworks (Foundation, Compression, CryptoKit).
- **No background scheduling.** The sync engine runs when the host app
  calls it.

## Data ownership

All report data, credentials, and computed metrics stay under the control of
the app that embeds this package. ASCAPIAnalytics performs no network
communication other than the App Store Connect requests the host app makes
through ASCAPIKit, and it never uploads data anywhere. Tests run fully
offline against synthetic fixtures; no real report, API key, or private key
is ever committed or transmitted.

## Platform

macOS 14+ is the primary (currently only) supported platform.

## Build and test

```bash
swift package resolve
swift build
swift test
```

Requirements: macOS 14+ with a Swift 5.9+ toolchain.

Usage examples (offline parsing, metrics, aggregation, sync) are in
[docs/USAGE.md](docs/USAGE.md). Sync semantics are documented in
[docs/SYNC_SEMANTICS.md](docs/SYNC_SEMANTICS.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) for the
non-negotiable constraints of this repository (money handling, additivity
rules, offline tests, and security rules).

## License

[MIT](LICENSE) © yvente
