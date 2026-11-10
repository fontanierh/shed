// One session: header, its subagents, the live transcript and the composer.
import SwiftUI

struct SessionView: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var renaming: SessionSummary?

    /// Where the session stands once idle, so a quiet session is never a mystery: the commands and subagents that
    /// will wake it, each opening its list, or plainly that nothing will.
    private var idleLines: [IdleLine] {
        guard session.status == .idle, !store.transcript.isEmpty else { return [] }
        var lines: [IdleLine] = []
        // One short line each, naming the thing when there is one; the list is a tap away.
        if let waiting = session.activityText() {
            lines.append(IdleLine(id: "jobs", text: waiting.sentenceCased, systemImage: "apple.terminal", tint: Palette.accent, action: openJobs))
        }
        let total = store.activeDescendants(of: session.id)
        if total > 0 {
            let working = store.children(of: session.id).filter(\.isActive)
            let what = total == 1 && working.count == 1 ? "subagent " + (working[0].name ?? "") : "\(total) subagents"
            lines.append(IdleLine(id: "subagents", text: "Waiting on " + what, systemImage: "person.2", tint: Palette.accent, action: openSubagents))
        }
        // Said quietly, but said: an agent that claims to be waiting while nothing runs is stuck, not busy.
        if lines.isEmpty {
            let who = session.isSubagent ? "a message" : "your message"
            lines.append(IdleLine(id: "done", text: "Nothing running · waiting for \(who)", systemImage: "moon.zzz",
                                  tint: Palette.moon.opacity(0.45)))
        }
        return lines
    }

    /// Why the conversation isn't shown yet, while it hasn't arrived: an empty transcript is then no empty conversation.
    private var pendingTranscript: String? {
        guard !store.transcriptLoaded else { return nil }
        if ended { return "This subagent has ended." }
        switch store.connection {
        case .connected: return "Loading conversation…"
        case .connecting: return "Connecting to \(store.environment(of: session.id)?.name ?? "the bridge")…"
        case .disconnected: return "Can't reach \(store.environment(of: session.id)?.name ?? "the bridge")"
        }
    }

    /// Read-only sessions are watched, not driven: no stopping their calls.
    private var stopTool: ReaderAction? {
        if session.readOnly { return nil }
        let store = store
        return ReaderAction { store.stopTool() }
    }

    /// Only Prime runs a Python kernel.
    private var restartKernel: ReaderAction? {
        if session.readOnly || session.agent != .prime { return nil }
        let store = store
        return ReaderAction { store.restartKernel() }
    }

    /// Connected and waiting for the conversation: the dither rain plays.
    private var raining: Bool { rains && !reduceMotion && store.connection == .connected && !store.transcriptLoaded && !ended }
    /// The conversation opens out of the rain: on the phone's stage, and on the Mac.
    private var rains: Bool {
        #if os(iOS)
        beamStage
        #else
        true
        #endif
    }
    /// A subagent that turned out to have ended as it was opened: its screen says so, then gives way to its parent.
    private var ended: Bool { store.ended.contains(session.id) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A phone in portrait: the text runs edge to edge.
    private var narrow: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
    /// The conversation kept out of sight while it materialises.
    @State private var veiled = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.beamStage) private var beamStage
    // The phone's sheets, and its question before restarting the kernel. The Mac has these in its header.
    @State private var showingJobs = false
    @State private var showingSubagents = false
    @State private var showingSites = false
    @State private var restartingKernel = false
    #else
    private let beamStage = false
    /// The details open beside the conversation.
    @State private var detail = DetailSelection()
    #endif

    var body: some View {
        content
        .background {
            // One plain dark field behind the whole session, and the beam running
            // down the right edge, beside the text rather than under it. A phone has no margin beside the text, so
            // there the beam lies along the bottom, under the composer, where no text runs.
            // On the phone the shared stage behind the navigation stack draws it (`BeamPose.conversation`).
            if beamStage {
                Color.clear
            } else if narrow {
                Backdrop(beam: 1, anchor: UnitPoint(x: 0.4, y: 1.0), shape: .floor)
            } else {
                Backdrop(beam: 1, anchor: UnitPoint(x: 0.93, y: 0.4), shape: .edge)
            }
        }
        .navigationTitle(session.isSubagent ? (session.name ?? "Subagent") : session.title)
        #if os(macOS)
        // The header already shows the title.
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PhoneSessionToolbar(store: store, session: session, rename: { renaming = session }, showJobs: { showingJobs = true },
                                                  showSites: { showingSites = true }, restartKernel: { restartingKernel = true }) }
        .modifier(SoftTopEdge(off: beamStage))
        .sheet(isPresented: $showingJobs) { PhoneBackgroundCommands(store: store, session: session) }
        .sheet(isPresented: $showingSubagents) { PhoneSubagentList(store: store, parentId: session.id) }
        .sheet(isPresented: $showingSites) {
            NavigationStack {
                SitesPanel(entries: store.sites(of: session),
                           title: "Sites", empty: "Servers this session starts appear here.")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #endif
        .renameSession($renaming, store: store)
    }

    #if os(macOS)
    /// The conversation, and beside it the details of the row the reader opened.
    private var content: some View {
        HStack(spacing: 0) {
            column
            if let sheet = detail.sheet {
                reading(DetailPanel(sheet: sheet, selection: detail) { show(nil) })
                    .transition(.move(edge: .trailing))
            }
        }
        // How far the panel's edge can be dragged.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detail.area = $0 }
        // Another session's details have no place beside this one.
        .onChange(of: session.id) { detail.sheet = nil }
    }

    /// Opens the panel, closes it, or changes what it shows. It slides as it comes and goes.
    private func show(_ sheet: FeedSheet?) {
        let change = { if let sheet { detail.toggle(sheet) } else { detail.sheet = nil } }
        if reduceMotion { return change() }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.92)) { change() }
    }
    #else
    private var content: some View { column }
    #endif

    /// What the conversation reads of its session, and the details beside it too.
    private func reading(_ view: some View) -> some View {
        view
            .fileLinks()
            .environment(\.media, store.media(for: session.id))
            .environment(\.liveText, store.live)
            .environment(\.stopTool, stopTool)
            .environment(\.restartKernel, restartKernel)
            .environment(\.subagents, SubagentLinks(store: store, parent: session.id))
    }

    /// The conversation, out of sight while it materialises.
    private var transcript: some View {
        TranscriptView(
            items: store.transcript,
            session: session,
            // The rain says it is loading; the line stays for a connection that isn't there.
            pending: raining ? "" : pendingTranscript,
            idle: idleLines,
            openParent: session.parentId.map { id in { @MainActor in store.select(id) } },
            earlier: store.earlier,
            loadingEarlier: store.loadingEarlier,
            loadEarlier: { await store.loadEarlier() }
        )
        .opacity(veiled ? 0 : 1)
    }

    private var column: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SessionHeader(store: store, session: session) { renaming = session }
            #endif
            // The transcript and the dither it materialises out of: a sibling, so the transcript
            // changing identity as it arrives doesn't start the effect over.
            reading(ZStack {
            #if os(iOS)
            transcript
            .id(session.id + (store.transcriptLoaded ? "" : " waiting"))
            .transition(beamStage ? .identity : .opacity)
            .animation(beamStage ? nil : .easeOut(duration: 0.35), value: store.transcriptLoaded)
            #else
            transcript
            .environment(\.openSheet, SheetOpener { show($0) })
            .environment(\.detailSelection, detail)
            // Each session opens at its end, following new output. The rain brings the conversation in; a fade as well
            // would leave it faint when the rain reads it. With Reduce Motion there is no rain, and it cross-fades.
            .id(session.id + (store.transcriptLoaded ? "" : " waiting"))
            .transition(reduceMotion ? .opacity : .identity)
            // Nothing animates as it arrives: the rain prints it, and an animation there lays the whole conversation
            // out again under it.
            .animation(reduceMotion ? .easeOut(duration: 0.35) : nil, value: store.transcriptLoaded)
            #endif
            // The conversation materialises out of the beam's dither instead of a loading line.
            if rains {
                Materialize(loading: raining, veiled: $veiled)
            }
            if beamStage {
                // The phone's own fade under the navigation bar, in place of the system's soft edge: dark under the
                // bar, easing out over a line's height below it.
                GeometryReader { geometry in
                    let top = geometry.safeAreaInsets.top, fade: CGFloat = 26
                    LinearGradient(stops: [.init(color: Palette.canvas.opacity(0.94), location: 0),
                                           .init(color: Palette.canvas.opacity(0.84), location: top / (top + fade)),
                                           .init(color: Palette.canvas.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: top + fade)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
            }
            })
            .fillsProposal()
            // On the phone the conversation stops at the composer rather than running on under it and the beam below:
            // off the edge by a hair, so the scroll view doesn't stretch into the composer's inset. The composer's
            // soft pool covers where it ends.
            .padding(.bottom, beamStage ? 1 : 0)
            #if os(iOS)
            // A tap or a drag on the conversation puts the keyboard away: the feed's collection view does both itself.
            // Under the session's header: inside a session, a dropped connection otherwise just looks like an agent
            // that stopped answering.
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBar(store: store, sessionId: session.id) }
            .confirmRestartKernel($restartingKernel) { store.restartKernel() }
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ComposerDock(store: store, session: session, narrow: narrow)
            }
        }
    }

    /// The phone opens the lists from the idle lines; the Mac has both in its header.
    private var openJobs: (() -> Void)? {
        #if os(iOS)
        session.hasBackgroundCommands ? { showingJobs = true } : nil
        #else
        nil
        #endif
    }

    private var openSubagents: (() -> Void)? {
        #if os(iOS)
        { showingSubagents = true }
        #else
        nil
        #endif
    }
}

#if os(iOS)
/// The conversation fades out under the navigation bar rather than meeting a hard-edged bar.
private struct SoftTopEdge: ViewModifier {
    /// Off on the phone, which draws a plain fade instead: the system's soft edge blurs what's under the bar again on
    /// every frame of a scroll, and draws it apart from the conversation, so it can't come in with the rain.
    var off = false
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectHidden(off, for: .top)
        } else {
            content.toolbarBackground(Palette.surface.opacity(0.85), for: .navigationBar)
        }
    }
}
#endif
