// One session: header, its subagents, the live transcript and the composer.
import SwiftUI

struct SessionView: View {
    let store: SessionStore
    let session: SessionSummary
    @State private var renaming: SessionSummary?
    @State private var showingJobs = false
    @State private var restartingKernel = false
    @State private var showingSubagents = false
    /// The running background commands, fetched when their count changes, so the transcript can name what it waits on.
    @State private var runningCommands: [String] = []

    /// Where the session stands once idle, so a quiet session is never a mystery: the commands and subagents that
    /// will wake it, each opening its list, or plainly that nothing will.
    private var idleLines: [IdleLine] {
        guard session.status == .idle, !store.transcript.isEmpty else { return [] }
        var lines: [IdleLine] = []
        let jobs = session.backgroundJobs
        // One short line each, naming the thing when there is one; the list is a tap away.
        if jobs > 0 {
            let what = jobs == 1 && runningCommands.count == 1
                ? Self.short(ToolDescription.oneLine(runningCommands[0])) : "\(jobs) background commands"
            lines.append(IdleLine(id: "jobs", text: "Waiting on " + what, systemImage: "apple.terminal", tint: Palette.amber, action: openJobs))
        }
        let total = store.activeDescendants(of: session.id)
        if total > 0 {
            let working = store.children(of: session.id).filter(\.isActive)
            let what = total == 1 && working.count == 1 ? "subagent " + (working[0].name ?? "") : "\(total) subagents"
            lines.append(IdleLine(id: "subagents", text: "Waiting on " + what, systemImage: "person.2", tint: Palette.amber, action: openSubagents))
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

    /// The part of a command worth reading: "cd /Users/me/dev/project && uv run tool watch …" is "uv run tool
    /// watch …", which otherwise falls past the cut.
    private static func short(_ line: String) -> String {
        let line = line.replacingOccurrences(of: #"^cd \S+ && "#, with: "", options: .regularExpression)
        return line.count > 48 ? String(line.prefix(47)) + "…" : line
    }

    /// Read-only sessions are watched, not driven: no stopping their calls.
    private var stopTool: (@MainActor () -> Void)? {
        if session.readOnly { return nil }
        let store = store
        return { store.stopTool() }
    }

    /// Only Prime runs a Python kernel.
    private var restartKernel: (@MainActor () -> Void)? {
        if session.readOnly || session.agent != .prime { return nil }
        let store = store
        return { store.restartKernel() }
    }

    private var hasJobs: Bool { !(session.agent == .pi && session.isSubagent) }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            SessionHeader(store: store, session: session) { renaming = session }
            #endif
            TranscriptView(
                items: store.transcript,
                session: session,
                pending: pendingTranscript,
                idle: idleLines,
                openChild: { name in store.child(of: session.id, named: name).map { store.select($0.id) } },
                openParent: session.parentId.map { id in { store.select(id) } },
                earlier: store.earlier,
                loadingEarlier: store.loadingEarlier,
                loadEarlier: { await store.loadEarlier() }
            )
            // Each session opens at its end, following new output.
            .id(session.id)
            #if os(iOS)
            // Reading, not typing: a tap or a drag on the conversation puts the keyboard away. Simultaneous, so the
            // blocks' own buttons still work.
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(TapGesture().onEnded {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            })
            // Under the session's header: inside a session, a dropped connection otherwise just looks like an agent
            // that stopped answering.
            .safeAreaInset(edge: .top, spacing: 0) { ConnectionBar(store: store, sessionId: session.id) }
            #endif
            .environment(\.media, store.media(for: session.id))
            .environment(\.stopTool, stopTool)
            .environment(\.restartKernel, restartKernel)
            .confirmRestartKernel($restartingKernel) { store.restartKernel() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if let error = session.error, session.status == .error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(Palette.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .card(radius: 10, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.4))
                    }
                    ComposerArea(store: store, session: session)
                }
                .frame(maxWidth: Layout.column)
                .padding(.horizontal, Layout.gutter)
                .padding(.bottom, 14)
                .padding(.top, 4)
                .frame(maxWidth: .infinity)
                .background {
                    // Fade the transcript out under the composer.
                    LinearGradient(stops: [.init(color: Palette.canvas.opacity(0), location: 0), .init(color: Palette.canvas.opacity(0.92), location: 0.35)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background {
            ZStack {
                Velvet()
                Fireflies(count: 6, warm: 0.4, seed: UInt64(abs(session.id.hashValue % 997)) + 1, clear: Layout.column + 2 * Layout.gutter)
            }
        }
        .navigationTitle(session.isSubagent ? (session.name ?? "Subagent") : session.title)
        #if os(macOS)
        // The header already shows the title.
        .toolbar(removing: .title)
        #else
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PhoneSessionToolbar(store: store, session: session, rename: { renaming = session }, showJobs: { showingJobs = true },
                                                  restartKernel: { restartingKernel = true }) }
        .modifier(SoftTopEdge())
        .sheet(isPresented: $showingJobs) { PhoneBackgroundCommands(store: store, session: session) }
        .sheet(isPresented: $showingSubagents) { PhoneSubagentList(store: store, parentId: session.id) }
        #endif
        .renameSession($renaming, store: store)
        .task(id: "\(session.id)-\(session.backgroundJobs)") {
            guard hasJobs, session.backgroundJobs > 0 else { runningCommands = []; return }
            if let jobs = try? await store.listJobs(session.id) { runningCommands = jobs.filter(\.isRunning).map(\.command) }
        }
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
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                .scrollEdgeEffectStyle(.soft, for: .top)
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
            ToolbarItem(placement: .topBarTrailing) { stop }
            ToolbarItem(placement: .topBarTrailing) { menu }
        }
    }

    /// Stops the current run, while there is one.
    @ViewBuilder private var stop: some View {
        if session.status.isBusy, !session.readOnly {
            Button { store.abort() } label: {
                Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.amber)
                    .frame(width: 32, height: 32)
                    .background(Palette.amber.opacity(0.14), in: Circle())
                    .overlay(Circle().strokeBorder(Palette.amber.opacity(0.5)))
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
            .foregroundStyle(Palette.amber)
            .padding(.horizontal, 4)
            .frame(height: 32)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.25), value: session.backgroundJobs)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(session.backgroundJobs == 1 ? "1 background command running" : "\(session.backgroundJobs) background commands running")
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
                    Toggle("Auto-compaction", isOn: Binding(get: { session.autoCompaction }, set: { store.setAutoCompaction($0) }))
                }
                if session.agent == .prime {
                    Button("Restart Python Kernel…", systemImage: "arrow.clockwise", action: restartKernel)
                }
                if !(session.agent == .pi && session.isSubagent) {
                    Button("Background Commands", systemImage: "apple.terminal", action: showJobs)
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

/// The subagents as a few overlapping spirits and how many are working. Opens the full list.
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
                        Spirit(color: Palette.avatar(child.name ?? "s"), size: 18, working: child.status.isBusy)
                            .overlay(Circle().strokeBorder(Palette.canvas, lineWidth: 1.5))
                    }
                }
                Text(active > 0 ? "\(active)/\(children.count)" : "\(children.count)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(active > 0 ? Palette.amber : Palette.moon.opacity(0.7))
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
            .background(Velvet(base: Palette.sidebar).ignoresSafeArea())
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
                Spirit(color: Palette.avatar(child.name ?? "s"), size: 30, working: child.status.isBusy)
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
                    Text(child.isActive ? (child.activityText ?? "working").capitalized : child.status.rawValue.capitalized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(child.isActive ? Palette.amber : child.status == .error ? Palette.danger : Palette.moon.opacity(0.5))
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
            Image(systemName: "cube.transparent").font(.system(size: size - 1.5, weight: .semibold)).foregroundStyle(Palette.amber.opacity(0.9))
            Text(model.name).font(.system(size: size, weight: .medium)).foregroundStyle(Palette.moon.opacity(0.85)).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Palette.amber.opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.amber.opacity(0.25)))
        .fixedSize()
        .accessibilityLabel("Model \(model.name)")
    }
}

/// The subagents as overlapping spirits and a count; the menu lists each with its status and opens it.
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
                        Text([child.isActive ? (child.activityText ?? "working").capitalized : child.status.rawValue.capitalized, child.model?.name]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                HStack(spacing: -6) {
                    ForEach(children.prefix(4)) { child in
                        Spirit(color: Palette.avatar(child.name ?? "s"), size: 20, working: child.status.isBusy)
                            .overlay(Circle().strokeBorder(Palette.surface, lineWidth: 1.5))
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                Text(active > 0 ? "\(active)/\(children.count) working" : children.count == 1 ? "1 subagent" : "\(children.count) subagents")
                    .font(.system(size: 12.5))
                    .foregroundStyle(active > 0 ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
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
                    if session.isSubagent { Spirit(color: Palette.avatar(session.name ?? "s"), size: 22, working: session.status.isBusy) }
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
                Label(session.folderName, systemImage: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(session.cwd)
                    .contextMenu { Button("Copy Path") { Clipboard.copy(session.cwd) } }
                    .layoutPriority(-1)
            }

            Spacer(minLength: 8)

            let children = store.children(of: session.id)
            if !children.isEmpty { SubagentMenu(store: store, children: children) }

            // The composer shows the context gauge; read-only sessions have none.
            if session.readOnly || session.status == .stopped, let context = session.context { ContextGauge(context: context) }
            // Pi subagents run in the parent's process; their commands are the parent's.
            if !(session.agent == .pi && session.isSubagent) { BackgroundCommandsButton(store: store, session: session) }
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
                    Toggle("Auto-compaction", isOn: Binding(get: { session.autoCompaction }, set: { store.setAutoCompaction($0) }))
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
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background {
            LinearGradient(colors: [Palette.surface.opacity(0.9), Palette.surface.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Palette.border.opacity(0.2), Palette.rail.opacity(0.9), Palette.border.opacity(0.2)], startPoint: .leading, endPoint: .trailing)
                        .frame(height: 1)
                }
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                .ignoresSafeArea(edges: .top)
        }
        #if os(macOS)
        // Stands in for the title bar: drag it to move the window.
        .gesture(WindowDragGesture())
        #endif
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
                .foregroundStyle(session.status.isBusy ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                .shimmer(session.status.isBusy)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: session.status)
        .accessibilityElement(children: .combine)
    }

    // A Prime agent keeps going while its subagents and background jobs run, so say so next to "idle".
    private var text: String {
        var parts = [session.status == .running ? "working" : session.status.rawValue]
        if !session.status.isBusy, session.backgroundJobs > 0, let jobs = session.activityText { parts.append(jobs) }
        if activeSubagents > 0 { parts.append(activeSubagents == 1 ? "1 subagent at work" : "\(activeSubagents) subagents at work") }
        return parts.joined(separator: " · ")
    }
}

/// A ring with the share of the context window in use: moonlight, warming to amber, then red near the limit.
struct ContextGauge: View {
    let context: ContextUsage

    var body: some View {
        let fraction = min(1, max(0, (context.percent ?? 0) / 100))
        let tint: Color = fraction > 0.9 ? Palette.danger : fraction > 0.7 ? Palette.amber : Palette.ice
        HStack(spacing: 7) {
            ZStack {
                Circle().stroke(Palette.border, lineWidth: 2.5)
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
                    LazyVStack(spacing: 2) {
                        ForEach(filtered, id: \.key) { model in
                            Button {
                                store.setModel(model)
                                done()
                            } label: {
                                let selected = model.key == current?.key
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name).foregroundStyle(Palette.moon)
                                        Text(model.key).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.reasoning { Image(systemName: "brain").foregroundStyle(.tertiary).help("Reasoning") }
                                    if selected { Image(systemName: "checkmark").foregroundStyle(Palette.amber) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(selected ? Palette.amber.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Palette.amber.opacity(0.45) : .clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
            }
        }
        .frame(width: 360, height: 420)
        .background(Velvet(base: Palette.surface))
        .task { await store.loadModels() }
    }

    private var filtered: [ModelInfo] { ModelInfo.newestFirst(store.models, matching: query) }
}

/// The composer, or why there isn't one.
struct ComposerArea: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        if session.readOnly {
            Label(session.isSubagent ? "Pi subagents are read-only. Steer the parent instead." : "This session is read-only.",
                  systemImage: "eye")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .card(radius: 16)
        } else if session.status == .stopped {
            HStack {
                Spirit(color: Palette.agent(session.agent), size: 22, asleep: true)
                Text("This session is stopped.").foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { store.resume() }.buttonStyle(AmberButton())
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
    @FocusState private var focused: Bool
    @State private var showModels = false
    /// Bumped on each send, to kick the button.
    @State private var sent = 0

    private var text: Binding<String> {
        Binding(get: { store.drafts[session.id] ?? "" }, set: { store.setDraft($0, for: session.id) })
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
            if !session.queue.forReader.isEmpty {
                QueuedMessages(queue: session.queue.forReader)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if busy {
                WorkingStrip(store: store, session: session)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .bottom, spacing: 8) {
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

                if busy {
                    Button(action: queueFollowUp) {
                        Image(systemName: "text.append")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.moon)
                            .frame(width: 34, height: 34)
                            .card(radius: 17, fill: Palette.raised)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)
                    .help("Queue: send after the agent finishes")
                    .transition(.scale.combined(with: .opacity))

                    Button(action: send) {
                        Label("Steer", systemImage: "arrow.up.right")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.amber)
                            .padding(.horizontal, 14).frame(height: 34)
                            .background(Palette.amber.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.amber.opacity(trimmed.isEmpty ? 0.3 : 0.75)))
                            .glow(radius: 8, on: !trimmed.isEmpty)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.6 : 1)
                    .help("Steer: deliver now, while the agent works")
                    .transition(.scale.combined(with: .opacity))

                    Button { store.abort() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.moon)
                            .padding(.horizontal, 14).frame(height: 34)
                            .card(radius: 17, fill: Palette.raised)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop the current run (⌘.)")
                    .transition(.scale.combined(with: .opacity))
                } else {
                    SendButton(enabled: !trimmed.isEmpty, kick: sent, action: send)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Palette.surface.opacity(0.95)))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(focused || busy ? Palette.ice.opacity(0.45) : Palette.border, lineWidth: 1)
            )
            .shadow(color: focused ? Palette.ice.opacity(0.12) : .black.opacity(0.3), radius: focused ? 16 : 14, y: focused ? 0 : 6)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }

            HStack(spacing: 8) {
                Button { showModels = true } label: {
                    ChipLabel(text: session.model?.name ?? "No model", menu: true) {
                        Image(systemName: "cube.transparent").foregroundStyle(Palette.amber.opacity(0.9))
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
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: busy)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.queue.forReader.steering.count + session.queue.forReader.followUp.count)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: session.goal?.objective)
    }

    /// The effort level's position, 0...1, for the bars.
    private var effortLevel: Double {
        let levels = session.thinkingLevels
        guard let current = session.thinkingLevel, let index = levels.firstIndex(of: current), levels.count > 1 else { return 0.5 }
        return Double(index) / Double(levels.count - 1)
    }

    private var trimmed: String { text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var placeholder: String {
        #if os(macOS)
        if session.status.isBusy { return "Steer \(session.agent.displayName)…" }
        #endif
        return session.isSubagent ? "Message this subagent directly…" : "Message \(session.agent.displayName)…"
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        store.send(trimmed)
        text.wrappedValue = ""
        sent += 1
        #if os(iOS)
        // Sent: back to reading. The Mac keeps the focus for the next message.
        focused = false
        #endif
    }

    private func queueFollowUp() {
        guard !trimmed.isEmpty else { return }
        store.followUp(trimmed)
        text.wrappedValue = ""
    }
}

/// The round amber send button. It lights up when there's something to send, and kicks up when it goes.
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
                    Circle().fill(enabled ? AnyShapeStyle(Palette.amber.gradient) : AnyShapeStyle(Palette.raised))
                    Circle().fill(LinearGradient(colors: [Color.white.opacity(enabled ? 0.35 : 0.05), .clear], startPoint: .top, endPoint: .center))
                }
                .overlay(Circle().strokeBorder(enabled ? Color.clear : Palette.border))
                .glow(radius: lift ? 18 : 10, on: enabled)
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

/// Signal bars for the reasoning effort; the lit ones glow amber.
struct EffortBars: View {
    let level: Double

    var body: some View {
        let lit = Int((level * 3).rounded()) + 1
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < lit ? Palette.amber : Palette.rail)
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
        .card(radius: 15, fill: Palette.surface.opacity(0.85))
        .contentShape(Capsule())
    }
}

/// The goal the agent keeps working toward across turns: what it is, how far it has gone, and a way to drop it.
struct GoalCard: View {
    let goal: Goal
    let cancel: () -> Void
    @State private var expanded = false
    @State private var confirming = false
    /// The objective a cancel was sent for, until the goal goes away (a running turn takes it at its next step).
    @State private var cancelling: String?

    private var tint: Color { goal.status == "active" ? Palette.periwinkle : Palette.amber }

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
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.amber.opacity(0.8))
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
                    Text(summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.amber)
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
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.amber.opacity(0.8))
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
            .foregroundStyle(Palette.amber)
            .frame(width: 22, height: 22)
            .background(Palette.amber.opacity(0.14), in: Circle())
    }
}

/// While the agent works: its spirit, what it's doing now, and for how long, along a firefly trail.
struct WorkingStrip: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            Spirit(color: Palette.agent(session.agent), size: 20, working: true)
            Text(session.status == .compacting ? "Compacting context" : "\(session.agent.displayName) is working")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.moon)
                .fixedSize()
            FireflyTrail()
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

/// A faint line with a firefly gliding along it, back and forth.
struct FireflyTrail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TrailField(still: reduceMotion)
            .accessibilityHidden(true)
    }
}
