import Foundation
import Testing
@testable import VikingBarCore

struct LiveModelsTests {
    @Test func `decimal source amounts remain separate and inexact byte projections are unavailable`() throws {
        let balance = try LiveAPI.decodeBalance(Data(Self.balanceJSON.utf8))
        #expect(balance.bundles.count == 2)
        #expect(balance.bundles[0].total == Decimal(string: "9007199254740993"))
        #expect(balance.bundles[1].used == Decimal(string: "0.5"))
        #expect(balance.bundles[0].allowance(at: Self.now) == .finite(
            totalBytes: 9_007_199_254_740_993, usedBytes: 1, remainingBytes: 9_007_199_254_740_992,
        ))
        #expect(balance.bundles[1].allowance(at: Self.now) == .unavailable)
        #expect(balance.outOfBundleCost == Decimal(string: "1.25"))
        #expect(balance.regionality == "national")
    }

    @Test func `unlimited zero negative overflow and expired allowances stay distinct`() throws {
        func allowance(total: String, used: String, remaining: String, date: Date = Self.now) throws -> Allowance {
            let json = Self.bundle(total: total, used: used, remaining: remaining)
            return try LiveAPI.decodeBalance(Data("{\"bundles\":[\(json)]}".utf8)).bundles[0].allowance(at: date)
        }
        #expect(try allowance(total: "-1", used: "0", remaining: "-1") == .unlimited(usedBytes: 0))
        #expect(try allowance(total: "100", used: "100", remaining: "0") == .finite(
            totalBytes: 100, usedBytes: 100, remainingBytes: 0,
        ))
        #expect(try allowance(total: "-2", used: "0", remaining: "0") == .unavailable)
        #expect(try allowance(total: "18446744073709551616", used: "0", remaining: "0") == .unavailable)
        #expect(try allowance(total: "100", used: "1", remaining: "99", date: .distantFuture) == .unavailable)
    }

    @Test func `subscription decoding rejects unknown types and exports only mobile identity`() throws {
        let values = try LiveAPI.decodeSubscriptions(Data("""
        [{"id":"internet","type":"fixed-internet"},{"id":"phone","type":"prepaid",
        "sim":{"alias":"Work SIM","msisdn":"synthetic","pin1":"NEVER_EXPORT","puk1":"NEVER_EXPORT"}}]
        """.utf8))
        #expect(values.count == 1)
        #expect(values[0].displayName == "Work SIM")
        let encoded = try #require(String(bytes: JSONEncoder().encode(values), encoding: .utf8))
        #expect(!encoded.contains("NEVER_EXPORT"))
        for json in [
            "[{\"id\":\"x\"}]",
            "[{\"id\":\"x\",\"type\":\"future\"}]",
            "[{\"id\":\"../x\",\"type\":\"prepaid\"}]",
        ] {
            #expect(throws: LiveFailure.malformedResponse) { try LiveAPI.decodeSubscriptions(Data(json.utf8)) }
        }
    }

    static let now = Date(timeIntervalSince1970: 1_788_768_000)
    static let subscriptions = """
    [{"id":"sim-a","type":"postpaid","sim":{"alias":"First"}},
    {"id":"sim-b","type":"prepaid","sim":{"alias":"Second"}}]
    """
    static let balanceJSON = """
    {"bundles":[\(Self.bundle(total: "9007199254740993", used: "1", remaining: "9007199254740992")),
    \(Self.bundle(total: "100", used: "0.5", remaining: "99.5"))],
    "regionality":"national","out_of_bundle_cost":1.25}
    """

    static func bundle(total: String = "100", used: String = "25", remaining: String = "75") -> String {
        """
        {"descriptions":{"title":"Data","description":"Synthetic bundle"},"category":"default","type":"data",
        "total":\(total),"used":\(used),"remaining":\(remaining),
        "valid_from":"2026-01-01T00:00:00Z","valid_until":"2027-01-01T00:00:00Z"}
        """
    }
}
