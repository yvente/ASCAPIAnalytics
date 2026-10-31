import Compression
import Foundation

/// CRC-32 (IEEE 802.3, reflected, polynomial `0xEDB88320`) as required by
/// the gzip trailer (RFC 1952). Implemented locally because no Apple system
/// framework exposes CRC32 through Swift.
enum ASCCRC32 {
    static let initial: UInt32 = 0xFFFF_FFFF

    private static let table: [UInt32] = {
        var generated: [UInt32] = []
        generated.reserveCapacity(256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 != 0 {
                    value = 0xEDB8_8320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            generated.append(value)
        }
        return generated
    }()

    static func update(_ crc: UInt32, with byte: UInt8) -> UInt32 {
        (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
    }

    /// CRC32 of a byte buffer. Known vectors: `""` → `0x00000000`,
    /// `"123456789"` → `0xCBF43926`.
    static func checksum(_ bytes: UnsafePointer<UInt8>, count: Int) -> UInt32 {
        var crc = initial
        for index in 0..<count {
            crc = update(crc, with: bytes[index])
        }
        return ~crc
    }

    /// CRC32 of `Data`. Empty data yields `0x00000000`.
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return ~initial }
            return checksum(base.assumingMemoryBound(to: UInt8.self), count: data.count)
        }
    }
}

/// Decodes gzip streams (RFC 1952) using only Apple system frameworks.
///
/// The decoder is deliberately strict and is built for Apple report
/// segments:
///
/// - The gzip header is validated byte by byte: magic bytes, compression
///   method (deflate only), reserved flag bits (RFC 1952 requires zero),
///   and all optional header fields (`FEXTRA`, `FNAME`, `FCOMMENT`,
///   `FHCRC`) are parsed and bounds-checked; a present header checksum is
///   verified.
/// - The deflate body is inflated with the system Compression framework
///   (`COMPRESSION_ZLIB`, which implements the raw DEFLATE codec).
/// - The trailer's CRC32 and ISIZE are verified against the actual output.
/// - Concatenated members are supported, bounded by `maximumMembers`.
/// - Output size is enforced incrementally, so a decompression bomb fails
///   once it exceeds `maximumOutputSize` instead of exhausting memory.
/// - Truncated and corrupt streams raise errors; no check is skipped to
///   make input pass.
public struct ASCGzipDecoder: Sendable {
    /// Decoder limits. Defaults are sized for Apple report segments
    /// (a few megabytes at most) with generous headroom.
    public struct Configuration: Sendable {
        /// Maximum accepted compressed input size in bytes.
        public var maximumInputSize: Int
        /// Maximum accepted decompressed output size in bytes. Enforced
        /// incrementally during inflation.
        public var maximumOutputSize: Int
        /// Maximum number of concatenated gzip members.
        public var maximumMembers: Int

        public init(
            maximumInputSize: Int = 512 * 1024 * 1024,
            maximumOutputSize: Int = 512 * 1024 * 1024,
            maximumMembers: Int = 16
        ) {
            self.maximumInputSize = maximumInputSize
            self.maximumOutputSize = maximumOutputSize
            self.maximumMembers = maximumMembers
        }
    }

    public static let defaultConfiguration = Configuration()

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Decodes a gzip stream.
    ///
    /// - Parameter data: raw gzip bytes (for example a downloaded report
    ///   segment as served with `Accept: application/a-gzip`).
    /// - Returns the concatenation of all decoded members.
    public func decode(_ data: Data) throws -> Data {
        guard data.count <= configuration.maximumInputSize else {
            throw ASCAnalyticsError.gzipOutputLimitExceeded(limit: configuration.maximumInputSize)
        }
        guard data.count >= 2, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            throw ASCAnalyticsError.gzipInvalidMagic
        }

        var output = Data()
        var offset = 0
        var memberCount = 0

        while offset < data.count {
            guard data[data.startIndex + offset] == 0x1F,
                  data[data.startIndex + offset + 1] == 0x8B
            else {
                throw ASCAnalyticsError.gzipTrailingData(offset: offset)
            }

            memberCount += 1
            guard memberCount <= configuration.maximumMembers else {
                throw ASCAnalyticsError.gzipMemberLimitExceeded(limit: configuration.maximumMembers)
            }

            let decoded = try decodeMember(
                data, memberStart: offset, outputSoFar: output.count
            )
            output.append(decoded.output)
            offset = decoded.endOffset
        }

        return output
    }

    // MARK: - Member decoding

    private struct MemberResult {
        let output: Data
        let endOffset: Int
    }

    private func decodeMember(
        _ data: Data, memberStart: Int, outputSoFar: Int
    ) throws -> MemberResult {
        var offset = memberStart

        // Fixed 10-byte header: ID1 ID2 CM FLG MTIME(4) XFL OS.
        let fixedHeaderEnd = memberStart + 10
        guard fixedHeaderEnd <= data.count else {
            throw ASCAnalyticsError.gzipHeaderTruncated
        }

        let method = data[data.startIndex + memberStart + 2]
        guard method == 8 else {
            throw ASCAnalyticsError.gzipUnsupportedCompressionMethod(rawMethod: method)
        }

        let flags = data[data.startIndex + memberStart + 3]
        let flagMask = flags & 0b1110_0000
        guard flagMask == 0 else {
            throw ASCAnalyticsError.gzipUnsupportedHeaderFlags(rawFlags: flags)
        }

        let hasHeaderCRC = flags & 0b0000_0010 != 0
        let hasExtra = flags & 0b0000_0100 != 0
        let hasName = flags & 0b0000_1000 != 0
        let hasComment = flags & 0b0001_0000 != 0

        offset = fixedHeaderEnd
        let headerStartForChecksum = memberStart

        if hasExtra {
            guard offset + 2 <= data.count else {
                throw ASCAnalyticsError.gzipHeaderTruncated
            }
            let extraLength = Int(Self.readUInt16LE(data, offset: &offset))
            guard offset + extraLength <= data.count else {
                throw ASCAnalyticsError.gzipOptionalFieldTruncated(field: "FEXTRA")
            }
            offset += extraLength
        }

        if hasName {
            offset = try skipZeroTerminatedField(
                data, from: offset, field: "FNAME"
            )
        }

        if hasComment {
            offset = try skipZeroTerminatedField(
                data, from: offset, field: "FCOMMENT"
            )
        }

        if hasHeaderCRC {
            guard offset + 2 <= data.count else {
                throw ASCAnalyticsError.gzipHeaderTruncated
            }
            // The header checksum covers everything before the FHCRC
            // field itself.
            let headerEnd = offset
            let expected = Self.readUInt16LE(data, offset: &offset)
            let headerBytes = data.subdata(
                in: (data.startIndex + headerStartForChecksum)..<(data.startIndex + headerEnd)
            )
            let actualCRC32 = ASCCRC32.checksum(headerBytes)
            let actualCRC16 = UInt16(truncatingIfNeeded: actualCRC32)
            guard expected == actualCRC16 else {
                throw ASCAnalyticsError.gzipHeaderChecksumMismatch(
                    expected: expected,
                    actual: actualCRC16
                )
            }
        }

        // Inflate the raw deflate body.
        //
        // Apple's Compression framework consumes the whole fed buffer when
        // it reports COMPRESSION_STATUS_END — it never reports how many
        // input bytes the deflate stream actually used, so the trailer
        // position cannot be read off `src_size`. Strategy:
        //
        // 1. Fast path: assume this member ends at EOF (trailer is the
        //    last 8 bytes) and inflate `[deflateStart, count - 8)`.
        // 2. If that assumption produces a valid CRC32 + ISIZE, the member
        //    ends at EOF. Otherwise bisect for the smallest prefix that
        //    inflates to completion; its position is the true end of the
        //    deflate stream, and the trailer is validated there. The outer
        //    loop then verifies that the following bytes are either EOF or
        //    the magic of a concatenated member.
        let deflateStart = offset
        let budget = configuration.maximumOutputSize - outputSoFar

        if data.count - 8 >= deflateStart {
            let outcome = try inflatePrefix(
                data, from: deflateStart, end: data.count - 8, remainingOutputBudget: budget
            )
            if case .ended(let output) = outcome {
                do {
                    try Self.validateTrailer(of: output, in: data, at: data.count - 8)
                    return MemberResult(output: output, endOffset: data.count)
                } catch {
                    // The member does not end at EOF; locate its real end
                    // below, so that trailing data and concatenated members
                    // are reported honestly.
                }
            }
        }

        let located = try locateMemberEndAndDecode(
            data, deflateStart: deflateStart, budget: budget
        )
        return MemberResult(output: located.output, endOffset: located.endOffset)
    }

    private struct LocatedMember {
        let output: Data
        let endOffset: Int
    }

    private static func validateTrailer(
        of output: Data, in data: Data, at trailerStart: Int
    ) throws {
        var offset = trailerStart
        let expectedCRC = readUInt32LE(data, offset: &offset)
        let expectedISize = readUInt32LE(data, offset: &offset)

        let actualCRC = ASCCRC32.checksum(output)
        guard actualCRC == expectedCRC else {
            throw ASCAnalyticsError.gzipCRC32Mismatch(
                expected: expectedCRC,
                actual: actualCRC
            )
        }
        let actualISize = UInt32(truncatingIfNeeded: output.count)
        guard actualISize == expectedISize else {
            throw ASCAnalyticsError.gzipISIZEMismatch(
                expected: Int(expectedISize),
                actual: output.count
            )
        }
    }

    /// Bisection search for the true end of the deflate stream: the
    /// smallest prefix length whose inflation reports completion. The
    /// trailer is then validated at that position.
    private func locateMemberEndAndDecode(
        _ data: Data, deflateStart: Int, budget: Int
    ) throws -> LocatedMember {
        var anyFailureStatus: Int32?
        var smallestEnded: Int?

        // Binary search: END is monotone in the fed length — prefixes
        // shorter than the stream fail or never complete under FINALIZE,
        // prefixes that reach the final block report END.
        var low = deflateStart + 1
        var high = data.count - 8
        while low <= high {
            let mid = (low + high) / 2
            let outcome = try inflatePrefix(
                data, from: deflateStart, end: mid, remainingOutputBudget: budget
            )
            switch outcome {
            case .ended:
                smallestEnded = mid
                high = mid - 1
            case .incomplete:
                low = mid + 1
            case .failed(let status):
                anyFailureStatus = status
                low = mid + 1
            }
        }

        guard let candidate = smallestEnded else {
            // No prefix inflates to completion. Distinguish a truncated
            // stream from a corrupt one: without FINALIZE, a decoder that
            // consumed everything and still asks for more input means the
            // stream is truncated; a hard failure means the data is
            // corrupt.
            let fullOutcome = try inflatePrefix(
                data, from: deflateStart, end: data.count - 8,
                remainingOutputBudget: budget, finalize: false
            )
            switch fullOutcome {
            case .incomplete:
                throw ASCAnalyticsError.gzipStreamTruncated
            case .failed(let status):
                throw ASCAnalyticsError.gzipDeflateFailed(status: Int(status))
            case .ended:
                throw ASCAnalyticsError.gzipStreamTruncated
            }
        }

        let outcome = try inflatePrefix(
            data, from: deflateStart, end: candidate, remainingOutputBudget: budget
        )
        guard case .ended(let output) = outcome else {
            if let status = anyFailureStatus {
                throw ASCAnalyticsError.gzipDeflateFailed(status: Int(status))
            }
            throw ASCAnalyticsError.gzipStreamTruncated
        }

        do {
            try Self.validateTrailer(of: output, in: data, at: candidate)
        } catch {
            // The trailer at the true stream end is wrong: report the
            // checksum mismatch rather than a positional guess.
            throw error
        }
        return LocatedMember(output: output, endOffset: candidate + 8)
    }

    // MARK: - Inflate

    private enum InflatePrefixOutcome {
        /// The deflate stream ended within the fed bytes.
        case ended(output: Data)
        /// The fed bytes were exhausted without reaching the end.
        case incomplete
        /// The decoder rejected the input under FINALIZE.
        case failed(status: Int32)
    }

    /// Inflates the byte range `[start, end)` as a complete deflate stream
    /// (FINALIZE). Enforces the output budget incrementally.
    private func inflatePrefix(
        _ data: Data, from start: Int, end: Int, remainingOutputBudget: Int,
        finalize: Bool = true
    ) throws -> InflatePrefixOutcome {
        let inputLength = end - start
        guard inputLength > 0 else {
            return .incomplete
        }

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        let initStatus = compression_stream_init(
            &stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB
        )
        guard initStatus == COMPRESSION_STATUS_OK else {
            throw ASCAnalyticsError.gzipDeflateFailed(status: Int(initStatus.rawValue))
        }
        defer { compression_stream_destroy(&stream) }

        let destinationCapacity = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(
            capacity: destinationCapacity
        )
        defer { destination.deallocate() }

        var output = Data()
        let budget = remainingOutputBudget
        var outcome: InflatePrefixOutcome = .incomplete

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else {
                throw ASCAnalyticsError.gzipStreamTruncated
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var consumed = 0

            while true {
                let available = inputLength - consumed
                let feed = min(available, 1 << 20)

                stream.src_ptr = bytes + start + consumed
                stream.src_size = feed
                stream.dst_ptr = destination
                stream.dst_size = destinationCapacity

                let flags: Int32 = finalize
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                let status = compression_stream_process(&stream, flags)

                switch status {
                case COMPRESSION_STATUS_OK:
                    let produced = destinationCapacity - stream.dst_size
                    if produced > 0 {
                        if output.count + produced > budget {
                            throw ASCAnalyticsError.gzipOutputLimitExceeded(limit: configuration.maximumOutputSize)
                        }
                        output.append(destination, count: produced)
                    }
                    consumed += feed - stream.src_size

                    let inputExhausted = consumed >= inputLength
                    if inputExhausted && produced == 0 && stream.src_size == 0 {
                        outcome = .incomplete
                        return
                    }

                case COMPRESSION_STATUS_END:
                    let produced = destinationCapacity - stream.dst_size
                    if produced > 0 {
                        if output.count + produced > budget {
                            throw ASCAnalyticsError.gzipOutputLimitExceeded(limit: configuration.maximumOutputSize)
                        }
                        output.append(destination, count: produced)
                    }
                    outcome = .ended(output: output)
                    return

                case COMPRESSION_STATUS_ERROR:
                    outcome = .failed(status: status.rawValue)
                    return

                default:
                    outcome = .failed(status: status.rawValue)
                    return
                }
            }
        }

        return outcome
    }

    // MARK: - Field readers

    private static func readUInt16LE(_ data: Data, offset: inout Int) -> UInt16 {
        let low = UInt32(data[data.startIndex + offset])
        let high = UInt32(data[data.startIndex + offset + 1])
        offset += 2
        return UInt16(low | (high << 8))
    }

    private static func readUInt32LE(_ data: Data, offset: inout Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        offset += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func skipZeroTerminatedField(
        _ data: Data, from start: Int, field: String
    ) throws -> Int {
        var offset = start
        while offset < data.count {
            if data[data.startIndex + offset] == 0 {
                return offset + 1
            }
            offset += 1
        }
        throw ASCAnalyticsError.gzipOptionalFieldTruncated(field: field)
    }
}
