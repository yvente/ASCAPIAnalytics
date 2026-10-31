# Sync Semantics

This document defines exactly how `ASCReportSyncEngine` handles repeated
runs, late data, Apple's corrections, duplicate segments, and interrupted
resumes. Everything here is enforced by the offline test suite.

## Identities

- **Analytics ingestion** = one report *instance* (identified by the
  instance id, with its processing date and granularity). Instances are
  the unit Apple delivers and corrects (see *Data Completeness and
  Corrections*).
- **Sales ingestion** = the full tuple (vendor number, report type,
  report subtype, frequency, report date, **version**). The kind
  component (`"TYPE/SUBTYPE/FREQUENCY"`) keeps a daily and a weekly
  report for the same date separate. `reportVersion` matches **exactly**:
  `nil` identifies an import fetched as "latest available" whose version
  number Apple does not echo back, and it never conflates with an
  explicitly versioned import.

Every ingestion is recorded in the store's ledger with: report name and
category, instance or version identity, **processing date**, granularity,
segment ids, **declared segment checksums**, **schema fingerprint** (SHA-256
over the verified header), **content checksum** (SHA-256 over the bytes as
received), record count, and import time.

## Idempotency

Re-running a sync never re-counts data:

1. Before downloading, an instance whose ledger entry is `imported` and
   whose *declared* segment checksums are unchanged — with a checksum
   present for **every** segment — is skipped (`skippedAlreadyImported`).
   An empty declared checksum means "no checksum": treating empty ==
   empty as "unchanged" would freeze stale data, so it never
   short-circuits a download.
2. Otherwise the segments are re-downloaded and the verified *content*
   checksums decide:
   - identical content → `skippedAlreadyImported` (already processed,
     whatever the ledger state);
   - different content → *quarantine* (see below).

## Segment identity

Segments are partitions of one instance, identified by their **segment
id**. The same segment id listed twice is downloaded and parsed once.
Two *different* segment ids are both kept even when their bytes happen to
be identical — dropping one by content alone would silently discard a
partition. Segment failures (download error, empty content, parse error)
abort the whole instance as a `failed` outcome with nothing committed.

## Supported reports and defaults

By default the engine syncs the categories carrying the two officially
supported reports (App Downloads, App Store Discovery and Engagement) and
**skips** any instance whose header matches neither signature with an
explicit `skippedUnsupported` diagnostic — unsupported reports are never
counted and never fail the run. Strict mode
(`failsOnUnsupportedReports: true`) turns them into failures instead.

## Atomicity

An instance is committed **only after every one of its segments has been
downloaded, parsed, and cross-verified** (all segments must share one
schema fingerprint — they are partitions of a single report). The ledger
entry and all normalized records are written in one store transaction.
Any failure — download error, parse error, schema disagreement, empty
segment, checksum surprise — aborts the instance with **nothing
committed**: an incomplete instance is never marked successful.

## Duplicate segments

Segments are physical partitions of one instance, identified by their
**segment id**. The same segment id listed twice is downloaded and parsed
once, so rows are never counted twice. Two *different* segment ids are
both kept even when their bytes happen to be identical — deduplicating by
content alone would silently discard a partition. Rows are stored per
segment with segment-level provenance for audit.

## Late data (Analytics)

Instances with older processing dates still arrive later in wall-clock
time; that is normal. Each instance is imported independently, with its
own provenance. **Nothing is merged at ingest time.** Reads apply Apple's
documented overwrite rule *within* an overwrite group — the tuple
(app Apple Identifier, report identity, schema variant fingerprint,
granularity, event date) — so a correction can never overwrite another
app's, another report's, another variant's (standard/detailed), or
another granularity's (daily/weekly) data:

> "Instances from a more recent processing date overwrite instances with
> an earlier processing date … Don't merge records for a Date across two
> report instances to avoid double counting. Use the latest instance."
> — *Data Completeness and Corrections*

`ASCInstanceSelection.latestProcessingDatePerEventDate(_:)` implements
this: per event date, only records from the instance with the latest
processing date participate; records without a processing date count as
the oldest and survive only when no dated instance covers their date.

## Corrections

- **Sales and Trends, explicit versions**: the semantics are
  **order-independent** — importing v1 after v2 never demotes v2.
  - A newer, numerically comparable explicit version of the same report
    date supersedes **all** older current versions in the same
    transaction. Queries exclude superseded data by default
    (`scope: .current`); `scope: .all` retains everything for audit, with
    the superseding key recorded on each superseded entry.
  - Importing an **older** version after a newer one: with different
    content it is stored as `superseded` on arrival (retained for audit,
    reported as `importedForAuditOnly`); with identical content it is
    skipped — an older version never supersedes a newer one, even when
    the bytes match.
  - Incomparable version strings (contents differ or are identical):
    never superseded automatically. The new delivery is retained as
    `pendingReview` with an explicit manual-review reason instead of two
    current versions coexisting silently.
- **Sales and Trends, unversioned ("latest") downloads**: Apple does not
  echo the version of an unversioned download, so the fetched content is
  recognized by actual content:
  - identical to an already-imported version → skip;
  - different from everything imported → `pendingReview` requiring
    **manual resolution**. Old statistics keep counting, the conflict is
    visible, and nothing is silently replaced or double-counted.
- **Sales and Trends, explicit version after an unversioned import**:
  identical content identifies the earlier delivery (the unversioned
  entry is superseded, exactly one counted copy remains); different
  content cannot be ordered and is quarantined for manual review.
- **Analytics**: corrections arrive as new instances with a later
  processing date — covered by the overwrite rule above.

## Quarantine: unproven update semantics

When the **same identity** (same instance id / same sales version) arrives
again with **different content**, Apple's semantics are not documented in
a way this package can prove (mutated instances do not occur in the
documented flow). The engine therefore:

1. keeps the previously imported data untouched and still counted,
2. records the conflicting delivery under its own delivery key (keyed by
   its content checksum) in state `pendingReview`, including its parsed
   records, schema fingerprint, and checksums,
3. excludes `pendingReview` data from current-scope queries and all
   aggregation — nothing is silently added, replaced, or double-counted,

and the sync result reports the outcome as `pendingReview` with the
reason. Host apps inspect pending entries and decide (e.g. re-import
after resolving).

## Completeness

Apple publishes per-report completeness thresholds ("Completeness: within
two days" for App Downloads, "within three days" for App Store Discovery
and Engagement). `ASCReportCompletenessThreshold.assess(eventDate:
processingDate:thresholdDays:)` classifies each event date in an instance
as complete or not-yet-complete against those thresholds. Sales and Trends
has no published day threshold; its completeness is reported as `unknown`.

## Currently effective data

`ASCAnalyticsStore.effectiveDownloadRecords` /
`effectiveDiscoveryRecords` apply the overwrite rule above and are the
reliable "current data" query path — callers never apply
`ASCInstanceSelection` by hand:

```swift
// One app's currently effective daily data for one report variant:
let daily = try await store.effectiveDownloadRecords(
    appIdentifiers: ["1234567890"],
    granularities: [.daily],
    reportIdentities: ["id:rep-1"]        // ASCInstanceSelection.logicalReportIdentity
)
```

**Never sum across scopes.** Daily and weekly instances of the same
window, and standard and detailed variants of the same events, describe
the same underlying activity: summing them double counts. The
provenance-aware aggregators enforce this —
`ASCSalesAggregator.summary(_:[salesReportKinds:])` (sales) and
`ASCAnalyticsAggregator.downloads(_:)` / `discovery(_:)` (analytics) throw
`ASCAnalyticsError.ambiguousMetricScope` when their input spans several
report kinds, granularities, or logical variants, instead of producing a
total that looks correct but is not. Select one scope first, or aggregate
each scope separately.

## What the engine does not do

- **No scheduling.** The host app decides when to run the engine.
- **No deletion.** Superseded and pending-review data is retained with
  provenance (repository rule: persist source information so numbers can
  be audited later).
- **No cross-report merging.** Sales (transaction windows, `MM/DD/YYYY`)
  and Analytics (UTC event days, `YYYY-MM-DD`) use different date bases
  and are never combined implicitly.
