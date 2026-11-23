# Verification Matrix

Per-report record of what has been verified, against which source, and at
what level. Levels **cannot be skipped**:

| Level | Meaning |
|---|---|
| **LEVEL 1 — SYNTHETIC_VERIFIED** | Hand-crafted offline fixtures pass the official parsers. |
| **LEVEL 2 — OFFICIAL_FORMAT_VERIFIED** | Structure checked against Apple's official documentation; LEVEL 1 tests pass. |
| **LEVEL 3 — REAL_REPORT_PARSED** | A real Apple report parsed successfully with the official parsers, locally. |
| **LEVEL 4 — METRICS_RECONCILED** | Same-basis expected figures reconciled for specific metrics and a specific scope (implies LEVEL 3). |

LEVEL 4 never means the package reproduces every App Store Connect
dashboard metric — only that the named metrics, report, and scope were
reconciled.

**Current overall status: Summary Sales = LEVEL 3 (REAL_REPORT_PARSED,
2026-10-31); App Downloads and Discovery and Engagement = LEVEL 2
(`REAL_REPORT_VALIDATION = NOT_RUN_NO_PRIVATE_REPORT` for those
families).** See [REAL_REPORT_VALIDATION.md](REAL_REPORT_VALIDATION.md)
for the verification log and how to reach LEVEL 3/4 locally with a
private report.

Documentation sources below were re-checked against the live Apple pages
on **2026-10-31**:

- Analytics Reports API overview and "Downloading Analytics Reports"
  (developer.apple.com/documentation/appstoreconnectapi/downloading-analytics-reports)
- Summary Sales Report
  (developer.apple.com/help/app-store-connect/reference/reporting/summary-sales-report)
- Sales and Trends reports availability
  (developer.apple.com/help/app-store-connect/reference/reporting/sales-and-trends-reports-availability)
- App Downloads report
  (developer.apple.com/documentation/analytics-reports/app-download)
- App Store Discovery and Engagement
  (developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement)
- Analytics metric definitions
  (developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions)

---

## Summary Sales Report — LEVEL 3 (REAL_REPORT_PARSED)

| Item | Status |
|---|---|
| Official schema source | Summary Sales Report reference (v1_3), re-checked 2026-10-31 |
| Supported header | All 19 documented columns; name-based lookup, order-independent |
| Verified fields | Begin/End Date (`MM/DD/YYYY`), Apple Identifier, SKU, Parent Identifier (parent-app SKU for IAP), Product Type Identifier (full published table), Units `DECIMAL(18,2)`, Customer Price, Customer Currency, Developer Proceeds **(per unit)**, Currency of Proceeds, Country Code, CMB/CMB-C |
| Sign rules | Apple's examples pinned in tests: refunds have negative Units and Customer Price with **positive** per-unit proceeds (`-50 / .7 / -.99`); CMB-C credits follow the same convention |
| Synthetic fixtures | **PASS** — 28 parser tests: app sales, IAP, subscriptions, refunds, partial refunds (Units 0), free/zero-price, updates, re-downloads, bundles with CMB-C, multi-currency, per-unit proceeds math, unknown product types, blank proceeds currency on zero-value rows, column reorders, compatible extra columns, gzip input |
| Real Apple report | **PASS — LEVEL 3 (REAL_REPORT_PARSED)**. A private Apple Summary Daily Sales report was parsed locally on 2026-10-31; all 64 data rows passed the production parser. No raw report data was committed or uploaded. |
| Metrics reconciliation | **NOT RUN — LEVEL 4 not achieved.** No independent, same-scope expected figures were provided. Successful parsing and metric calculation do not establish agreement with App Store Connect dashboard totals. |
| Unknown-field policy | Extra columns preserved verbatim in `extraFields`; unknown product types/CMB values surfaced in `unknownProductTypeIdentifiers` / metrics, never folded into known buckets |
| Money / date basis | `Decimal` only; gross sales grouped by Customer Currency, proceeds by Currency of Proceeds (never mixed); dates are Apple's transaction window (`MM/DD/YYYY`) — a different basis from Analytics event days |
| Dashboard consistency | **Not asserted.** Proceeds are per-unit values; multi-currency proceeds are never summed or converted. Same-basis reconciliation is possible locally via the `--expected` file (single currency at a time) |

## App Downloads Report (Analytics Reports API) — LEVEL 2

| Item | Status |
|---|---|
| Official schema source | App Downloads report page, re-checked 2026-10-31 |
| Supported header | Core columns Date, App Apple Identifier, Download Type, Territory, Counts (required); all other documented columns (App Name, App Version, Device, Platform Version, Source Type/Info, Campaign, Page Type/Title, Pre-Order) tolerated and preserved; tab or comma delimiter, standard and detailed variants |
| Verified fields | Download Type glossary (First-time Download — Apple ID account based, Redownload, Manual update, Auto-update, Restore), Pre-Order flag preserved separately, Counts, Territory, Date (`YYYY-MM-DD`; week/month anchor semantics) |
| Synthetic fixtures | **PASS** — classification of all documented types, unknown type preservation, pre-order flag parsing, extra/detail columns, CSV and gzip, delimiter auto-detection, error diagnostics |
| Real Apple report | **NOT RUN — no private report available** |
| Metrics reconciliation | **NOT RUN** |
| Unknown-field policy | Unknown download types surface as `other(raw:)` with counts; extra columns preserved verbatim |
| Money / date basis | Counts are additive; conversion-rate basis caveats documented (pre-order flag ≠ placements; multi-day unique devices not recomputable) |
| Dashboard consistency | **Not asserted.** Apple's Total Downloads (first-time + redownload) is implemented exactly as defined; dashboard impressions-based conversion rate is refused for report-derived denominators |

## App Store Discovery and Engagement — LEVEL 2

| Item | Status |
|---|---|
| Official schema source | Discovery and Engagement report page, re-checked 2026-10-31 |
| Supported header | Core columns Date, App Apple Identifier, Event, Territory, Counts (required); Page Type, Source Type, Engagement Type, Unique Counts and detail-only columns preserved; standard and detailed variants |
| Verified fields | Event glossary (Impression / Page view / Tap), Counts vs **Unique Counts stored separately** with per-row deduplication-domain keys |
| Synthetic fixtures | **PASS** — event classification, per-domain unique counts, cross-domain/cross-event refusal to sum, unknown events, CSV |
| Real Apple report | **NOT RUN — no private report available** |
| Metrics reconciliation | **NOT RUN** |
| Unknown-field policy | Unknown events surface as `other(raw:)`; extra columns preserved verbatim |
| Money / date basis | Counts additive; unique counts **non-additive** across dates, dimensions, and event types (dashboard Impressions include unique product page views — a basis the report cannot reconstruct) |
| Dashboard consistency | **Not asserted.** Impression-event unique counts are a narrower basis than dashboard Impressions by an unpublished amount |

---

## Not-yet-adapted reports

Every other Apple report (App Usage, Performance, Commerce, Framework
Usage, Payments/Financial, Pre-orders, Subscriptions, …) is **explicitly
unsupported**: the sync engine skips instances whose header matches no
supported signature with an explicit `skippedUnsupported` diagnostic —
they are never silently parsed as one of the reports above.

## Privacy threshold / statistical noise

Apple applies privacy measures to Detailed Analytics reports
("additional privacy measures … to help protect uniquely identifiable
information for individuals"). The package parses whatever values the
report contains and applies **no** noise-correction or threshold logic;
where Apple's dashboards apply adjustments that are not visible in exports
(pre-order cancellations, privacy thresholds), the difference is
documented in `METRIC_DEFINITIONS.md` rather than corrected by guesswork.
