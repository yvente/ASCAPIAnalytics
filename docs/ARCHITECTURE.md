# Architecture

ASCAPIAnalytics is a Swift package (Swift tools 5.9, macOS 14+) that sits on
top of [ASCAPIKit](https://github.com/yvente/ASCAPIKit). This document
describes the module boundaries, dependency direction, and data flow of the
implemented core.

## Module boundaries

| Layer | Contents | Talks to network? | Talks to storage? |
|---|---|---|---|
| `Core` | `ASCAnalyticsError` (structured diagnostics), `ASCCalendarDate` / `ASCDateRange` / `ASCReportGranularity`, `ASCReportProvenance` (+ SHA-256 fingerprinting), `ASCSupportStatus` / `ASCDataCompleteness` / quality notes, `ASCProvenancedRecord` | No | No |
| `Parsing` | `ASCGzipDecoder` (strict RFC 1952 on the system Compression framework), `ASCTSVParser` (byte-level state machine, TSV/CSV), `ASCReportTable` (name-based column lookup, typed accessors with line diagnostics) | No | No |
| `Reports` | `ASCSalesReportParser`, `ASCDownloadsReportParser`, `ASCDiscoveryReportParser` (record models + classification + provenance), `ASCReportProvider` protocol, `ASCAPIClientReportProvider` (ASCAPIKit adapter), `ASCStubReportProvider` (offline) | Only via ASCAPIKit | No |
| `Metrics` | `ASCSalesMetrics`, `ASCDownloadMetrics`, `ASCDiscoveryMetrics`, `ASCConversionRateEvaluator`, `ASCMetricCatalog` | No | No |
| `Aggregation` | `ASCSalesAggregator`, `ASCAnalyticsAggregator` (+ filters, summaries), `ASCInstanceSelection` (latest-processing-date overwrite rule) | No | No |
| `Storage` | `ASCAnalyticsStore` / `ASCAnalyticsStoreTransaction` protocols, ingestion ledger model, `ASCInMemoryAnalyticsStore` reference implementation | No | Protocol only |
| `Sync` | `ASCReportSyncEngine` (idempotent, atomic, quarantine-aware) + configurations/results | Yes, via Reports | Yes, via protocols |

## Dependency direction

```text
            ┌───────────────────────────────────────────────┐
            │                 Host application              │
            │  (owns credentials, chooses storage engine,   │
            │   decides when to run sync)                   │
            └──────┬───────────────────────────────┬────────┘
                   │                               │
                   ▼                               ▼
        ┌────────────────────┐            ┌────────────────────┐
        │    ASCAPIAnalytics │            │   Storage impl     │
        │  Sync ──▶ Reports  │──persist──▶│ (provided by host, │
        │    │               │  protocol  │  e.g. SQLite-based)│
        │    ├─▶ Parsing     │            └────────────────────┘
        │    ├─▶ Metrics     │
        │    └─▶ Aggregation │
        │          Core ◀────│  (all layers depend on Core)
        └─────────┬──────────┘
                  │  only Reports/Sync touch the network,
                  │  and only through ASCAPIKit
                  ▼
        ┌────────────────────┐
        │      ASCAPIKit     │
        │  JWT · HTTP · ASC  │
        └────────────────────┘
```

Rules enforced by review and tests:

- Only `Reports` and `Sync` import ASCAPIKit. Parsing, Metrics, and
  Aggregation are pure, deterministic, and offline-testable.
- No layer imports SwiftUI, UIKit, or AppKit.
- Storage is consumed through protocols declared in this package; the only
  bundled implementation is an in-memory reference store — no database
  driver ships with the library.
- No third-party runtime dependency other than ASCAPIKit and Apple system
  frameworks (Foundation, Compression, CryptoKit).

## Data flow

1. The host app constructs an ASCAPIKit client with its own credentials and
   wraps it in `ASCAPIClientReportProvider` (or injects any other
   `ASCReportProvider`, e.g. the offline stub).
2. `Sync` lists report requests → reports → instances → segments through
   the provider, decides what is missing, and downloads segments.
3. Parsing verifies the schema against the supported report signatures (see
   `REPORT_FORMATS.md`), decompresses, and decodes rows with full
   diagnostics.
4. `Metrics` computes per-row and per-collection metric values. Money is
   `Decimal` only; proceeds are per-unit and multiplied per row.
5. `Aggregation` combines rows under additivity rules: no cross-currency
   sums, no summation of non-additive unique counts, latest processing
   date wins per event date.
6. Results are persisted through the `ASCAnalyticsStore` protocols with
   full provenance and an ingestion-ledger state
   (`imported` / `pendingReview` / `superseded`).
7. `Sync` commits each instance atomically only after every segment
   parsed and verified; conflicting re-deliveries are quarantined as
   pending review; corrected sales versions supersede older ones. See
   `SYNC_SEMANTICS.md`.

## Invariants

- All tests are offline: injected providers, synthetic fixtures only.
- Aggregation never produces totals that break currency or additivity
  rules; where a total is impossible to compute honestly, it is
  represented as `unavailable`, not approximated.
- Apple does not publish every conceivable metric; anything not directly
  supported by published reports stays marked as `unsupported`
  (see `METRIC_DEFINITIONS.md`).
