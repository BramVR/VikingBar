import Foundation
import VikingBarCore

struct AccountOptions {
    var account: AccountKey?
    var provider: ProviderID?
    var remaining: [String] = []

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            if option == "--account" || option == "--provider" {
                guard index + 1 < arguments.count else { throw ProofFailure.invalidInput }
                index += 1
                if option == "--account" {
                    guard self.account == nil else { throw ProofFailure.invalidInput }
                    self.account = try AccountKey(selector: arguments[index])
                    _ = try ProviderRegistry.production.registration(self.account!.provider)
                } else {
                    guard self.provider == nil, let provider = ProviderID(rawValue: arguments[index]) else {
                        throw ProofFailure.invalidInput
                    }
                    _ = try ProviderRegistry.production.registration(provider)
                    self.provider = provider
                }
            } else {
                self.remaining.append(option)
            }
            index += 1
        }
        guard self.account == nil || self.provider == nil || self.account?.provider == self.provider else {
            throw ProofFailure.invalidInput
        }
    }

    func resolve(in catalog: AccountCatalog) throws -> AccountKey {
        try catalog.resolve(self.account, provider: self.provider)
    }
}

extension VikingBarCLI {
    static func accounts(arguments: [String]) {
        do {
            guard let command = arguments.first else { throw ProofFailure.invalidInput }
            let options = try AccountOptions(arguments: Array(arguments.dropFirst()))
            switch command {
            case "list":
                guard options.remaining.isEmpty, options.account == nil, options.provider == nil else {
                    throw ProofFailure.invalidInput
                }
                try self.writeJSON(AccountCatalog.production().snapshot())
            case "add":
                guard options.remaining.isEmpty, options.account == nil else { throw ProofFailure.invalidInput }
                let registration = try ProviderRegistry.production.registration(options.provider ?? .mobileVikings)
                try self.writeJSON(AccountCatalog.production().reserve(
                    provider: registration.id, label: registration.displayName,
                ))
            case "select":
                guard options.account == nil, options.provider == nil,
                      options.remaining.count == 1 || (options.remaining.count == 3
                          && options.remaining[1] == "--if-selected") else { throw ProofFailure.invalidInput }
                let key = try AccountKey(selector: options.remaining[0])
                _ = try ProviderRegistry.production.registration(key.provider)
                let expected = try options.remaining.count == 3 ? AccountKey(selector: options.remaining[2]) : nil
                let catalog = try AccountCatalog.production()
                try catalog.select(key, replacing: expected)
                try self.writeJSON(catalog.snapshot())
            default: throw ProofFailure.invalidInput
            }
        } catch {
            self.writeJSON(CommandFailure(error: "account-command-failed"))
            exit(2)
        }
    }
}

extension VikingBarCLI {
    static func fixtureAccounts(arguments: [String]) async {
        do {
            guard arguments.isEmpty || arguments.count == 2 || arguments.count == 4 else {
                throw ProofFailure.invalidInput
            }
            var key = FixtureAccounts.home
            var service: String?
            var index = 0
            while index < arguments.count {
                switch arguments[index] {
                case "--account": key = try AccountKey(selector: arguments[index + 1])
                case "--service": service = arguments[index + 1]
                default: throw ProofFailure.invalidInput
                }
                index += 2
            }
            guard FixtureAccounts.catalog.accounts.contains(where: { $0.key == key }) else {
                throw LiveFailure.invalidSelection
            }
            let registry = FixtureAccounts.registry(at: Date(timeIntervalSince1970: 1_788_768_000))
            let registration = try registry.registration(key.provider)
            let session = try registration.makeSession(AccountStorage(
                root: URL(fileURLWithPath: "/unused-fixture"),
                key: key,
            ))
            let options = try LiveOptions(arguments: service.map { ["--service", $0] } ?? [])
            do {
                _ = try await self.loadLive(options: options, active: session)
            } catch {
                guard await session.state().failure != nil else { throw error }
            }
            await self.writeJSON(LiveReport(state: session.state()))
        } catch {
            self.writeJSON(CommandFailure(error: "fixture-account-failed"))
            exit(2)
        }
    }
}
