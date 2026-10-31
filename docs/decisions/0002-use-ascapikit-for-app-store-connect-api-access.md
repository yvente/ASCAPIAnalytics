# ADR-0002: Use ASCAPIKit for all App Store Connect API access

- Status: Accepted
- Date: 2026-10-31

## Context

ASCAPIAnalytics needs App Store Connect report access. ASCAPIKit
(https://github.com/yvente/ASCAPIKit) already implements ES256 JWT signing,
the App Store Connect HTTP client, typed models, and an injectable transport
(`ASCTransport` / `URLSessionASCTransport`).

## Decision

ASCAPIAnalytics delegates **all** App Store Connect authentication and API
requests to ASCAPIKit and never re-implements JWT signing or an Apple API
HTTP client. The dependency is constrained to compatible 0.5.x releases:

```swift
.package(
    url: "https://github.com/yvente/ASCAPIKit.git",
    .upToNextMinor(from: "0.5.0")
)
```

ASCAPIKit v0.5.0 is the current release this constraint resolves against.

## Consequences

- ASCAPIAnalytics versions track ASCAPIKit capability releases; the
  constraint may not be changed unilaterally by contributors or agents.
- Network access stays injectable (`ASCTransport`), keeping all tests offline.
- Bug fixes in auth/HTTP semantics arrive by updating within 0.5.x.
