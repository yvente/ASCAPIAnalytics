import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCTSVParserTests: XCTestCase {
    private let parser = ASCTSVParser()

    // MARK: - Basics

    func testParsesSimpleTable() throws {
        let data = ASCFixtures.tsv([
            "A\tB\tC",
            "1\t2\t3",
            "4\t5\t6",
        ])
        let table = try parser.parse(data)
        XCTAssertEqual(table.header, ["A", "B", "C"])
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0].fields, ["1", "2", "3"])
        XCTAssertEqual(table.rows[1].fields, ["4", "5", "6"])
        XCTAssertEqual(table.rows[0].lineNumber, 2)
        XCTAssertEqual(table.rows[1].lineNumber, 3)
    }

    func testSkipsUTF8BOM() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("A\tB\n1\t2".utf8))
        let table = try parser.parse(data)
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.rows.first?.fields, ["1", "2"])
    }

    func testHandlesCRLFLineEndings() throws {
        let data = Data("A\tB\r\n1\t2\r\n3\t4\r\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.rows.map(\.fields), [["1", "2"], ["3", "4"]])
    }

    func testHandlesMissingTrailingNewline() throws {
        let data = Data("A\tB\n1\t2".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows.count, 1)
        XCTAssertEqual(table.rows[0].fields, ["1", "2"])
    }

    func testPreservesEmptyFieldsIncludingLastColumn() throws {
        let data = Data("A\tB\tC\n\t\t\nx\t\t".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["", "", ""])
        XCTAssertEqual(table.rows[1].fields, ["x", "", ""])
    }

    func testHeaderOnlyTableHasNoRows() throws {
        let table = try parser.parse(Data("A\tB\n".utf8))
        XCTAssertEqual(table.header, ["A", "B"])
        XCTAssertEqual(table.rows.count, 0)
    }

    // MARK: - Quoting

    func testQuotedFieldWithDelimiterAndNewline() throws {
        let data = Data("A\tB\n\"line1\tstill B\"\tsecond\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["line1\tstill B", "second"])
    }

    func testQuotedFieldSpanningLines() throws {
        let data = Data("A\tB\n\"multi\nline\"\t2\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["multi\nline", "2"])
        XCTAssertEqual(table.rows[0].lineNumber, 2)
        XCTAssertEqual(table.rows.count, 1)
    }

    func testEscapedQuotesInsideQuotedField() throws {
        let data = Data("A\n\"say \"\"hi\"\" now\"\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["say \"hi\" now"])
    }

    func testQuotesInsideUnquotedFieldsAreLiteralData() throws {
        let data = Data("Title\nMy \"App\" 2\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["My \"App\" 2"])
    }

    func testQuotedEmptyField() throws {
        let data = Data("A\tB\n\"\"\t1\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["", "1"])
    }

    func testCRLFInsideQuotedFieldIsData() throws {
        let data = Data("A\tB\n\"a\r\nb\"\t2\n".utf8)
        let table = try parser.parse(data)
        XCTAssertEqual(table.rows[0].fields, ["a\r\nb", "2"])
    }

    // MARK: - Errors

    func testRejectsEmptyInput() {
        assertThrowsASCError(try parser.parse(Data())) { error in
            XCTAssertEqual(error, .tsvEmptyInput)
        }
    }

    func testRejectsBOMOnlyInput() {
        assertThrowsASCError(try parser.parse(Data([0xEF, 0xBB, 0xBF]))) { error in
            XCTAssertEqual(error, .tsvEmptyInput)
        }
    }

    func testRejectsInvalidUTF8() {
        let data = Data([0x41, 0xFF, 0xFE, 0x0A])
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvInvalidUTF8)
        }
    }

    func testRejectsDuplicateHeaderNames() {
        let data = Data("A\tB\tA\n1\t2\t3\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(
                error,
                .tsvDuplicateHeader(name: "A", firstColumn: 1, duplicateColumn: 3)
            )
        }
    }

    func testRejectsDuplicateHeaderNamesCaseInsensitively() {
        let data = Data("Date\tDATE\n1\t2\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(
                error,
                .tsvDuplicateHeader(name: "DATE", firstColumn: 1, duplicateColumn: 2)
            )
        }
    }

    func testRejectsInconsistentFieldCount() {
        let data = Data("A\tB\tC\n1\t2\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvInconsistentFieldCount(line: 2, expected: 3, actual: 2))
        }
    }

    func testRejectsEmptyHeaderName() {
        let data = Data("A\t\tC\n1\t2\t3\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvEmptyHeaderName(line: 1, column: 2))
        }
    }

    func testRejectsUnterminatedQuote() {
        let data = Data("A\n\"unterminated\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvUnterminatedQuote(line: 2))
        }
    }

    func testRejectsTextAfterClosingQuote() {
        let data = Data("A\n\"abc\"def\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvTextAfterClosingQuote(line: 2, column: 1))
        }
    }

    func testRejectsBareCarriageReturn() {
        let data = Data("A\n1\r2\n".utf8)
        assertThrowsASCError(try parser.parse(data)) { error in
            XCTAssertEqual(error, .tsvBareCarriageReturn(line: 2))
        }
    }

    func testRejectsRowLimitViolation() {
        let strict = ASCTSVParser(
            configuration: ASCTSVParserConfiguration(maximumRows: 2)
        )
        let data = ASCFixtures.tsv([
            "A",
            "1",
            "2",
            "3",
        ])
        assertThrowsASCError(try strict.parse(data)) { error in
            XCTAssertEqual(error, .tsvRowLimitExceeded(limit: 2))
        }
    }

    func testRejectsSizeLimitViolation() {
        let strict = ASCTSVParser(
            configuration: ASCTSVParserConfiguration(maximumInputSize: 4)
        )
        assertThrowsASCError(try strict.parse(Data("A\tB\tC\n".utf8))) { error in
            XCTAssertEqual(error, .tsvSizeLimitExceeded(limit: 4))
        }
    }

    // MARK: - CSV delimiter

    func testParsesCSVWithQuotedCommas() throws {
        let csv = ASCTSVParser(
            configuration: ASCTSVParserConfiguration(delimiter: .comma)
        )
        let data = Data("Name,Note\n\"Doe, Jane\",\"a, b\"\n".utf8)
        let table = try csv.parse(data)
        XCTAssertEqual(table.header, ["Name", "Note"])
        XCTAssertEqual(table.rows[0].fields, ["Doe, Jane", "a, b"])
    }
}

final class ASCReportTableTests: XCTestCase {
    private func makeTable() throws -> ASCReportTable {
        try ASCTSVParser().parse(Data(
            "Date\tApp Apple Identifier\tCounts\n2025-10-01\t1234567890\t42\n".utf8
        ))
    }

    func testColumnLookupIsCaseInsensitive() throws {
        let table = try makeTable()
        XCTAssertEqual(table.columnIndex(named: "date"), 0)
        XCTAssertEqual(table.columnIndex(named: "DATE"), 0)
        XCTAssertEqual(table.columnIndex(named: "counts"), 2)
        XCTAssertNil(table.columnIndex(named: "Missing"))
    }

    func testRequireColumnThrowsWithReportName() {
        let table = try! makeTable().withReportName("Test Report")
        assertThrowsASCError(try table.requireColumn(named: "Nope")) { error in
            XCTAssertEqual(error, .missingRequiredColumn(report: "Test Report", column: "Nope"))
        }
    }

    func testDecimalParsesLeadingDotValues() throws {
        let table = try ASCTSVParser().parse(ASCFixtures.tsv([
            "V",
            ".7",
            "-0.99",
            "2.10",
            "+3",
        ]))
        XCTAssertEqual(try table.decimal("V", row: table.rows[0]), Decimal(string: "0.7"))
        XCTAssertEqual(try table.decimal("V", row: table.rows[1]), Decimal(string: "-0.99"))
        XCTAssertEqual(try table.decimal("V", row: table.rows[2]), Decimal(string: "2.10"))
        XCTAssertEqual(try table.decimal("V", row: table.rows[3]), Decimal(3))
    }

    func testDecimalRejectsThousandsSeparatorsAndText() throws {
        let table = try ASCTSVParser().parse(ASCFixtures.tsv([
            "V",
            "1,234.5",
            "abc",
        ]))
        for row in table.rows {
            assertThrowsASCError(try table.decimal("V", row: row)) { error in
                guard case .invalidFieldValue = error else {
                    return XCTFail("expected invalidFieldValue, got \(error)")
                }
            }
        }
    }

    func testIntegerRejectsFractionalValues() throws {
        let table = try ASCTSVParser().parse(ASCFixtures.tsv([
            "V",
            "2.5",
        ]))
        assertThrowsASCError(try table.integer("V", row: table.rows[0])) { error in
            guard case .invalidFieldValue(let report, let column, let value, _, let reason) = error else {
                return XCTFail("expected invalidFieldValue, got \(error)")
            }
            XCTAssertEqual(report, "report")
            XCTAssertEqual(column, "V")
            XCTAssertEqual(value, "2.5")
            XCTAssertEqual(reason, "expected a whole number")
        }
    }

    func testRequiredStringRejectsBlank() throws {
        // "V\n\n": header plus one data row whose single field is empty.
        let table = try ASCTSVParser().parse(Data("V\n\n".utf8))
        XCTAssertEqual(table.rows.count, 1)
        assertThrowsASCError(try table.requiredString("V", row: table.rows[0])) { error in
            XCTAssertEqual(error, .missingRequiredField(report: "report", column: "V", line: 2))
        }
    }
}

final class ASCCalendarDateTests: XCTestCase {
    func testValidation() {
        XCTAssertNotNil(ASCCalendarDate(year: 2024, month: 2, day: 29)) // leap year
        XCTAssertNil(ASCCalendarDate(year: 2023, month: 2, day: 29))
        XCTAssertNil(ASCCalendarDate(year: 2025, month: 13, day: 1))
        XCTAssertNil(ASCCalendarDate(year: 2025, month: 4, day: 31))
    }

    func testISOAndSalesParsing() {
        let iso = ASCCalendarDate(iso8601Day: "2025-10-01")
        XCTAssertEqual(iso?.description, "2025-10-01")
        let sales = ASCCalendarDate(salesReportDate: "10/01/2025")
        XCTAssertEqual(sales?.description, "2025-10-01")
        XCTAssertEqual(sales, iso)
        XCTAssertNil(ASCCalendarDate(iso8601Day: "2025-10-1"))
        XCTAssertNil(ASCCalendarDate(salesReportDate: "10/01/25"))
    }

    func testWeekAnchorsToMonday() {
        // 2025-10-01 is a Wednesday; the week starts Monday 2025-09-29.
        let wednesday = ASCCalendarDate(iso8601Day: "2025-10-01")!
        XCTAssertEqual(wednesday.startOfWeek.description, "2025-09-29")
        // Sunday 2025-10-05 belongs to the same Monday-based week.
        let sunday = ASCCalendarDate(iso8601Day: "2025-10-05")!
        XCTAssertEqual(sunday.startOfWeek.description, "2025-09-29")
        let monday = ASCCalendarDate(iso8601Day: "2025-10-06")!
        XCTAssertEqual(monday.startOfWeek.description, "2025-10-06")
    }

    func testDateRangeBasics() {
        let start = ASCCalendarDate(iso8601Day: "2025-10-01")!
        let end = ASCCalendarDate(iso8601Day: "2025-10-07")!
        let range = ASCDateRange(start: start, end: end)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.dayCount, 7)
        XCTAssertEqual(range?.days.count, 7)
        XCTAssertTrue(range!.contains(ASCCalendarDate(iso8601Day: "2025-10-04")!))
        XCTAssertFalse(range!.contains(ASCCalendarDate(iso8601Day: "2025-10-08")!))
        XCTAssertNil(ASCDateRange(start: end, end: start))
    }

    func testCompletenessAssessment() {
        let eventDate = ASCCalendarDate(iso8601Day: "2024-03-30")!
        // App Downloads report: completeness within two days.
        let processed = ASCCalendarDate(iso8601Day: "2024-04-01")!
        let complete = ASCReportCompletenessThreshold.assess(
            eventDate: eventDate, processingDate: processed,
            thresholdDays: ASCReportCompletenessThreshold.analyticsDownloadsDays
        )
        XCTAssertEqual(complete, .complete)

        let early = ASCCalendarDate(iso8601Day: "2024-03-31")!
        let notComplete = ASCReportCompletenessThreshold.assess(
            eventDate: early, processingDate: processed,
            thresholdDays: ASCReportCompletenessThreshold.analyticsDownloadsDays
        )
        XCTAssertEqual(notComplete, .notYetComplete(expectedCompleteOnOrAfter: "2024-04-02"))
    }
}
