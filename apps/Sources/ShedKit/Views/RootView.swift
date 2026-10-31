// Top-level layout: session tree on the left, the selected session on the right.
import SwiftUI

public struct RootView: View {
    @Bindable var store: SessionStore
    @State private var showNewSession = false
    @State private var showSettings = false
    @State private var lightbox = Lightbox()

    public init(store: SessionStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, newSession: { showNewSession = true }, openSettings: { showSettings = true })
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                if let session = store.selected {
                    SessionView(store: store, session: session)
                } else if case .disconnected = store.connection {
                    Unreachable(store: store, showSettings: $showSettings)
                } else {
                    Welcome(enabled: store.connection == .connected) { showNewSession = true }
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
        .sheet(isPresented: $showNewSession) { NewSessionSheet(store: store) }
        .sheet(isPresented: $showSettings) { EnvironmentSettings(store: store) }
        .alert("Error", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .tint(Palette.amber)
        .task { store.start() }
    }
}

/// No session selected: a spirit keeping its lantern lit.
struct Welcome: View {
    let enabled: Bool
    let newSession: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Spirit(color: Palette.ice, size: 84)
                Lantern().offset(x: 46, y: 6)
            }
            .padding(.bottom, 6)
            Text("Pick a session or start a new one")
                .font(.system(size: 24, weight: .regular, design: .serif))
                .foregroundStyle(Palette.moon)
            Text("Your agents' conversations, reasoning and subagents live here.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Button(action: newSession) {
                HStack(spacing: 10) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.canvas)
                        .frame(width: 24, height: 24).background(Palette.amber.gradient, in: Circle())
                    Text("New session").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.moon)
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 6)
                }
                .padding(.leading, 10).padding(.trailing, 16).frame(height: 44)
                .card(radius: 14, fill: Palette.raised, border: Palette.amber.opacity(0.55))
                .glow(radius: 14)
            }
            .buttonStyle(PressStyle())
            .disabled(!enabled)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack { Velvet(); Fireflies(count: 9, warm: 0.45, seed: 3) }
        }
    }
}

/// A little paper lantern with a warm flicker.
struct Lantern: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Palette.lineNumber).frame(width: 10, height: 3)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(RadialGradient(colors: [Palette.moon, Palette.amber, Palette.ember], center: .center, startRadius: 1, endRadius: 16))
                .frame(width: 20, height: 26)
                .overlay(VStack(spacing: 5) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Palette.ember.opacity(0.35)).frame(height: 0.8) } })
            Capsule().fill(Palette.lineNumber).frame(width: 10, height: 3)
        }
        .shadow(color: Palette.amber.opacity(0.6), radius: 12)
        .background {
            PulseField(color: Palette.amber, period: 2.6, still: reduceMotion)
                .frame(width: 70, height: 70)
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }
}

/// The bridge can't be reached: the spirit dozes until it can.
struct Unreachable: View {
    let store: SessionStore
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spirit(color: Palette.periwinkle, size: 76, asleep: true)
                .overlay(alignment: .topTrailing) {
                    Text("z z").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(Palette.periwinkle)
                        .offset(x: 26, y: -18)
                }
            Text(store.environments.isEmpty ? "No computers yet" : "Can\u{2019}t reach \(names)").font(.system(size: 24, design: .serif)).foregroundStyle(Palette.moon)
            Text(store.environments.isEmpty ? "Add a computer running the bridge in Settings." : "Shed couldn\u{2019}t connect to \(store.environments.count == 1 ? "its bridge" : "their bridges").")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Settings…") { showSettings = true }.buttonStyle(QuietButton())
                Button { store.connect() } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(AmberButton())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ZStack { Velvet(); Fireflies(count: 5, warm: 0.2, seed: 11) } }
    }

    private var names: String {
        ListFormatter.localizedString(byJoining: store.environments.map(\.name))
    }
}

/// The primary action: warm amber, lit from within.
struct AmberButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.canvas)
            .padding(.horizontal, 18).frame(height: 36)
            .background(LinearGradient(colors: [Palette.moon.opacity(0.25), .clear], startPoint: .top, endPoint: .center), in: Capsule())
            .background(Palette.amber, in: Capsule())
            .glow(radius: configuration.isPressed ? 4 : 10, on: enabled)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A secondary action: a quiet velvet capsule.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Palette.moon)
            .padding(.horizontal, 16).frame(height: 36)
            .card(radius: 18, fill: configuration.isPressed ? Palette.raised : Palette.surface)
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
                    bar(Text("Connecting to \(env.name)\u{2026}"), color: Palette.amber)
                case .disconnected(let reason):
                    bar(Text("Can\u{2019}t reach \(env.name)") + Text(reason.map { ": \($0)" } ?? ""), color: Palette.danger)
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

    private func bar(_ text: Text, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            text.font(.callout).lineLimit(1)
            Spacer()
            if let showSettings { Button("Settings\u{2026}") { showSettings.wrappedValue = true } }
            Button("Retry") { store.connect(env.id) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
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
        let (color, status): (Color, String) = switch state {
        case .connected: (Palette.ice, "Connected")
        case .connecting: (Palette.amber, "Connecting\u{2026}")
        case .disconnected(let reason): (Palette.danger, reason ?? "Not connected")
        }
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
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
