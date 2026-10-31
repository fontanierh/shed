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
            SessionSidebar(store: store) { showNewSession = true }
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
        .sheet(isPresented: $showSettings) { ConnectionSettings(store: store) }
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
            Text("Can\u{2019}t reach your Mac").font(.system(size: 24, design: .serif)).foregroundStyle(Palette.moon)
            Text("Shed couldn\u{2019}t connect to the bridge at \(store.bridgeURL).").font(.system(size: 14)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Settings…") { showSettings = true }.buttonStyle(QuietButton())
                Button { store.connect() } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(AmberButton())
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ZStack { Velvet(); Fireflies(count: 5, warm: 0.2, seed: 11) } }
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

struct ConnectionBar: View {
    let store: SessionStore
    /// Opens the connection settings; without it the bar offers only Retry.
    var showSettings: Binding<Bool>? = nil

    var body: some View {
        switch store.connection {
        case .connected:
            EmptyView()
        case .connecting:
            bar(Text("Connecting to \(store.bridgeURL)…"), color: Palette.amber)
        case .disconnected(let reason):
            bar(Text("Disconnected from the bridge") + Text(reason.map { ": \($0)" } ?? ""), color: Palette.danger)
        }
    }

    private func bar(_ text: Text, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            text.font(.callout).lineLimit(1)
            Spacer()
            if let showSettings { Button("Settings…") { showSettings.wrappedValue = true } }
            Button("Retry") { store.connect() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

struct ConnectionSettings: View {
    @Bindable var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Bridge URL", text: $store.bridgeURL, prompt: Text("wss://my-mac.tailnet.ts.net/ws"))
            SecureField("Token", text: $store.token)
            Text("The token is in ~/.agent-remote/config.json on the computer running the bridge.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    store.connect()
                    dismiss()
                }
            }
        }
    }
}
