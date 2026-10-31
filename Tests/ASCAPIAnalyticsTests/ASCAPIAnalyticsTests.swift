import XCTest

import ASCAPIAnalytics
import ASCAPIKit

/// Base offline tests: the package module and its ASCAPIKit dependency must
/// both be importable and usable without any network access.
final class ASCAPIAnalyticsModuleTests: XCTestCase {
    func testModuleEntryIsAvailable() {
        XCTAssertEqual(String(describing: ASCAPIAnalytics.self), "ASCAPIAnalytics")
        XCTAssertEqual(ASCAPIAnalytics.version, "0.1.0-dev")
    }

    func testASCAPIKitDependencyIsUsableOffline() {
        // `URLSessionASCTransport` and `ASCRequestMethod` are provided by
        // ASCAPIKit. Constructing the injectable transport and reading a case
        // proves the dependency resolves, compiles and links — entirely
        // offline, with no App Store Connect access.
        let transport = URLSessionASCTransport()
        XCTAssertEqual(String(describing: type(of: transport)), "URLSessionASCTransport")
        XCTAssertEqual(ASCRequestMethod.get.rawValue, "GET")
    }
}
