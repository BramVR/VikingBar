import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct AppLaunchOptionsTests {
    @Test func `live app paths remain separate from shared CLI options`() throws {
        let options = try AppLaunchOptions(arguments: [
            "--credential-reference", "/synthetic-home/reference.json", "--proof-directory", "/synthetic-home/proof",
            "--unit", "GiB",
        ])
        #expect(options.credentialReference?.path == "/synthetic-home/reference.json")
        #expect(options.proofDirectory?.path == "/synthetic-home/proof")
        #expect(options.shared.unit == .gibibytes)
        #expect(options.shared.fixture == nil)
    }

    @Test func `live paths reject fixtures relative paths duplicate flags and mixed help`() {
        for flag in ["--credential-reference", "--proof-directory"] {
            for arguments in [
                [flag], [flag, "relative"], [flag, "/a", flag, "/b"],
                [flag, "/a", "--fixture", "finite"], [flag, "/a", "--help"],
            ] {
                #expect(throws: ArgumentError.self) { try AppLaunchOptions(arguments: arguments) }
            }
        }
    }
}
