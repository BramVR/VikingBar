import Foundation
import Testing
@testable import VikingBarCore

struct BundleBalanceTests {
    @Test func `every documented kind decodes and an unknown kind fails the whole balance`() throws {
        let kinds = ["data", "sms", "voice", "value"]
        let bundles = kinds.map { Self.bundle(type: $0) }.joined(separator: ",")
        let balance = try LiveAPI.decodeBalance(Data("{\"bundles\":[\(bundles)]}".utf8))
        #expect(balance.bundles.map(\.type) == [.data, .sms, .voice, .value])
        let unknown = "{\"bundles\":[\(Self.bundle(type: "data")),\(Self.bundle(type: "mms"))]}"
        #expect(throws: LiveFailure.malformedResponse) { try LiveAPI.decodeBalance(Data(unknown.utf8)) }
    }

    @Test func `each kind keeps its own exact unit`() throws {
        #expect(try Self.balance("data", total: "100", used: "40", remaining: "60")
            == .data(.finite(totalBytes: 100, usedBytes: 40, remainingBytes: 60)))
        #expect(try Self.balance("sms", total: "100", used: "40", remaining: "60")
            == .sms(.finite(total: Self.sms(100), used: Self.sms(40), remaining: Self.sms(60))))
        #expect(try Self.balance("voice", total: "2400", used: "1230", remaining: "1170")
            == .voice(.finite(total: Self.seconds(2400), used: Self.seconds(1230), remaining: Self.seconds(1170))))
        let value = try Self.balance("value", total: "15", used: "2.5", remaining: "12.505")
        #expect(value == .value(.finite(
            total: Self.euros("15"), used: Self.euros("2.5"), remaining: Self.euros("12.505"),
        )))
        guard case let .value(.finite(_, _, remaining)) = value else { throw BundleTestFailure.unexpected }
        #expect(remaining.euros == Decimal(string: "12.505"))
    }

    @Test func `minus one is unlimited for every kind`() throws {
        #expect(try Self.balance("data", total: "-1", used: "7", remaining: "-1") == .data(.unlimited(usedBytes: 7)))
        #expect(try Self.balance("sms", total: "-1", used: "7", remaining: "-1") == .sms(.unlimited(used: Self.sms(7))))
        #expect(try Self.balance("voice", total: "-1", used: "7", remaining: "-1")
            == .voice(.unlimited(used: Self.seconds(7))))
        #expect(try Self.balance("value", total: "-1", used: "0.5", remaining: "-1")
            == .value(.unlimited(used: Self.euros("0.5"))))
    }

    @Test func `fractional counts negative amounts and out of window bundles are unavailable`() throws {
        #expect(try Self.balance("sms", total: "100", used: "0.5", remaining: "99.5") == .sms(.unavailable))
        #expect(try Self.balance("voice", total: "60", used: "1.5", remaining: "58.5") == .voice(.unavailable))
        #expect(try Self.balance("sms", total: "-2", used: "0", remaining: "0") == .sms(.unavailable))
        #expect(try Self.balance("voice", total: "60", used: "0", remaining: "-5") == .voice(.unavailable))
        #expect(try Self.balance("value", total: "-2", used: "0", remaining: "0") == .value(.unavailable))
        #expect(try Self.balance("value", total: "10", used: "-0.5", remaining: "10.5") == .value(.unavailable))
        #expect(try Self.balance("sms", total: "100", used: "1", remaining: "99", at: .distantFuture)
            == .sms(.unavailable))
        #expect(try Self.balance("value", total: "5", used: "1", remaining: "4", at: .distantPast)
            == .value(.unavailable))
    }

    @Test func `only data bundles are ever active`() throws {
        let balance = try LiveAPI.decodeBalance(Data(
            "{\"bundles\":[\(Self.bundle(type: "sms")),\(Self.bundle(type: "data"))]}".utf8,
        ))
        #expect(balance.bundles.map { $0.isCurrent(at: LiveModelsTests.now) } == [true, true])
        #expect(balance.bundles.map { $0.isActive(at: LiveModelsTests.now) } == [false, true])
        #expect(balance.bundles[0].allowance(at: LiveModelsTests.now) == .unavailable)
    }

    @Test func `publish selects the data bundle listed after an sms bundle`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let bundles = [Self.bundle(type: "sms"), Self.bundle(type: "data", total: "50", used: "20", remaining: "30")]
        await rig.transport.setResponse(
            path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundles.joined(separator: ","))]}",
        )
        let state = try await rig.session.refresh()
        #expect(state.selectedBundleIndex == 1)
        #expect(state.snapshot.allowance == .finite(totalBytes: 50, usedBytes: 20, remainingBytes: 30))
        await #expect(throws: LiveFailure.invalidSelection) { try await rig.session.selectBundle(index: 0) }
        #expect(await rig.session.state().selectedBundleIndex == 1)
    }

    @Test func `a SIM with only non data bundles has no selected bundle`() async throws {
        let rig = Rig()
        _ = try await rig.session.bootstrap(credentials: LiveSessionTests.credentials)
        let bundles = [Self.bundle(type: "voice"), Self.bundle(type: "sms"), Self.bundle(type: "value")]
        await rig.transport.setResponse(
            path: "/mv/subscriptions/sim-a/balance", json: "{\"bundles\":[\(bundles.joined(separator: ","))]}",
        )
        let state = try await rig.session.refresh()
        #expect(state.selectedBundleIndex == nil)
        #expect(state.snapshot.allowance == .unavailable)
        #expect(MenuPresentation(snapshot: state.snapshot).statusTitle == "VikingBar ?")
        #expect(state.balance?.bundles.count == 3)
    }

    @Test func `legacy cache with voice and sms bundles decodes and round trips`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vikingbar-bundle-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("balance-v1.json")
        try Data(Self.legacyCache.utf8).write(to: url)
        let connectionID = try ConnectionID(rawValue: #require(UUID(uuidString: Self.connection)))
        let cache = FileBalanceCache(url: url)
        let loaded = try #require(try cache.load(connectionID: connectionID))
        #expect(loaded.balance?.bundles.map(\.type) == [.data, .voice, .sms])
        #expect(loaded.balance?.bundles[1].used == 1230)
        #expect(loaded.selectedBundleIndex == 0)
        try cache.save(loaded)
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(saved.contains("\"type\":\"voice\"") && saved.contains("\"type\":\"sms\""))
        #expect(try cache.load(connectionID: connectionID) == loaded)
    }

    private static let connection = "00000000-0000-0000-0000-000000000001"

    private static let legacyCache = """
    {"version":1,"state":{"connectionID":{"rawValue":"\(connection)"},
    "subscriptions":[{"id":"sim-a","type":"postpaid","displayName":"SIM"}],"selectedSubscriptionID":"sim-a",
    "balance":{"bundles":[
    {"title":"Data","description":"","category":"default","type":"data","total":100,"used":40,"remaining":60,
    "validFrom":800000000,"validUntil":900000000},
    {"title":"","description":"","category":"default","type":"voice","total":2400,"used":1230,"remaining":1170,
    "validFrom":800000000,"validUntil":900000000},
    {"title":"","description":"","category":"default","type":"sms","total":-1,"used":3,"remaining":-1,
    "validFrom":800000000,"validUntil":900000000}],"regionality":"national"},
    "selectedBundleIndex":0,
    "snapshot":{"source":{"live":{}},"subscriptionName":"SIM",
    "allowance":{"finite":{"totalBytes":100,"usedBytes":40,"remainingBytes":60}},"expiresAt":900000000,
    "freshness":{"current":{"lastUpdated":850000000}}},"isRefreshing":false,"scopeMismatch":false}}
    """

    static func bundle(type: String, total: String = "100", used: String = "25", remaining: String = "75") -> String {
        LiveModelsTests.bundle(total: total, used: used, remaining: remaining)
            .replacingOccurrences(of: "\"type\":\"data\"", with: "\"type\":\"\(type)\"")
    }

    private static func balance(
        _ type: String, total: String, used: String, remaining: String, at date: Date = LiveModelsTests.now,
    ) throws -> BundleBalance {
        let json = "{\"bundles\":[\(Self.bundle(type: type, total: total, used: used, remaining: remaining))]}"
        return try LiveAPI.decodeBalance(Data(json.utf8)).bundles[0].balance(at: date)
    }

    private static func sms(_ count: UInt64) -> MessageCount {
        MessageCount(exact: Decimal(count))!
    }

    private static func seconds(_ seconds: UInt64) -> CallDuration {
        CallDuration(exact: Decimal(seconds))!
    }

    private static func euros(_ text: String) -> EuroAmount {
        EuroAmount(exact: Decimal(string: text)!)!
    }
}

enum BundleTestFailure: Error {
    case unexpected
}
