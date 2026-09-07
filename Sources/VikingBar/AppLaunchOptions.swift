import Foundation
import VikingBarCore

struct AppLaunchOptions {
    let shared: LaunchOptions
    let settingsFile: URL?

    init(arguments: [String]) throws {
        var sharedArguments: [String] = []
        var settingsFile: URL?
        var index = 0
        while index < arguments.count {
            if arguments[index] == "--settings-file" {
                guard settingsFile == nil, index + 1 < arguments.count,
                      arguments[index + 1].hasPrefix("/")
                else { throw ArgumentError.invalid("--settings-file requires one absolute path.") }
                settingsFile = URL(fileURLWithPath: arguments[index + 1])
                index += 2
            } else {
                sharedArguments.append(arguments[index])
                index += 1
            }
        }
        self.shared = try LaunchOptions(arguments: sharedArguments)
        guard settingsFile == nil || self.shared.fixture != nil else {
            throw ArgumentError.invalid("--settings-file requires --fixture.")
        }
        self.settingsFile = settingsFile
    }
}
