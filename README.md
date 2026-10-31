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
  Exactly computable only for single-day windows with a single unique
  impressions deduplication domain; otherwise `unavailable`, or
  `estimated` with an explicit lower-bound note on request. D1/D7/D35
  download-to-paid and retention cohorts are **unsupported** by design.
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

### Not implemented / not precisely reproducible

- **No SQLite or any database driver** — storage is a protocol; host apps
  provide implementations.
- **D1/D7/D35 download-to-paid** and **retention cohorts**: Apple's public
  reports do not publish cohort-level data; the package refuses to
  approximate them.
- **Multi-day conversion rates**: unique device impressions are deduplicated
  per day by Apple, so exact multi-day rates cannot be recomputed from
  published exports; the evaluator returns `unavailable` or an explicitly
  labeled lower-bound `estimated` value.
- **Apple's own dashboard numbers**: metrics here are recomputed from
  published report files; where a report basis differs from a dashboard
  metric (for example Pre-Orders minus cancellations), that is documented
  in `docs/METRIC_DEFINITIONS.md` rather than hidden.
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
