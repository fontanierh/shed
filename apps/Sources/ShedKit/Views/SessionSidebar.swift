// The session tree: root sessions with their subagents folded below, plus every subagent at work at a glance.
import SwiftUI

struct SessionSidebar: View {
    let store: SessionStore
    var newSession: () -> Void = {}
    /// The computers Shed controls.
    var openSettings: () -> Void = {}
    @State private var query = ""
    /// Sessions whose subagents are shown.
    @State private var expanded: Set<String> = []
    @State private var renaming: SessionSummary?
    @FocusState private var searching: Bool
    @Namespace private var selection
    /// Off until the first session list has been drawn: the sidebar appears as it is, without its rows sliding in.
    @State private var settled = false

    /// The one spring every change in the list moves with.
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.86)

    var body: some View {
        list.renameSession($renaming, store: store)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Sprout(size: 26)
                Text("Shed").font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Palette.moon)
                Spacer()
                if store.sessions.values.contains(where: \.hasSites) { AllSitesButton(store: store) }
                Button(action: openSettings) {
                    Image(systemName: "network").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",")
                .help("Computers")
            }
            .padding(.leading, 18).padding(.trailing, 10)
            #if os(macOS)
            // Below the window's traffic lights.
            .padding(.top, 34)
            // With them, where the title bar would be: drag it to move the window.
            .background { WindowDragArea().ignoresSafeArea(edges: .top) }
            #else
            .padding(.top, 8)
            #endif
            .padding(.bottom, 14)

            searchField.padding(.horizontal, 12).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !query.isEmpty {
                        SectionTitle("Results")
                        ForEach(matches) { session in row(session, depth: 0) }
                    } else {
                        let active = store.activeSubagents
                        if !active.isEmpty {
                            SectionTitle("At work · \(active.count)").transition(.opacity)
                            ForEach(active) { sub in
                                // Also under its parent when that is open: the lantern stays there, so only one row carries it.
                                SidebarRow(session: sub, depth: 0, selected: store.selectedId == sub.id, selection: selection,
                                           lanternSource: !shownInTree(sub),
                                           detail: [sub.activityText(), store.parent(of: sub).map { "in \($0.title)" },
                                                    store.environments.count > 1 ? store.environment(of: sub.id)?.name : nil].compactMap { $0 }.joined(separator: " · "))
                                    .onTapGesture { store.select(sub.id) }
                                    .accessibilityAction { store.select(sub.id) }
                                    .transition(Self.rowTransition)
                            }
                            Spacer().frame(height: 10).transition(.opacity)
                        }
                        if store.environments.count > 1 {
                            // A section per computer, in the order they were added.
                            ForEach(store.environments) { env in
                                EnvironmentTitle(env: env, state: store.connection(of: env.id))
                                let roots = store.tree(in: env.id)
                                if roots.isEmpty {
                                    Text(store.connection(of: env.id) == .connected ? "No sessions" : "Not connected")
                                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                                        .contentTransition(.identity)
                                        .padding(.horizontal, 8).padding(.bottom, 4)
                                        .transition(.opacity)
                                }
                                ForEach(roots) { node in tree(node, depth: 0) }
                                Spacer().frame(height: 8)
                            }
                        } else {
                            SectionTitle("Sessions")
                            ForEach(store.tree) { node in tree(node, depth: 0) }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
                // Everything that moves rows or changes their shape, in one transaction: rows joining or leaving a
                // section, subagents opening, the lantern, status icons. Not the first list, which just appears.
                .animation(settled ? Self.spring : nil, value: layout)
            }
            .scrollIndicators(.never)
            .onAppear { if !store.sessions.isEmpty { settle() } }
            .onChange(of: store.snapshots) { settle() }
            .overlay {
                if store.sessions.isEmpty && store.connection == .connected { EmptySidebar() }
            }

            NewSessionButton(action: newSession)
                .disabled(store.connection != .connected)
                .padding(12)
        }
        .background {
            ZStack(alignment: .bottomLeading) {
                Velvet(base: Palette.sidebar, light: .top)
                Sprig()
                    .fill(Palette.ice.opacity(0.07))
                    .frame(width: 110, height: 170)
                    .offset(x: -8, y: -64)
                Fireflies(count: 4, warm: 0.5, seed: 7)
            }
            .ignoresSafeArea()
        }
        #if os(macOS)
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.border.opacity(0.7)).frame(width: 1).ignoresSafeArea() }
        #endif
        .background {
            // ⌘K focuses search.
            Button("") { searching = true }.keyboardShortcut("k").hidden()
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searching)
                .onKeyPress(.escape) { query = ""; searching = false; return .handled }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .card(radius: 9, fill: Palette.sunken.opacity(0.7), border: searching ? Palette.ice.opacity(0.45) : Palette.border)
        .animation(.easeOut(duration: 0.15), value: searching)
    }

    /// One tick after the first list is drawn, so that list itself is not animated.
    private func settle() {
        guard !settled else { return }
        Task { settled = true }
    }

    /// What the list's shape depends on: which rows are shown where, the selection, and each row's state.
    private var layout: [String] {
        func state(_ s: SessionSummary) -> String {
            "\(s.id) \(s.status.rawValue) \(s.backgroundJobs > 0) \(s.model?.key ?? "")"
        }
        var out = [store.selectedId ?? "", "\(store.environments.map(\.id))"]
        out += store.environments.map { "\($0.id) \(store.connection(of: $0.id) == .connected)" }
        out += store.activeSubagents.map { "at work " + state($0) }
        func walk(_ nodes: [SessionNode]) {
            for node in nodes {
                out.append(state(node.session) + " \(node.children?.count ?? 0) \(store.activeDescendants(of: node.id))")
                if let children = node.children, expanded.contains(node.id) { walk(children) }
            }
        }
        walk(store.tree)
        return out
    }

    /// Whether a session's row is in its computer's tree right now: every session above it is open.
    private func shownInTree(_ session: SessionSummary) -> Bool {
        var parent = store.parent(of: session)
        while let p = parent {
            if !expanded.contains(p.id) { return false }
            parent = store.parent(of: p)
        }
        return true
    }

    /// Rows fade and grow in place; a `.move` edge would slide them in from the top of the whole list.
    static let rowTransition = AnyTransition.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                                                       removal: .opacity.combined(with: .scale(scale: 0.96)))

    private func tree(_ node: SessionNode, depth: Int) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 2) {
            row(node.session, depth: depth, children: node.children?.count ?? 0)
            if let children = node.children, expanded.contains(node.id) {
                ForEach(children) { child in tree(child, depth: depth + 1) }
            }
        })
    }

    private func row(_ session: SessionSummary, depth: Int, children: Int = 0) -> some View {
        SidebarRow(session: session, depth: depth, selected: store.selectedId == session.id, selection: selection,
                   activeBelow: store.activeDescendants(of: session.id), children: children,
                   open: Binding(get: { expanded.contains(session.id) }, set: { if $0 { expanded.insert(session.id) } else { expanded.remove(session.id) } }))
            .onTapGesture { store.select(session.id) }
            // The row says it is a button: VoiceOver and other assistive apps press it rather than tap it.
            .accessibilityAction { store.select(session.id) }
            .contextMenu {
                if !session.isSubagent && !session.readOnly {
                    Button("Rename…") { renaming = session }
                }
                Button("Copy Path") { Clipboard.copy(session.cwd) }
                if !session.isSubagent {
                    Divider()
                    Button("Delete", role: .destructive) { store.delete(session.id) }
                }
            }
            .transition(Self.rowTransition)
    }

    private var matches: [SessionSummary] {
        let q = query.lowercased()
        return store.sessions.values
            .filter { [$0.title, $0.name ?? "", $0.cwd].contains { $0.lowercased().contains(q) } }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

/// A computer's section in the list: its name, and a dot unless it is connected.
private struct EnvironmentTitle: View {
    let env: BridgeEnvironment
    let state: BridgeClient.State

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: env.isLocal ? "laptopcomputer" : "network").font(.system(size: 10.5, weight: .medium))
            Text(env.name).font(.system(size: 11.5, weight: .medium))
            switch state {
            case .connected: EmptyView()
            case .connecting: Circle().fill(Palette.amber).frame(width: 6, height: 6)
            case .disconnected: Circle().fill(Palette.danger).frame(width: 6, height: 6)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 4).padding(.bottom, 4)
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .contentTransition(.numericText())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4).padding(.bottom, 4)
    }
}

/// A session: its spirit, title, what it's doing, and its state. The selected row carries the lantern.
struct SidebarRow: View {
    let session: SessionSummary
    let depth: Int
    let selected: Bool
    let selection: Namespace.ID
    /// Off for a second row of the same session: only one row moves the lantern, the other is lit in place.
    var lanternSource = true
    var activeBelow = 0
    var children = 0
    var open: Binding<Bool>? = nil
    var detail: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if children > 0, let open {
                Button { open.wrappedValue.toggle() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                        .frame(width: 10, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open.wrappedValue ? "Hide subagents" : "Show subagents")
                .transition(.opacity)
            } else {
                Spacer().frame(width: 10)
            }
            Spirit(color: session.isSubagent ? Palette.avatar(session.name ?? "s") : Palette.agent(session.agent),
                   size: depth > 0 ? 22 : 28, working: session.status.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.isSubagent ? (session.name ?? "subagent") : session.title)
                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                        .foregroundStyle(Palette.moon)
                        .lineLimit(1)
                        // Renamed or selected, the title changes at once rather than smearing between two widths.
                        .contentTransition(.identity)
                    // Subagents often run on other models than their parent: say which.
                    if session.isSubagent, let model = session.model { ModelTag(model: model, size: 10).transition(.opacity) }
                }
                // Ticks while a command is waited on, to keep its running time current.
                TimelineView(.periodic(from: .now, by: session.waitingOn == nil ? 3600 : 30)) { context in
                    Text(detail ?? secondary(at: context.date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.status.isBusy ? AnyShapeStyle(Palette.amber.opacity(0.9)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .contentTransition(.identity)
                }
            }
            Spacer(minLength: 4)
            if activeBelow > 0 {
                Text("\(activeBelow)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Palette.amber.opacity(0.16), in: Circle())
                    .foregroundStyle(Palette.amber)
                    .contentTransition(.numericText())
                    .help("\(activeBelow) subagent(s) at work")
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            ActivityIcon(session: session)
        }
        .padding(.leading, 2 + CGFloat(depth) * 16)
        .padding(.trailing, 10)
        .padding(.vertical, depth > 0 ? 5 : 7)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Palette.raised)
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [Palette.amber.opacity(0.75), Palette.amber.opacity(0.35)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                    .shadow(color: Palette.amber.opacity(0.18), radius: 10)
                    // A second lit row matches nothing, rather than a second source fighting the first over the lantern.
                    .matchedGeometryEffect(id: lanternSource ? "lantern" : "lantern " + session.id, in: selection)
            } else if hovering {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.raised.opacity(0.55))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func secondary(at now: Date) -> String {
        if let activity = session.activityText(at: now) { return activity.sentenceCased }
        if session.isSubagent { return session.title }
        return "\(session.agent.displayName) · \(session.folderName)"
    }
}

struct NewSessionButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.canvas)
                    .frame(width: 24, height: 24)
                    .background(Palette.amber.gradient, in: Circle())
                    .glow(radius: hovering ? 10 : 5)
                    .rotationEffect(.degrees(hovering ? 90 : 0))
                Text("New Session").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.moon)
                Spacer()
                #if os(macOS)
                Text("⌘N").font(.system(size: 11)).foregroundStyle(.tertiary)
                #endif
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .card(radius: 12, fill: hovering ? Palette.raised : Palette.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut("n")
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
    }
}

/// Buttons sink a little when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct EmptySidebar: View {
    var body: some View {
        VStack(spacing: 10) {
            Spirit(color: Palette.ice, size: 48, asleep: true)
                .overlay(alignment: .topTrailing) {
                    Text("z").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Palette.periwinkle)
                        .offset(x: 12, y: -14)
                }
            Text("No sessions yet").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.moon)
            Text("Start one with New Session.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(.bottom, 60)
    }
}

/// An ember that breathes while working, an hourglass while waiting on background commands, otherwise a status dot.
struct ActivityIcon: View {
    let session: SessionSummary

    var body: some View {
        if session.status.isBusy {
            Ember(color: session.status == .compacting ? Palette.lilac : Palette.amber)
                .transition(.opacity)
        } else if session.backgroundJobs > 0 {
            Image(systemName: "hourglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .frame(width: 12)
                .help("\(session.backgroundJobs) background command(s) running; it wakes when they finish")
                .transition(.opacity)
        } else {
            StatusDot(status: session.status).transition(.opacity)
        }
    }
}

/// A live dot: a warm core with a ring that keeps rippling out.
struct Ember: View {
    var color: Color = Palette.amber
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).shadow(color: color.opacity(0.9), radius: 4)
            .background {
                // The ripple runs in Core Animation: no redraw per frame for as long as the agent works.
                RippleField(color: color, diameter: size, still: reduceMotion)
                    .frame(width: size * 3, height: size * 3)
                    .allowsHitTesting(false)
            }
            .frame(width: 12, height: 12)
            .accessibilityLabel("Working")
    }
}

extension SessionSummary {
    /// "working", "waiting on git lfs pull · 14m", or nil when finished.
    func activityText(at now: Date = .now) -> String? {
        if let stuck, stuck.isToolCall || !status.isBusy {
            let started = stuck.startedAt.map { " · " + Format.elapsed(ms: now.timeIntervalSince1970 * 1000 - $0) } ?? ""
            return (stuck.isToolCall ? "tool call looks stuck" : "looks stuck on " + ToolDescription.shortCommand(stuck.command)) + started
        }
        if status.isBusy { return status == .compacting ? "compacting" : "working" }
        guard backgroundJobs > 0 else { return nil }
        guard let waitingOn else { return backgroundJobs == 1 ? "waiting on 1 command" : "waiting on \(backgroundJobs) commands" }
        var text = "waiting on " + ToolDescription.shortCommand(waitingOn.command)
        if backgroundJobs > 1 { text += " + \(backgroundJobs - 1) more" }
        if let started = waitingOn.startedAt {
            text += " · " + Format.elapsed(ms: now.timeIntervalSince1970 * 1000 - started)
        }
        return text
    }
}

extension String {
    /// "waiting on git lfs pull" as "Waiting on git lfs pull", where `capitalized` would capitalize every word.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

struct StatusDot: View {
    let status: SessionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.6), radius: 3)
            .frame(width: 12)
            .help(status.rawValue.capitalized)
    }

    private var color: Color {
        switch status {
        case .running, .starting: Palette.amber
        case .compacting: Palette.lilac
        case .idle: Palette.ice
        case .done: Palette.periwinkle.opacity(0.6)
        case .stopped: Color.secondary.opacity(0.6)
        case .error: Palette.danger
        }
    }
}

struct AgentBadge: View {
    let agent: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            Spirit(color: Palette.agent(agent), size: 16)
            Text(agent.displayName).font(.system(size: 12.5, weight: .medium))
        }
        .padding(.leading, 4).padding(.trailing, 11).frame(height: 26)
        .background(Palette.agent(agent).opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.agent(agent).opacity(0.32)))
        .foregroundStyle(Palette.agent(agent))
    }
}
