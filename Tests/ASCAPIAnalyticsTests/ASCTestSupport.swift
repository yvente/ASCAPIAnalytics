import Compression
import Foundation
import XCTest

@testable import ASCAPIAnalytics

/// Little-endian bytes of a fixed-width integer.
private func LE<T: FixedWidthInteger>(_ value: T) -> Data {
    var littleEndianValue = value.littleEndian
    return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
}

/// Test-side helpers for building gzip fixtures.
///
/// The CRC32 here is a deliberately different implementation (bitwise,
/// table-free) from the table-driven one under test, and the fixed vectors
/// were generated with an independent zlib implementation.
enum ASCGzipFixture {
    /// Bitwise CRC-32 (IEEE, reflected), independent of the production
    /// table-driven implementation.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    /// Wraps `payload` in a gzip member using stored (uncompressed)
    /// deflate blocks — every byte of the fixture is constructed here, so
    /// the decoder is validated against fully hand-built streams.
    static func gzip(
        payload: Data,
        flags: UInt8 = 0,
        extra: Data = Data(),
        name: String? = nil,
        comment: String? = nil,
        withHeaderCRC: Bool = false,
        corruptHeaderCRC: Bool = false,
        corruptCRC: Bool = false,
        corruptISize: Bool = false,
        mtime: UInt32 = 0
    ) -> Data {
        var data = Data()
        data.append(0x1F)
        data.append(0x8B)
        data.append(0x08) // CM = deflate
        data.append(flags)
        data.append(contentsOf: LE(mtime))
        data.append(0x00) // XFL
        data.append(0x03) // OS = Unix

        if flags & 0x04 != 0 { // FEXTRA
            data.append(contentsOf: LE(UInt16(extra.count)))
            data.append(extra)
        }
        if flags & 0x08 != 0, let name { // FNAME
            data.append(Data(name.utf8))
            data.append(0x00)
        }
        if flags & 0x10 != 0, let comment { // FCOMMENT
            data.append(Data(comment.utf8))
            data.append(0x00)
        }
        if flags & 0x02 != 0 { // FHCRC
            let crc16 = UInt16(truncatingIfNeeded: crc32(data))
            let corrupted = corruptHeaderCRC ? crc16 ^ 0x5A5A : crc16
            data.append(contentsOf: LE(corrupted))
        }

        // Stored deflate blocks, max 65535 bytes each.
        var offset = 0
        repeat {
            let chunkSize = min(65535, payload.count - offset)
            let isFinal = offset + chunkSize >= payload.count
            data.append(isFinal ? 0x01 : 0x00) // BFINAL + BTYPE=00 (stored)
            let length = UInt16(chunkSize)
            data.append(contentsOf: LE(length))
            data.append(contentsOf: LE(~length))
            data.append(payload.subdata(in: payload.startIndex + offset..<payload.startIndex + offset + chunkSize))
            offset += chunkSize
        } while offset < payload.count

        var crc = crc32(payload)
        if corruptCRC {
            crc ^= 0xFFFF_FFFF
        }
        data.append(contentsOf: LE(crc))

        var isize = UInt32(truncatingIfNeeded: payload.count)
        if corruptISize {
            isize &+= 1
        }
        data.append(contentsOf: LE(isize))

        return data
    }

    /// Concatenates gzip members into one multi-member stream.
    static func concatenated(_ members: [Data]) -> Data {
        members.reduce(into: Data()) { $0.append($1) }
    }

    /// Produces a real deflate stream with the system Compression
    /// framework (raw DEFLATE) and wraps it in a gzip container with the
    /// test-side CRC32. Exercises the decoder against genuine dynamic
    /// Huffman output.
    static func gzipWithSystemDeflate(payload: Data) throws -> Data {
        let algorithm = COMPRESSION_ZLIB
        let destinationCapacity = payload.count + 4096
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destination.deallocate() }

        let compressedSize = try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let source = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            let size = compression_encode_buffer(
                destination, destinationCapacity,
                source, payload.count,
                nil, algorithm
            )
            guard size > 0 else {
                throw NSError(domain: "fixture", code: 1)
            }
            return size
        }

        var data = Data()
        data.append(0x1F)
        data.append(0x8B)
        data.append(0x08)
        data.append(0x00)
        data.append(contentsOf: LE(UInt32(0)))
        data.append(0x00)
        data.append(0x03)
        data.append(destination, count: compressedSize)
        data.append(contentsOf: LE(crc32(payload)))
        data.append(contentsOf: LE(UInt32(truncatingIfNeeded: payload.count)))
        return data
    }
}

/// Shared synthetic report content builders. All data is hand-crafted;
/// no real report is ever committed or used.
enum ASCFixtures {
    static func tsv(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    /// Sales report header in Apple's documented order.
    static let salesHeader = [
        "Provider", "Provider Country", "SKU", "Developer", "Title",
        "Version", "Product Type Identifier", "Units", "Developer Proceeds",
        "Begin Date", "End Date", "Customer Currency", "Country Code",
        "Currency of Proceeds", "Apple Identifier", "Customer Price",
        "Promo Code", "Parent Identifier", "CMB",
    ]

    static func salesLine(
        sku: String = "APPONE",
        productType: String,
        units: String,
        proceeds: String,
        begin: String = "10/01/2025",
        end: String = "10/01/2025",
        currency: String = "USD",
        country: String = "US",
        proceedsCurrency: String = "USD",
        appleIdentifier: String = "1234567890",
        customerPrice: String,
        parentIdentifier: String = "",
        cmb: String = "",
        title: String = "App One",
        extra: [String] = []
    ) -> String {
        [
            "APPLE", "US", sku, "Developer One", title, "1.2.3",
            productType, units, proceeds, begin, end, currency, country,
            proceedsCurrency, appleIdentifier, customerPrice, "", parentIdentifier, cmb,
        ].joined(separator: "\t")
    }

    static func salesReport(_ lines: [String]) -> Data {
        tsv([salesHeader.joined(separator: "\t")] + lines)
    }

    static let downloadsHeader = [
        "Date", "App Name", "App Apple Identifier", "Download Type",
        "App Version", "Device", "Platform Version", "Source Type",
        "Page Type", "Pre-Order", "Territory", "Counts",
    ]

    static func downloadsReport(_ lines: [String]) -> Data {
        tsv([downloadsHeader.joined(separator: "\t")] + lines)
    }

    static func downloadsLine(
        date: String,
        downloadType: String,
        territory: String = "US",
        counts: String,
        appIdentifier: String = "1234567890",
        preOrder: String = "",
        sourceType: String = "App Store browse",
        pageType: String = "Product page"
    ) -> String {
        [
            date, "App One", appIdentifier, downloadType, "1.2.3", "iPhone",
            "18.0", sourceType, pageType, preOrder, territory, counts,
        ].joined(separator: "\t")
    }

    static let discoveryHeader = [
        "Date", "App Name", "App Apple Identifier", "Event", "Page Type",
        "Source Type", "Engagement Type", "Device", "Platform Version",
        "Territory", "Counts", "Unique Counts",
    ]

    static func discoveryReport(_ lines: [String]) -> Data {
        tsv([discoveryHeader.joined(separator: "\t")] + lines)
    }

    static func discoveryLine(
        date: String,
        event: String,
        pageType: String = "Product page",
        sourceType: String = "App Store browse",
        engagementType: String = "",
        territory: String = "US",
        counts: String,
        uniqueCounts: String,
        appIdentifier: String = "1234567890"
    ) -> String {
        [
            date, "App One", appIdentifier, event, pageType, sourceType,
            engagementType, "iPhone", "18.0", territory, counts, uniqueCounts,
        ].joined(separator: "\t")
    }
}

/// Fixed gzip vectors produced with an independent zlib implementation.
enum ASCGzipVectors {
    /// gzip of "hello" (stored block, MTIME 0, OS 3).
    static let helloGzip: [UInt8] = [
        0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x01, 0x05, 0x00, 0xFA, 0xFF, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
        0x86, 0xA6, 0x10, 0x36, 0x05, 0x00, 0x00, 0x00,
    ]

    static let helloCRC32: UInt32 = 0x3610_A686
    static let canonicalCRC32: UInt32 = 0xCBF4_3926 // "123456789"
    static let foxCRC32: UInt32 = 0x414F_A339 // "The quick brown fox jumps over the lazy dog"
}

/// Asserts that the expression throws an `ASCAnalyticsError` and verifies
/// it with `verifier`, failing the test on any other error type.
func assertThrowsASCError<T>(
    _ expression: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verifier: (ASCAnalyticsError) -> Void
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        guard let ascError = error as? ASCAnalyticsError else {
            XCTFail("expected ASCAnalyticsError, got \(error)", file: file, line: line)
            return
        }
        verifier(ascError)
    }
}
