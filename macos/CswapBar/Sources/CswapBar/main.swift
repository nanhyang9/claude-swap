import AppKit

// Plain AppKit entry point. A SwiftUI `App` must declare at least one scene,
// and the empty Settings scene that took opened a blank "Settings" window.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
// The bundled app also sets LSUIElement; this keeps `swift run` out of the Dock.
app.setActivationPolicy(.accessory)
app.mainMenu = AppDelegate.makeMainMenu()
app.run()
