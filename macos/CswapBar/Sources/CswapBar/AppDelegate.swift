import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the panel.
///
/// An `NSPopover` rather than SwiftUI's `MenuBarExtra` window: the popover
/// stays attached under the menu bar item when its content grows or shrinks
/// (the MenuBarExtra window drifted down and left a see-through strip), and
/// it closes when another app is clicked instead of turning translucent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var storeObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
        }
        statusItem = item

        let hosting = NSHostingController(rootView: ContentView().environmentObject(store))
        // Let the popover follow the SwiftUI content's size as it changes.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true

        updateStatusButton()
        storeObserver = store.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new values land.
            DispatchQueue.main.async { self?.updateStatusButton() }
        }
    }

    /// The menu bar shows only the active account's 5h · 7d percentages
    /// (no icon), or "Claude" until the first reading arrives.
    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        button.image = nil
        button.title = store.menuBarText ?? "Claude"
        button.toolTip = "Claude Swap"
    }

    /// Opening the app again (Finder, Spotlight) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover(nil) }
        return false
    }

    /// A menu bar app has no visible main menu, but text fields still need
    /// its Edit items for Cmd-C / Cmd-V / Cmd-A to work.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        return main
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem?.button else { return }
        store.popoverOpened()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
