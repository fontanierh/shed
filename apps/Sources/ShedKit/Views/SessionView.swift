// One session: header, its subagents, the live transcript and the composer.
import SwiftUI

struct SessionView: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var renaming: SessionSummary?
    @State private var showingJobs = false
    @State private var restartingKernel = false
    @State private var showingSubagents = false
    @State private var showingSites = false
    /// The running background commands, fetched when their count changes, so the transcript can name what it waits on.

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

    private var hasJobs: Bool { session.hasBackgroundCommands }

    /// Connected and waiting for the conversation: the phone's dither rain plays.
    private var raining: Bool { beamStage && !reduceMotion && store.connection == .connected && !store.transcriptLoaded }
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
    #else
    private let beamStage = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SessionHeader(store: store, session: session) { renaming = session }
            #endif
            // The transcript and, on the phone, the dither it materialises out of: a sibling, so the transcript
            // changing identity as it arrives doesn't start the effect over.
            ZStack {
            TranscriptView(
                items: store.transcript,
                session: session,
                // The rain says it is loading; the line stays for a connection that isn't there.
                pending: raining ? "" : pendingTranscript,
                idle: idleLines,
                openChild: { name in store.child(of: session.id, named: name).map { store.select($0.id) } },
                openParent: session.parentId.map { id in { @MainActor in store.select(id) } },
                earlier: store.earlier,
                loadingEarlier: store.loadingEarlier,
                loadEarlier: { await store.loadEarlier() }
            )
            .equatable()
            .opacity(veiled ? 0 : 1)
            // Each session opens at its end, following new output. The conversation arriving replaces the waiting
            // line with a cross-fade, not a cut.
            .id(session.id + (store.transcriptLoaded ? "" : " waiting"))
            // On the phone the rain brings it in; a fade as well would leave it faint when the rain reads it.
            .transition(beamStage ? .identity : .opacity)
            // On the phone nothing animates as it arrives: the rain prints it, and an animation there laid the whole
            // conversation out again under it.
            .animation(beamStage ? nil : .easeOut(duration: 0.35), value: store.transcriptLoaded)
            // On the phone the conversation materialises out of the beam's dither instead of a loading line.
            if beamStage {
                Materialize(loading: raining, veiled: $veiled)
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
            }
            .fillsProposal()
            // On the phone the conversation stops at the composer rather than running on under it and the beam below:
            // off the edge by a hair, so the scroll view doesn't stretch into the composer's inset. The composer's
            // soft pool covers where it ends.
            .padding(.bottom, beamStage ? 1 : 0)
            #if os(iOS)
            // Reading, not typing: a tap or a drag on the conversation puts the keyboard away. Simultaneous, so the
            // blocks' own buttons still work.
            .scrollDismissesKeyboard(.interactively)
            // A plain rectangle: otherwise each touch first works out the shape of everything in the conversation to
            // see whether it lands on this gesture, which held the start of a scroll.
            .contentShape(.interaction, Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            // Under the session's header: inside a session, a dropped connection otherwise just looks like an agent
            // that stopped answering.
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBar(store: store, sessionId: session.id) }
            #endif
            .fileLinks()
            .environment(\.media, store.media(for: session.id))
            .environment(\.liveText, store.live)
            .environment(\.stopTool, stopTool)
            .environment(\.restartKernel, restartKernel)
            .confirmRestartKernel($restartingKernel) { store.restartKernel() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let stuck = session.stuck {
                        StuckBanner(store: store, session: session, stuck: stuck)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    if let error = session.error, session.status == .error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .card(radius: 10, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.4))
                    }
                    ComposerArea(store: store, session: session)
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: session.stuck)
                .frame(maxWidth: Layout.column)
                .padding(.horizontal, Layout.gutter)
                .padding(.bottom, 14)
                .padding(.top, 4)
                .background {
                    if narrow {
                        // On a phone: a soft, rounded pool of dark under the bar and its chips, its edges blurred
                        // away into the beam on every side, so no line or corner shows. Rasterised once, so scrolling
                        // under it costs nothing.
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(Palette.canvas.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.top, -16)
                            .padding(.bottom, 6)
                            // Room around it for the blur, so its edges aren't cut off.
                            .padding(40)
                            .blur(radius: 16)
                            .drawingGroup()
                            .padding(-40)
                            .allowsHitTesting(false)
                    } else {
                    // The transcript slides under the composer: a fade into the field's own dark, so no row shows
                    // through between the bar and its chips, and no hard band either. A plain gradient, not a mask
                    // or a blur, so scrolling under it costs nothing.
                    LinearGradient(stops: [.init(color: Palette.canvas.opacity(0), location: 0),
                                           .init(color: Palette.canvas.opacity(0.94), location: 0.3),
                                           .init(color: Palette.canvas.opacity(0.97), location: narrow ? 0.62 : 1),
                                           .init(color: Palette.canvas.opacity(narrow ? 0.2 : 0.97), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .padding(.top, -28)
                        // Only under the column, its sides fading out, so the beam beside it stays lit.
                        .padding(.horizontal, -90)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                                     .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                                             startPoint: .leading, endPoint: .trailing))
                        .ignoresSafeArea(edges: .bottom)
                        .allowsHitTesting(false)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
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
                SitesPanel(entries: session.servedSites.map { SiteEntry(site: $0, session: session) },
                           title: "Sites", empty: "Servers this session starts appear here.")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #endif
        .renameSession($renaming, store: store)
    }

    /// The phone opens the lists from the idle lines; the Mac has both in its header.
    private var openJobs: (() -> Void)? {
        #if os(iOS)
        hasJobs ? { showingJobs = true } : nil
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

#if os(iOS)
/// The iPhone's navigation bar, kept slight: a dot in the agent's colour and the title, and one menu for the rest,
/// headed by the agent, the cost and the folder.
struct PhoneSessionToolbar: ToolbarContent {
    let store: SessionStore
    let session: SessionSummary
    let rename: () -> Void
    let showJobs: () -> Void
    let showSites: () -> Void
    let restartKernel: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                Circle().fill(Palette.agent(session.agent)).frame(width: 7, height: 7)
                Text(session.isSubagent ? (session.name ?? "Subagent") : session.title)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.moon)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let children = store.children(of: session.id)
        if #available(iOS 26, *) {
            if !children.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { PhoneSubagentsButton(store: store, children: children) }
                    .sharedBackgroundVisibility(.hidden)
            }
            if session.backgroundJobs > 0 {
                ToolbarItem(placement: .topBarTrailing) { jobs }
                    .sharedBackgroundVisibility(.hidden)
            }
            if session.hasSites {
                ToolbarItem(placement: .topBarTrailing) { sites }
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem(placement: .topBarTrailing) { stop }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { menu }
                .sharedBackgroundVisibility(.hidden)
        } else {
            if !children.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { PhoneSubagentsButton(store: store, children: children) }
            }
            if session.backgroundJobs > 0 {
                ToolbarItem(placement: .topBarTrailing) { jobs }
            }
            if session.hasSites {
                ToolbarItem(placement: .topBarTrailing) { sites }
            }
            ToolbarItem(placement: .topBarTrailing) { stop }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
    }

    /// Stops the current run, while there is one.
    @ViewBuilder private var stop: some View {
        if session.status.isBusy, !session.readOnly {
            Button { store.abort() } label: {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accent)
                    .frame(width: 32, height: 32)
                    .background(Palette.accent.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(Palette.accent.opacity(0.5)))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("Stop")
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The running background commands: a terminal and how many. Opens their list.
    private var jobs: some View {
        Button(action: showJobs) {
            HStack(spacing: 5) {
                Image(systemName: "apple.terminal").font(.system(size: 13, weight: .medium))
                Text("\(session.backgroundJobs)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: session.backgroundJobs)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(session.backgroundJobs == 1 ? "1 background command running" : "\(session.backgroundJobs) background commands running")
    }

    /// The session's sites: a globe and how many. Opens their list.
    private var sites: some View {
        Button(action: showSites) {
            HStack(spacing: 5) {
                Image(systemName: "globe").font(.system(size: 13, weight: .medium))
                Text("\(session.servedSites.count)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Palette.ice)
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: session.servedSites.count)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(session.servedSites.count == 1 ? "1 site running" : "\(session.servedSites.count) sites running")
    }

    private var summary: String {
        let cost = session.cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        return "\(session.agent.displayName) · \(cost) · \(session.folderName)"
    }

    private var menu: some View {
        Menu {
            if let parent = store.parent(of: session) {
                Button("Open \(parent.isSubagent ? (parent.name ?? "Parent") : "Parent Session")", systemImage: "arrow.up.left") { store.select(parent.id) }
            }
            if !session.readOnly {
                Section(summary) {
                    if !session.isSubagent {
                        Button("Rename…", systemImage: "pencil", action: rename)
                    }
                }
                Section {
                    Button("Compact Now", systemImage: "rectangle.compress.vertical") { store.compact() }
                        .disabled(session.status.isBusy)
                    if session.controlsAutoCompaction {
                        Toggle("Auto-compaction", isOn: Binding(get: { session.autoCompaction }, set: { store.setAutoCompaction($0) }))
                    }
                }
                if session.agent == .prime {
                    Button("Restart Python Kernel…", systemImage: "arrow.clockwise", action: restartKernel)
                }
                if session.hasBackgroundCommands {
                    Button("Background Commands", systemImage: "apple.terminal", action: showJobs)
                }
                if session.hasSites {
                    Button("Sites", systemImage: "globe", action: showSites)
                }
                Button("Copy Path", systemImage: "doc.on.doc") { Clipboard.copy(session.cwd) }
                Button("Stop Session", systemImage: "stop.circle", role: .destructive) { store.close() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.moon)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
    }
}

/// The subagents as a few overlapping marks and how many are working. Opens the full list.
struct PhoneSubagentsButton: View {
    let store: SessionStore
    let children: [SessionSummary]
    @State private var showing = false

    var body: some View {
        let active = children.filter(\.isActive).count
        Button { showing = true } label: {
            HStack(spacing: 6) {
                HStack(spacing: -7) {
                    ForEach(children.suffix(3)) { child in
                        AgentMark(name: child.name ?? "s", size: 18, working: child.status.isBusy)
                            .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 1.5))
                    }
                }
                Text(active > 0 ? "\(active)/\(children.count)" : "\(children.count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(active > 0 ? Palette.accent : Palette.moon.opacity(0.7))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize()
            }
            .fixedSize()
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: active)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(active > 0 ? "Subagents, \(active) of \(children.count) working" : "\(children.count) subagents")
        .sheet(isPresented: $showing) {
            PhoneSubagentList(store: store, parentId: children.first?.parentId ?? "")
        }
    }
}

/// Every subagent of the session in one calm list: the ones working first, then the finished ones, each in the order
/// it started so rows don't shuffle as they report in.
struct PhoneSubagentList: View {
    let store: SessionStore
    let parentId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let children = store.children(of: parentId)
        let working = children.filter(\.isActive)
        let finished = children.filter { !$0.isActive }
        NavigationStack {
            List {
                if !working.isEmpty {
                    Section("Working") { ForEach(working) { row($0) } }
                }
                if !finished.isEmpty {
                    Section("Finished") { ForEach(finished) { row($0) } }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.sidebar.ignoresSafeArea())
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: working.map(\.id))
            .navigationTitle("Subagents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ child: SessionSummary) -> some View {
        Button {
            dismiss()
            store.select(child.id)
        } label: {
            HStack(spacing: 12) {
                AgentMark(name: child.name ?? "s", size: 30, working: child.status.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.name ?? "Subagent").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.moon)
                        .lineLimit(1)
                    if let model = child.model { ModelTag(model: model) }
                    if child.title != child.name {
                        Text(child.title).font(.system(size: 13)).foregroundStyle(Palette.moon.opacity(0.55))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(child.isActive ? (child.activityText() ?? "working").sentenceCased : child.status.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(child.isActive ? Palette.accent : child.status == .error ? Palette.danger : Palette.moon.opacity(0.5))
                    if child.cost > 0 {
                        Text(child.cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .listRowBackground(Palette.surface.opacity(0.6))
    }
}
#endif

/// Which model a session runs on, as a small tag.
struct ModelTag: View {
    let model: ModelInfo
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "cube.transparent").font(.system(size: size - 1.5, weight: .semibold)).foregroundStyle(Palette.accent.opacity(0.9))
            Text(model.name).font(.system(size: size, weight: .medium)).foregroundStyle(Palette.moon.opacity(0.85)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Palette.accent.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.25)))
        .fixedSize()
        .accessibilityLabel("Model \(model.name)")
    }
}

/// The subagents as overlapping marks and a count; the menu lists each with its status and opens it.
struct SubagentMenu: View {
    let store: SessionStore
    let children: [SessionSummary]

    var body: some View {
        let active = children.filter(\.isActive).count
        Menu {
            Section("Subagents (\(children.count))") {
                ForEach(children) { child in
                    Button { store.select(child.id) } label: {
                        Text(child.name ?? child.title)
                        Text([child.isActive ? (child.activityText() ?? "working").sentenceCased : child.status.rawValue.capitalized, child.model?.name]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                HStack(spacing: -6) {
                    ForEach(children.prefix(4)) { child in
                        AgentMark(name: child.name ?? "s", size: 20, working: child.status.isBusy)
                            .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 1.5))
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                Text(active > 0 ? "\(active)/\(children.count) working" : children.count == 1 ? "1 subagent" : "\(children.count) subagents")
                    .font(.system(size: 12.5))
                    .foregroundStyle(active > 0 ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .pill()
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: children.map(\.id))
            .animation(.easeOut(duration: 0.25), value: active)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subagents")
    }
}

struct SessionHeader: View {
    let store: SessionStore
    let session: SessionSummary
    let rename: () -> Void
    @State private var restartingKernel = false
    /// The branch of the repository the session works in, from its computer's `git`.
    @State private var branch: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    if let parent = store.parent(of: session) {
                        Button { store.select(parent.id) } label: {
                            HStack(spacing: 4) {
                                Text(parent.isSubagent ? (parent.name ?? "parent") : parent.title)
                                    .lineLimit(1)
                                    .frame(maxWidth: 200, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open the parent session")
                    }
                    if session.isSubagent { AgentMark(name: session.name ?? "s", size: 22, working: session.status.isBusy) }
                    Text(session.isSubagent ? (session.name ?? "Subagent") : session.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.moon)
                        .lineLimit(1)
                        .help(session.title)
                }
                .layoutPriority(2)
                AgentBadge(agent: session.agent)
                StatusLabel(session: session, activeSubagents: 0)
                    .fixedSize()
                // The folder, not the whole path: the path is in its tooltip and the … menu.
                HStack(spacing: 6) {
                    Label(session.folderName, systemImage: "folder")
                        .lineLimit(1)
                    if let branch { BranchChip(branch: branch).transition(.opacity) }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(session.cwd)
                .contextMenu { Button("Copy Path") { Clipboard.copy(session.cwd) } }
                .layoutPriority(-1)
            }

            Spacer(minLength: 8)

            let children = store.children(of: session.id)
            if !children.isEmpty { SubagentMenu(store: store, children: children) }

            // The composer shows the context gauge; read-only sessions have none.
            if session.readOnly || session.status == .stopped, let context = session.context { ContextGauge(context: context) }
            if session.hasBackgroundCommands { BackgroundCommandsButton(store: store, session: session) }
            if session.hasSites { SitesButton(store: store, session: session) }
            Text(session.cost, format: .currency(code: "USD").precision(.fractionLength(2)))
                .font(.system(size: 12.5).monospacedDigit())
                .contentTransition(.numericText(value: session.cost))
                .animation(.snappy, value: session.cost)
                .pill()
                .help("Cost of this session so far")

            if !session.readOnly {
                Menu {
                    if !session.isSubagent {
                        Button("Rename…", action: rename)
                        Divider()
                    }
                    Button("Compact Now") { store.compact() }
                        .disabled(session.status.isBusy)
                    if session.controlsAutoCompaction {
                        Toggle("Auto-compaction", isOn: Binding(get: { session.autoCompaction }, set: { store.setAutoCompaction($0) }))
                    }
                    if session.agent == .prime {
                        Button("Restart Python Kernel…") { restartingKernel = true }
                    }
                    Divider()
                    Button("New Session (same agent)") { store.newSession() }
                    Button("Copy Path") { Clipboard.copy(session.cwd) }
                    Divider()
                    Button("Stop Session", role: .destructive) { store.close() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.moon)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .confirmRestartKernel($restartingKernel) { store.restartKernel() }
        .task(id: session.cwd) {
            guard let env = store.environment(of: session.id)?.id,
                  let overview = try? await store.gitOverview(in: env, folders: [session.cwd]) else { return }
            withAnimation(.easeOut(duration: 0.2)) { branch = overview.repo(containing: session.cwd)?.branch }
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 52)
        #if os(macOS)
        // Stands in for the title bar: drag it to move the window.
        .background { WindowDragArea().ignoresSafeArea(edges: .top) }
        #endif
        .background {
            // Glass over the beam: frosted, darkened, a hairline under it.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Palette.canvas.opacity(0.55))
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Palette.border.opacity(0), Palette.border.mix(with: .white, by: 0.15, in: .perceptual), Palette.border.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .top)
        }
    }
}

struct StatusLabel: View {
    let session: SessionSummary
    let activeSubagents: Int

    var body: some View {
        HStack(spacing: 6) {
            ActivityIcon(session: session)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(session.status.isBusy ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
                .shimmer(session.status.isBusy)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: session.status)
        .accessibilityElement(children: .combine)
    }

    // A Prime agent keeps going while its subagents and background jobs run, so say so next to "idle".
    private var text: String {
        var parts = [session.status == .running ? "working" : session.status.rawValue]
        if !session.status.isBusy, session.backgroundJobs > 0, let jobs = session.activityText() { parts.append(jobs) }
        if activeSubagents > 0 { parts.append(activeSubagents == 1 ? "1 subagent at work" : "\(activeSubagents) subagents at work") }
        return parts.joined(separator: " · ")
    }
}

/// A ring with the share of the context window in use: blue, turning orange, then red near the limit.
struct ContextGauge: View {
    let context: ContextUsage

    var body: some View {
        let fraction = min(1, max(0, (context.percent ?? 0) / 100))
        let tint: Color = fraction > 0.9 ? Palette.danger : fraction > 0.7 ? Palette.attention : Palette.accent
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(Palette.rail, lineWidth: 2.5)
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.7), radius: 3)
            }
            .frame(width: 15, height: 15)
            .animation(.spring(response: 0.7, dampingFraction: 0.75), value: fraction)
            Text("\(context.tokens.map(Format.tokens) ?? "?") / \(Format.tokens(context.window))")
                .font(.system(size: 12.5).monospacedDigit())
                .contentTransition(.numericText())
                .fixedSize()
        }
        .pill()
        .help("Context window: \(context.tokens.map { $0.formatted() } ?? "unknown") of \(context.window.formatted()) tokens (\(Int(fraction * 100))%)")
    }
}

struct ModelPicker: View {
    let store: SessionStore
    let current: ModelInfo?
    let done: () -> Void
    @State private var query = ""
    /// Provider groups shown open: the current model's at first. A search opens them all.
    @State private var open: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .card(radius: 9, fill: Palette.sunken)
            .padding(10)
            if store.models.isEmpty {
                ProgressView().padding(30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let groups = ModelInfo.byProvider(store.models, matching: query, first: current)
                        ForEach(groups, id: \.provider) { group in
                            let expanded = groups.count == 1 || !query.isEmpty || open.contains(group.provider)
                            Button {
                                if open.remove(group.provider) == nil { open.insert(group.provider) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                                    Text(group.provider).font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text("\(group.models.count)").font(.system(size: 11).monospacedDigit())
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if expanded {
                                ForEach(group.models, id: \.key) { model in row(model) }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(width: 360, height: 420)
        .background(Palette.sidebar)
        .onAppear { if let current { open.insert(current.groupLabel) } }
        .task { await store.loadModels() }
    }

    private func row(_ model: ModelInfo) -> some View {
        Button {
            store.setModel(model)
            done()
        } label: {
            let selected = model.key == current?.key
            HStack {
                Text(model.shortName).foregroundStyle(Palette.moon)
                Spacer()
                if let window = model.contextWindow {
                    Text(ContextWindowMenu.short(window)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if model.reasoning { Image(systemName: "brain").foregroundStyle(.tertiary).help("Reasoning") }
                if selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
            }
            .padding(.leading, 28).padding(.trailing, 10).padding(.vertical, 6)
            .background(selected ? Palette.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Palette.accent.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.key)
    }
}

/// A tool call or background command that looks stuck, why, and the way out, above the composer.
struct StuckBanner: View {
    let store: SessionStore
    let session: SessionSummary
    let stuck: Stuck
    @State private var confirming = false

    /// The bridge's reason as a sentence, naming the computer it runs on.
    static func phrase(_ reason: String, on computer: String?) -> String {
        var text = computer.map { reason.replacingOccurrences(of: "this Mac", with: $0) } ?? reason
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text.sentenceCased
    }

    private var what: String {
        stuck.isToolCall ? ToolDescription.python(code: stuck.command).detail ?? ToolDescription.shortCommand(stuck.command, limit: 60)
            : ToolDescription.shortCommand(stuck.command, limit: 60)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stuck.isToolCall ? "This tool call looks stuck" : "A background command looks stuck")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.moon)
                    if let probability = stuck.probability {
                        Text("\(Int((probability * 100).rounded()))% sure")
                            .font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(Palette.attention)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.attention.opacity(0.14), in: Capsule())
                            .help("How likely the stall check judged it stuck")
                    }
                }
                Text(Self.phrase(stuck.reason, on: store.environment(of: session.id)?.name))
                    .font(.caption).foregroundStyle(Palette.moon.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(what).font(.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !session.readOnly, stuck.isToolCall || stuck.jobId != nil {
                Button { confirming = true } label: {
                    Text(stuck.isToolCall ? "Stop" : "Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.attention)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Palette.attention.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.attention.opacity(0.45)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .confirmationDialog(stuck.isToolCall ? "Stop this tool call?" : "Cancel this command?", isPresented: $confirming,
                                    titleVisibility: .visible) {
                    Button(stuck.isToolCall ? "Stop" : "Cancel Command", role: .destructive) { act() }
                    Button("Keep Waiting", role: .cancel) {}
                } message: {
                    Text(stuck.isToolCall ? "The agent's turn ends here. Messages you queued are sent right away so it can carry on."
                         : "The agent is told the command ended, and carries on.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12, fill: Palette.attention.opacity(0.08), border: Palette.attention.opacity(0.4))
    }

    private func act() {
        if stuck.isToolCall {
            store.stopTool()
        } else if let jobId = stuck.jobId {
            let store = store, id = session.id
            Task { await store.killJob(id, jobId) }
        }
    }
}

/// The composer, or why there isn't one.
struct ComposerArea: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        if session.readOnly {
            Label(session.isSubagent ? "\(session.agent.displayName) subagents are read-only. Steer the parent instead." : "This session is read-only.",
                  systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .card(radius: 16)
        } else if session.status == .stopped {
            HStack {
                AgentMark(agent: session.agent, size: 22, asleep: true)
                Text("This session is stopped.").foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { store.resume() }.buttonStyle(PrimaryButton())
            }
            .padding(12)
            .card(radius: 16)
        } else {
            Composer(store: store, session: session)
        }
    }
}

/// A text field with the send button inside it; the model, effort and context controls sit in a row below.
struct Composer: View {
    let store: SessionStore
    let session: SessionSummary
    #if os(macOS)
    @State private var focused = false
    #else
    @FocusState private var focused: Bool
    #endif
    @State private var showModels = false
    /// Bumped on each send, to kick the button.
    @State private var sent = 0
    @State private var attachments: [Attachment] = []
    @State private var dropping = false

    /// The draft being typed. It is saved to the store a moment after typing stops, not on every keystroke: saving
    /// writes every session's draft to disk and redraws whatever reads the store.
    @State private var draft = ""
    /// Bumped on each keystroke, to time the save.
    @State private var edits = 0

    private var text: Binding<String> {
        Binding(get: { draft }, set: { draft = $0; edits += 1 })
    }

    private func saveDraft(for id: String? = nil) {
        store.setDraft(draft, for: id ?? session.id)
    }

    var body: some View {
        #if os(iOS)
        // On iPhone the input bar stays as it is while the agent works: sending steers, and Stop is in the top bar.
        let busy = false
        #else
        let busy = session.status.isBusy
        #endif
        VStack(alignment: .leading, spacing: 8) {
            if let goal = session.goal {
                GoalCard(goal: goal, cancel: store.clearGoal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let question = session.question {
                QuestionCard(store: store, session: session, question: question)
                    .id(question.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !session.queue.forReader.isEmpty {
                QueuedMessages(queue: session.queue.forReader)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if busy {
                WorkingStrip(store: store, session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { gone in attachments.removeAll { $0.id == gone.id } }
                    .padding(.horizontal, 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
                #if os(macOS)
                ComposerTextView(text: text, focused: $focused, submit: send) { files in attach { await files.load() } }
                    .background(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(placeholder).font(.system(size: 14.5)).foregroundStyle(.tertiary).allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 8)
                #else
                TextField(placeholder, text: text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Palette.moon)
                    .lineSpacing(3)
                    .lineLimit(1...10)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            text.wrappedValue += "\n"
                        } else {
                            send()
                        }
                        return .handled
                    }
                    .padding(.vertical, 8)
                    .accessibilityLabel("Message")
                #endif

                if busy {
                    Button(action: queueFollowUp) {
                        Image(systemName: "text.append")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.moon)
                            .frame(width: 34, height: 34)
                            .card(radius: 17, fill: Palette.raised.opacity(0.8))
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.5)
                    .help("Queue: send after the agent finishes")
                    .transition(.scale.combined(with: .opacity))

                    Button(action: send) {
                        Label("Steer", systemImage: "arrow.up.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Palette.accent.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.accent.opacity(canSend ? 0.75 : 0.3)))
                            .glow(radius: 8, on: canSend)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.6)
                    .help("Steer: deliver now, while the agent works")
                    .transition(.scale.combined(with: .opacity))

                    Button { store.abort() } label: { StopGlyph() }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the current run (⌘.)")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    SendButton(enabled: canSend, kick: sent, action: send)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            // Opaque: the transcript scrolls under it, and its text mustn't show through what's being typed.
            .card(radius: 22, fill: Palette.composer,
                  border: dropping ? Palette.accent.opacity(0.85) : focused || busy ? Palette.accent.opacity(0.6) : Palette.accent.opacity(0.32))
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.canvas))
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            .shadow(color: Palette.accent.opacity(focused ? 0.28 : 0.14), radius: focused ? 20 : 16)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            HStack(spacing: 8) {
                Button { showModels = true } label: {
                    ChipLabel(text: session.model?.name ?? "No model", menu: true) {
                        Image(systemName: "cube").foregroundStyle(Palette.moon.opacity(0.75))
                    }
                }
                .buttonStyle(PressStyle())
                #if os(iOS)
                .sheet(isPresented: $showModels) {
                    PhoneModelPicker(store: store, current: session.model)
                }
                #else
                .popover(isPresented: $showModels, arrowEdge: .top) {
                    ModelPicker(store: store, current: session.model) { showModels = false }
                }
                #endif
                .help("Model")

                if !session.thinkingLevels.isEmpty {
                    Menu {
                        Picker("Effort", selection: Binding(get: { session.thinkingLevel ?? "" }, set: { store.setThinking($0) })) {
                            ForEach(session.thinkingLevels, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        ChipLabel(text: (session.thinkingLevel ?? "default").capitalized, menu: true) {
                            EffortBars(level: effortLevel)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Reasoning effort")
                }

                Spacer(minLength: 8)

                if let context = session.context {
                    // The gauge doubles as the context window's controls.
                    Menu {
                        ContextWindowMenu(store: store, session: session, inline: true)
                        Divider()
                        Button("Compact Now", systemImage: "rectangle.compress.vertical") { store.compact() }
                            .disabled(session.status.isBusy)
                    } label: {
                        ContextGauge(context: context)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 4)
        }
        #if os(macOS)
        // On iPhone the keyboard would cover the transcript, so it waits for a tap.
        .onAppear { focused = true }
        #endif
        // Anywhere on the composer: files from Finder, the screenshot thumbnail, images dragged out of other apps.
        .onDrop(of: attachableTypes, isTargeted: $dropping) { providers in
            attach { await droppedFiles(providers) }
            return true
        }
        .onAppear { draft = store.drafts[session.id] ?? "" }
        .onChange(of: session.id) { old, new in
            saveDraft(for: old)
            draft = store.drafts[new] ?? ""
            attachments = []
        }
        .task(id: edits) {
            guard edits > 0, (try? await Task.sleep(for: .milliseconds(500))) != nil else { return }
            saveDraft()
        }
        .onDisappear { saveDraft() }
        // A message that failed to send comes back as the draft.
        .onChange(of: store.drafts[session.id]) { _, restored in
            if let restored, draft.isEmpty { draft = restored }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: attachments.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: busy)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.queue.forReader.steering.count + session.queue.forReader.followUp.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.goal?.objective)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.question?.id)
    }

    /// The effort level's position, 0...1, for the bars.
    private var effortLevel: Double {
        let levels = session.thinkingLevels
        guard let current = session.thinkingLevel, let index = levels.firstIndex(of: current), levels.count > 1 else { return 0.5 }
        return Double(index) / Double(levels.count - 1)
    }

    /// Something to send, and no file still on its way to the session's computer. Asked several times a redraw, so
    /// it stops at the first character that isn't blank instead of trimming the whole draft.
    private var canSend: Bool {
        (draft.contains { !$0.isWhitespace } || attachments.contains { $0.path != nil }) && !attachments.contains(where: \.uploading)
    }

    /// The text with the uploaded files' embeds after it.
    private var message: String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([trimmed].filter { !$0.isEmpty } + attachments.compactMap(\.embed)).joined(separator: "\n\n")
    }

    private func attach(_ files: @escaping @MainActor () async -> [(name: String, data: Data)]) {
        let media = store.media(for: session.id)
        Task {
            for file in await files() {
                let attachment = Attachment(name: file.name)
                attachments.append(attachment)
                do {
                    let path = try await media.upload(file.data, name: file.name)
                    if let i = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[i].path = path }
                } catch {
                    if let i = attachments.firstIndex(where: { $0.id == attachment.id }) { attachments[i].error = error.localizedDescription }
                }
            }
        }
    }

    private var placeholder: String {
        if session.question != nil { return "Or type your answer…" }
        #if os(macOS)
        if session.status.isBusy { return "Steer \(session.agent.displayName)…" }
        #endif
        return session.isSubagent ? "Message this subagent directly…" : "Message \(session.agent.displayName)…"
    }

    private func send() {
        guard canSend else { return }
        store.send(message)
        draft = ""
        saveDraft()
        attachments = []
        sent += 1
        #if os(iOS)
        // Sent: back to reading. The Mac keeps the focus for the next message.
        focused = false
        #endif
    }

    private func queueFollowUp() {
        guard canSend else { return }
        store.followUp(message)
        draft = ""
        saveDraft()
        attachments = []
    }
}

/// The round send button: a white disc when there's something to send, dim glass otherwise. It kicks up when it
/// goes.
struct SendButton: View {
    let enabled: Bool
    let kick: Int
    let action: () -> Void
    @State private var lift = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? Palette.canvas : Color.secondary)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(enabled ? AnyShapeStyle(LinearGradient(colors: [.white, Palette.moon.mix(with: Palette.ice, by: 0.25, in: .perceptual)],
                                                                         startPoint: .top, endPoint: .bottom))
                                          : AnyShapeStyle(Palette.raised))
                }
                .overlay(Circle().strokeBorder(enabled ? Color.white.opacity(0.6) : Palette.border))
                .glow(Palette.accent, radius: lift ? 18 : 9, on: enabled)
                .offset(y: lift ? -5 : 0)
                .scaleEffect(enabled ? 1 : 0.92)
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .help("Send")
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: enabled)
        .onChange(of: kick) {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { lift = true }
            Task {
                try? await Task.sleep(for: .milliseconds(180))
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { lift = false }
            }
        }
    }
}

/// Signal bars for the reasoning effort; the lit ones glow blue.
struct EffortBars: View {
    let level: Double

    var body: some View {
        let lit = Int((level * 3).rounded()) + 1
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? Palette.accent : Palette.rail)
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: lit)
    }
}

/// A chip below the composer: icon, label, and a chevron when it opens a menu.
struct ChipLabel<Icon: View>: View {
    let text: String
    var menu = false
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 7) {
            icon.font(.system(size: 12, weight: .medium))
            Text(text).lineLimit(1).foregroundStyle(Palette.moon)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12).frame(height: 30)
        .card(radius: 15, fill: Palette.surface.opacity(0.85), border: Palette.lit.opacity(0.8))
        .contentShape(Capsule())
    }
}

/// The goal the agent keeps working toward across turns: what it is, how far it has gone, and a way to drop it.
/// What the agent asks, above the composer: its options to pick from, or an answer typed below. The ✕ skips it.
struct QuestionCard: View {
    let store: SessionStore
    let session: SessionSummary
    let question: AgentQuestion
    @State private var picked: [String: [String]] = [:]
    @State private var sending = false
    /// Options come in one after another when the card arrives.
    @State private var shown = false

    /// One question to pick one option for: a tap answers it.
    private var answersOnTap: Bool {
        question.questions.count == 1 && question.questions[0].multiSelect != true
    }

    private var complete: Bool {
        question.questions.allSatisfy { !($0.options ?? []).isEmpty && !(picked[$0.id] ?? []).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LiveDot(state: .attention, size: 8)
                Text("\(session.agent.displayName) asks")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.attention)
                if question.continued == true {
                    Text("Carried on meanwhile")
                        .font(.caption2.weight(.medium)).foregroundStyle(Palette.moon.opacity(0.55))
                        .help("The agent stopped waiting and carried on. Your answer still reaches it.")
                }
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.mini) }
                Button { answer([:]) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.moon.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .background(Palette.moon.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(sending)
                .help("Skip the question")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(question.questions, id: \.id) { item in
                        itemView(item)
                    }
                }
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)

            if !answersOnTap, question.questions.contains(where: { !($0.options ?? []).isEmpty }) {
                HStack {
                    Spacer()
                    Button("Answer") { answer(picked) }
                        .buttonStyle(PrimaryButton())
                        .disabled(!complete || sending)
                }
            }
        }
        .padding(12)
        .card(radius: 16, fill: Palette.surface.opacity(0.95), border: Palette.attention.opacity(0.55))
        .shadow(color: Palette.attention.opacity(0.14), radius: 16)
        .onAppear { shown = true }
    }

    @ViewBuilder
    private func itemView(_ item: AgentQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = item.header, !header.isEmpty {
                Text(header.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.moon.opacity(0.5))
            }
            Text(item.question)
                .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.moon)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail = item.detail, !detail.isEmpty {
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 10, fill: Palette.raised.opacity(0.6))
            }
            ForEach(Array((item.options ?? []).enumerated()), id: \.element.label) { index, option in
                optionRow(option, of: item)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 6)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.08 + Double(index) * 0.06), value: shown)
            }
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, of item: AgentQuestion.Item) -> some View {
        let multi = item.multiSelect == true
        let on = (picked[item.id] ?? []).contains(option.label)
        return Button {
            if answersOnTap {
                answer([item.id: [option.label]])
            } else if multi {
                var labels = picked[item.id] ?? []
                if on { labels.removeAll { $0 == option.label } } else { labels.append(option.label) }
                picked[item.id] = labels
            } else {
                picked[item.id] = [option.label]
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 14)).foregroundStyle(on ? Palette.attention : Palette.moon.opacity(0.4))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.moon)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(Palette.moon.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Palette.attention.opacity(0.12) : Palette.raised.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Palette.attention.opacity(0.55) : Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(sending)
    }

    private func answer(_ answers: [String: [String]]) {
        sending = true
        let (store, id, questionId) = (store, session.id, question.id)
        Task {
            await store.answerQuestion(id, questionId, picked: answers)
            sending = false
        }
    }
}

struct GoalCard: View {
    let goal: Goal
    let cancel: () -> Void
    @State private var expanded = false
    @State private var confirming = false
    /// The objective a cancel was sent for, until the goal goes away (a running turn takes it at its next step).
    @State private var cancelling: String?

    private var tint: Color { goal.status == "active" ? Palette.accent : Palette.attention }

    private var state: String {
        if cancelling == goal.objective { return "Cancelling…" }
        switch goal.status {
        case "active": return "Goal"
        case "paused": return "Goal paused"
        case "budget_limited": return "Goal out of budget"
        default: return "Goal"
        }
    }

    /// "12.9K tokens · 3m", with the budget when there is one.
    private var usage: String {
        let tokens = goal.tokenBudget.map { "\(Format.tokens(goal.tokensUsed)) / \(Format.tokens($0)) tokens" }
            ?? "\(Format.tokens(goal.tokensUsed)) tokens"
        return "\(tokens) · \(Format.duration(ms: Double(goal.timeUsedSeconds) * 1000))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 22, height: 22)
                            .background(tint.opacity(0.14), in: Circle())
                        Text(state).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                        if !expanded {
                            Text(goal.objective).font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Chevron(open: expanded)
                    }
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if cancelling == goal.objective {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                } else {
                    Button { confirming = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.moon.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Palette.moon.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel the goal")
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.objective).font(.system(size: 12.5)).foregroundStyle(Palette.moon).textSelection(.enabled)
                    Text(usage).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.moon.opacity(0.5))
                    if let reason = goal.lastReason, goal.status != "active" {
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.attention.opacity(0.85))
                    }
                }
                .padding(.leading, 30).padding(.top, 6).padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .card(radius: 14, fill: Palette.surface.opacity(0.9))
        .confirmationDialog("Cancel this goal?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Cancel Goal", role: .destructive) {
                cancelling = goal.objective
                cancel()
            }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text("The agent stops pursuing it after its current step.")
        }
    }
}

extension Queue {
    /// What the reader would recognize as waiting: Prime also queues its own notices (a subagent that exited or was
    /// cancelled, a message from another agent, a goal's continuation) for the end of the turn, and an agent pursuing a
    /// goal rarely ends one, so they would sit in the bar for good. They show in the transcript once delivered.
    var forReader: Queue {
        Queue(steering: steering.filter { !Self.isNotice($0) }, followUp: followUp.filter { !Self.isNotice($0) })
    }

    private static func isNotice(_ text: String) -> Bool {
        text.hasPrefix("Agent message received:") || text.hasPrefix("[goal") || Note(text).kind != .other
    }
}

/// Messages waiting for the agent: steering is delivered at the next step, follow-ups when it finishes.
struct QueuedMessages: View {
    let queue: Queue
    @State private var expanded = false

    private var entries: [(steering: Bool, text: String)] {
        queue.steering.map { (true, $0) } + queue.followUp.map { (false, $0) }
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 0) {
            // One line however many are waiting: how many, and the latest.
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    icon(steering: !queue.steering.isEmpty)
                    Text(summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                        .monospacedDigit().contentTransition(.numericText())
                    if !expanded, let last = entries.last {
                        Text(last.text).font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entries.count > 1 || expanded { Chevron(open: expanded) }
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entries.count < 2 && !expanded)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.steering ? "arrow.up.right" : "text.append")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent.opacity(0.8))
                                    .frame(width: 22)
                                Text(entry.text).font(.system(size: 12.5)).foregroundStyle(Palette.moon).lineLimit(3)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .card(radius: 14, fill: Palette.surface.opacity(0.9))
        .onChange(of: entries.isEmpty) { if $1 { expanded = false } }
    }

    /// "Steering", "3 pending", "2 steering · 1 queued".
    private var summary: String {
        let (steering, queued) = (queue.steering.count, queue.followUp.count)
        if steering + queued == 1 { return steering == 1 ? "Steering" : "Queued" }
        if steering > 0, queued > 0 { return "\(steering) steering · \(queued) queued" }
        return "\(steering + queued) pending"
    }

    private func icon(steering: Bool) -> some View {
        Image(systemName: steering ? "arrow.up.right" : "text.append")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .frame(width: 22, height: 22)
            .background(Palette.accent.opacity(0.14), in: Circle())
    }
}

/// While the agent works: its mark, what it's doing now, and for how long, along a trail of light.
struct WorkingStrip: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: session.agent, size: 20, working: true)
            Text(session.status == .compacting ? "Compacting context" : "\(session.agent.displayName) is working")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.moon)
                .shimmer(color: session.status == .compacting ? Palette.lilac : Palette.accent)
                .fixedSize()
            LightTrail()
                .frame(height: 10)
                .frame(minWidth: 40)
            if let step = currentStep {
                Text(step).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: step)
            }
            if let start = turnStart {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.duration(ms: max(0, context.date.timeIntervalSince(start)) * 1000))
                        .font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// The latest reasoning title or tool call of this turn.
    private var currentStep: String? {
        guard let last = store.items.last(where: { $0.kind == .tool || $0.kind == .thinking }),
              let turn = store.items.lastIndex(where: { $0.kind == .user }),
              let index = store.items.firstIndex(where: { $0.id == last.id }), index > turn
        else { return nil }
        if last.kind == .thinking { return Reasoning(last.text).title }
        let description = ToolDescription(last)
        return [description.title, description.detail].compactMap { $0 }.joined(separator: " ")
    }

    private var turnStart: Date? { store.items.last { $0.kind == .user }?.date }
}

/// A faint line with a spark of light gliding along it, back and forth.
struct LightTrail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TrailField(still: reduceMotion)
            .accessibilityHidden(true)
    }
}

/// Stop: a filled square in a glass circle, with a blue arc spinning round its edge while the agent works.
struct StopGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Palette.moon)
            .frame(width: 11, height: 11)
            .frame(width: 34, height: 34)
            .card(radius: 17, fill: hovering ? Palette.raised : Palette.raised.opacity(0.75))
            .overlay {
                SpinField(color: Palette.accent, lineWidth: 2, still: reduceMotion)
                    .frame(width: 36, height: 36)
                    .allowsHitTesting(false)
            }
            .glow(Palette.accent, radius: 8)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .accessibilityLabel("Stop")
    }
}
