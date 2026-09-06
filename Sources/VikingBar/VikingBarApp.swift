import AppKit
import Observation
import SwiftUI
import VikingBarCore

@MainActor
@Observable
final class FixtureSession {
    var fixture: FixtureState?
    var unit: DataUnit
    let timeZone: TimeZone
    let referenceDate = Date()

    init(options: LaunchOptions) {
        self.fixture = options.fixture
        self.unit = options.unit
        self.timeZone = options.timeZone
    }

    var menu: MenuPresentation {
        let snapshot = self.fixture?.snapshot(referenceDate: self.referenceDate) ?? .notConnected
        return MenuPresentation(snapshot: snapshot, unit: self.unit, timeZone: self.timeZone)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let session: FixtureSession

    init(options: LaunchOptions) {
        self.session = FixtureSession(options: options)
        super.init()
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
        self.popover.contentSize = NSSize(width: 360, height: 520)
        self.popover.contentViewController = NSHostingController(rootView: DataCard(
            session: self.session,
            onChange: { [weak self] in self?.updateStatus() },
        ))
    }

    private func updateStatus() {
        let menu = self.session.menu
        self.statusItem?.button?.title = menu.statusTitle
        self.statusItem?.button?.toolTip = menu.accessibilityLabel
        self.statusItem?.button?.setAccessibilityLabel(menu.accessibilityLabel)
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
            let options = try LaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.showHelp {
                print(LaunchOptions.usage.replacingOccurrences(of: "vikingbar", with: "VikingBar"))
                return
            }
            let application = NSApplication.shared
            let delegate = AppDelegate(options: options)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            FileHandle.standardError.write(Data("VikingBar: \(error)\n".utf8))
            exit(2)
        }
    }
}
