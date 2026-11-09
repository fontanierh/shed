// The iPhone app: the session list, pushing into a session, the connect screen and Live Activities.
#if os(iOS)
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var store: SessionStore
    /// The session on screen, following the store's selection inside one animation.
    @State private var shown: String?
    @State private var showNewSession = false
    @State private var newSession = NewSessionDraft()
    @State private var showSettings = false
    @State private var lightbox = Lightbox()
    @State private var activities = LiveActivities()

    public init(store: SessionStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.environments.isEmpty {
                PhoneConnect(store: store)
            } else {
                // One screen, not a stack of pages: opening a session, the list's rows dissolve and the conversation
                // condenses in their place while the beam travels underneath to its new pose. Both composers sit at
                // the bottom, so the one under your thumb stays put. The list stays alive below, keeping its scroll.
                ZStack {
                    NavigationStack {
                        SessionSidebar(store: store, newSession: { newSession = NewSessionDraft(); showNewSession = true },
                                       openSettings: { showSettings = true },
                                       start: { message, folder in
                                           newSession = NewSessionDraft(message: message, folder: folder)
                                           showNewSession = true
                                       })
                            .toolbar(.hidden, for: .navigationBar)
                            .containerBackground(.clear, for: .navigation)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                ConnectionBar(store: store, showSettings: $showSettings)
                            }
                    }
                    .opacity(shown == nil ? 1 : 0)
                    .scaleEffect(shown == nil ? 1 : 0.97)
                    .blur(radius: shown == nil ? 0 : 6)
                    .allowsHitTesting(shown == nil)
                    .accessibilityHidden(shown != nil)

                    if let id = shown {
                        NavigationStack {
                            Group {
                                if let session = store.sessions[id] {
                                    SessionView(store: store, session: session)
                                } else {
                                    Unreachable(store: store, showSettings: $showSettings)
                                }
                            }
                            .containerBackground(.clear, for: .navigation)
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: back) { Image(systemName: "chevron.left") }
                                        .accessibilityLabel("Sessions")
                                }
                            }
                        }
                        // Another session (a subagent, say) replaces this one the same way.
                        .id(id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 1.03)),
                            removal: .opacity.combined(with: .scale(scale: 1.03))))
                        // Back: a swipe in from the left edge, as with a pushed page.
                        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { drag in
                            if drag.startLocation.x < 28, drag.translation.width > 70,
                               abs(drag.translation.height) < drag.translation.width { back() }
                        })
                    }
                }
                .environment(\.beamStage, true)
                .background { BeamStage(pose: shown == nil ? .list : .conversation, poses: [.list, .conversation]).ignoresSafeArea() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .environment(\.lightbox, lightbox)
        .overlay { LightboxView(lightbox: lightbox) }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet(store: store, initialMessage: newSession.message, initialFolder: newSession.folder)
        }
        .sheet(isPresented: $showSettings) { NavigationStack { EnvironmentSettings(store: store) } }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        // The list selects; the screen follows, morphing in step with the beam's move.
        .onChange(of: store.selectedId, initial: true) { _, id in
            // Nil while going back is the end of `back()`, already shown.
            guard id != shown, !(id == nil && shown == nil) else { return }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { shown = id }
        }
        .onChange(of: store.sessions, initial: true) { _, sessions in activities.sync(sessions, store: store) }
        .onOpenURL { url in open(url) }
        .task { if !store.environments.isEmpty { store.start() } }
    }

    /// Back to the list: the conversation dissolves first, then the session is let go. Deselecting clears the
    /// transcript, which would otherwise flash its loading line while it fades.
    private func back() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { shown = nil } completion: {
            if shown == nil { store.select(nil) }
        }
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
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 8) {
                    ShedMark(size: 28)
                    Text("Shed").font(.system(size: 30, weight: .semibold)).foregroundStyle(Palette.moon)
                    Spacer()
                }
                .padding(.top, 8)

                ShedMark(size: 96)
                    .frame(width: 168, height: 168)
                    .card(radius: 44, fill: Palette.surface.opacity(0.55))
                    .shadow(color: Palette.accent.opacity(0.25), radius: 30)
                    .padding(.top, 12)

                VStack(spacing: 8) {
                    Text("Connect to your Mac").font(.system(size: 28, weight: .semibold)).foregroundStyle(Palette.moon)
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
                    field("Name", text: $name, prompt: url.isEmpty ? "My Mac" : BridgeEnvironment.name(for: url))
                    field("Bridge address", text: $url, prompt: "wss://my-mac.tailnet.ts.net:7878/ws")
                    field("Token", text: $token, prompt: "Paste the token", secure: true)
                }

                Button {
                    store.save(BridgeEnvironment(name: name, url: url, token: token))
                    store.start()
                } label: {
                    Label("Connect", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButton())
                .disabled(url.isEmpty || token.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { Backdrop(beam: 1, anchor: UnitPoint(x: 0.5, y: 0.3)) }
    }

    private func step(_ number: Int, _ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent.opacity(0.12)))
                .background(Circle().strokeBorder(Palette.accent.opacity(0.5)))
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
            .card(radius: 14, fill: Palette.surface.opacity(0.75))
        }
    }
}
#endif
