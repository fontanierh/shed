// Starting a session: the computer, the agent, a folder on that computer, and the model and effort.
import SwiftUI

struct NewSessionSheet: View {
    let store: SessionStore
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

    private func restoreFolder() {
        let first = store.environments.first?.id
        cwd = folders(lastFolders).first { $0.env == env }?.path ?? (env == first ? legacyCwd : "")
    }

    @ViewBuilder private var environmentPicker: some View {
        if store.environments.count > 1 {
            Picker("Computer", selection: Binding(get: { env }, set: { chosenEnv = $0 })) {
                ForEach(store.environments) { e in Text(e.name).tag(e.id) }
            }
            .labelsHidden()
            #if os(macOS)
            .pickerStyle(.segmented)
            .fixedSize()
            #endif
        }
    }
    /// The models DeepSeek Harness last said it has set up, kept so a choice of one is recognised before it answers.
    @AppStorage("newSession.dshModels") private var dshModels = ""

    private var harnessModels: [String] {
        let listed = dshModels.split(separator: "\n").map(String.init)
        return listed.isEmpty ? ["deepseek-official/deepseek-v4-pro", "deepseek-official/deepseek-v4-flash"] : listed
    }

    private func runsOnHarness(_ model: String) -> Bool { model.hasPrefix("deepseek") || harnessModels.contains(model) }

    /// DeepSeek Harness runs only the providers set up in it, and the other agents none of them: a model left from the
    /// other kind of agent would fail to start.
    private func fitModel() {
        if !model.isEmpty, runsOnHarness(model) != (agent == .deepseek) { model = "" }
    }

    /// Asks the computer's DeepSeek Harness which models it has, so providers added to it are offered too.
    private func loadHarnessModels() async {
        guard agent == .deepseek, let listed = try? await store.agentModels(in: env, .deepseek), !listed.isEmpty else { return }
        dshModels = listed.joined(separator: "\n")
    }

    private var models: [String] {
        let saved = recentModels.split(separator: "\n").map(String.init)
        if agent == .deepseek {
            let harness = harnessModels
            return saved.filter(runsOnHarness) + harness.filter { !saved.contains($0) }
        }
        return saved.filter { !runsOnHarness($0) } + ["openai/gpt-6.1-terra"].filter { !saved.contains($0) }
    }

    var body: some View {
        Group {
            #if os(iOS)
            phone
            #else
            mac
            #endif
        }
        .onAppear { restoreFolder(); fitModel() }
        .onChange(of: env) { restoreFolder() }
        .onChange(of: agent) { fitModel() }
        .task(id: "\(env) \(agent.rawValue)") { await loadHarnessModels() }
    }

    private var mac: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Sprout(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("New session").font(.system(size: 26, design: .serif)).foregroundStyle(Palette.moon)
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
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

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
                .buttonStyle(AmberButton())
                .keyboardShortcut(.defaultAction)
                .disabled(cwd.isEmpty || creating)
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }
        .frame(width: 920)
        .background {
            ZStack(alignment: .bottomLeading) {
                Velvet(base: Palette.sidebar)
                Sprig().fill(Palette.ice.opacity(0.06)).frame(width: 130, height: 200).offset(x: -10, y: -40)
                Fireflies(count: 6, warm: 0.4, seed: 21)
            }
        }
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
                ForEach(models, id: \.self) { name in Button(name) { model = name } }
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

    private var effortPicker: some View {
        Picker("Effort", selection: $thinking) {
            Text("Default").tag("")
            ForEach(["low", "medium", "high", "xhigh"], id: \.self) { Text($0 == "xhigh" ? "Max" : $0.capitalized).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
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
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { ZStack { Velvet(base: Palette.sidebar); Fireflies(count: 5, warm: 0.4, seed: 21) }.ignoresSafeArea() }
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
        Task {
            let ok = await store.createSession(in: env, agent: agent, cwd: folder, model: chosenModel, thinking: thinking,
                                               firstMessage: "")
            creating = false
            if ok {
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
            }
        }
    }
}

/// An agent to pick: its spirit, what it is, and a lantern glow when chosen. The chosen spirit hops.
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
                Spirit(color: Palette.agent(kind), size: 52)
                    .offset(y: hop ? -8 : 0)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind == .prime ? "Prime Agent" : kind.displayName).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.moon)
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(selected ? Palette.amber : Palette.rail)
                    .frame(width: 10, height: 10)
                    .shadow(color: selected ? Palette.amber : .clear, radius: 5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 16, fill: selected ? Palette.raised : Palette.surface.opacity(hovering ? 0.95 : 0.75),
                  border: selected ? Palette.amber.opacity(0.75) : Palette.border)
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
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(current ? Palette.amber : Palette.ice).frame(width: 16)
                Text(name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(current ? Palette.amber.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Palette.amber.opacity(0.45) : .clear))
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
                .foregroundStyle(LinearGradient(colors: [Palette.ice, Palette.periwinkle], startPoint: .top, endPoint: .bottom))
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
                            .foregroundStyle(Palette.amber)
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
                .foregroundStyle(LinearGradient(colors: [Palette.ice, Palette.periwinkle], startPoint: .top, endPoint: .bottom))
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
