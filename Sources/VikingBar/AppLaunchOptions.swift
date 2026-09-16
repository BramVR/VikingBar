import AppKit
import Foundation
import VikingBarCore

struct AppLaunchOptions {
    enum FixtureAppearance: String {
        case light, dark
        case highContrastLight = "high-contrast-light"
        case highContrastDark = "high-contrast-dark"

        var appearance: NSAppearance? {
            let name: NSAppearance.Name = switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .highContrastLight: .accessibilityHighContrastAqua
            case .highContrastDark: .accessibilityHighContrastDarkAqua
            }
            return NSAppearance(named: name)
        }
    }

    let fixtureAppearance: FixtureAppearance?
    let fixtureReduceTransparency: Bool
    let shared: LaunchOptions
    let settingsFile: URL?
    let credentialReference: URL?
    let proofDirectory: URL?
    let allowLoginItem: Bool
    let paymentFixture: Bool

    init(arguments: [String]) throws {
        var appearance: FixtureAppearance?
        var reduceTransparency = false
        var sharedArguments: [String] = []
        var paths: [String: URL] = [:]
        let pathOptions = ["--settings-file", "--credential-reference", "--proof-directory"]
        let flagOptions: Set = ["--allow-login-item", "--payment-fixture"]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if flagOptions.contains(option) {
                guard flags.insert(option).inserted else { throw ArgumentError.invalid("Repeated \(option).") }
                index += 1
            } else if option == "--fixture-appearance" {
                guard appearance == nil else { throw ArgumentError.invalid("Duplicate --fixture-appearance.") }
                appearance = try Self.parseAppearance(arguments, at: index + 1)
                index += 2
            } else if option == "--fixture-reduce-transparency" {
                guard !reduceTransparency
                else { throw ArgumentError.invalid("Duplicate --fixture-reduce-transparency.") }
                reduceTransparency = true
                index += 1
            } else if pathOptions.contains(option) {
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
        self.fixtureAppearance = appearance
        self.fixtureReduceTransparency = reduceTransparency
        self.settingsFile = paths["--settings-file"]
        self.credentialReference = paths["--credential-reference"]
        self.proofDirectory = paths["--proof-directory"]
        self.allowLoginItem = flags.contains("--allow-login-item")
        self.paymentFixture = flags.contains("--payment-fixture")
        try self.validate(paths: paths)
    }

    private func validate(paths: [String: URL]) throws {
        guard !self.shared.showHelp || paths.isEmpty else { throw ArgumentError.invalid("Use --help on its own.") }
        guard paths["--settings-file"] == nil || self.shared.fixture != nil else {
            throw ArgumentError.invalid("--settings-file requires --fixture.")
        }
        guard self.shared.fixture == nil
            || (paths["--credential-reference"] == nil && paths["--proof-directory"] == nil)
        else { throw ArgumentError.invalid("Credential and proof paths cannot be used with --fixture.") }
        guard !self.allowLoginItem || (self.shared.fixture != nil && paths["--settings-file"] != nil) else {
            throw ArgumentError.invalid("--allow-login-item requires --fixture and --settings-file.")
        }
        guard self.fixtureAppearance == nil && !self.fixtureReduceTransparency || self.shared.fixture != nil else {
            throw ArgumentError.invalid("Fixture appearance options require --fixture.")
        }
        guard !self.paymentFixture || self.shared.fixture != nil else {
            throw ArgumentError.invalid("--payment-fixture requires --fixture.")
        }
    }

    private static func parseAppearance(_ arguments: [String], at index: Int) throws -> FixtureAppearance {
        guard arguments.indices.contains(index), let value = FixtureAppearance(rawValue: arguments[index]) else {
            throw ArgumentError.invalid(
                "--fixture-appearance requires light, dark, high-contrast-light, or high-contrast-dark.",
            )
        }
        return value
    }
}
