import AppKit

/// Standard responder-chain menus, created only when Settings is opened.
@MainActor
enum SettingsMenus {
    static func make(target: AnyObject, settings: Selector, quit: Selector) -> NSMenu {
        let root = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            root.addItem(item)
            return submenu
        }
        func add(_ title: String, _ selector: Selector, _ key: String, to menu: NSMenu, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
        let app = menu("Tweaks")
        add("About Tweaks", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", to: app, target: NSApp)
        app.addItem(.separator())
        add("Settings…", settings, ",", to: app, target: target)
        app.addItem(.separator())
        add("Hide Tweaks", #selector(NSApplication.hide(_:)), "h", to: app, target: NSApp)
        add("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", to: app, target: NSApp)
        app.addItem(.separator())
        add("Quit Tweaks", quit, "q", to: app, target: target)

        let edit = menu("Edit")
        add("Undo", NSSelectorFromString("undo:"), "z", to: edit)
        add("Redo", NSSelectorFromString("redo:"), "Z", to: edit)
        edit.addItem(.separator())
        add("Cut", #selector(NSText.cut(_:)), "x", to: edit)
        add("Copy", #selector(NSText.copy(_:)), "c", to: edit)
        add("Paste", #selector(NSText.paste(_:)), "v", to: edit)
        add("Select All", #selector(NSText.selectAll(_:)), "a", to: edit)

        let windows = menu("Window")
        add("Close", #selector(NSWindow.performClose(_:)), "w", to: windows)
        add("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", to: windows)
        add("Zoom", #selector(NSWindow.performZoom(_:)), "", to: windows)
        NSApp.windowsMenu = windows
        return root
    }
}
