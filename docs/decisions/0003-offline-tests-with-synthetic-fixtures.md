# ADR-0003: Offline tests with synthetic fixtures

- Status: Accepted
- Date: 2026-10-31

## Context

ASCAPIAnalytics will compute revenue and acquisition metrics. Tests that
depend on live App Store Connect access would be slow, non-deterministic,
credential-dependent, and would risk leaking real business data into the
repository.

## Decision

All tests in this package are offline by default:

- Network interfaces are injectable protocols (ASCAPIKit's `ASCTransport`
  already provides this), and tests use in-memory fakes.
- Every API, model, or calculation change ships with offline XCTests.
- Test fixtures are hand-crafted synthetic data only. Real Apple report
  exports (`.gz`, `.tsv`, `.csv`) are never committed; `.gitignore` blocks
  them, with an explicit allow-list for synthetic fixtures under
  `Tests/**/Fixtures/`.

## Consequences

- Parsers and aggregators must be designed against byte/row inputs, not live
  clients, which also keeps Parsing/Metrics/Aggregation free of ASCAPIKit
  dependencies.
- Continuous integration needs no secrets and cannot produce flaky results
  from Apple-side changes.
