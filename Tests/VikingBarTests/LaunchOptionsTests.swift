import Foundation
import Testing
@testable import VikingBarCore

@Test(arguments: [
    ["--fixture"], ["--fixture", "live"], ["--unknown"],
    ["--fixture", "finite", "--fixture", "error"], ["--unit", "TB"],
    ["--time-zone", "Invalid/Nowhere"], ["--help", "--fixture", "finite"],
    ["finite"], ["--fixture", "finite", "extra"],
])
func `invalid CLI arguments fail at the boundary`(arguments: [String]) {
    #expect(throws: ArgumentError.self) { try LaunchOptions(arguments: arguments) }
}

@Test func `no arguments require explicit fixture for CLI report`() throws {
    let options = try LaunchOptions(arguments: [])
    #expect(options.fixture == nil)
    #expect(throws: ArgumentError.fixtureRequired) {
        try FixtureReport(options: options, referenceDate: Date(timeIntervalSince1970: 0))
    }
}

@Test func `help needs no fixture`() throws {
    #expect(try LaunchOptions(arguments: ["--help"]).showHelp)
    #expect(try LaunchOptions(arguments: ["-h"]).showHelp)
}

@Test(arguments: FixtureState.allCases)
func `cli report uses identical snapshot and menu model`(state: FixtureState) throws {
    let options = try LaunchOptions(arguments: ["--fixture", state.rawValue, "--unit", "GiB", "--time-zone", "UTC"])
    let referenceDate = Date(timeIntervalSince1970: 1_783_252_800)
    let report = try FixtureReport(options: options, referenceDate: referenceDate)
    #expect(report.snapshot == state.snapshot(referenceDate: referenceDate))
    #expect(report.menu == MenuPresentation(snapshot: report.snapshot, unit: .gibibytes, timeZone: options.timeZone))
    let encoded = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(FixtureReport.self, from: encoded) == report)
    #expect(report.schemaVersion == 1)
}
