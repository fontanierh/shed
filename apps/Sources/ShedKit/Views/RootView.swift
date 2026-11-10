// Top-level layout: session tree on the left, the selected session on the right.
import SwiftUI

public struct RootView: View {
    @Bindable var store: SessionStore
    /// New Session, open with what the home page's composer starts a session with.
    @State private var newSession: NewSessionDraft?
    @State private var showSettings = false
    @State private var lightbox = Lightbox()

    public init(store: SessionStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, newSession: { newSession = NewSessionDraft() }, openSettings: { showSettings = true })
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if let session = store.selected {
                    SessionView(store: store, session: session)
                } else if case .disconnected = store.connection {
                    Unreachable(store: store, showSettings: $showSettings)
                } else {
                    HomeView(store: store) { message, folder in
                        newSession = NewSessionDraft(message: message, folder: folder)
                    }
                }
            }
            .transition(.opacity)
        }
        #if os(macOS)
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionBar(store: store, showSettings: $showSettings)
        }
        .environment(\.lightbox, lightbox)
        .overlay { LightboxView(lightbox: lightbox) }
        .sheet(item: $newSession) { draft in
            NewSessionSheet(store: store, initialMessage: draft.message, initialFolder: draft.folder)
        }
        .sheet(isPresented: $showSettings) { EnvironmentSettings(store: store) }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .task { store.start() }
    }
}

/// What New Session opens with: a first message and a folder, from the home page.
struct NewSessionDraft: Identifiable {
    let id = UUID()
    var message = ""
    var folder: String? = nil
}

/// The bridge can't be reached: a computer with a red dot, and the way back.
struct Unreachable: View {
    let store: SessionStore
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: store.environments.count == 1 && store.environments[0].isLocal ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.moon.opacity(0.85))
                .frame(width: 88, height: 88)
                .card(radius: 26, fill: Palette.surface.opacity(0.7))
                .overlay(alignment: .topTrailing) {
                    LiveDot(state: .error, size: 10).offset(x: 4, y: -4)
                }
            Text(store.environments.isEmpty ? "No computers yet" : "Can\u{2019}t reach \(names)").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.moon)
            Text(store.environments.isEmpty ? "Add a computer running the bridge in Settings." : "Shed couldn\u{2019}t connect to \(store.environments.count == 1 ? "its bridge" : "their bridges").")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Settings…") { showSettings = true }.buttonStyle(QuietButton())
                Button { store.connect() } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(PrimaryButton())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Backdrop(beam: 0.7, anchor: UnitPoint(x: 0.55, y: 0.18)) }
    }

    private var names: String {
        ListFormatter.localizedString(byJoining: store.environments.map(\.name))
    }
}

/// The primary action: electric blue, lit from within.
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 36)
            .background(LinearGradient(colors: [Color.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center), in: Capsule())
            .background(LinearGradient(colors: [Palette.accent, Palette.accentDeep], startPoint: .top, endPoint: .bottom), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
            .glow(radius: configuration.isPressed ? 4 : 10, on: enabled)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A secondary action: a quiet glass capsule.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.moon)
            .padding(.horizontal, 16).frame(height: 36)
            .card(radius: 18, fill: configuration.isPressed ? Palette.raised : Palette.surface.opacity(0.85))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// One line per computer not connected, under the window or inside a session (for that session's computer only).
struct ConnectionBar: View {
    let store: SessionStore
    /// Opens the settings; without it the bar offers only Retry.
    var showSettings: Binding<Bool>? = nil
    /// Only this session's computer.
    var sessionId: String? = nil

    var body: some View {
        let shown = sessionId.flatMap { store.environment(of: $0) }.map { [$0] } ?? store.environments
        VStack(spacing: 0) {
            ForEach(shown) { env in
                Line(store: store, env: env, showSettings: showSettings)
            }
        }
    }
}

/// One computer's line, shown only once it has been down for a moment. iOS drops the socket whenever the app leaves
/// the screen, even for a second, and it's back within half a second of returning: a bar flashing in and out above the
/// transcript in that time pushed it down and let it snap back.
private struct Line: View {
    let store: SessionStore
    let env: BridgeEnvironment
    let showSettings: Binding<Bool>?
    @State private var shown = false

    private static let grace = Duration.seconds(2)

    var body: some View {
        let state = store.connection(of: env.id)
        Group {
            if shown {
                switch state {
                case .connected:
                    EmptyView()
                case .connecting:
                    bar(Text("Connecting to \(env.name)\u{2026}"), dot: .attention)
                case .disconnected(let reason):
                    bar(Text("Can\u{2019}t reach \(env.name)") + Text(reason.map { ": \($0)" } ?? ""), dot: .error)
                }
            }
        }
        .task(id: state == .connected) {
            guard state != .connected else {
                shown = false
                return
            }
            try? await Task.sleep(for: Self.grace)
            if !Task.isCancelled { shown = true }
        }
    }

    private func bar(_ text: Text, dot: LiveDot.Kind) -> some View {
        HStack(spacing: 8) {
            LiveDot(state: dot)
            text.font(.callout).foregroundStyle(Palette.moon).lineLimit(1)
            Spacer()
            if let showSettings {
                Button("Settings\u{2026}") { showSettings.wrappedValue = true }.buttonStyle(.plain).foregroundStyle(Palette.ice)
            }
            Button("Retry") { store.connect(env.id) }.buttonStyle(.plain).foregroundStyle(Palette.ice).fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(Palette.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// The computers Shed controls: this Mac, and others running the bridge, reached over Tailscale.
struct EnvironmentSettings: View {
    let store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: BridgeEnvironment?

    var body: some View {
        Form {
            Section {
                ForEach(store.environments) { env in
                    Button { editing = env } label: { row(env) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Edit\u{2026}") { editing = env }
                            Button("Reconnect") { store.connect(env.id) }
                            Button("Remove", role: .destructive) { store.remove(env.id) }
                        }
                }
                .onDelete { offsets in offsets.map { store.environments[$0].id }.forEach(store.remove) }
                .onMove { store.moveEnvironments(from: $0, to: $1) }
                Button {
                    editing = BridgeEnvironment(name: "", url: "", token: "")
                } label: {
                    Label("Add Computer\u{2026}", systemImage: "plus")
                }
            } footer: {
                Text("Each computer runs the bridge: setup/install.sh there ends by printing its address and how to read its token.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 320)
        #endif
        .navigationTitle("Computers")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .sheet(item: $editing) { env in
            #if os(iOS)
            NavigationStack { EnvironmentEditor(store: store, env: env) }
            #else
            EnvironmentEditor(store: store, env: env)
            #endif
        }
    }

    private func row(_ env: BridgeEnvironment) -> some View {
        let state = store.connection(of: env.id)
        let (dot, status): (LiveDot.Kind, String) = switch state {
        case .connected: (.waiting, "Connected")
        case .connecting: (.attention, "Connecting\u{2026}")
        case .disconnected(let reason): (.error, reason ?? "Not connected")
        }
        return HStack(spacing: 10) {
            LiveDot(state: dot)
            VStack(alignment: .leading, spacing: 2) {
                Text(env.name).foregroundStyle(Palette.moon)
                Text(env.url).font(.mono(11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// A computer's name, bridge address and token.
struct EnvironmentEditor: View {
    let store: SessionStore
    @State var env: BridgeEnvironment
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { !store.environments.contains { $0.id == env.id } }

    var body: some View {
        Form {
            TextField("Name", text: $env.name, prompt: Text(env.url.isEmpty ? "Jim\u{2019}s MacBook" : BridgeEnvironment.name(for: env.url)))
            TextField("Bridge URL", text: $env.url, prompt: Text("wss://my-mac.tailnet.ts.net:7878/ws"))
                .font(.mono(13))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
            SecureField("Token", text: $env.token, prompt: Text(env.isLocal ? "Read from this Mac\u{2019}s config" : "Paste the token"))
            if !isNew {
                Section {
                    Button("Remove This Computer", role: .destructive) {
                        store.remove(env.id)
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 440)
        #endif
        .navigationTitle(isNew ? "Add Computer" : env.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    store.save(env)
                    dismiss()
                }
                .disabled(env.url.trimmingCharacters(in: .whitespaces).isEmpty || (env.token.isEmpty && !env.isLocal))
            }
        }
    }
}
