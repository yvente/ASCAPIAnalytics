import Foundation
import XCTest

@testable import ASCAPIAnalytics

final class ASCGzipDecoderTests: XCTestCase {
    private let decoder = ASCGzipDecoder()

    // MARK: - CRC32 primitives

    func testCRC32KnownVectors() {
        XCTAssertEqual(ASCCRC32.checksum(Data()), 0x0000_0000)
        XCTAssertEqual(ASCCRC32.checksum(Data("123456789".utf8)), ASCGzipVectors.canonicalCRC32)
        XCTAssertEqual(
            ASCCRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)),
            ASCGzipVectors.foxCRC32
        )
        XCTAssertEqual(ASCCRC32.checksum(Data("hello".utf8)), ASCGzipVectors.helloCRC32)
    }

    func testTestSideCRC32MatchesProductionOnVectors() {
        // Two independently written implementations must agree.
        XCTAssertEqual(ASCGzipFixture.crc32(Data("123456789".utf8)), ASCGzipVectors.canonicalCRC32)
        XCTAssertEqual(ASCGzipFixture.crc32(Data("hello".utf8)), ASCGzipVectors.helloCRC32)
    }

    // MARK: - Valid streams

    func testDecodesHandCraftedHelloFixture() throws {
        let data = Data(ASCGzipVectors.helloGzip)
        let decoded = try decoder.decode(data)
        XCTAssertEqual(decoded, Data("hello".utf8))
    }

    func testDecodesStoredBlockFixture() throws {
        let payload = Data("ASCAPIAnalytics synthetic report payload".utf8)
        let decoded = try decoder.decode(ASCGzipFixture.gzip(payload: payload))
        XCTAssertEqual(decoded, payload)
    }

    func testDecodesMultiBlockStoredPayload() throws {
        let payload = Data(String(repeating: "0123456789", count: 20_000).utf8) // 200 KB
        let decoded = try decoder.decode(ASCGzipFixture.gzip(payload: payload))
        XCTAssertEqual(decoded, payload)
    }

    func testDecodesSystemCompressedDeflate() throws {
        let payload = Data(String(repeating: "ASCAPIAnalytics-", count: 5_000).utf8)
        let fixture = try ASCGzipFixture.gzipWithSystemDeflate(payload: payload)
        let decoded = try decoder.decode(fixture)
        XCTAssertEqual(decoded, payload)
    }

    func testDecodesEmptyPayload() throws {
        let decoded = try decoder.decode(ASCGzipFixture.gzip(payload: Data()))
        XCTAssertEqual(decoded, Data())
    }

    func testDecodesMemberWithAllOptionalHeaderFields() throws {
        let payload = Data("rich header".utf8)
        let fixture = ASCGzipFixture.gzip(
            payload: payload,
            flags: 0b0001_1110, // FHCRC + FEXTRA + FNAME + FCOMMENT
            extra: Data([0x01, 0x02, 0x03, 0x04]),
            name: "report.txt",
            comment: "synthetic",
            withHeaderCRC: true
        )
        XCTAssertEqual(try decoder.decode(fixture), payload)
    }

    func testDecodesConcatenatedMembers() throws {
        let first = ASCGzipFixture.gzip(payload: Data("one".utf8))
        let second = ASCGzipFixture.gzip(payload: Data("two".utf8))
        let decoded = try decoder.decode(ASCGzipFixture.concatenated([first, second]))
        XCTAssertEqual(decoded, Data("onetwo".utf8))
    }

    // MARK: - Corrupt and unsupported streams

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(try decoder.decode(Data())) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipInvalidMagic)
        }
    }

    func testRejectsNonGzipInput() {
        let data = Data("not gzip at all".utf8)
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipInvalidMagic)
        }
    }

    func testRejectsUnsupportedCompressionMethod() {
        var fixture = ASCGzipFixture.gzip(payload: Data("x".utf8))
        fixture[2] = 0x09 // CM = 9 (unsupported)
        XCTAssertThrowsError(try decoder.decode(fixture)) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipUnsupportedCompressionMethod(rawMethod: 0x09))
        }
    }

    func testRejectsReservedHeaderFlags() {
        let fixture = ASCGzipFixture.gzip(payload: Data("x".utf8), flags: 0b0010_0000)
        XCTAssertThrowsError(try decoder.decode(fixture)) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipUnsupportedHeaderFlags(rawFlags: 0b0010_0000))
        }
    }

    func testRejectsCorruptHeaderChecksum() {
        let fixture = ASCGzipFixture.gzip(
            payload: Data("x".utf8),
            flags: 0b0000_0010,
            withHeaderCRC: true,
            corruptHeaderCRC: true
        )
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            guard case .gzipHeaderChecksumMismatch = error else {
                return XCTFail("expected gzipHeaderChecksumMismatch, got \(error)")
            }
        }
    }

    func testRejectsTruncatedHeader() {
        var fixture = ASCGzipFixture.gzip(payload: Data("hello".utf8))
        fixture = fixture.prefix(7) // Cut inside the fixed header.
        XCTAssertThrowsError(try decoder.decode(Data(fixture))) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipHeaderTruncated)
        }
    }

    func testRejectsTruncatedBody() {
        var fixture = ASCGzipFixture.gzip(payload: Data("hello world".utf8))
        fixture = fixture.prefix(fixture.count - 10) // Remove footer + part of body.
        XCTAssertThrowsError(try decoder.decode(Data(fixture))) { error in
            XCTAssertTrue(
                error as? ASCAnalyticsError == .gzipStreamTruncated
                    || error as? ASCAnalyticsError == .gzipDeflateFailed(status: 0)
                    || error as? ASCAnalyticsError == .gzipHeaderTruncated,
                "unexpected error: \(error)"
            )
        }
    }

    func testRejectsTruncatedFooter() {
        var fixture = ASCGzipFixture.gzip(payload: Data("hello".utf8))
        fixture.removeLast(4) // Cut into the trailer.
        XCTAssertThrowsError(try decoder.decode(Data(fixture))) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipStreamTruncated)
        }
    }

    func testRejectsCorruptCRC32() {
        let fixture = ASCGzipFixture.gzip(payload: Data("payload".utf8), corruptCRC: true)
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            guard case .gzipCRC32Mismatch = error else {
                return XCTFail("expected gzipCRC32Mismatch, got \(error)")
            }
        }
    }

    func testRejectsCorruptISize() {
        let fixture = ASCGzipFixture.gzip(payload: Data("payload".utf8), corruptISize: true)
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            guard case .gzipISIZEMismatch = error else {
                return XCTFail("expected gzipISIZEMismatch, got \(error)")
            }
        }
    }

    func testRejectsTrailingGarbage() {
        var fixture = ASCGzipFixture.gzip(payload: Data("payload".utf8))
        fixture.append(Data("garbage".utf8))
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            guard case .gzipTrailingData = error else {
                return XCTFail("expected gzipTrailingData, got \(error)")
            }
        }
    }

    func testRejectsBitFlippedPayload() {
        var fixture = ASCGzipFixture.gzip(payload: Data("payload with content".utf8))
        // Flip one byte inside the stored block body.
        fixture[fixture.count - 13] ^= 0xFF
        XCTAssertThrowsError(try decoder.decode(fixture)) { error in
            // Stored blocks carry no checksum of their own; the damage
            // surfaces in the trailer CRC.
            guard case ASCAnalyticsError.gzipCRC32Mismatch = error as! ASCAnalyticsError else {
                return XCTFail("expected gzipCRC32Mismatch, got \(error)")
            }
        }
    }

    // MARK: - Limits

    func testEnforcesOutputLimit() {
        // ~200 KB of zeros compresses to almost nothing with the system
        // deflate; a 1 KB limit must stop it before completion.
        let payload = Data(repeating: 0, count: 200_000)
        let fixture = try! ASCGzipFixture.gzipWithSystemDeflate(payload: payload)
        let strictDecoder = ASCGzipDecoder(
            configuration: .init(maximumOutputSize: 1024)
        )
        XCTAssertThrowsError(try strictDecoder.decode(fixture)) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipOutputLimitExceeded(limit: 1024))
        }
    }

    func testEnforcesMemberLimit() {
        let members = [
            ASCGzipFixture.gzip(payload: Data("a".utf8)),
            ASCGzipFixture.gzip(payload: Data("b".utf8)),
            ASCGzipFixture.gzip(payload: Data("c".utf8)),
        ]
        let strictDecoder = ASCGzipDecoder(
            configuration: .init(maximumMembers: 2)
        )
        XCTAssertThrowsError(try strictDecoder.decode(ASCGzipFixture.concatenated(members))) { error in
            XCTAssertEqual(error as? ASCAnalyticsError, .gzipMemberLimitExceeded(limit: 2))
        }
    }

    // MARK: - Review regressions: boundary safety

    func testTrailingLoneMagicByteIsStructuredErrorNotCrash() throws {
        // A valid member followed by a single 0x1F byte: reading the
        // second magic byte must be bounds-checked, never crash.
        var fixture = ASCGzipFixture.gzip(payload: Data("payload".utf8))
        fixture.append(0x1F)
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            guard case .gzipTrailingData = error else {
                return XCTFail("expected gzipTrailingData, got \(error)")
            }
        }
    }

    func testTruncatedSecondMemberHeaderIsStructuredError() {
        let first = ASCGzipFixture.gzip(payload: Data("one".utf8))
        // A second member cut off inside its fixed header.
        var truncatedMember = Data([0x1F, 0x8B, 0x08])
        let fixture = ASCGzipFixture.concatenated([first, truncatedMember])
        _ = truncatedMember
        assertThrowsASCError(try decoder.decode(fixture)) { error in
            XCTAssertEqual(error, .gzipHeaderTruncated)
        }
    }

    func testNonFinalStoredBlockNeverCompletes() throws {
        // A stored block whose BFINAL bit is 0: the stream never ends, so
        // under FINALIZE the decoder cannot complete and the failure must
        // be a structured truncation/deflate error, never a hang or crash.
        var data = Data()
        data.append(0x1F)
        data.append(0x8B)
        data.append(0x08)
        data.append(0x00)
        data.append(contentsOf: LE(UInt32(0)))
        data.append(0x00)
        data.append(0x03)
        // Stored block, NOT final (0x00), length 5, "hello".
        data.append(0x00)
        data.append(contentsOf: LE(UInt16(5)))
        data.append(contentsOf: LE(UInt16(~UInt16(5))))
        data.append(Data("hello".utf8))
        // Trailer (would only matter if the stream ended).
        data.append(contentsOf: LE(ASCGzipFixture.crc32(Data("hello".utf8))))
        data.append(contentsOf: LE(UInt32(5)))

        assertThrowsASCError(try decoder.decode(data)) { error in
            switch error {
            case .gzipStreamTruncated, .gzipDeflateFailed:
                break // structured truncation/deflate errors are expected
            default:
                XCTFail("expected truncation or deflate failure, got \(error)")
            }
        }
    }

    func testZeroAndNegativeOutputLimitsAreSafe() throws {
        let fixture = ASCGzipFixture.gzip(payload: Data("x".utf8))

        let zeroLimit = ASCGzipDecoder(configuration: .init(maximumOutputSize: 0))
        assertThrowsASCError(try zeroLimit.decode(fixture)) { error in
            XCTAssertEqual(error, .gzipOutputLimitExceeded(limit: 0))
        }

        let negativeLimit = ASCGzipDecoder(configuration: .init(maximumOutputSize: -1))
        assertThrowsASCError(try negativeLimit.decode(fixture)) { error in
            XCTAssertEqual(error, .gzipOutputLimitExceeded(limit: -1))
        }

        // An empty payload produces zero output bytes and stays within a
        // zero budget.
        let emptyFixture = ASCGzipFixture.gzip(payload: Data())
        XCTAssertEqual(try zeroLimit.decode(emptyFixture), Data())
    }

    func testRandomGarbageNeverCrashes() {
        // Structured errors for arbitrary hostile input.
        let inputs: [Data] = [
            Data([0x1F]),
            Data([0x1F, 0x8B]),
            Data([0x1F, 0x8B, 0x08]),
            Data(repeating: 0x1F, count: 64),
            Data([0x00, 0x01, 0x02, 0x03]),
        ]
        for input in inputs {
            XCTAssertThrowsError(try decoder.decode(input)) { error in
                XCTAssertTrue(error is ASCAnalyticsError, "expected structured error, got \(error)")
            }
        }
    }
}
