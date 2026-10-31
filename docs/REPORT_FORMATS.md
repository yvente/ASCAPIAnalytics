# Report Formats

Inventory of the Apple report families ASCAPIAnalytics adapts, with the
field lists verified against the official documentation. Sources:

- Summary Sales Report: developer.apple.com/help/app-store-connect/reference/summary-sales-report
- Product type identifiers: developer.apple.com/help/app-store-connect/reference/product-type-identifiers
- App Downloads report: developer.apple.com/documentation/analytics-reports/app-download
- App Store Discovery and Engagement: developer.apple.com/documentation/analytics-reports/app-store-discovery-and-engagement
- Data Completeness and Corrections: developer.apple.com/documentation/analytics-reports/data-completeness-corrections

> Apple changes report schemas. Column **positions** may change over time
> — Apple explicitly advises relying on column names, which is how the
> parsers work. When Apple introduces fields this package does not know,
> they are preserved verbatim in each record's `extraFields`; when it
> introduces values this package does not classify (product types,
> download types, events), they are preserved and surfaced rather than
> folded into a known bucket.

## 1. Summary Sales Report (Sales and Trends) — implemented

Delivered gzip-compressed TSV, UTF-8, via `/v1/salesReports`
(`SALES` / `SUMMARY` / `DAILY`, with a `version` filter for Apple's
corrected restatements). Dates are `MM/DD/YYYY`. Money types are
`DECIMAL(18,2)`; values like `.7` (no leading zero) occur in Apple's own
examples.

Required columns parsed (version 1_3):

| Column | Type | Notes |
|---|---|---|
| Begin Date | Date `MM/DD/YYYY` | Report window start; the record's event date |
| End Date | Date `MM/DD/YYYY` | Report window end |
| Apple Identifier | `DECIMAL(18,0)` | The row's Apple ID (app/product) |
| SKU | `VARCHAR` | Seller SKU |
| Parent Identifier | `VARCHAR(100)` | Apple: the SKU of the app associated with an In-App Purchase; blank otherwise |
| Product Type Identifier | `VARCHAR(20)` | Classified from Apple's table; unknown values preserved |
| Units | `DECIMAL(18,2)` | Negative = refund or CMB-C credit; 0 may indicate a partial refund |
| Customer Price | `DECIMAL(18,2)` | Per unit, Customer Currency; negative = refund or CMB-C credit |
| Customer Currency | `CHAR(3)` | ISO code |
| Developer Proceeds | `DECIMAL(18,2)` | **Per unit**, Currency of Proceeds; **positive** on refund rows |
| Currency of Proceeds | `CHAR(3)` | ISO code — a different currency space from Customer Currency |
| Country Code | `CHAR(2)` | ISO storefront code |
| CMB | `VARCHAR(5)` | `CMB` = completes an app bundle; `CMB-C` = credit for a previously purchased app; blank otherwise |

Sign conventions verified against Apple's examples:

- Sale: positive units, positive prices.
- Refund: `Units: -50, Developer Proceeds: .7, Customer Price: -0.99` —
  negative units and customer price, **positive** per-unit proceeds.
- Bundle: `1-B`/`F1-B` rows with `CMB = "CMB"` plus `CMB-C` credit rows;
  the CMB customer price plus the sum of the CMB-C customer prices equals
  the bundle price the customer paid.
- Developer codes: units counted, both money fields 0.

All other columns (Provider, Provider Country, Developer, Title, Version,
Promo Code, Subscription, Period, Category, Supported Platforms, Device,
Preserved Pricing, Proceeds Reason, Client, Order Type, …) are preserved
verbatim in `extraFields`.

## 2. App Downloads report (Analytics Reports API) — implemented

Instances (daily / weekly / monthly, per processing date) of one or more
gzip-compressed segments; segments may be tab- or comma-delimited (both
supported; detected from the header). The Date column is `YYYY-MM-DD`
(first day of the week/month for weekly/monthly instances). Standard and
detailed variants share the core columns; detailed-only columns are
preserved when present.

Core columns: **Date**, **App Name**, **App Apple Identifier**,
**Download Type**, **App Version**, **Device**, **Platform Version**,
**Source Type**, **Source Info**, **Campaign**, **Page Type**,
**Page Title**, **Pre-Order**, **Territory**, **Counts**.

The `Pre-Order` flag marks downloads that **came from a pre-order** —
those rows are already inside their download-type buckets. It is not a
count of independent pre-order placements (Apple's Pre-Orders metric,
"placed, minus cancelations", lives in the App Store Pre-orders report);
the flag must never be added on top of download totals.

Download Type glossary (case-insensitive match, unknown values preserved):

| Value | Meaning |
|---|---|
| First-time Download | First download by the user — **based on the user's Apple ID account**, not the device |
| Redownload | Subsequent installation by an Apple ID account |
| Manual update | User tapped Update |
| Auto-update | Device replaced the app automatically |
| Restore | Restored from iCloud Backup |

Completeness: within two days. Instances may carry late-arriving batches
or, rarely, corrections; the latest processing date overwrites earlier
ones per event date (see `SYNC_SEMANTICS.md`).

## 3. App Store Discovery and Engagement report (Analytics Reports API) — implemented

Same delivery mechanics as the downloads report. Completeness: within
three days.

Core columns: **Date**, **App Name**, **App Apple Identifier**, **Event**,
**Page Type**, **Page Title**, **Source Type**, **Source Info**,
**Campaign**, **Engagement Type**, **Device**, **Platform Version**,
**Territory**, **Counts**, **Unique Counts**.

Event glossary: `Impression` (icon seen in a list — excludes page views),
`Page view` (dedicated page presented), `Tap` (on an impression or page);
unknown events preserved.

Counts and Unique Counts are stored separately. Unique Counts are
deduplicated by Apple **per date and per dimension combination**; the
record exposes its deduplication-domain key and the metrics layer refuses
to sum across domains.

## 4. Other report families — not yet adapted

The remaining Analytics reports (App Usage, Performance, Commerce,
Framework Usage) and the financial/Payments reports are **not** adapted
yet. The generic parsing machinery (gzip, TSV/CSV, table) handles their
containers, but no dedicated models, metrics, or sync defaults exist for
them. Unsupported reports are never silently parsed into a guessed
schema: a header that matches no supported report signature is a hard
error.

## Verifying a real report locally

`ASCAnalyticsVerify` (see [REAL_REPORT_VALIDATION.md](REAL_REPORT_VALIDATION.md))
parses a local report file with the exact parsers described here and
reports format validity, schema identity, unknown values, and optional
single-currency reconciliation — fully offline, no raw rows printed.
Current per-report verification levels live in
[VALIDATION_MATRIX.md](VALIDATION_MATRIX.md) (LEVEL 2 everywhere;
`REAL_APPLE_REPORT_VALIDATION = NOT_RUN_NO_PRIVATE_REPORT`).

## Parsing ground rules (enforced in code)

1. Column lookup is by header name (case-insensitive); positions never
   matter.
2. gzip is validated fully (header fields, CRC32, ISIZE); corrupt or
   truncated input is an error.
3. Unknown columns are carried through verbatim; known-but-unclassified
   values keep their raw form and surface in metrics.
4. Timestamps/dates keep each report's own semantics: Sales dates are
   `MM/DD/YYYY` transaction windows; Analytics dates are `YYYY-MM-DD`
   event days. They are never conflated.
5. Every parsed batch records provenance: report family, instance and
   segment identity, processing date, schema fingerprint, content
   checksum.
6. Fixtures in tests are hand-crafted synthetic data modeled on Apple's
   published examples; real exports are never committed (`.gitignore`
   blocks them).
