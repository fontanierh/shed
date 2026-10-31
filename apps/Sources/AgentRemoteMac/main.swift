// macOS entry point. Built as a plain SwiftPM executable, so it has to make itself a regular foreground app.
import AgentRemoteKit
import AppKit
import SwiftUI

struct AgentRemoteMacApp: App {
    @State private var store = SessionStore()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Shed") {
            RootView(store: store)
                .frame(minWidth: 820, minHeight: 520)
        }
        // No title bar: the session header is the top edge of the window.
        .windowStyle(.hiddenTitleBar)
    }
}

AgentRemoteMacApp.main()
