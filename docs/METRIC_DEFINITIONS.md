# Metric Definitions

Planning reference for the metrics ASCAPIAnalytics intends to support.
**Implementation status: none of these metrics are implemented yet.** Each
entry records the intended data source and must be re-verified against the
official App Store Connect export schema before a parser is written (see
`REPORT_FORMATS.md`).

Conventions used below:

- **Additive** — values may be summed across the dimension (time, territory,
  app version…).
- **Non-additive** — summing across dimensions double-counts; totals must be
  recomputed from the base data or left unavailable.

## Acquisition metrics (Analytics reports)

| Metric | Definition | Source | Additivity | Status |
|---|---|---|---|---|
| First-time downloads | Downloads by Apple Accounts that had never downloaded this app on that device before. | App Store Connect Analytics "App Downloads" export (exact export name/columns to be verified) | Additive over time and territory | Not implemented |
| Re-downloads | Downloads by users who had previously downloaded the app. | Analytics "App Downloads" export | Additive over time and territory | Not implemented |
| Updates | App updates counted by Apple in the downloads report. | Analytics "App Downloads" export ("Updates" download type; to be verified) | Additive over time and territory | Not implemented |
| Impressions | Times the app was viewed in an App Store listing (icon, screenshots, etc.), split by source. Daily dedup per device is Apple's; treat cross-source totals carefully. | Analytics impressions exports | Non-additive across some dimensions (dedup) | Not implemented |
| Product page views | Views of the App Store product page (unique vs. total as Apple reports). | Analytics "App Page Views" export | Non-additive for unique counts | Not implemented |
| Conversion rate | Downloads relative to product page views, as Apple computes it in Analytics. Definition must be confirmed against official documentation before use. | Derived from page views + downloads; possibly published directly | Non-additive (ratio) | Not implemented |

## Purchase and revenue metrics (Sales and Trends reports)

| Metric | Definition | Source | Additivity | Status |
|---|---|---|---|---|
| In-app purchases | Count of in-app purchase transactions reported by Apple. | Sales and Trends "Sales" report rows for IAP product types; Analytics IAP export (to be verified) | Additive over time and territory | Not implemented |
| Sales (gross) | Customer-price value: customer price × units, in the customer's currency. Never converted or summed across currencies without an explicit recorded conversion step. | Sales and Trends "Sales" report | Additive only within a currency | Not implemented |
| Developer proceeds (所得) | Apple's "Developer Proceeds" amount, in the customer currency as reported; Apple's payout conversion happens outside this package. Money arithmetic uses `Decimal` only. | Sales and Trends "Sales" report | Additive only within a currency | Not implemented |

## Cohort metrics

| Metric | Definition | Source | Additivity | Status |
|---|---|---|---|---|
| Retention cohorts | Share of an install cohort (e.g. by first-download day) still active after N days. **Cannot be rebuilt** by summing daily active users or downloads; requires cohort-specific data that Apple's public exports do not provide. Until Apple publishes cohort data this package can consume, this stays explicitly unsupported. | Not available in current public exports | Non-additive; not reconstructable | Not implemented — explicitly unsupported |

## Global rules for every metric

1. Money is `Decimal`; never `Double`.
2. Never sum amounts across currencies.
3. Never accumulate non-additive metrics by simple summation.
4. Metrics Apple does not publish are never presented as precisely supported.
5. Every stored value carries provenance (source report, date range, fetch
   time, schema fingerprint) and metric semantics, so results are auditable.
6. Any change to a definition requires an offline test that pins the change.
