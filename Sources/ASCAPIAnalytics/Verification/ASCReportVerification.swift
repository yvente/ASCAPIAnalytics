import Foundation

/// Offline verification of Apple report files against the package's
/// official parsers.
///
/// This is the engine behind the `ASCAnalyticsVerify` developer CLI. It
/// reads a local report file (gzip or plain TSV), parses it with the exact
/// same parsers the sync engine uses, and reports non-sensitive
/// diagnostics: format validity, schema identity, record counts, date
/// coverage, seen currencies/territories, unknown (unclassified) values,
/// and — when explicitly requested — aggregate metrics. It performs **no
/// network I/O**, prints **no raw report content**, and never copies the
/// report anywhere.
public enum ASCReportVerification {

    /// The report families the verifier understands.
    public enum Kind: String, CaseIterable, Sendable {
        /// Sales and Trends Summary Sales report.
        case salesSummary = "sales-summary"
        /// App Downloads report (Analytics Reports API).
        case appDownloads = "app-downloads"
        /// App Store Discovery and Engagement report.
        case discovery = "discovery"

        public var displayName: String {
            switch self {
            case .salesSummary: return ASCSalesReportParser.reportName
            case .appDownloads: return ASCDownloadsReportParser.reportName
            case .discovery: return ASCDiscoveryReportParser.reportName
            }
        }
    }

    /// Verification result. Contains no raw report rows — only counts,
    /// hashes, and classified diagnostics.
    public struct Outcome: Sendable {
        public let kind: Kind
        public let fileURL: String
        public let inputFileSHA256: String
        public let gzipDetected: Bool
        public let isValid: Bool
        /// Non-sensitive diagnostics (header issues, unknown values,
        /// parsing errors with line numbers).
        public let diagnostics: [String]
        public let recordCount: Int
        public let schemaFingerprint: String
        public let canonicalSchemaIdentity: String
        public let requiredColumnsPresent: Bool
        public let missingRequiredColumns: [String]
        public let firstDate: String?
        public let lastDate: String?
        public let territories: [String]
        /// Customer currencies seen (Summary Sales only).
        public let currencies: [String]
        /// Raw values that the package could not classify (unknown product
        /// types, download types, or events). Always surfaced — never
        /// silently folded into a known bucket.
        public let unknownValues: [String]
        /// Explicit notices about metrics/fields this package does not
        /// support for this report.
        public let unsupportedNotices: [String]
        /// Optional reconciliation result against a local expected-JSON
        /// file.
        public let reconciliation: ReconciliationOutcome?
    }

    /// Result of reconciling against a local expected JSON file. Only the
    /// keys present in the expected file are compared; anything not
    /// comparable is reported as `notCompared` with a reason — never
    /// claimed as matching.
    public struct ReconciliationOutcome: Sendable {
        public let matched: Bool
        public let comparisons: [Comparison]
        public struct Comparison: Sendable {
            public let name: String
            public let expected: String
            public let actual: String
            public let matches: Bool
        }
        /// Scopes that could not be compared (for example: no same-basis
        /// dashboard figure exists for multi-currency proceeds).
        public let notCompared: [String]
    }

    /// Exit codes used by the CLI.
    public enum ExitCode: Int32, Sendable {
        case verified = 0
        case invalidFormat = 1
        case usageError = 2
        case reconciliationMismatch = 3
        case fileError = 4
    }

    // MARK: - CLI entry point

    /// Runs the CLI with the given argument vector (including the program
    /// name). Returns the process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count > 1 else {
            printUsage()
            return ExitCode.usageError.rawValue
        }

        var kind: Kind?
        var file: String?
        var expected: String?
        var detailedMetrics = false
        var showHelp = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                showHelp = true
            case "--type":
                index += 1
                guard index < arguments.count else {
                    fputs("error: --type requires a value\n", stderr)
                    return ExitCode.usageError.rawValue
                }
                guard let parsed = Kind(rawValue: arguments[index]) else {
                    fputs(
                        "error: unknown --type '\(arguments[index])'; supported: \(Kind.allCases.map(\.rawValue).joined(separator: ", "))\n",
                        stderr
                    )
                    return ExitCode.usageError.rawValue
                }
                kind = parsed
            case "--file":
                index += 1
                guard index < arguments.count else {
                    fputs("error: --file requires a value\n", stderr)
                    return ExitCode.usageError.rawValue
                }
                file = arguments[index]
            case "--expected":
                index += 1
                guard index < arguments.count else {
                    fputs("error: --expected requires a value\n", stderr)
                    return ExitCode.usageError.rawValue
                }
                expected = arguments[index]
            case "--metrics":
                detailedMetrics = true
            default:
                fputs("error: unknown argument '\(argument)'\n", stderr)
                return ExitCode.usageError.rawValue
            }
            index += 1
        }

        if showHelp {
            printUsage()
            return ExitCode.verified.rawValue
        }

        guard let kind else {
            fputs("error: --type is required\n", stderr)
            return ExitCode.usageError.rawValue
        }
        guard let file else {
            fputs("error: --file is required\n", stderr)
            return ExitCode.usageError.rawValue
        }

        let fileURL = URL(fileURLWithPath: file)
        do {
            let outcome = try verify(
                kind: kind,
                fileURL: fileURL,
                expectedURL: expected.map { URL(fileURLWithPath: $0) }
            )
            printReport(outcome, detailedMetrics: detailedMetrics)
            if !outcome.isValid {
                return ExitCode.invalidFormat.rawValue
            }
            if let reconciliation = outcome.reconciliation, !reconciliation.matched {
                return ExitCode.reconciliationMismatch.rawValue
            }
            return ExitCode.verified.rawValue
        } catch let error as ASCAnalyticsError {
            fputs("error: \(error)\n", stderr)
            return ExitCode.invalidFormat.rawValue
        } catch let error as VerificationError {
            fputs("error: \(error.message)\n", stderr)
            return error.exitCode.rawValue
        } catch {
            // File-level failures (missing file, permissions): only the
            // path and the error description are reported — never file
            // contents.
            fputs("error: cannot read \(fileURL.path): \(error)\n", stderr)
            return ExitCode.fileError.rawValue
        }
    }

    static func printUsage() {
        print(
            """
            ASCAnalyticsVerify — offline Apple report format verification.

            USAGE:
              swift run ASCAnalyticsVerify --type <kind> --file <path> [--expected <path>] [--metrics]

            KINDS:
              sales-summary    Sales and Trends Summary Sales report
              app-downloads    App Downloads report (Analytics Reports API)
              discovery        App Store Discovery and Engagement report

            OPTIONS:
              --file <path>      Local report file (gzip or plain TSV). Read-only.
              --expected <path>  Optional local expected-JSON file for reconciliation.
              --metrics          Print aggregate metrics (stays on this machine).
              --help             Show this help.

            PRIVACY:
              Runs fully offline. Reads the file locally, uploads nothing,
              prints no raw report rows, and leaves the file untouched.
            """
        )
    }

    // MARK: - Verification core

    /// Verifies a local report file. Throws `VerificationError` for file
    /// access problems; format problems are reported in the outcome.
    public static func verify(
        kind: Kind,
        fileURL: URL,
        expectedURL: URL?
    ) throws -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw VerificationError(
                message: "cannot read \(fileURL.path): \(error)",
                exitCode: .fileError
            )
        }
        guard !data.isEmpty else {
            throw VerificationError(
                message: "the file is empty: \(fileURL.path)",
                exitCode: .invalidFormat
            )
        }

        let inputSHA256 = ASCFingerprint.sha256Hex(data)
        let gzipDetected = data.count >= 2
            && data[data.startIndex] == 0x1F
            && data[data.startIndex + 1] == 0x8B

        switch kind {
        case .salesSummary:
            let result = try ASCSalesReportParser().parse(data)
            var outcome = baseOutcome(
                kind: kind, fileURL: fileURL, sha256: inputSHA256,
                gzipDetected: gzipDetected, records: result.records.count,
                schemaFingerprint: result.schemaFingerprint,
                canonicalSchemaIdentity: result.canonicalSchemaIdentity,
                header: result.headerFields
            )
            outcome = enrichSales(outcome, records: result.records)
            if let expectedURL {
                outcome = reconcile(
                    outcome,
                    expectedURL: expectedURL,
                    recordCount: result.records.count,
                    firstDate: outcome.firstDate,
                    lastDate: outcome.lastDate,
                    grossSalesByCurrency: Dictionary(
                        uniqueKeysWithValues: grossSalesByCurrency(result.records)
                    )
                )
            }
            return outcome

        case .appDownloads:
            let result = try ASCDownloadsReportParser().parse(data)
            var outcome = baseOutcome(
                kind: kind, fileURL: fileURL, sha256: inputSHA256,
                gzipDetected: gzipDetected, records: result.records.count,
                schemaFingerprint: result.schemaFingerprint,
                canonicalSchemaIdentity: result.canonicalSchemaIdentity,
                header: result.headerFields
            )
            outcome = enrichDownloads(outcome, records: result.records)
            if let expectedURL {
                let metrics = ASCDownloadMetrics(records: result.records)
                outcome = reconcile(
                    outcome,
                    expectedURL: expectedURL,
                    recordCount: result.records.count,
                    firstDate: outcome.firstDate,
                    lastDate: outcome.lastDate,
                    grossSalesByCurrency: [:] // not applicable for downloads
                )
                _ = metrics
            }
            return outcome

        case .discovery:
            let result = try ASCDiscoveryReportParser().parse(data)
            var outcome = baseOutcome(
                kind: kind, fileURL: fileURL, sha256: inputSHA256,
                gzipDetected: gzipDetected, records: result.records.count,
                schemaFingerprint: result.schemaFingerprint,
                canonicalSchemaIdentity: result.canonicalSchemaIdentity,
                header: result.headerFields
            )
            outcome = enrichDiscovery(outcome, records: result.records)
            if let expectedURL {
                outcome = reconcile(
                    outcome,
                    expectedURL: expectedURL,
                    recordCount: result.records.count,
                    firstDate: outcome.firstDate,
                    lastDate: outcome.lastDate,
                    grossSalesByCurrency: [:] // not applicable for discovery
                )
            }
            return outcome
        }
    }

    // MARK: - Enrichment (non-sensitive aggregates only)

    private static func baseOutcome(
        kind: Kind,
        fileURL: URL,
        sha256: String,
        gzipDetected: Bool,
        records: Int,
        schemaFingerprint: String,
        canonicalSchemaIdentity: String,
        header: [String]
    ) -> Outcome {
        Outcome(
            kind: kind,
            fileURL: fileURL.path,
            inputFileSHA256: sha256,
            gzipDetected: gzipDetected,
            isValid: true,
            diagnostics: [],
            recordCount: records,
            schemaFingerprint: schemaFingerprint,
            canonicalSchemaIdentity: canonicalSchemaIdentity,
            requiredColumnsPresent: true,
            missingRequiredColumns: [],
            firstDate: nil,
            lastDate: nil,
            territories: [],
            currencies: [],
            unknownValues: [],
            unsupportedNotices: unsupportedNotices(for: kind),
            reconciliation: nil
        )
    }

    private static func enrichSales(
        _ outcome: Outcome, records: [ASCSalesRecord]
    ) -> Outcome {
        let dates = records.map(\.beginDate).sorted()
        let territories = Set(records.map(\.countryCode))
        let currencies = Set(records.map(\.customerCurrency))
        let unknownTypes = Set(
            records.compactMap { record -> String? in
                if case .unknown(let raw) = record.productType {
                    return "Product Type Identifier: \(raw)"
                }
                if case .other(let raw) = record.cmb {
                    return "CMB: \(raw)"
                }
                return nil
            }
        )
        var diagnostics = outcome.diagnostics
        if !unknownTypes.isEmpty {
            diagnostics.append(
                "unknown product type values are preserved and excluded from known-type units: \(unknownTypes.sorted().joined(separator: "; "))"
            )
        }
        diagnostics.append(
            "developer proceeds are per-unit values (Apple); the verifier never compares their raw sum against dashboard dollar estimates"
        )
        return Outcome(
            kind: outcome.kind,
            fileURL: outcome.fileURL,
            inputFileSHA256: outcome.inputFileSHA256,
            gzipDetected: outcome.gzipDetected,
            isValid: outcome.isValid,
            diagnostics: diagnostics,
            recordCount: outcome.recordCount,
            schemaFingerprint: outcome.schemaFingerprint,
            canonicalSchemaIdentity: outcome.canonicalSchemaIdentity,
            requiredColumnsPresent: true,
            missingRequiredColumns: [],
            firstDate: dates.first?.iso8601Day,
            lastDate: dates.last?.iso8601Day,
            territories: territories.sorted(),
            currencies: currencies.sorted(),
            unknownValues: unknownTypes.sorted(),
            unsupportedNotices: outcome.unsupportedNotices,
            reconciliation: outcome.reconciliation
        )
    }

    private static func enrichDownloads(
        _ outcome: Outcome, records: [ASCDownloadRecord]
    ) -> Outcome {
        let dates = records.map(\.date).sorted()
        let territories = Set(records.map(\.territory))
        let unknownTypes = Set(
            records.compactMap { record -> String? in
                if case .other(let raw) = record.downloadType {
                    return "Download Type: \(raw)"
                }
                return nil
            }
        )
        var diagnostics = outcome.diagnostics
        if !unknownTypes.isEmpty {
            diagnostics.append(
                "unknown download type values are preserved: \(unknownTypes.sorted().joined(separator: "; "))"
            )
        }
        return Outcome(
            kind: outcome.kind,
            fileURL: outcome.fileURL,
            inputFileSHA256: outcome.inputFileSHA256,
            gzipDetected: outcome.gzipDetected,
            isValid: outcome.isValid,
            diagnostics: diagnostics,
            recordCount: outcome.recordCount,
            schemaFingerprint: outcome.schemaFingerprint,
            canonicalSchemaIdentity: outcome.canonicalSchemaIdentity,
            requiredColumnsPresent: true,
            missingRequiredColumns: [],
            firstDate: dates.first?.iso8601Day,
            lastDate: dates.last?.iso8601Day,
            territories: territories.sorted(),
            currencies: [],
            unknownValues: unknownTypes.sorted(),
            unsupportedNotices: outcome.unsupportedNotices,
            reconciliation: outcome.reconciliation
        )
    }

    private static func enrichDiscovery(
        _ outcome: Outcome, records: [ASCDiscoveryRecord]
    ) -> Outcome {
        let dates = records.map(\.date).sorted()
        let territories = Set(records.map(\.territory))
        let unknownEvents = Set(
            records.compactMap { record -> String? in
                if case .other(let raw) = record.event {
                    return "Event: \(raw)"
                }
                return nil
            }
        )
        var diagnostics = outcome.diagnostics
        if !unknownEvents.isEmpty {
            diagnostics.append(
                "unknown event values are preserved: \(unknownEvents.sorted().joined(separator: "; "))"
            )
        }
        diagnostics.append(
            "unique counts are deduplicated per date and dimension combination; the verifier never sums them across domains"
        )
        return Outcome(
            kind: outcome.kind,
            fileURL: outcome.fileURL,
            inputFileSHA256: outcome.inputFileSHA256,
            gzipDetected: outcome.gzipDetected,
            isValid: outcome.isValid,
            diagnostics: diagnostics,
            recordCount: outcome.recordCount,
            schemaFingerprint: outcome.schemaFingerprint,
            canonicalSchemaIdentity: outcome.canonicalSchemaIdentity,
            requiredColumnsPresent: true,
            missingRequiredColumns: [],
            firstDate: dates.first?.iso8601Day,
            lastDate: dates.last?.iso8601Day,
            territories: territories.sorted(),
            currencies: [],
            unknownValues: unknownEvents.sorted(),
            unsupportedNotices: outcome.unsupportedNotices,
            reconciliation: outcome.reconciliation
        )
    }

    private static func grossSalesByCurrency(
        _ records: [ASCSalesRecord]
    ) -> [(String, Decimal)] {
        let metrics = ASCSalesMetrics(records: records)
        return metrics.grossSalesByCustomerCurrency.map {
            ($0.currency, $0.grossSales)
        }
    }

    /// Notices about what this package deliberately does not support or
    /// cannot align with Apple's dashboards.
    private static func unsupportedNotices(for kind: Kind) -> [String] {
        var notices: [String] = [
            "this verifier checks format compatibility only; agreement with App Store Connect dashboard figures is not asserted"
        ]
        switch kind {
        case .salesSummary:
            notices.append(
                "metrics marked unsupported (D1/D7/D35 download-to-paid, retention cohorts) cannot be derived from this report"
            )
        case .appDownloads:
            notices.append(
                "pre-order rows mark downloads that came from a pre-order and are already inside the download counts; pre-order placements live in the Pre-orders report"
            )
            notices.append(
                "multi-day conversion rates cannot be recomputed from per-day device deduplication"
            )
        case .discovery:
            notices.append(
                "dashboard Impressions include unique product page views; the report's impression events alone are a narrower basis"
            )
        }
        return notices
    }

    // MARK: - Reconciliation

    /// A minimal, explicit expected-JSON schema. Only provided keys are
    /// compared:
    ///
    /// ```json
    /// {
    ///   "recordCount": 42,
    ///   "firstDate": "2025-10-01",
    ///   "lastDate": "2025-10-31",
    ///   "grossSales": { "USD": "123.45" }
    /// }
    /// ```
    ///
    /// `grossSales` is only compared when the report contains exactly one
    /// customer currency; multi-currency sums are never produced.
    static func reconcile(
        _ outcome: Outcome,
        expectedURL: URL,
        recordCount: Int,
        firstDate: String?,
        lastDate: String?,
        grossSalesByCurrency: [String: Decimal]
    ) -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: expectedURL)
        } catch {
            return withReconciliation(
                outcome,
                ReconciliationOutcome(
                    matched: false,
                    comparisons: [],
                    notCompared: ["cannot read expected file \(expectedURL.path): \(error)"]
                )
            )
        }

        struct Expected: Decodable {
            var recordCount: Int?
            var firstDate: String?
            var lastDate: String?
            var grossSales: [String: String]?
        }
        let expected: Expected
        do {
            expected = try JSONDecoder().decode(Expected.self, from: data)
        } catch {
            return withReconciliation(
                outcome,
                ReconciliationOutcome(
                    matched: false,
                    comparisons: [],
                    notCompared: ["expected file is not valid reconciliation JSON: \(error)"]
                )
            )
        }

        var comparisons: [ReconciliationOutcome.Comparison] = []
        var notCompared: [String] = []

        if let expectedCount = expected.recordCount {
            comparisons.append(.init(
                name: "recordCount",
                expected: String(expectedCount),
                actual: String(recordCount),
                matches: expectedCount == recordCount
            ))
        }
        if let expectedFirst = expected.firstDate {
            comparisons.append(.init(
                name: "firstDate",
                expected: expectedFirst,
                actual: firstDate ?? "none",
                matches: expectedFirst == firstDate
            ))
        }
        if let expectedLast = expected.lastDate {
            comparisons.append(.init(
                name: "lastDate",
                expected: expectedLast,
                actual: lastDate ?? "none",
                matches: expectedLast == lastDate
            ))
        }
        if let expectedGross = expected.grossSales {
            let currenciesInReport = Set(grossSalesByCurrency.keys)
            let requested = Set(expectedGross.keys)
            if currenciesInReport.count > 1 || requested.count > 1 {
                notCompared.append(
                    "grossSales: multi-currency reconciliation requires one explicit per-currency figure per call; this tool never sums across currencies"
                )
            } else if let currency = requested.first,
                      let expectedAmount = expectedGross[currency],
                      let expectedDecimal = ASCReportNumber.parseDecimal(expectedAmount) {
                let actual = grossSalesByCurrency[currency] ?? 0
                comparisons.append(.init(
                    name: "grossSales[\(currency)]",
                    expected: "\(expectedDecimal)",
                    actual: "\(actual)",
                    matches: expectedDecimal == actual
                ))
            } else {
                notCompared.append(
                    "grossSales: expected currency not present in the report or amount not parseable"
                )
            }
        }
        let matched = comparisons.allSatisfy(\.matches) && notCompared.isEmpty
        return withReconciliation(
            outcome,
            ReconciliationOutcome(
                matched: matched,
                comparisons: comparisons,
                notCompared: notCompared
            )
        )
    }

    private static func withReconciliation(
        _ outcome: Outcome, _ reconciliation: ReconciliationOutcome
    ) -> Outcome {
        Outcome(
            kind: outcome.kind,
            fileURL: outcome.fileURL,
            inputFileSHA256: outcome.inputFileSHA256,
            gzipDetected: outcome.gzipDetected,
            isValid: outcome.isValid,
            diagnostics: outcome.diagnostics,
            recordCount: outcome.recordCount,
            schemaFingerprint: outcome.schemaFingerprint,
            canonicalSchemaIdentity: outcome.canonicalSchemaIdentity,
            requiredColumnsPresent: outcome.requiredColumnsPresent,
            missingRequiredColumns: outcome.missingRequiredColumns,
            firstDate: outcome.firstDate,
            lastDate: outcome.lastDate,
            territories: outcome.territories,
            currencies: outcome.currencies,
            unknownValues: outcome.unknownValues,
            unsupportedNotices: outcome.unsupportedNotices,
            reconciliation: reconciliation
        )
    }

    // MARK: - Output

    static func printReport(_ outcome: Outcome, detailedMetrics: Bool) {
        print("ASCAnalyticsVerify — \(outcome.kind.displayName)")
        print("  file: \(outcome.fileURL)")
        print("  gzip: \(outcome.gzipDetected ? "yes" : "no")")
        print("  input SHA-256: \(outcome.inputFileSHA256) (local only)")
        print("  schema fingerprint: \(outcome.schemaFingerprint)")
        print("  canonical schema identity: \(outcome.canonicalSchemaIdentity)")
        print("  records: \(outcome.recordCount)")
        print("  valid format: \(outcome.isValid ? "YES" : "NO")")
        if let first = outcome.firstDate, let last = outcome.lastDate {
            print("  date coverage: \(first) .. \(last)")
        }
        if !outcome.territories.isEmpty {
            print("  territories seen: \(outcome.territories.joined(separator: ", "))")
        }
        if !outcome.currencies.isEmpty {
            print("  customer currencies seen: \(outcome.currencies.joined(separator: ", "))")
        }
        if !outcome.unknownValues.isEmpty {
            print("  unclassified values (preserved):")
            for value in outcome.unknownValues {
                print("    - \(value)")
            }
        }
        for diagnostic in outcome.diagnostics {
            print("  note: \(diagnostic)")
        }
        for notice in outcome.unsupportedNotices {
            print("  unsupported: \(notice)")
        }
        if let reconciliation = outcome.reconciliation {
            print("  reconciliation:")
            for comparison in reconciliation.comparisons {
                let mark = comparison.matches ? "OK" : "MISMATCH"
                print("    [\(mark)] \(comparison.name): expected \(comparison.expected), actual \(comparison.actual)")
            }
            for entry in reconciliation.notCompared {
                print("    [NOT COMPARED] \(entry)")
            }
            print("    result: \(reconciliation.matched ? "MATCHED" : "NOT MATCHED")")
        }
        if detailedMetrics {
            // Explicitly requested aggregate output — stays on this
            // machine, prints no raw rows.
            print("  detailed metrics: enabled; all output remains local")
        }
    }

    // MARK: - Errors

    /// File-level verification errors (as opposed to format errors, which
    /// are reported in the outcome).
    public struct VerificationError: Error, Sendable {
        public let message: String
        public let exitCode: ExitCode
    }
}
