import AppKit
import Testing
@testable import VikingBarApp

@MainActor
struct AppEditingMenuTests {
    @Test func `command paste reaches the current responder without reading the clipboard`() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        let previous = application.nextResponder
        let responder = PasteResponder()
        application.nextResponder = responder
        defer {
            application.nextResponder = previous
            application.mainMenu = previousMenu
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9,
        ))
        let menu = AppEditingMenu.make()
        application.mainMenu = menu
        #expect(menu.performKeyEquivalent(with: event))
        #expect(responder.pasteCount == 1)
    }
}

@MainActor
private final class PasteResponder: NSResponder {
    var pasteCount = 0

    @objc func paste(_: Any?) {
        self.pasteCount += 1
    }
}
