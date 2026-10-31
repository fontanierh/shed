// The iPhone app: the session list, pushing into a session, the connect screen and Live Activities.
#if os(iOS)
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var store: SessionStore
    @State private var path: [String] = []
    @State private var showNewSession = false
    @State private var showSettings = false
    @State private var lightbox = Lightbox()
    @State private var activities = LiveActivities()

    public init(store: SessionStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.token.isEmpty {
                PhoneConnect(store: store)
            } else {
                NavigationStack(path: $path) {
                    SessionSidebar(store: store) { showNewSession = true }
                        .toolbar(.hidden, for: .navigationBar)
                        .navigationDestination(for: String.self) { id in
                            if let session = store.sessions[id] {
                                SessionView(store: store, session: session)
                            } else {
                                Unreachable(store: store, showSettings: $showSettings)
                            }
                        }
                        .safeAreaInset(edge: .top, spacing: 0) {
                            ConnectionBar(store: store, showSettings: $showSettings)
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.amber)
        .environment(\.lightbox, lightbox)
        .overlay { LightboxView(lightbox: lightbox) }
        .sheet(isPresented: $showNewSession) { NewSessionSheet(store: store) }
        .sheet(isPresented: $showSettings) { NavigationStack { ConnectionSettings(store: store) } }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        // The list selects; the stack follows. Going back deselects.
        .onChange(of: store.selectedId) { _, id in
            let wanted = id.map { [$0] } ?? []
            if path != wanted { path = wanted }
        }
        .onChange(of: path) { _, now in
            if now.last != store.selectedId { store.select(now.last) }
        }
        .onChange(of: store.sessions, initial: true) { _, sessions in activities.sync(sessions, store: store) }
        .onOpenURL { url in open(url) }
        .task { if !store.token.isEmpty { store.start() } }
    }

    /// `shed://session/<id>`, optionally `?stop=1`: from the Live Activity and notifications.
    private func open(_ url: URL) {
        guard url.scheme == "shed", url.host == "session", let id = url.pathComponents.dropFirst().first else { return }
        store.select(id)
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "stop" }) == true {
            Task { try? await Task.sleep(for: .milliseconds(400)); store.abort() }
        }
    }
}

/// First run: where the bridge is and its token. Shed reaches the Mac over Tailscale.
struct PhoneConnect: View {
    @Bindable var store: SessionStore
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 8) {
                    Sprout(size: 28)
                    Text("Shed").font(.system(size: 30, weight: .medium, design: .serif)).foregroundStyle(Palette.moon)
                    Spacer()
                }
                .padding(.top, 8)

                ZStack {
                    Sprig().fill(Palette.ice.opacity(0.16)).frame(width: 120, height: 170).offset(x: 70, y: -6)
                    Spirit(color: Palette.ice, size: 120, working: true)
                }
                .frame(height: 190)
                .padding(.top, 12)

                VStack(spacing: 8) {
                    Text("Connect to your Mac").font(.system(size: 30, weight: .medium, design: .serif)).foregroundStyle(Palette.moon)
                    Text("Shed talks to the bridge on your Mac over Tailscale.")
                        .font(.system(size: 16)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 0) {
                    step(1, "terminal", "Install on your Mac", "Run setup/install.sh in the Shed folder.")
                    Divider().overlay(Palette.border)
                    step(2, "point.3.connected.trianglepath.dotted", "Open Tailscale", "Sign in on this iPhone and on the Mac.")
                    Divider().overlay(Palette.border)
                    step(3, "key", "Paste the bridge token", "From ~/.agent-remote/config.json on the Mac.")
                }
                .card(radius: 18, fill: Palette.surface.opacity(0.8))

                VStack(alignment: .leading, spacing: 10) {
                    field("Bridge address", text: $url, prompt: "wss://my-mac.tailnet.ts.net:7878/ws")
                    field("Token", text: $token, prompt: "Paste the token", secure: true)
                }

                Button {
                    store.bridgeURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.start()
                } label: {
                    Label("Connect", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(AmberButton())
                .disabled(url.isEmpty || token.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { ZStack { Velvet(); Fireflies(count: 7, warm: 0.45, seed: 5) }.ignoresSafeArea() }
        .onAppear { url = store.bridgeURL }
    }

    private func step(_ number: Int, _ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ice)
                .frame(width: 26, height: 26)
                .background(Circle().strokeBorder(Palette.ice.opacity(0.5)))
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.moon)
                .frame(width: 34, height: 34).card(radius: 9, fill: Palette.raised)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.moon)
                Text(detail).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Group {
                if secure { SecureField("", text: text, prompt: Text(prompt)) } else { TextField("", text: text, prompt: Text(prompt)) }
            }
            .font(.mono(14))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14).frame(height: 48)
            .card(radius: 14, fill: Palette.sunken)
        }
    }
}
#endif
