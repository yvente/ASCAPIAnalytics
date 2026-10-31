# Metric Definitions

Reference for the metrics ASCAPIAnalytics computes, their data sources,
additivity semantics, and support status. Definitions cite Apple's
published documentation (App Store Connect metric definitions,
developer.apple.com/help/app-store-connect-analytics/reference/metrics-definitions,
and the per-report pages under
developer.apple.com/documentation/analytics-reports). The live catalog is
`ASCMetricCatalog` in the code; this document explains the same decisions.

Conventions:

- **Additive** — values may be summed across the dimension (time,
  territory, app version…).
- **Non-additive** — summing across dimensions double-counts; totals must
  be recomputed from base data or left unavailable.
- Money is `Decimal`; never `Double`.

## Acquisition metrics (Analytics reports)

| Metric | Definition (per Apple) | Source | Additivity | Status |
|---|---|---|---|---|
| First-time downloads | "The first time a user downloaded your app. Based on the user's **Apple ID account**." Not a device-level first install. | App Downloads report, `Download Type` = First-time Download | Additive over time and territory | **Supported** |
| Redownloads | "A subsequent installation of an app onto a device by an Apple ID account." | App Downloads report | Additive | **Supported** |
| Manual updates | "The process of manually replacing an app on a device with another version of the same app." | App Downloads report | Additive | **Supported** |
| Auto-updates | The device replaced the app with another version automatically. | App Downloads report | Additive | **Supported** |
| Restores | Restoring an app from iCloud Backup. | App Downloads report | Additive | **Supported** |
| Total downloads | "The sum of First Time Downloads and Redownloads." Updates are a separate metric. | Derived | Additive | **Supported** |
| Pre-orders (as visible here) | Rows of the downloads report whose `Pre-Order` flag is true. Apple's own Pre-Orders metric ("placed, minus cancelations") subtracts cancellations, which the downloads report does not expose. | App Downloads report | Additive | **Supported, with the cancellation caveat** |
| Impressions (counts) | "The number of times your app was viewed on the Today, Games, Apps, and Search tabs of the App Store for more than one second. Includes product page views." | Discovery and Engagement report, `Event` = Impression, `Counts` | Additive | **Supported** |
| Impressions (unique devices) | "The number of unique devices that have viewed your app on the Today, Games, Apps, and Search tabs of the App Store." | Discovery and Engagement report, `Unique Counts` | **Non-additive** — Apple deduplicates per date and per dimension combination; sums across dates or dimensions double-count devices | **Supported per domain; combined value unavailable outside a single domain** |
| Product page views (counts) | "The total number of times your App Store product page was viewed." | Discovery and Engagement report, `Event` = Page view, `Counts` | Additive | **Supported** |
| Product page views (unique devices) | "The number of unique devices that have viewed your App Store product page." | Discovery and Engagement report, `Unique Counts` | Non-additive (as above) | **Supported per domain; combined unavailable** |

## Conversion rate

**Definition (Apple):** *"Total downloads and pre-orders divided by unique
device impressions. When a user pre-orders an app, it counts towards your
conversion rate. It is not counted again when it downloads to their
device."*

> **Correction of an earlier draft of this document:** the conversion rate
> is **not** "downloads divided by product page views". The denominator is
> **unique device impressions**, and the numerator includes **pre-orders**.

Reproduction rules implemented by `ASCConversionRateEvaluator`:

- Numerator and denominator must cover the same app and the same window.
- A rate is returned **only** when the window is a single day and the
  impression data spans exactly one deduplication domain (one date in one
  dimension combination). Otherwise the result is `unavailable` with the
  reason.
- On explicit request (`evaluateAllowingEstimate`), a multi-day window may
  return an `estimated` rate whose denominator is the sum of per-day
  unique counts — an upper bound, so the estimated rate is a **lower
  bound** of Apple's value. Dimension splits, app mismatches, and window
  mismatches are never estimated.
- Zero impressions yield `unavailable`, never a fabricated 0% or 100%.

| Status | Meaning |
|---|---|
| `available` | Exact, single-day, single domain |
| `estimated` | Labeled approximation with its bound direction |
| `unavailable` | Well defined; inputs not comparable |
| `unsupported` | Cannot be produced from Apple's published reports |

## Purchase and revenue metrics (Sales and Trends)

| Metric | Definition | Source | Additivity | Status |
|---|---|---|---|---|
| Units by product type | Aggregated units from the Summary Sales report, classified with Apple's published product type identifiers (apps, bundles, updates, re-downloads, IAP, auto-renewable and non-renewing subscriptions, restored IAP). Unknown identifiers stay in their own bucket and are listed by raw value. | Summary Sales report, `Units` | Additive | **Supported** |
| Refunds and credits | Apple: "Refunds have negative values for Units and Customer Price, and positive values for Developer Proceeds." The same signs apply to `CMB-C` bundle credits. A Units value of 0 may indicate a partial refund. | Summary Sales report | Additive (signed) | **Supported** |
| Gross sales (customer price value) | Per row: `units × |customer price|`, summed **only within the same Customer Currency**. Taking the price magnitude keeps sale rows positive and refund rows negative under Apple's documented sign convention. | Summary Sales report | Additive within a currency only | **Supported** |
| Developer proceeds | Apple reports proceeds **per unit** ("Amount you receive per unit"). Per row: `units × |developer proceeds|`, summed **only within the same Currency of Proceeds**. The per-unit value is never summed across rows. | Summary Sales report | Additive within a currency only | **Supported** |
| Cross-currency totals | Never produced. Summing amounts across currencies requires an explicit, recorded conversion step that this package does not perform; the API returns `unavailable` instead. | — | — | **Unavailable by design** |

## Explicitly unsupported metrics

| Metric | Reason |
|---|---|
| D1/D7/D35 download-to-paid | Requires cohort-level purchase attribution Apple's public reports do not publish. The package refuses to approximate it. |
| Retention cohorts | Requires cohort-specific data Apple's public exports do not provide; not reconstructable from daily aggregates. |
| Apple dashboard parity | Values are recomputed from published report files. Where Apple's dashboard applies adjustments not visible in exports (e.g. pre-order cancellations), that difference is documented rather than hidden. |

## Global rules for every metric

1. Money is `Decimal`; never `Double`.
2. Never sum amounts across currencies.
3. Never accumulate non-additive metrics by simple summation.
4. Metrics Apple does not publish are never presented as precisely
   supported.
5. Every stored value carries provenance (source report, date range,
   instance/segment, processing date, schema fingerprint, content
   checksum) so results are auditable.
6. Any change to a definition requires an offline test that pins the
   change.
