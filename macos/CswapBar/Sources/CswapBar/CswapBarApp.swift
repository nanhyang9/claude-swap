import AppKit
import SwiftUI

@main
struct CswapBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        // `.window` style: clicking the menu bar item opens a panel (not a
        // plain menu) that shows every account's usage.
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            if let text = store.menuBarText {
                Text("\(Image(systemName: "chart.bar.fill")) \(text)")
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this also keeps `swift run`
        // (no bundle) out of the Dock.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
