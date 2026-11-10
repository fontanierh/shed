// Starting a session: the computer, the agent, a folder on that computer, and the model and effort.
import SwiftUI

struct NewSessionSheet: View {
    let store: SessionStore
    /// What to send once the session starts, from the home page's composer.
    var initialMessage = ""
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newSession.agent") private var agent: AgentKind = .prime
    @AppStorage("newSession.environment") private var chosenEnv = ""
    /// The folder last started in, per environment, as "<environment>\t<path>" lines.
    @AppStorage("newSession.folders") private var lastFolders = ""
    /// The folder last started in before Shed knew several computers: the first environment's.
    @AppStorage("newSession.cwd") private var legacyCwd = ""
    @State private var cwd = ""
    @AppStorage("newSession.model") private var model = ""
    @AppStorage("newSession.thinking") private var thinking = ""
    @AppStorage("newSession.recentFolders") private var recentFolders = ""
    @AppStorage("newSession.recentModels") private var recentModels = ""
    @State private var creating = false
    /// Why the last Start failed, shown in the sheet until the choice changes.
    @State private var startError: String?

    /// The computer the session starts on: the one chosen last, while it is still there.
    private var env: String {
        store.environments.contains { $0.id == chosenEnv } ? chosenEnv : store.environments.first?.id ?? ""
    }

    /// Recent folders are "<environment>\t<path>" lines; older ones without an environment belong to the first.
    private func folders(_ lines: String) -> [(env: String, path: String)] {
        lines.split(separator: "\n").map { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : (store.environments.first?.id ?? "", parts[0])
        }
    }

    private var recents: [String] { folders(recentFolders).filter { $0.env == env }.map(\.path) }

    /// Whether the bridge refused a folder because it is gone.
    private static func isMissing(_ error: Error) -> Bool {
        error.localizedDescription.contains("No such file or directory")
    }

    /// Takes a folder that no longer exists out of the recent and last-used ones on this computer.
    private func forget(_ path: String, in env: String) {
        func line(_ entry: (env: String, path: String)) -> String { "\(entry.env)\t\(entry.path)" }
        recentFolders = folders(recentFolders).filter { $0.env != env || $0.path != path }.map(line).joined(separator: "\n")
        lastFolders = folders(lastFolders).filter { $0.env != env || $0.path != path }.map(line).joined(separator: "\n")
    }

    /// Recent folders deleted since are dropped, and so is a restored folder that went with them.
    private func pruneFolders() async {
        let env = env
        for path in Set(recents + [cwd]) where !path.isEmpty {
            do { _ = try await store.listDir(in: env, path) } catch let error where Self.isMissing(error) {
                forget(path, in: env)
                if cwd == path { cwd = "" }
            } catch {}
        }
    }

    private func restoreFolder() {
        let first = store.environments.first?.id
        cwd = folders(lastFolders).first { $0.env == env }?.path ?? (env == first ? legacyCwd : "")
    }

    @ViewBuilder private var environmentPicker: some View {
        if store.environments.count > 1 {
            #if os(macOS)
            GlassSegments(options: store.environments.map { ($0.id, $0.name) },
                          selection: Binding(get: { env }, set: { chosenEnv = $0 }))
                .fixedSize()
            #else
            Picker("Computer", selection: Binding(get: { env }, set: { chosenEnv = $0 })) {
                ForEach(store.environments) { e in Text(e.name).tag(e.id) }
            }
            .labelsHidden()
            #endif
        }
    }
    /// The models each agent last said it has on each computer, as "<environment>\t<agent>\t<provider/id>" lines: kept
    /// so the menu is full at once and a chosen model is recognised before the agent answers again.
    @AppStorage("newSession.agentModels") private var agentModels = ""

    private func listed(_ kind: AgentKind) -> [String] {
        let prefix = "\(env)\t\(kind.rawValue)\t"
        return agentModels.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Whether `kind` can start on `model` here: one it listed, or before it has said, one in its usual providers.
    private func fits(_ model: String, _ kind: AgentKind) -> Bool {
        let known = listed(kind)
        if !known.isEmpty { return known.contains(model) }
        return model.hasPrefix("deepseek") == (kind == .deepseek)
    }

    /// A model left from another agent, or another computer, would fail to start.
    private func fitModel() {
        if !model.isEmpty, !fits(model, agent) { model = "" }
    }

    /// Asks the computer which models the agent has, so every provider set up there is offered.
    private func loadModels() async {
        let (env, kind) = (env, agent)
        guard let models = try? await store.agentModels(in: env, kind), !models.isEmpty else { return }
        let prefix = "\(env)\t\(kind.rawValue)\t"
        let others = agentModels.split(separator: "\n").filter { !$0.hasPrefix(prefix) }.map(String.init)
        agentModels = (others + models.map { prefix + $0 }).joined(separator: "\n")
    }

    /// Recently used ones first, then the rest of what the agent listed.
    private var models: [String] {
        let recent = recentModels.split(separator: "\n").map(String.init).filter { fits($0, agent) }
        var all = listed(agent)
        if all.isEmpty {
            all = agent == .deepseek ? ["deepseek-official/deepseek-v4-pro", "deepseek-official/deepseek-v4-flash"] : ["openai/gpt-6.1-terra"]
        }
        return recent + all.filter { !recent.contains($0) }
    }

    /// The models past the recent ones, by provider, so a long list stays a short menu. Open Codex serves every
    /// provider under its own name, so its models group by the provider inside it.
    private var byProvider: [(provider: String, prefix: String, models: [String])] {
        let recent = Set(recentModels.split(separator: "\n").map(String.init))
        let rest = models.filter { !recent.contains($0) }
        var order: [String] = []
        var groups: [String: (prefix: String, models: [String])] = [:]
        for name in rest {
            let (provider, prefix) = Self.provider(of: name)
            if groups[provider] == nil { order.append(provider) }
            groups[provider, default: (prefix, [])].models.append(name)
        }
        return order.sorted(by: ModelInfo.groupOrder).map { ($0, groups[$0]?.prefix ?? "", groups[$0]?.models ?? []) }
    }

    /// A recent model's name in the menu: "gpt-6.1-sol · OpenAI API key".
    private static func label(_ name: String) -> String {
        let (group, prefix) = provider(of: name)
        return prefix.count < name.count ? "\(name.dropFirst(prefix.count)) · \(group)" : name
    }

    /// The menu a "provider/id" name goes in, and what it starts with there (dropped from its button).
    private static func provider(of name: String) -> (String, String) {
        let provider = String(name.split(separator: "/", maxSplits: 1).first ?? "")
        let group = ModelInfo.group(provider: provider, id: String(name.dropFirst(provider.count + 1)))
        return (group.label, provider + "/" + group.prefix)
    }

    var body: some View {
        Group {
            #if os(iOS)
            phone
            #else
            mac
            #endif
        }
        .onAppear {
            restoreFolder()
            if message.isEmpty { message = initialMessage }
            fitModel()
        }
        .onChange(of: env) { restoreFolder() }
        .onChange(of: agent) { fitModel() }
        .task(id: "\(env) \(agent.rawValue)") { await loadModels(); fitModel() }
        .task(id: env) { await pruneFolders() }
        .onChange(of: "\(env)\t\(agent.rawValue)\t\(cwd)\t\(model)") { startError = nil }
    }

    /// Why Start failed, in the sheet itself.
    @ViewBuilder private var startErrorBanner: some View {
        if let startError {
            Label(startError, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Palette.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .card(radius: 10, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.4))
        }
    }

    private var mac: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ShedMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New session").font(.system(size: 24, weight: .semibold)).foregroundStyle(Palette.moon)
                    Text(store.environments.count > 1 ? "Choose a computer, an agent and a folder to work in." : "Choose an agent and a folder to work in.")
                        .font(.system(size: 13.5)).foregroundStyle(.secondary)
                }
                Spacer()
                environmentPicker
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    AgentCard(kind: .prime, selected: agent == .prime,
                              detail: "Python REPL agent. Asynchronous subagents keep working in the background.") { agent = .prime }
                    AgentCard(kind: .pi, selected: agent == .pi,
                              detail: "Minimal coding agent with file and shell tools. Subagents run in sequence.") { agent = .pi }
                    AgentCard(kind: .deepseek, selected: agent == .deepseek,
                              detail: "DeepSeek Harness. Subagents and background commands on DeepSeek's models.") { agent = .deepseek }
                }

                section("Folder", note: "Double-click or › to open a folder") {
                    FolderBrowser(store: store, env: env, selection: $cwd, recents: recents)
                        .id(env)
                        .frame(height: 420)
                }

                HStack(alignment: .top, spacing: 20) {
                    section("Model") { modelField(height: 32) }
                    section("Reasoning effort") { effortPicker }
                }

                section("First message", note: "Optional") { messageField }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            startErrorBanner.padding(.horizontal, 32).padding(.bottom, 16)
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(cwd.isEmpty ? "No folder chosen" : Format.path(cwd))
                        .font(.callout)
                        .foregroundStyle(cwd.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .card(radius: 10, fill: Palette.sunken)
                .help(cwd)
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
                Button(action: start) {
                    Label(creating ? "Starting…" : "Start session", systemImage: "arrow.up")
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(cwd.isEmpty || creating)
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }
        .frame(width: 920)
        .background { Backdrop(beam: 0.4, base: Palette.sidebar, anchor: UnitPoint(x: 0.2, y: 0.95)) }
        .disabled(creating)
    }

    private func modelField(height: CGFloat) -> some View {
        HStack(spacing: 0) {
            TextField("Model", text: $model, prompt: Text("Agent default"))
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .padding(.leading, 10)
            Menu {
                Button("Agent default") { model = "" }
                Divider()
                let recent = models.filter { recentModels.split(separator: "\n").contains(Substring($0)) }
                ForEach(recent, id: \.self) { name in Button(Self.label(name)) { model = name } }
                if !recent.isEmpty { Divider() }
                let groups = byProvider
                if groups.count > 1 && models.count > 12 {
                    ForEach(groups, id: \.provider) { group in
                        Menu(group.provider) {
                            ForEach(group.models, id: \.self) { name in Button(name.dropFirst(group.prefix.count)) { model = name } }
                        }
                    }
                } else {
                    ForEach(groups.flatMap(\.models), id: \.self) { name in Button(name) { model = name } }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: height, height: height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .frame(height: height)
        .card(radius: 10, fill: Palette.sunken)
    }

    /// What the agent gets as soon as it starts; empty starts it waiting.
    private var messageField: some View {
        TextField("First message", text: $message, prompt: Text("What should \(agent.displayName) do?"), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...6)
            .font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .card(radius: 12, fill: Palette.sunken)
    }

    private var effortPicker: some View {
        GlassSegments(options: [("", "Default")] + ["low", "medium", "high", "xhigh"].map { ($0, $0 == "xhigh" ? "Max" : $0.capitalized) },
                      selection: $thinking, height: 32)
    }

    #if os(iOS)
    /// One column: the agents stacked, the folder on its own drill-down screen, Start in the toolbar.
    private var phone: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if store.environments.count > 1 {
                        section("Computer") {
                            environmentPicker
                                .pickerStyle(.menu)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).frame(height: 44)
                                .card(radius: 12, fill: Palette.sunken)
                        }
                    }
                    VStack(spacing: 10) {
                        AgentCard(kind: .prime, selected: agent == .prime,
                                  detail: "Python REPL agent. Asynchronous subagents keep working in the background.") { agent = .prime }
                        AgentCard(kind: .pi, selected: agent == .pi,
                                  detail: "Minimal coding agent with file and shell tools. Subagents run in sequence.") { agent = .pi }
                        AgentCard(kind: .deepseek, selected: agent == .deepseek,
                                  detail: "DeepSeek Harness. Subagents and background commands on DeepSeek's models.") { agent = .deepseek }
                    }

                    section("Folder") {
                        NavigationLink {
                            PhoneFolderPicker(store: store, env: env, selection: $cwd, recents: recents,
                                              start: cwd.isEmpty ? nil : (cwd as NSString).deletingLastPathComponent)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill").foregroundStyle(Palette.ice)
                                Text(cwd.isEmpty ? "Choose a folder" : Format.path(cwd))
                                    .foregroundStyle(cwd.isEmpty ? .secondary : .primary)
                                    .lineLimit(1).truncationMode(.head)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                            .font(.system(size: 15))
                            .padding(.horizontal, 14).frame(height: 48)
                            .card(radius: 12, fill: Palette.sunken)
                        }
                        .buttonStyle(.plain)
                    }

                    section("Model") { modelField(height: 44) }
                    section("Reasoning effort") { effortPicker }
                    section("First message") { messageField }
                    startErrorBanner
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { Backdrop(beam: 0.4, base: Palette.sidebar, anchor: UnitPoint(x: 0.1, y: 0.98)) }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Starting…" : "Start", action: start)
                        .fontWeight(.semibold)
                        .disabled(cwd.isEmpty || creating)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .disabled(creating)
    }
    #endif

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.moon)
                Spacer()
                if let note { Text(note).font(.caption).foregroundStyle(.tertiary) }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start() {
        creating = true
        let folder = cwd
        let chosenModel = model
        let env = env
        let message = message
        startError = nil
        Task {
            do {
                try await store.createSession(in: env, agent: agent, cwd: folder, model: chosenModel, thinking: thinking,
                                              firstMessage: message.trimmingCharacters(in: .whitespacesAndNewlines))
                creating = false
                func line(_ entry: (env: String, path: String)) -> String { "\(entry.env)\t\(entry.path)" }
                let others = folders(recentFolders).filter { $0.env != env }
                let mine = ([folder] + recents.filter { $0 != folder }).prefix(6).map { (env: env, path: $0) }
                recentFolders = (mine + others).map(line).joined(separator: "\n")
                lastFolders = ([(env: env, path: folder)] + folders(lastFolders).filter { $0.env != env }).map(line).joined(separator: "\n")
                if !chosenModel.isEmpty {
                    let saved = recentModels.split(separator: "\n").map(String.init)
                    recentModels = ([chosenModel] + saved.filter { $0 != chosenModel }).prefix(5).joined(separator: "\n")
                }
                dismiss()
            } catch {
                creating = false
                if Self.isMissing(error) {
                    forget(folder, in: env)
                    startError = "\(Format.path(folder)) no longer exists on this computer. Choose another folder."
                } else {
                    startError = error.localizedDescription
                }
            }
        }
    }
}

/// An agent to pick: its mark, what it is, and a blue edge and glow when chosen. The chosen mark hops.
struct AgentCard: View {
    let kind: AgentKind
    let selected: Bool
    let detail: String
    let action: () -> Void
    @State private var hovering = false
    @State private var hop = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                AgentMark(agent: kind, size: 44)
                    .offset(y: hop ? -8 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .prime ? "Prime Agent" : kind.displayName).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.moon)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(selected ? Palette.accent : Palette.rail)
                    .frame(width: 10, height: 10)
                    .shadow(color: selected ? Palette.accent : .clear, radius: 5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 16, fill: selected ? Palette.raised : Palette.surface.opacity(hovering ? 0.95 : 0.75),
                  border: selected ? Palette.accent.opacity(0.75) : Palette.border)
            .glow(radius: 14, on: selected)
            .scaleEffect(selected ? 1 : 0.985)
            .opacity(selected ? 1 : 0.8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: selected)
        .onChange(of: selected) { _, now in
            guard now else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { hop = true }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.45)) { hop = false }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Browses folders on the bridge's machine: places on the left, the current folder's subfolders on the right.
/// Selecting a row picks it; double-click, Return or › opens it.
struct FolderBrowser: View {
    let store: SessionStore
    let env: String
    @Binding var selection: String
    let recents: [String]

    @State private var listing: DirListing?
    @State private var error: String?
    @State private var filter = ""
    @State private var showHidden = false
    @State private var back: [String] = []
    @State private var forward: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                places
                    .frame(width: 200)
                Divider()
                folders
            }
        }
        .background(Palette.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task {
            // Open where the last session started, so the previous choice is in view.
            load(selection.isEmpty ? nil : (selection as NSString).deletingLastPathComponent, record: false)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("chevron.left", help: "Back", disabled: back.isEmpty) {
                guard let previous = back.popLast(), let current = listing?.path else { return }
                forward.append(current)
                load(previous, record: false)
            }
            toolButton("chevron.right", help: "Forward", disabled: forward.isEmpty) {
                guard let next = forward.popLast(), let current = listing?.path else { return }
                back.append(current)
                load(next, record: false)
            }
            toolButton("arrow.up", help: "Enclosing folder", disabled: listing?.parent == nil) { load(listing?.parent) }
            toolButton("house", help: "Home folder", disabled: false) { load(nil) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            breadcrumb
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField("Filter", text: $filter, prompt: Text("Filter folders"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8).frame(width: 200, height: 28)
            .card(radius: 8, fill: Palette.sunken)
        }
        .padding(.horizontal, 8).frame(height: 42)
    }

    private func toolButton(_ icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Palette.sunken.opacity(disabled ? 0 : 1), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? .tertiary : .secondary)
        .disabled(disabled)
        .help(help)
    }

    private var breadcrumb: some View {
        // The root, then the last three folders: the current one always shows.
        let all = crumbs
        let shown = all.count > 4 ? [all[0]] + [("…", "")] + all.suffix(3) : all
        return HStack(spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }
                if crumb.path.isEmpty {
                    Text(crumb.name).foregroundStyle(.tertiary)
                } else {
                    Button { load(crumb.path) } label: {
                        Text(Self.shorten(crumb.name))
                            .font(.system(size: 12.5, weight: index == shown.count - 1 ? .semibold : .regular))
                            .foregroundStyle(index == shown.count - 1 ? .primary : .secondary)
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help(crumb.path)
                }
            }
        }
    }

    /// Long folder names keep their start and end: "c8bc66…95a381".
    private static func shorten(_ name: String) -> String {
        name.count <= 18 ? name : name.prefix(8) + "…" + name.suffix(8)
    }

    private var crumbs: [(name: String, path: String)] {
        guard let listing else { return [] }
        var result: [(String, String)] = []
        var path = listing.path
        while true {
            let name = path == listing.home ? "~" : path == "/" ? "/" : (path as NSString).lastPathComponent
            result.insert((name, path), at: 0)
            if path == listing.home || path == "/" { break }
            path = (path as NSString).deletingLastPathComponent
        }
        return result
    }

    // MARK: Places

    private var places: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                placeHeader("Places")
                place(name: "Home", icon: "house", path: listing?.home ?? "")
                if !recents.isEmpty {
                    placeHeader("Recent").padding(.top, 8)
                    ForEach(recents, id: \.self) { path in
                        place(name: (path as NSString).lastPathComponent, icon: "clock", path: path)
                    }
                }
            }
            .padding(8)
        }
        .background(Palette.sunken.opacity(0.5))
    }

    private func placeHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func place(name: String, icon: String, path: String) -> some View {
        let current = listing?.path == path
        return Button {
            load(path)
            selection = path
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(current ? Palette.accent : Palette.ice).frame(width: 16)
                Text(name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(current ? Palette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Palette.accent.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Format.path(path))
    }

    // MARK: Folders

    @ViewBuilder private var folders: some View {
        if let error {
            ContentUnavailableView("Can't open this folder", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let listing {
            VStack(spacing: 0) {
                HStack {
                    Text("Name")
                    Spacer()
                    Text("Modified").frame(width: 96, alignment: .leading)
                    Color.clear.frame(width: 22)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16).frame(height: 26)
                Divider()
                List(selection: Binding(get: { selection.isEmpty ? nil : selection }, set: { if let path = $0 { selection = path } })) {
                    if filtered.isEmpty {
                        Text(listing.entries.isEmpty ? "No folders here" : "No matches")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { entry in
                        row(entry).tag(entry.path)
                    }
                }
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { paths in
                    if let path = paths.first { load(path) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Each folder slides in like a page turn.
                .id(listing.path)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                .environment(\.defaultMinListRowHeight, 32)
                Divider()
                HStack {
                    Toggle("Hidden folders", isOn: $showHidden)
                        #if os(macOS)
                        .toggleStyle(.checkbox)
                        #endif
                        .font(.caption)
                        .onChange(of: showHidden) { load(listing.path, record: false) }
                    Spacer()
                    Button("Choose “\(listing.path == listing.home ? "~" : (listing.path as NSString).lastPathComponent)”") {
                        selection = listing.path
                    }
                    .font(.caption)
                    .disabled(selection == listing.path)
                }
                .padding(.horizontal, 12).frame(height: 32)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filtered: [DirListing.Entry] {
        guard let listing else { return [] }
        let q = filter.lowercased()
        return q.isEmpty ? listing.entries : listing.entries.filter { $0.name.lowercased().contains(q) }
    }

    private func row(_ entry: DirListing.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(LinearGradient(colors: [Palette.ice, Palette.accent], startPoint: .top, endPoint: .bottom))
                .frame(width: 18)
            Text(entry.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            if entry.git {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text(entry.branch ?? "git").lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).frame(height: 18)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.border))
                .foregroundStyle(.secondary)
                .help("Git repository")
            }
            Spacer(minLength: 8)
            Group {
                if let modified = entry.modified {
                    Text(Date(timeIntervalSince1970: modified / 1000), format: .relative(presentation: .named))
                } else {
                    Text("")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
            Button { load(entry.path) } label: {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(entry.name)")
        }
    }

    private func load(_ path: String?, record: Bool = true) {
        let current = listing?.path
        Task {
            do {
                let next = try await store.listDir(in: env, path, hidden: showHidden)
                if record, let current, current != next.path {
                    back.append(current)
                    forward = []
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { listing = next }
                error = nil
                filter = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#if os(iOS)
/// The phone's folder chooser: tap a folder to go into it, "Use this folder" to pick where you are.
struct PhoneFolderPicker: View {
    let store: SessionStore
    let env: String
    @Binding var selection: String
    let recents: [String]
    let start: String?
    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirListing?
    @State private var error: String?
    @State private var filter = ""
    @State private var showHidden = false

    var body: some View {
        List {
            if let listing, filter.isEmpty {
                Section {
                    Button { selection = listing.path; dismiss() } label: {
                        Label("Use \(listing.path == listing.home ? "home folder" : "“\((listing.path as NSString).lastPathComponent)”")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.accent)
                    }
                    if let parent = listing.parent {
                        Button { load(parent) } label: { Label("Enclosing folder", systemImage: "arrow.up") }
                    }
                } footer: {
                    Text(Format.path(listing.path)).lineLimit(2).truncationMode(.head)
                }
                if !recents.isEmpty && listing.path == listing.home {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { path in
                            Button { selection = path; dismiss() } label: {
                                Label((path as NSString).lastPathComponent, systemImage: "clock")
                            }
                        }
                    }
                }
            }
            Section {
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else if listing == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if filtered.isEmpty {
                    Text(listing?.entries.isEmpty == true ? "No folders here" : "No matches").foregroundStyle(.secondary)
                }
                ForEach(filtered) { entry in
                    Button { load(entry.path) } label: { row(entry) }
                }
            } header: {
                if listing != nil { Text("Folders") }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.sidebar)
        .tint(Palette.moon)
        .searchable(text: $filter, prompt: "Filter folders")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { load(nil) } label: { Label("Home folder", systemImage: "house") }
                    Toggle("Hidden folders", isOn: $showHidden)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onChange(of: showHidden) { load(listing?.path) }
        .task { if listing == nil { load(start) } }
    }

    private var title: String {
        guard let listing else { return "Folder" }
        return listing.path == listing.home ? "~" : (listing.path as NSString).lastPathComponent
    }

    private var filtered: [DirListing.Entry] {
        guard let listing else { return [] }
        let q = filter.lowercased()
        return q.isEmpty ? listing.entries : listing.entries.filter { $0.name.lowercased().contains(q) }
    }

    private func row(_ entry: DirListing.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(LinearGradient(colors: [Palette.ice, Palette.accent], startPoint: .top, endPoint: .bottom))
            Text(entry.name).foregroundStyle(Palette.moon).lineLimit(1).truncationMode(.middle)
            if entry.git {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                    Text(entry.branch ?? "git").lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 6).frame(height: 18)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
        }
    }

    private func load(_ path: String?) {
        Task {
            do {
                let next = try await store.listDir(in: env, path, hidden: showHidden)
                withAnimation(.snappy) { listing = next }
                error = nil
                filter = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
#endif
