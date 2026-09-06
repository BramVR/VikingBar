import AppKit
import Observation
import SwiftUI
import VikingBarCore

@MainActor
@Observable
final class FixtureSession {
    var fixture: FixtureState? {
        didSet { self.onPresentationChange?() }
    }

    var unit: DataUnit {
        didSet { self.onPresentationChange?() }
    }

    var showRemainingGB: Bool {
        didSet {
            self.preferences.setShowRemainingGB(self.showRemainingGB)
            self.settingsError = self.preferences.errorMessage
            self.onPresentationChange?()
        }
    }

    private(set) var settingsError: String?
    let timeZone: TimeZone
    let referenceDate: Date
    @ObservationIgnored var onPresentationChange: (() -> Void)?
    @ObservationIgnored private let preferences: MenuBarPreferences

    init(options: LaunchOptions, preferences: MenuBarPreferences, referenceDate: Date = Date()) {
        self.fixture = options.fixture
        self.unit = options.unit
        self.timeZone = options.timeZone
        self.referenceDate = referenceDate
        self.preferences = preferences
        self.showRemainingGB = preferences.showRemainingGB
        self.settingsError = preferences.errorMessage
    }

    var snapshot: UsageSnapshot {
        self.fixture?.snapshot(referenceDate: self.referenceDate) ?? .notConnected
    }

    var menu: MenuPresentation {
        MenuPresentation(snapshot: self.snapshot, unit: self.unit, timeZone: self.timeZone)
    }

    var status: StatusPresentation {
        StatusPresentation(
            snapshot: self.snapshot,
            showRemainingGB: self.showRemainingGB,
            unit: self.unit,
            timeZone: self.timeZone,
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let session: FixtureSession

    init(options: LaunchOptions, preferences: MenuBarPreferences) {
        self.session = FixtureSession(options: options, preferences: preferences)
        super.init()
        self.session.onPresentationChange = { [weak self] in self?.updateStatus() }
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        item.button?.target = self
        item.button?.action = #selector(self.togglePopover)
        item.button?.setAccessibilityIdentifier("vikingbar.status")
        self.updateStatus()
        self.popover.behavior = .transient
        self.popover.contentSize = NSSize(width: 360, height: 570)
        self.popover.contentViewController = NSHostingController(rootView: PopoverView(session: self.session))
    }

    private func updateStatus() {
        let status = self.session.status
        guard let button = self.statusItem?.button else { return }
        button.image = HelmetRenderer.image(for: status.treatment)
        button.title = status.title
        button.imagePosition = status.title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = status.accessibilityLabel
        button.setAccessibilityLabel(status.accessibilityLabel)
    }

    @objc private func togglePopover() {
        guard let button = self.statusItem?.button else { return }
        if self.popover.isShown {
            self.popover.performClose(nil)
        } else {
            NSApplication.shared.activate()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct VikingBarApp {
    @MainActor
    static func main() {
        do {
            let appOptions = try AppLaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let options = appOptions.shared
            if options.showHelp {
                print(LaunchOptions.usage.replacingOccurrences(of: "vikingbar", with: "VikingBar"))
                print("App fixture option: --settings-file ABSOLUTE_PATH saves the menu bar setting.")
                return
            }
            let application = NSApplication.shared
            let settingsFile = options.fixture == nil
                ? URL.applicationSupportDirectory.appending(path: "VikingBar/menu-bar-preferences.json")
                : appOptions.settingsFile
            let delegate = AppDelegate(options: options, preferences: MenuBarPreferences(fileURL: settingsFile))
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            FileHandle.standardError.write(Data("VikingBar: \(error)\n".utf8))
            exit(2)
        }
    }
}
