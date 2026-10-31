# ASCAPIAnalytics

Swift package for retrieving, parsing, and aggregating App Store Connect
reporting data — the reporting companion to
[ASCAPIKit](https://github.com/yvente/ASCAPIKit).

## Status: initial development

> ⚠️ **This package is in initial development.** There is no published release
> yet, and the analytics functionality described below is **not implemented**.
> Do not ship or adopt this package as a finished analytics SDK.

## What this package is

ASCAPIAnalytics focuses on the layer **after** App Store Connect API access:

- Report retrieval flows
- Decompression and parsing of report files
- Metric definitions and computation
- Aggregation with explicit currency and additivity rules
- Data quality and provenance records
- Synchronization state (late data, corrections, duplicate segments,
  interrupted resumes)

## Relationship to ASCAPIKit

All App Store Connect authentication and API requests are delegated to
[ASCAPIKit](https://github.com/yvente/ASCAPIKit). ASCAPIAnalytics **never**
re-implements ES256 JWT signing, Apple's HTTP API client, or App Store Connect
models. It depends on `ASCAPIKit` `0.5.x` only
(`.upToNextMinor(from: "0.5.0")`).

## Planned scope

Planned future work (not implemented yet):

- Parsing and aggregation of App Store Connect **Analytics** reports
  (downloads, re-downloads, updates, impressions, product page views,
  in-app purchases, conversion).
- Parsing and aggregation of **Sales and Trends** reports (units, sales,
  developer proceeds) with `Decimal`-based money handling.
- A protocol-abstracted storage layer (no bundled database driver).
- A sync engine that handles late-arriving data, Apple's corrections,
  duplicate report segments, and interrupted resumes.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/METRIC_DEFINITIONS.md](docs/METRIC_DEFINITIONS.md), and
[docs/REPORT_FORMATS.md](docs/REPORT_FORMATS.md) for the current planning
documents. See [CHANGELOG.md](CHANGELOG.md) for what has actually landed.

## What this package is not

- **No UI.** No SwiftUI, UIKit, or AppKit.
- **No database driver.** Storage is a protocol abstraction; host apps choose
  the concrete implementation (e.g. SQLite, GRDB, Core Data).
- **No telemetry.** Report data and credentials never leave the host app.
- **No third-party runtime dependencies** beyond ASCAPIKit and Apple system
  frameworks.

## Data ownership

All report data, credentials, and computed metrics stay under the control of
the app that embeds this package. ASCAPIAnalytics performs no network
communication other than the App Store Connect requests the host app makes
through ASCAPIKit, and it never uploads data anywhere.

## Platform

macOS 14+ is the primary (currently only) supported platform.

## Build and test

```bash
swift package resolve
swift build
swift test
```

Requirements: macOS 14+ with a Swift 5.9+ toolchain.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md) for the
non-negotiable constraints of this repository (money handling, additivity
rules, offline tests, and security rules).

## License

[MIT](LICENSE) © yvente
