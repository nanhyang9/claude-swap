import AppKit
import Combine
import SwiftUI

@main
struct CswapBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item and its panel are AppKit (see AppDelegate); SwiftUI
    // needs a scene, and an empty Settings scene opens no window.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

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
        // The bundled app sets LSUIElement; this also keeps `swift run`
        // (no bundle) out of the Dock.
        NSApplication.shared.setActivationPolicy(.accessory)

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

    /// The menu bar shows the active account's 5h · 7d percentages.
    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "Claude Swap")
        image?.isTemplate = true
        button.image = image
        if let text = store.menuBarText {
            button.title = " " + text
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
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
