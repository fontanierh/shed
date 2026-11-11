// The iPhone's navigation bar over a session, and the list of its subagents the bar opens.
import SwiftUI

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
                    if session.can.autoCompactionSwitch {
                        Toggle("Auto-compaction", isOn: Binding(get: { session.autoCompaction }, set: { store.setAutoCompaction($0) }))
                    }
                }
                if session.can.restartKernel {
                    Button("Restart Python Kernel…", systemImage: "arrow.clockwise", action: restartKernel)
                }
                if session.can.backgroundCommands {
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
        let ended = store.endedChildren(of: parentId)
        NavigationStack {
            List {
                if !working.isEmpty {
                    Section("Working") { ForEach(working) { row($0) } }
                }
                if !finished.isEmpty {
                    Section("Finished") { ForEach(finished) { row($0) } }
                }
                // Named still, with nowhere left to go.
                if !ended.isEmpty {
                    Section("Ended") { ForEach(ended) { row($0, ended: true) } }
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

    private func row(_ child: SessionSummary, ended: Bool = false) -> some View {
        Button {
            dismiss()
            store.select(child.id)
        } label: {
            HStack(spacing: 12) {
                AgentMark(name: child.name ?? "s", size: 30, working: child.status.isBusy && !ended, asleep: ended)
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
                    if !ended {
                        Text(child.isActive ? (child.activityText() ?? "working").sentenceCased : child.status.rawValue.capitalized)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(child.isActive ? Palette.accent : child.status == .error ? Palette.danger : Palette.moon.opacity(0.5))
                    }
                    if child.cost > 0 {
                        Text(child.cost.formatted(.currency(code: "USD").precision(.fractionLength(2))))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(ended ? 0.5 : 1)
        }
        .disabled(ended)
        .listRowBackground(Palette.surface.opacity(0.6))
    }
}
#endif
