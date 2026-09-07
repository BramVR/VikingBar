import Foundation
import VikingBarCore

struct AppLaunchOptions {
    let shared: LaunchOptions
    let settingsFile: URL?
    let credentialReference: URL?
    let proofDirectory: URL?

    init(arguments: [String]) throws {
        var sharedArguments: [String] = []
        var paths: [String: URL] = [:]
        let pathOptions = ["--settings-file", "--credential-reference", "--proof-directory"]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if pathOptions.contains(option) {
                guard paths[option] == nil, index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/")
                else { throw ArgumentError.invalid("\(option) requires one absolute path.") }
                paths[option] = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            } else {
                sharedArguments.append(option)
                index += 1
            }
        }
        self.shared = try LaunchOptions(arguments: sharedArguments)
        guard !self.shared.showHelp || paths.isEmpty else { throw ArgumentError.invalid("Use --help on its own.") }
        guard paths["--settings-file"] == nil || self.shared.fixture != nil else {
            throw ArgumentError.invalid("--settings-file requires --fixture.")
        }
        guard self.shared.fixture == nil
            || (paths["--credential-reference"] == nil && paths["--proof-directory"] == nil)
        else { throw ArgumentError.invalid("Credential and proof paths cannot be used with --fixture.") }
        self.settingsFile = paths["--settings-file"]
        self.credentialReference = paths["--credential-reference"]
        self.proofDirectory = paths["--proof-directory"]
    }
}
