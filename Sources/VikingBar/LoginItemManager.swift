import Foundation
import ServiceManagement
import VikingBarCore

enum LoginItemStatus: String, Codable, Sendable {
    case notRegistered, enabled, requiresApproval, unavailable

    var title: String {
        switch self {
        case .notRegistered: "Off"
        case .enabled: "On"
        case .requiresApproval: "Approval required"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor
protocol LoginItemManaging {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) async throws
    func openSettings()
}

struct LoginItemUnavailable: Error {}

@MainActor
struct DisabledLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus {
        .unavailable
    }

    func setEnabled(_: Bool) async throws {
        throw LoginItemUnavailable()
    }

    func openSettings() {}
}

@MainActor
struct SystemLoginItemManager: LoginItemManaging {
    private var isApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier == "be.bram.vikingbar"
    }

    var status: LoginItemStatus {
        guard self.isApplicationBundle else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async throws {
        guard self.isApplicationBundle else { throw LoginItemUnavailable() }
        if enabled {
            guard self.status != .enabled, self.status != .requiresApproval else { return }
            try SMAppService.mainApp.register()
        } else {
            guard self.status != .notRegistered else { return }
            try await SMAppService.mainApp.unregister()
        }
    }

    func openSettings() {
        guard self.isApplicationBundle else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum LoginItemCommand: String {
    case status, disable

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--login-item") else { return nil }
        guard arguments.count == 2, arguments[0] == "--login-item", let command = Self(rawValue: arguments[1]) else {
            throw ArgumentError.invalid("Use --login-item status or --login-item disable on its own.")
        }
        return command
    }

    @MainActor
    func run(manager: any LoginItemManaging) async -> LoginItemReport {
        var failure: String?
        if self == .disable {
            do { try await manager.setEnabled(false) } catch { failure = "login-item-disable-failed" }
        }
        let status = manager.status
        let passed = self == .status || (status == .notRegistered && failure == nil)
        return LoginItemReport(
            status: status, passed: passed, error: passed ? nil : failure ?? "login-item-still-registered",
        )
    }
}

struct LoginItemReport: Encodable {
    let schemaVersion = 1
    let status: LoginItemStatus
    let passed: Bool
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case status, passed, error
    }
}
