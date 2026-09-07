import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

@MainActor
struct LoginItemTests {
    @Test func `actual status rechecks after external changes and rejected mutation`() async throws {
        let manager = FakeLoginItems()
        let model = try AppSession(options: LaunchOptions(arguments: ["--fixture", "finite"]),
                                   preferences: MenuBarPreferences(fileURL: nil), loginItems: manager)
        #expect(model.loginItemStatus == .notRegistered)
        manager.status = .enabled
        model.checkLoginItem()
        #expect(model.launchAtLogin)
        manager.fail = true
        await model.setLaunchAtLogin(false)
        #expect(model.loginItemStatus == .enabled)
        #expect(model.loginItemError != nil)
        manager.fail = false
        manager.registeredStatus = .requiresApproval
        await model.setLaunchAtLogin(true)
        #expect(model.loginItemStatus == .requiresApproval)
        #expect(model.loginItemError == nil)
        model.openLoginItems()
        #expect(manager.settingsOpened == 1)
        await model.setLaunchAtLogin(false)
        #expect(model.loginItemStatus == .notRegistered)
        #expect(!model.launchAtLogin)
    }

    @Test func `maintenance reports status without mutation and fails incomplete cleanup`() async throws {
        let manager = FakeLoginItems()
        manager.status = .unavailable
        let status = await LoginItemCommand.status.run(manager: manager)
        #expect(status.passed)
        #expect(manager.mutations.isEmpty)
        manager.status = .enabled
        manager.fail = true
        let failed = await LoginItemCommand.disable.run(manager: manager)
        #expect(!failed.passed)
        let encoded = try JSONEncoder().encode(failed)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "status", "passed", "error"])
        #expect(object["error"] as? String == "login-item-disable-failed")
        manager.fail = false
        #expect(await LoginItemCommand.disable.run(manager: manager).passed)
        #expect(manager.status == .notRegistered)
    }

    @Test func `login flags are app only isolated and exclusive`() throws {
        #expect(try LoginItemCommand.parse(["--login-item", "status"]) == .status)
        #expect(try LoginItemCommand.parse(["--login-item", "disable"]) == .disable)
        let invalidMaintenanceArguments = [
            ["--login-item"], ["--login-item", "enable"],
            ["--login-item", "status", "--fixture", "finite"],
            ["--help", "--login-item", "disable"],
        ]
        for arguments in invalidMaintenanceArguments {
            #expect(throws: ArgumentError.self) { try LoginItemCommand.parse(arguments) }
        }
        let allowed = try AppLaunchOptions(arguments: ["--fixture", "finite", "--settings-file", "/synthetic/settings",
                                                       "--allow-login-item"])
        #expect(allowed.allowLoginItem)
        let invalidLaunchArguments = [
            ["--allow-login-item"], ["--fixture", "finite", "--allow-login-item"],
            ["--help", "--allow-login-item"],
            ["--fixture", "finite", "--settings-file", "/synthetic/settings",
             "--allow-login-item", "--allow-login-item"],
        ]
        for arguments in invalidLaunchArguments {
            #expect(throws: ArgumentError.self) { try AppLaunchOptions(arguments: arguments) }
        }
        #expect(throws: ArgumentError.self) { try LaunchOptions(arguments: ["--allow-login-item"]) }
    }
}

@MainActor
private final class FakeLoginItems: LoginItemManaging {
    var status: LoginItemStatus = .notRegistered
    var registeredStatus: LoginItemStatus = .enabled
    var fail = false
    var mutations: [Bool] = []
    var settingsOpened = 0

    func setEnabled(_ enabled: Bool) async throws {
        self.mutations.append(enabled)
        if self.fail {
            throw LoginItemUnavailable()
        }
        self.status = enabled ? self.registeredStatus : .notRegistered
    }

    func openSettings() {
        self.settingsOpened += 1
    }
}
