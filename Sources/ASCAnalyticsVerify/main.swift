import ASCAPIAnalytics
import Foundation

// Thin CLI shell around ASCReportVerification. All logic lives in the
// library so the exact same code path is unit-testable offline; this
// executable adds no networking, no telemetry, and no third-party
// dependencies.
let exitCode = ASCReportVerification.run(CommandLine.arguments)
Foundation.exit(exitCode)
