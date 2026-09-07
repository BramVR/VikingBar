import AppKit
import SwiftUI
import VikingBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let session: AppSession
    private let options: AppLaunchOptions
    private var terminationPending = false
    private var terminationReplySent = false

    init(options: AppLaunchOptions, preferences: MenuBarPreferences) {
        self.session = AppSession(
            options: options.shared, preferences: preferences,
            clientFactory: {
                try SessionProcessClient(executableURL: Self.bundledURL("MacOS/vikingbar"))
            },
            connectorFactory: {
                try AccountConnector(
                    cliURL: Self.bundledURL("MacOS/vikingbar"),
                    helperURL: Self.bundledURL("Resources/connect-account.py"),
                )
            },
        )
        self.options = options
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
        self.popover.contentSize = NSSize(width: 360, height: self.session.isFixtureLaunch ? 570 : 760)
        self.popover.contentViewController = NSHostingController(rootView: PopoverView(
            session: self.session,
            connect: self.connect,
        ))
        self.session.start()
    }

    private static func bundledURL(_ path: String) throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw LiveBridgeFailure.unavailable }
        return bundle.appending(path: "Contents/" + path)
    }

    private func connect() {
        if let reference = self.options.credentialReference {
            self.connect(reference: reference)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose the approved 1Password credential reference"
        panel.message = "Select the credential reference JSON file for your Mobile Vikings account."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            self?.connect(reference: url)
        }
    }

    private func connect(reference: URL) {
        self.session.connect(
            reference: reference,
            resultURL: self.options.proofDirectory?.appending(path: "connect-result.json"),
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !self.terminationPending else { return .terminateLater }
        self.terminationPending = true
        Task {
            await self.session.stop()
            self.completeTermination(sender)
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.completeTermination(sender)
        }
        return .terminateLater
    }

    private func completeTermination(_ application: NSApplication) {
        guard !self.terminationReplySent else { return }
        self.terminationReplySent = true
        application.reply(toApplicationShouldTerminate: true)
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
                print("Live options: --credential-reference ABSOLUTE_PATH --proof-directory ABSOLUTE_PATH")
                return
            }
            let application = NSApplication.shared
            let settingsFile = options.fixture == nil
                ? URL.applicationSupportDirectory.appending(path: "VikingBar/menu-bar-preferences.json")
                : appOptions.settingsFile
            let delegate = AppDelegate(options: appOptions, preferences: MenuBarPreferences(fileURL: settingsFile))
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        } catch {
            FileHandle.standardError.write(Data("VikingBar: \(error)\n".utf8))
            exit(2)
        }
    }
}
