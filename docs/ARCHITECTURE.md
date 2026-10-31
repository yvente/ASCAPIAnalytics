# Architecture

ASCAPIAnalytics is a Swift package (Swift tools 5.9, macOS 14+) that sits on
top of [ASCAPIKit](https://github.com/yvente/ASCAPIKit). This document
describes the planned module boundaries, dependency direction, and data flow.
**The package is in initial development — layers below are planning targets,
not implemented code.** See `CHANGELOG.md` for what exists.

## Module boundaries

The library is organized into focused layers. Source subdirectories are
created when code is actually added; no placeholder files are kept.

| Layer | Responsibility | Talks to network? | Talks to storage? |
|---|---|---|---|
| `Core` | Shared value types, errors, configuration, provenance records | No | No |
| `Reports` | Report retrieval flows: which report, which date range, which instance; hands raw bytes to Parsing | Yes, via ASCAPIKit only | No |
| `Parsing` | Decompression (gzip) and TSV/CSV decoding into typed rows, after field verification against official schemas | No | No |
| `Metrics` | Metric definitions and per-row computation (downloads, impressions, sales, proceeds…) | No | No |
| `Aggregation` | Dimensional aggregation under explicit additivity and currency rules | No | No |
| `Storage` | Persistence protocol(s); host apps provide concrete implementations | No | Protocol only |
| `Sync` | Orchestration and sync state: late data, corrections, duplicate segments, interrupted resumes | Yes, via Reports | Yes, via protocols |

## Dependency direction

```text
            ┌───────────────────────────────────────────────┐
            │                 Host application              │
            │   (owns credentials, chooses storage engine)  │
            └──────┬────────────────────────────────┬───────┘
                   │                                │
                   ▼                                ▼
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
- Storage is consumed through protocols declared in this package; no concrete
  database driver ships with the library.
- No third-party runtime dependency other than ASCAPIKit and Apple system
  frameworks.

## Data flow

1. The host app constructs an ASCAPIKit client with its own credentials and
   passes it (or an injectable transport) into ASCAPIAnalytics.
2. `Sync` determines what is missing or stale and asks `Reports` for specific
   report instances.
3. `Reports` fetches report archives through ASCAPIKit and forwards the raw
   bytes to `Parsing`.
4. `Parsing` verifies the schema against the official field list (see
   `REPORT_FORMATS.md`), decompresses, and decodes rows.
5. `Metrics` computes per-row metric values. Money is `Decimal` only.
6. `Aggregation` combines rows under additivity rules: no cross-currency
   sums, no summation of non-additive metrics.
7. Results are persisted through the `Storage` protocols, together with
   provenance (source report, fetch time, schema fingerprint) and metric
   semantics.
8. `Sync` records sync state so late-arriving data, Apple's corrections,
   duplicate segments, and interrupted runs converge to a consistent result.

## Invariants

- All tests are offline: injected transports, synthetic fixtures only.
- Aggregation never produces totals that break currency or additivity rules;
  where a total is impossible to compute honestly, it is represented as
  unavailable, not approximated.
- Apple does not publish every conceivable metric; anything not directly
  supported by published reports stays marked as unsupported.
