// The iPhone app: the session list, pushing into a session, the connect screen and Live Activities.
#if os(iOS)
import SwiftUI

public struct PhoneRootView: View {
    @Bindable var store: SessionStore
    /// The session on screen, following the store's selection inside one animation.
    @State private var shown: String?
    /// How far a swipe back has pulled the conversation away, 0 to 1: it follows the finger.
    @State private var pull: CGFloat = 0
    /// The list about to come back, laid out (all but invisible) a frame before it shows: hidden, it lays out only
    /// when it first shows, and that late first frame made the way back start with a jump.
    @State private var warming = false
    /// The conversation on its way back into the beam, as a picture; the live one is hidden underneath until it is
    /// let go. Shrinking, blurring or fading the live one made SwiftUI rehost its navigation stack, which laid it out
    /// again (its scroll shifting) and held the first frames.
    @State private var leaving: NavigationViewHandle.Picture?
    /// Set once the way back is under way, inside its animation.
    @State private var going = false
    @State private var sessionView = NavigationViewHandle()
    /// New Session, open with this draft. One value rather than a flag beside a draft: the sheet read the draft a
    /// beat late and opened without the message.
    @State private var newSession: NewSessionDraft?
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
                        SessionSidebar(store: store, newSession: { newSession = NewSessionDraft() },
                                       openSettings: { showSettings = true },
                                       start: { message, folder in
                                           newSession = NewSessionDraft(message: message, folder: folder)
                                       })
                            .toolbar(.hidden, for: .navigationBar)
                            .containerBackground(.clear, for: .navigation)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                ConnectionBar(store: store, showSettings: $showSettings)
                            }
                    }
                    // Under a swipe back, the list condenses into focus as the conversation dissolves: from a little
                    // larger and soft, settling sharp. Nothing slides.
                    .opacity(shown == nil || going ? 1 : max(pull, warming ? 0.002 : 0))
                    .scaleEffect(shown == nil || going ? 1 : 1.03 - 0.03 * pull)
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
                            .background { NavigationViewFinder(handle: sessionView) }
                            .toolbar {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button(action: back) { Image(systemName: "chevron.left") }
                                        .accessibilityLabel("Sessions")
                                }
                            }
                        }
                        // Its picture stands in for it on the way back.
                        .opacity(leaving == nil ? 1 : 0)
                        // Another session (a subagent, say) replaces this one the same way.
                        .id(id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 1.03)),
                            removal: leaving == nil ? .opacity : .identity))
                        // Back: a swipe in from the left edge. The conversation follows the finger; let go far enough
                        // along, or with a flick, and it glides away, otherwise it settles back.
                        .simultaneousGesture(DragGesture(minimumDistance: 10)
                            .onChanged { drag in
                                guard shown != nil, !going, drag.startLocation.x < 28 else { return }
                                if !warming { warming = true }
                                if leaving == nil { leaving = sessionView.snapshot() }
                                pull = min(1, max(0, drag.translation.width) / 320)
                            }
                            .onEnded { drag in
                                guard shown != nil, !going, drag.startLocation.x < 28 else { return }
                                if pull > 0.3 || drag.predictedEndTranslation.width > 220 {
                                    back()
                                } else {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { pull = 0 } completion: {
                                        guard !going else { return }
                                        warming = false
                                        leaving = nil
                                    }
                                }
                            })
                    }

                    // The conversation going back: pulled, it sinks into the beam (smaller toward the composer, softer,
                    // fainter) and, let go, dissolves the rest of the way.
                    if let leaving {
                        // Exactly where the conversation was on screen.
                        GeometryReader { geometry in
                            let origin = geometry.frame(in: .global).origin
                            Image(uiImage: leaving.image)
                                .resizable()
                                .frame(width: leaving.frame.width, height: leaving.frame.height)
                                .modifier(Dissolve(amount: going ? 1 : pull * 0.6))
                                .offset(x: leaving.frame.minX - origin.x, y: leaving.frame.minY - origin.y)
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .environment(\.beamStage, true)
                .background { BeamStage(pose: shown == nil || going ? .list : .conversation, poses: [.list, .conversation]).ignoresSafeArea() }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .environment(\.lightbox, lightbox)
        .overlay { LightboxView(lightbox: lightbox) }
        .sheet(item: $newSession) { draft in
            NewSessionSheet(store: store, initialMessage: draft.message, initialFolder: draft.folder)
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
            pull = 0
            withAnimation(.spring(response: 0.6, dampingFraction: 0.9)) { shown = id }
        }
        .onChange(of: store.sessions, initial: true) { _, sessions in activities.sync(sessions, store: store) }
        .onOpenURL { url in open(url) }
        .task { if !store.environments.isEmpty { store.start() } }
    }

    /// Back to the list: the conversation dissolves first, then the session is let go. Deselecting clears the
    /// transcript, which would otherwise flash its loading line while it fades.
    private func back() {
        guard shown != nil, !going else { return }
        let ready = warming && leaving != nil
        warming = true
        if leaving == nil { leaving = sessionView.snapshot() }
        Task { @MainActor in
            // The list and the picture land first, then the animation starts: its clock runs from a frame drawn.
            if !ready { try? await Task.sleep(for: .milliseconds(16)) }
            // One soft, unhurried settle from wherever a swipe left it.
            withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
                going = true
                // No picture: the live conversation fades as it goes.
                if leaving == nil { shown = nil }
            } completion: {
                shown = nil
                leaving = nil
                going = false
                pull = 0
                warming = false
                store.select(nil)
            }
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

/// The phone's navigation stack around a view, for a picture of it.
final class NavigationViewHandle {
    weak var view: UIView?

    struct Picture {
        var image: UIImage
        /// Where the stack was, in the window.
        var frame: CGRect
    }

    /// What the stack shows, its clear background left clear. Nil if it isn't on screen.
    func snapshot() -> Picture? {
        guard let view, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat(for: view.traitCollection)
        format.opaque = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
        }
        return Picture(image: image, frame: view.convert(view.bounds, to: nil))
    }
}

/// Zero-sized, inside a navigation stack: finds the stack's own view once it is in a window.
private struct NavigationViewFinder: UIViewRepresentable {
    let handle: NavigationViewHandle

    final class Finder: UIView {
        var handle: NavigationViewHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let v = view, !(v.next is UINavigationController) { view = v.superview }
            handle?.view = view
        }
    }

    func makeUIView(context: Context) -> Finder {
        let finder = Finder()
        finder.handle = handle
        finder.isUserInteractionEnabled = false
        return finder
    }

    func updateUIView(_ finder: Finder, context: Context) { finder.handle = handle }
}

/// The conversation going back into the beam, 0 (there) to 1 (gone): it shrinks toward the composer at the bottom,
/// blurs and fades, with no sideways motion.
private struct Dissolve: ViewModifier {
    var amount: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 - 0.07 * amount, anchor: .bottom)
            // Even a point of blur softens text at once: it comes in slowly, then gathers.
            .blur(radius: 12 * amount * amount)
            .opacity(1 - amount)
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
