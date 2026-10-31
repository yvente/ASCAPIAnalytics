# Validating Real Apple Reports Locally

This document explains how to verify **real Apple report files** against
the package's official parsers — entirely **offline, on your own machine**,
without uploading anything and without any App Store Connect credentials.

The verification tool reuses the exact parsers the sync engine uses, so a
passing verification means the package can parse your real report — not
that any dashboard figure has been reconciled (see
[VALIDATION_MATRIX.md](VALIDATION_MATRIX.md) for the verification levels).

## The verification CLI

```bash
swift build -c release
.build/release/ASCAnalyticsVerify --type <kind> --file <path> [--expected <path>] [--metrics]
```

Kinds:

| Kind | Report |
|---|---|
| `sales-summary` | Sales and Trends Summary Sales report (`/v1/salesReports`) |
| `app-downloads` | App Downloads report (Analytics Reports API segments) |
| `discovery` | App Store Discovery and Engagement report segments |

Accepted file formats: gzip-compressed or plain, tab- or comma-delimited
(delimiter detected from the header), UTF-8 with optional BOM — the same
inputs the parsers accept from ASCAPIKit downloads.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Format verified (and reconciliation matched, when requested) |
| 1 | Format invalid (the report could not be parsed) |
| 2 | Usage error |
| 3 | Reconciliation mismatch |
| 4 | File could not be read |

## What is printed

Only **non-sensitive diagnostics**:

- gzip detection and the input file's SHA-256 (computed locally)
- schema fingerprint and order-insensitive canonical schema identity
- record count, date coverage, territories and currencies *seen*
- unknown/unclassified values (unknown product types, download types,
  events) — always surfaced, never folded into a known bucket
- explicit "unsupported" notices (dashboard alignment is never asserted,
  pre-order flag semantics, unique-count deduplication limits, …)

The tool **never prints raw report rows, SKUs, titles, or per-transaction
records**. `--metrics` additionally prints aggregate values (totals per
currency and bucket); the output stays in your terminal and is never sent
anywhere.

## Privacy guarantees

1. No network access — the verification target does not even link
   ASCAPIKit; it cannot call App Store Connect.
2. Nothing is uploaded, logged to the system, or reported to any service.
3. The report file is opened read-only; it is never modified, moved, or
   deleted.
4. Decompression happens in memory; no temporary report files are written.
5. Real reports are never copied into the repository. The repository's
   `.gitignore` additionally blocks report-like files and private fixture
   directories.
6. File read failures report only the path and the error description.

## Keeping real reports private

Recommended location — **outside the repository**:

```text
/Users/<you>/…/ASCAPIAnalytics-PrivateFixtures/
```

The repository's `.gitignore` blocks this directory name as a defense in
depth, but since the directory lives outside the repository, git cannot
stage it in the first place. Never commit, paste into issues/PRs, or
attach real reports or expected figures to CI.

## Reconciling against your own expected figures

Prepare a local expected JSON file (outside the repository):

```json
{
  "recordCount": 42,
  "firstDate": "2025-10-01",
  "lastDate": "2025-10-31",
  "grossSales": { "USD": "123.45" }
}
```

Then:

```bash
.build/release/ASCAnalyticsVerify \
  --type sales-summary \
  --file "/private/path/to/report.txt.gz" \
  --expected "/private/path/to/expected.json"
```

Reconciliation rules — deliberately narrow:

- Only the keys you provide are compared (`recordCount`, `firstDate`,
  `lastDate`, `grossSales`).
- `grossSales` is compared **per currency, one currency at a time**. The
  tool never sums across currencies and never compares multi-currency
  Developer Proceeds against a dashboard dollar estimate.
- Anything that cannot be compared on the same basis (report kind, date
  window, territory, refund inclusion, completeness) is reported as
  `NOT COMPARED` with a reason — never as a match.
- A result of `MATCHED` means: for the provided keys, over this report
  file, the parsed values agree with your expected figures. It does **not**
  mean the package reproduces every App Store Connect dashboard metric.

## Real-report verification log

- **2026-10-31** — A real Apple **Daily Summary Sales** report
  (`S_D_*.txt.gz`, 64 data rows, single day 2026-10-28, 16 customer
  currencies, 24 territories) was verified locally with the release CLI:
  gzip and TSV parsing **PASS**, all **64/64 rows parsed successfully**,
  no unknown product types, no unknown schema columns. The verification
  surfaced one real-data compatibility finding: Apple leaves
  **Currency of Proceeds blank on zero-price, zero-proceeds rows**
  (free downloads/updates) — the parser now accepts that
  (as `nil`, never a fabricated currency) and rejects a missing
  proceeds currency only on monetary rows. This brings Summary Sales to
  **LEVEL 3 — REAL_REPORT_PARSED**. No same-basis dashboard figures were
  available, so LEVEL 4 was **not** attempted.

## Verification levels

See [VALIDATION_MATRIX.md](VALIDATION_MATRIX.md). In short:

1. **LEVEL 1 — SYNTHETIC_VERIFIED**: hand-crafted offline fixtures pass.
2. **LEVEL 2 — OFFICIAL_FORMAT_VERIFIED**: structure checked against
   Apple's official documentation, plus LEVEL 1.
3. **LEVEL 3 — REAL_REPORT_PARSED**: a real Apple report passed the
   official parsers locally.
4. **LEVEL 4 — METRICS_RECONCILED**: same-basis expected figures
   reconciled for the specific metrics and scope (implies LEVEL 3).

Levels cannot be skipped. Without successful validation against a real
Apple report, an individual report family can claim LEVEL 2 at most.

Current verification status:

- Summary Sales: LEVEL 3 — REAL_REPORT_PARSED. One private Apple Daily
  Summary Sales report passed the production parser locally on
  2026-10-31.
- App Downloads: LEVEL 2 — no private real report validated yet.
- App Store Discovery and Engagement: LEVEL 2 — no private real report
  validated yet.
- LEVEL 4 requires independent reconciliation against figures with
  matching report type, date range, currency, territory, and metric
  definitions.

Real report files and private expected values must never be committed
to the repository or uploaded to CI.
