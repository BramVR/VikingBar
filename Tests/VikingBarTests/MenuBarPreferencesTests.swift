import Foundation
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct MenuBarPreferencesTests {
    @Test func `memory settings perform no IO and start off`() {
        let fileIO = RecordingPreferenceIO()
        let store = MenuBarPreferences(fileURL: nil, fileIO: fileIO)
        #expect(!store.showRemainingGB)
        store.setShowRemainingGB(true)
        #expect(store.showRemainingGB)
        store.setShowRemainingGB(false)
        #expect(!store.showRemainingGB)
        #expect(fileIO.reads.isEmpty)
        #expect(fileIO.writes.isEmpty)
    }

    @Test func `missing key defaults off and malformed data reports failure`() {
        let fileIO = RecordingPreferenceIO()
        let url = URL(fileURLWithPath: "/synthetic-home/settings.json")
        fileIO.data = Data("{}".utf8)
        let empty = MenuBarPreferences(fileURL: url, fileIO: fileIO)
        #expect(!empty.showRemainingGB)
        #expect(empty.errorMessage == nil)
        fileIO.data = Data("invalid".utf8)
        let malformed = MenuBarPreferences(fileURL: url, fileIO: fileIO)
        #expect(!malformed.showRemainingGB)
        #expect(malformed.errorMessage?.contains("Could not load") == true)
        #expect(fileIO.reads == [url, url])
        #expect(fileIO.writes.isEmpty)
    }

    @MainActor @Test func `read and write failures stay visible while status changes`() throws {
        let fileIO = RecordingPreferenceIO()
        fileIO.failure = true
        let url = URL(fileURLWithPath: "/synthetic-home/settings.json")
        let preferences = MenuBarPreferences(fileURL: url, fileIO: fileIO)
        let session = try AppSession(
            options: LaunchOptions(arguments: ["--fixture", "finite"]),
            preferences: preferences,
        )
        #expect(session.settingsError?.contains("Could not load") == true)
        session.showRemainingGB = true
        #expect(session.status.title == "36 GB")
        #expect(session.settingsError?.contains("could not be saved") == true)
        fileIO.failure = false
        session.showRemainingGB = false
        #expect(session.settingsError == nil)
        #expect(fileIO.reads == [url])
        #expect(fileIO.writes == [url, url])
    }

    @MainActor @Test func `isolated file retains on and off across session recreation`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "VikingBarPreferences-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "synthetic-home/Application Support/VikingBar/settings.json")
        let fileIO = RecordingPreferenceIO(containedRoot: root)
        let options = try LaunchOptions(arguments: ["--fixture", "finite"])
        let first = AppSession(options: options, preferences: MenuBarPreferences(fileURL: url, fileIO: fileIO))
        #expect(!first.showRemainingGB)
        #expect(first.settingsError == nil)
        first.showRemainingGB = true
        #expect(first.settingsError == nil)
        let second = AppSession(options: options, preferences: MenuBarPreferences(fileURL: url, fileIO: fileIO))
        #expect(second.showRemainingGB)
        #expect(second.status.title == "36 GB")
        second.showRemainingGB = false
        let third = AppSession(options: options, preferences: MenuBarPreferences(fileURL: url, fileIO: fileIO))
        #expect(!third.showRemainingGB)
        #expect(third.status.title.isEmpty)
        #expect(fileIO.reads == [url, url, url])
        #expect(fileIO.writes == [url, url])
    }

    @Test func `app settings path requires explicit fixture without changing CLI contract`() throws {
        let parsed = try AppLaunchOptions(arguments: ["--settings-file", "/tmp/isolated.json", "--fixture", "finite"])
        #expect(parsed.settingsFile?.path == "/tmp/isolated.json")
        #expect(try AppLaunchOptions(arguments: ["--fixture", "finite"]).settingsFile == nil)
        for arguments in [
            ["--settings-file", "/tmp/isolated.json"],
            ["--fixture", "finite", "--settings-file", "relative.json"],
            ["--fixture", "finite", "--settings-file"],
            ["--fixture", "finite", "--settings-file", "/tmp/a", "--settings-file", "/tmp/b"],
        ] {
            #expect(throws: ArgumentError.self) { try AppLaunchOptions(arguments: arguments) }
        }
        #expect(throws: ArgumentError.self) {
            try LaunchOptions(arguments: ["--fixture", "finite", "--settings-file", "/tmp/a"])
        }
    }
}

private final class RecordingPreferenceIO: MenuBarPreferenceIO {
    var reads: [URL] = []
    var writes: [URL] = []
    var data: Data?
    var failure = false
    let containedRoot: URL?

    init(containedRoot: URL? = nil) {
        self.containedRoot = containedRoot
    }

    func read(from url: URL) throws -> Data? {
        self.reads.append(url)
        if self.failure {
            throw CocoaError(.fileReadNoPermission)
        }
        if let root = self.containedRoot {
            guard url.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            return try FileMenuBarPreferenceIO().read(from: url)
        }
        return self.data
    }

    func write(_ data: Data, to url: URL) throws {
        self.writes.append(url)
        if self.failure {
            throw CocoaError(.fileWriteNoPermission)
        }
        if let root = self.containedRoot {
            guard url.path.hasPrefix(root.path + "/") else { throw CocoaError(.fileWriteNoPermission) }
            try FileMenuBarPreferenceIO().write(data, to: url)
        } else {
            self.data = data
        }
    }
}

extension MenuBarPreferencesTests {
    @Test func `old settings preserve existing value and default new keys`() {
        let fileIO = RecordingPreferenceIO()
        fileIO.data = Data("{\"showRemainingGB\":true}".utf8)
        let preferences = MenuBarPreferences(fileURL: URL(fileURLWithPath: "/synthetic/settings"), fileIO: fileIO)
        #expect(preferences.showRemainingGB)
        #expect(preferences.dataDisplayMode == .remaining)
        #expect(preferences.refreshInterval == .fiveMinutes)
        #expect(preferences.errorMessage == nil)
    }

    @Test func `new settings persist together and write failure keeps session choice`() {
        let fileIO = RecordingPreferenceIO()
        let url = URL(fileURLWithPath: "/synthetic/settings")
        let preferences = MenuBarPreferences(fileURL: url, fileIO: fileIO)
        preferences.setDataDisplayMode(.used)
        preferences.setRefreshInterval(.oneHour)
        preferences.setShowRemainingGB(true)
        let restored = MenuBarPreferences(fileURL: url, fileIO: fileIO)
        #expect(restored.dataDisplayMode == .used)
        #expect(restored.refreshInterval == .oneHour)
        #expect(restored.showRemainingGB)
        fileIO.failure = true
        preferences.setRefreshInterval(.fifteenMinutes)
        #expect(preferences.refreshInterval == .fifteenMinutes)
        #expect(preferences.errorMessage?.contains("could not be saved") == true)
        fileIO.failure = false
        #expect(MenuBarPreferences(fileURL: url, fileIO: fileIO).refreshInterval == .oneHour)
    }

    @Test func `corrupt new key restores all defaults with visible error`() {
        let fileIO = RecordingPreferenceIO()
        fileIO.data = Data("{\"showRemainingGB\":true,\"refreshInterval\":12}".utf8)
        let preferences = MenuBarPreferences(fileURL: URL(fileURLWithPath: "/synthetic/settings"), fileIO: fileIO)
        #expect(!preferences.showRemainingGB)
        #expect(preferences.refreshInterval == .fiveMinutes)
        #expect(preferences.dataDisplayMode == .remaining)
        #expect(preferences.errorMessage != nil)
    }
}
