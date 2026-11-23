import Foundation
import XCTest
@testable import ASCAPIAnalytics

final class ASCPurchasesTests: XCTestCase {
    func testPurchasesSeparateRefundsAppPurchasesAndOtherAppsFromIAPCount() throws {
        let input = """
        Date\tApp Apple Identifier\tPurchase Type\tPurchases\tProceeds in USD\tPaying Users
        2026-11-21\t123\tIn-app purchases\t2\t6.50\t1
        2026-11-21\t123\tIn-app purchases\t-1\t-2.50\t
        2026-11-21\t123\tIn-app purchases\t0\t-.50\t1
        2026-11-21\t123\tApp purchase\t4\t7.00\t2
        2026-11-21\t789\tIn-app purchases\t18\t98\t10
        2026-11-22\t123\tFuture type\t9\t1\t1
        """
        let rows = try ASCPurchasesReportParser().parse(Data(input.utf8))
        XCTAssertEqual(rows.map(\.payingUsers), [1, nil, 1, 2, 10, 1])
        let days = ASCPurchasesAggregator().daily(rows, appID: "123")
        XCTAssertEqual(days.map(\.inAppPurchases), [2, nil])
        XCTAssertEqual(days.first?.proceedsUSD, Decimal(string: "10.50"))
    }
}
