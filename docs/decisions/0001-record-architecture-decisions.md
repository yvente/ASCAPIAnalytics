# ADR-0001: Record architecture decisions

- Status: Accepted
- Date: 2026-10-31

## Context

ASCAPIAnalytics is a long-term maintained repository that humans and coding
agents will extend over years. Its domain (App Store reporting) has strict
correctness rules — money handling, metric additivity, offline testing — that
are easy to violate silently.

## Decision

Architecture decisions are recorded as numbered Markdown files in
`docs/decisions/` using this lightweight format (Status / Date / Context /
Decision / Consequences). Decisions are append-only: a superseded decision
gets a new ADR referencing the old one, and the old ADR's status is updated.

## Consequences

- Any change to the non-negotiable constraints in `AGENTS.md` requires an ADR.
- Contributors and agents can check the reasoning behind a rule instead of
  guessing or quietly working around it.
