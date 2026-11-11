// The Mac's header over a session: where it is, how it is doing, its subagents, and the menu of what can be done to it.
import SwiftUI

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
                StatusLabel(session: session)
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
                    if session.startsNewSessionInPlace {
                        Button("New Session (same agent)") { store.newSession() }
                    }
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
        // Keyed on the session too: the header stays the same view across sessions, and what it found for one is
        // never shown for the next. Cleared at once, and set to what was found, no branch included.
        .task(id: "\(session.id)\n\(session.cwd)") {
            branch = nil
            guard let env = store.environment(of: session.id)?.id else { return }
            let found = (try? await store.gitBranch(in: env, of: session.cwd)) ?? nil
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { branch = found }
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
            let ended = children.first?.parentId.map { store.endedChildren(of: $0) } ?? []
            if !ended.isEmpty {
                Section("Ended") {
                    ForEach(ended) { child in Button(child.name ?? child.title) {}.disabled(true) }
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

struct StatusLabel: View {
    let session: SessionSummary

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

    // An agent keeps going while its background commands run, so say so next to "idle".
    private var text: String {
        var parts = [session.status == .running ? "working" : session.status.rawValue]
        if !session.status.isBusy, session.backgroundJobs > 0, let jobs = session.activityText() { parts.append(jobs) }
        return parts.joined(separator: " · ")
    }
}
