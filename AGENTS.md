# AGENTS.md

Instructions for humans and coding agents working in this repository. These
constraints are non-negotiable; a change to any of them requires a new
architecture decision record under `docs/decisions/` approved by the
maintainer.

## What this repository is

ASCAPIAnalytics is a Swift package for App Store Connect reporting: report
retrieval flows, decompression and parsing, metric computation, aggregation,
data quality, and sync state. It is the companion package to
[ASCAPIKit](https://github.com/yvente/ASCAPIKit), which owns all App Store
Connect authentication and API access.

**Current state: initial development.** Nothing in the planned scope is
implemented yet. Never present planned functionality as implemented, in code,
comments, docs, or commit messages.

## Non-negotiable constraints

1. **Scope.** ASCAPIAnalytics only handles report retrieval flows,
   decompression/parsing, metric computation, aggregation, data quality, and
   sync state. Anything else is out of scope.
2. **ASCAPIKit owns the API.** All App Store Connect authentication and API
   requests must reuse ASCAPIKit.
3. **No re-implementation.** Never re-implement ES256 JWT signing or an
   Apple API HTTP client in this package.
4. **No UI.** Do not import or depend on SwiftUI, UIKit, or AppKit.
5. **Storage abstraction.** Database access goes through protocols; never
   bind library code directly to SQLite or any other concrete engine.
6. **Injectable network.** Network interfaces are injectable protocols; all
   tests run offline by default — no test may hit the network.
7. **Decimal money.** Monetary amounts use `Decimal`. Never use `Double` for
   money arithmetic.
8. **No cross-currency sums.** Never total amounts across different
   currencies without an explicit, recorded conversion step.
9. **Additivity rules.** Never accumulate non-additive metrics by simple
   summation (e.g. paying users across dimensions, cohort counts).
10. **No fabricated precision.** Never present metrics that Apple does not
    publish as precisely supported. Mark approximations and gaps honestly.
11. **Sync realities.** Synchronization must account for late-arriving data,
    Apple's corrections, duplicate report segments, and interrupted resumes.
12. **Provenance.** Persist source information and metric semantics alongside
    results so numbers can be audited later.
13. **No secrets, no real data.** Never record or commit API keys, private
    keys (`*.p8`), JWTs, or real report data. Test fixtures must be
    hand-crafted synthetic data.
14. **Tests follow behavior.** Every API, model, or calculation change must
    come with offline tests.
15. **No autonomous releases.** Do not create tags, releases, or publish
    versions. Do not change the ASCAPIKit dependency constraint
    (`.upToNextMinor(from: "0.5.0")`) unilaterally.

## Layout

```text
Package.swift              Package manifest (Swift tools 5.9, macOS 14+)
Sources/ASCAPIAnalytics/   Library sources; subdirectories (Core, Reports,
                           Parsing, Metrics, Aggregation, Storage, Sync) are
                           created when code is actually added — no
                           placeholder files.
Tests/ASCAPIAnalyticsTests/Offline XCTests only.
docs/                      Planning docs and decision records.
.github/workflows/         CI: swift build + swift test on macOS.
```

## Working rules for agents

- Never reintroduce retry loops, busy waiting (`Task.yield` polling), or
  fixed attempt caps around store transactions: `ASCInMemoryAnalyticsStore`
  schedules `beginTransaction` FIFO with asynchronous waiting, and
  `storeInconsistentState` means a real protocol misuse. Any transaction
  correctness problem must be fixed in the store's scheduling, not
  masked by callers.
- The verification CLI (`ASCAnalyticsVerify`) and
  `ASCReportVerification` must stay offline-only, telemetry-free, and
  must never print raw report rows or accept real reports into the
  repository. Real-report verification levels in
  `docs/VALIDATION_MATRIX.md` may not be claimed above what was actually
  performed (levels cannot be skipped).
- Run `swift build` and `swift test` before finishing any task; both must
  pass. Report failures honestly — never claim success without output.
- Keep `README.md` and `CHANGELOG.md` in sync with reality. The README must
  continue to state that the package is in initial development until a real
  release is prepared by the maintainer.
- Commit messages follow conventional commits (`feat:`, `fix:`, `docs:`,
  `chore:`, `test:`, `refactor:`).
- Do not modify the ASCAPIKit repository or its tags.
- Before committing, run `git status --short` and `git diff --check` and
  confirm no secret or real report file is staged.
