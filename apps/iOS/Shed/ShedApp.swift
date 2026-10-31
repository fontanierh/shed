// The iPhone app: the shared session store and the phone layout.
import ShedKit
import SwiftUI

@main
struct ShedApp: App {
    @State private var store = SessionStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRootView(store: store)
        }
        .onChange(of: phase) { _, now in
            if now == .active { store.resumed() }
        }
    }
}
