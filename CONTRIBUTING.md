# Contributing to ASCAPIAnalytics

Thanks for your interest in contributing. This package is in **initial
development**; please read the constraints below before writing code. They
exist to keep the numbers this package will produce trustworthy.

## Setup

- macOS 14 or later.
- Xcode 15 / Swift 5.9 toolchain or newer.

## Local build and test

```bash
swift package resolve
swift build
swift test
```

Before opening a pull request, also run:

```bash
git diff --check   # no whitespace errors
git status --short # confirm exactly the intended files are staged
```

CI runs the same commands on a supported macOS runner via GitHub Actions.

## Code guidelines

- Swift tools 5.9, macOS 14+, no third-party runtime dependencies beyond
  [ASCAPIKit](https://github.com/yvente/ASCAPIKit) and Apple system
  frameworks.
- No SwiftUI, UIKit, or AppKit in library code.
- All App Store Connect authentication and API requests go through ASCAPIKit.
  Never re-implement JWT signing or HTTP client logic here.
- Database access behind protocols only; no direct SQLite or other concrete
  engine in library code.
- Network interfaces are injectable protocols; tests never touch the network.
- Money is `Decimal`, never `Double`. Never sum across currencies. Never
  accumulate non-additive metrics by summation.
- Keep documented metric semantics and provenance alongside computed values
  so results remain auditable.

## Testing guidelines

- Every API, model, or calculation change ships with offline XCTests.
- Test fixtures must be **hand-crafted synthetic data**. Never copy real
  Apple report exports into the repository, even truncated or "anonymized".
- Prefer small, focused tests that pin the semantics of a metric or parser,
  including edge cases: empty segments, duplicate segments, late data,
  corrections.

## Security rules

Never commit, paste, or log:

- API keys, `*.p8` private keys, certificates, or JWTs
- Real downloaded reports (`.gz`, `.tsv`, `.csv` exports from App Store
  Connect)
- Any file from local user data directories

`.gitignore` blocks these patterns; if you believe a file is being ignored by
mistake, discuss it in an issue rather than force-adding it.

## Commits and releases

- Conventional commit messages: `feat:`, `fix:`, `docs:`, `test:`,
  `refactor:`, `chore:`.
- Do not create tags or GitHub releases; maintainers handle versioning. Do
  not change the ASCAPIKit dependency constraint on your own.
- Update `CHANGELOG.md` under **Unreleased** as part of your change.

## Documentation

- Planning documents live in `docs/`. Significant decisions (dependency
  rules, metric semantics, storage choices) get an architecture decision
  record in `docs/decisions/`.
- Docs must reflect reality: planned features are marked as planned,
  implemented features as implemented.
