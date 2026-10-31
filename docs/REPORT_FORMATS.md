# Report Formats

Inventory of the Apple report families ASCAPIAnalytics plans to adapt, and
the ground rules for parsing them. **No parser is implemented yet.**

> ⚠️ **Mandatory before implementing any parser:** verify the exact export
> names, file layout, column list, and column order against the current
> official App Store Connect documentation and a real (local, never
> committed) export. Apple changes report schemas; this document records
> intent, not a frozen contract.

## 1. App Store Connect Analytics reports

Exported from App Store Connect → Analytics, or via the App Store Connect API
analytics report endpoints that ASCAPIKit already exposes. Expected to be
gzipped TSV/CSV with a header row and UTC timestamps.

Planned adaptation targets (export names to be verified):

- **App Downloads** — first-time downloads, re-downloads, updates, by day and
  territory/platform/version.
- **Product Page Views (App Page Views)** — unique and total page views.
- **Impressions (App Store Impressions)** — impressions split by source
  (App Store browse, search, etc.).
- **In-App Purchases** — IAP transaction counts, if published for the app.

Notes:

- Availability windows and lateness rules differ per report and must be
  verified; sync must tolerate late-arriving and corrected files.
- Some reports deduplicate per device per day, which makes their totals
  non-additive across dimensions.

## 2. Sales and Trends reports

Exported from App Store Connect → Sales and Trends, or via the API report
endpoints.

- **Sales report** — transaction-level daily/weekly/monthly TSV, gzip
  compressed, UTF-8. Commonly observed columns include: `Provider`,
  `Provider Country`, `SKU`, `Developer`, `Title`, `Version`,
  `Product Type Identifier`, `Units`, `Developer Proceeds`, `Begin Date`,
  `End Date`, `Customer Currency`, `Country Code`, `Customer Price`,
  `Promo Code`, and related fields. **The exact current column list and order
  must be verified against the official documentation and a real export
  before parsing.**
- **Payments / Financial reports** — payout-oriented documents. Out of scope
  for the initial milestone; listed here so they are not mistaken for sales
  data.

Notes:

- The Sales report is published with a delay and is subject to Apple's
  corrections and restatements; deduplicate by report segment, not by file.
- Amounts are in the customer currency; proceed/sales conversion is Apple's.

## 3. Parsing ground rules

1. Verify the official field list for the specific report version before
   parsing; treat unknown columns as errors or explicitly carry them through,
   never silently drop.
2. Decompress gzip in memory or temp storage; raw reports are never written
   into the repository.
3. TSV/CSV decoding must handle quoting, BOM, and Apple's header rows.
4. Timestamps are UTC; preserve the report's own date semantics.
5. Every parsed batch records provenance: report type, instance identifier,
   fetch time, schema fingerprint.
6. Fixtures in tests are hand-crafted synthetic data; real exports are never
   committed (`.gitignore` blocks them).
