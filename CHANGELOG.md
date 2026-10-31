# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial Swift package structure: `ASCAPIAnalytics` library product and
  target, plus an offline test target (`ASCAPIAnalyticsTests`) that verifies
  the module and its ASCAPIKit dependency are importable and linkable.
- Dependency on `ASCAPIKit` `0.5.x` via `.upToNextMinor(from: "0.5.0")`.
- Planning documentation: `README.md`, `AGENTS.md`, `CONTRIBUTING.md`,
  `docs/ARCHITECTURE.md`, `docs/METRIC_DEFINITIONS.md`,
  `docs/REPORT_FORMATS.md`, and architecture decision records under
  `docs/decisions/`.
- GitHub Actions workflow running `swift build` and `swift test` on a
  supported macOS runner.

### Notes

- The package is in **initial development**. No version has been released and
  no analytics functionality is implemented yet. See the roadmap in
  `README.md` for what is planned.
