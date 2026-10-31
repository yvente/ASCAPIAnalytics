# Sync Semantics

This document defines exactly how `ASCReportSyncEngine` handles repeated
runs, late data, Apple's corrections, duplicate segments, and interrupted
resumes. Everything here is enforced by the offline test suite.

## Identities

- **Analytics ingestion** = one report *instance* (identified by the
  instance id, with its processing date and granularity). Instances are
  the unit Apple delivers and corrects (see *Data Completeness and
  Corrections*).
- **Sales ingestion** = one (vendor number, report date, version) triple
  for the Summary Sales report.

Every ingestion is recorded in the store's ledger with: report name and
category, instance or version identity, **processing date**, granularity,
segment ids, **declared segment checksums**, **schema fingerprint** (SHA-256
over the verified header), **content checksum** (SHA-256 over the bytes as
received), record count, and import time.

## Idempotency

Re-running a sync never re-counts data:

1. Before downloading, an instance whose ledger entry is `imported` and
   whose *declared* segment checksums are unchanged is skipped
   (`skippedAlreadyImported`).
2. If the declared checksums changed, the segments are re-downloaded and
   the *content* checksums are compared:
   - identical content → `skippedAlreadyImported` (already processed,
     whatever the ledger state);
   - different content → *quarantine* (see below).

## Atomicity

An instance is committed **only after every one of its segments has been
downloaded, parsed, and cross-verified** (all segments must share one
schema fingerprint — they are partitions of a single report). The ledger
entry and all normalized records are written in one store transaction.
Any failure — download error, parse error, schema disagreement, empty
segment, checksum surprise — aborts the instance with **nothing
committed**: an incomplete instance is never marked successful.

## Duplicate segments

Segments are physical partitions of one instance. Identical segment
*content* appearing more than once within an instance is parsed once
(deduplicated by content checksum) so rows are never counted twice. Rows
are stored per segment with segment-level provenance for audit.

## Late data (Analytics)

Instances with older processing dates still arrive later in wall-clock
time; that is normal. Each instance is imported independently, with its
own provenance. **Nothing is merged at ingest time.** Reads apply Apple's
documented overwrite rule:

> "Instances from a more recent processing date overwrite instances with
> an earlier processing date … Don't merge records for a Date across two
> report instances to avoid double counting. Use the latest instance."
> — *Data Completeness and Corrections*

`ASCInstanceSelection.latestProcessingDatePerEventDate(_:)` implements
this: per event date, only records from the instance with the latest
processing date participate; records without a processing date count as
the oldest and survive only when no dated instance covers their date.

## Corrections

- **Sales and Trends**: Apple delivers corrected restatements as new
  report *versions* for the same report date. When a newer version is
  imported, the engine marks older imported versions `superseded` in the
  same transaction. Queries exclude superseded data by default
  (`scope: .current`); `scope: .all` retains everything for audit, with
  the superseding key recorded on each superseded entry. Versions that
  cannot be ordered (non-numeric, incomparable strings) are **not**
  superseded automatically: both are retained and the run reports a note
  for manual review instead of guessing.
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

## What the engine does not do

- **No scheduling.** The host app decides when to run the engine.
- **No deletion.** Superseded and pending-review data is retained with
  provenance (repository rule: persist source information so numbers can
  be audited later).
- **No cross-report merging.** Sales (transaction windows, `MM/DD/YYYY`)
  and Analytics (UTC event days, `YYYY-MM-DD`) use different date bases
  and are never combined implicitly.
