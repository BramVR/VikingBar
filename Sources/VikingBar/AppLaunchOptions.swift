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
    let proofAccountRoot: URL?
    let proofAccount: AccountKey?
    let allowLoginItem: Bool
    let paymentFixture: Bool
    let signInFixture: Bool

    private static let pathOptions = ["--settings-file", "--credential-reference", "--proof-directory",
                                      "--proof-account-root"]

    init(arguments: [String]) throws {
        var proofAccount: AccountKey?
        var appearance: FixtureAppearance?
        var sharedArguments: [String] = []
        var paths: [String: URL] = [:]
        let flagOptions: Set = [
            "--allow-login-item",
            "--payment-fixture",
            "--sign-in-fixture",
            "--fixture-reduce-transparency",
        ]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--proof-account" {
                guard proofAccount == nil, index + 1 < arguments.count else {
                    throw ArgumentError.invalid("--proof-account requires one account selector.")
                }
                proofAccount = try AccountKey(selector: arguments[index + 1])
                index += 2
            } else if flagOptions.contains(option) {
                guard flags.insert(option).inserted else { throw ArgumentError.invalid("Repeated \(option).") }
                index += 1
            } else if option == "--fixture-appearance" {
                guard appearance == nil else { throw ArgumentError.invalid("Duplicate --fixture-appearance.") }
                appearance = try Self.parseAppearance(arguments, at: index + 1)
                index += 2
            } else if Self.pathOptions.contains(option) {
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
        self.fixtureReduceTransparency = flags.contains("--fixture-reduce-transparency")
        self.settingsFile = paths["--settings-file"]
        self.credentialReference = paths["--credential-reference"]
        self.proofDirectory = paths["--proof-directory"]
        self.proofAccountRoot = paths["--proof-account-root"]
        self.proofAccount = proofAccount
        self.allowLoginItem = flags.contains("--allow-login-item")
        self.paymentFixture = flags.contains("--payment-fixture")
        self.signInFixture = flags.contains("--sign-in-fixture")
        try self.validate(paths: paths)
    }

    private func validate(paths: [String: URL]) throws {
        guard (self.proofAccountRoot == nil) == (self.proofAccount == nil) else {
            throw ArgumentError.invalid("Proof account and root must be supplied together.")
        }
        if let proofAccount {
            guard self.shared.fixture == nil, !self.shared.showHelp, self.proofDirectory != nil,
                  self.credentialReference == nil, proofAccount != .legacy, self.proofAccountRoot?.path != "/"
            else {
                throw ArgumentError.invalid("Use a separate live proof account, root and proof directory.")
            }
            _ = try ProviderRegistry.production.registration(proofAccount.provider)
        }
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
        guard !self.signInFixture || (self.shared.fixture != nil && self.settingsFile != nil) else {
            throw ArgumentError.invalid("--sign-in-fixture requires --fixture and --settings-file.")
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
