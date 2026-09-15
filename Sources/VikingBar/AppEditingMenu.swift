import AppKit

@MainActor
enum AppEditingMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let application = NSMenu(title: "VikingBar")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        application.addItem(
            withTitle: "Quit VikingBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )
        menu.addItem(applicationItem)
        let edit = NSMenu(title: "Edit")
        let item = NSMenuItem()
        item.submenu = edit
        menu.addItem(item)
        // Nil targets route editing to the focused field, including secure field editors.
        for (title, action, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        return menu
    }
}
