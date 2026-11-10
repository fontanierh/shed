// Session actions shared by the Mac header, the iPhone toolbar and the session list: renaming and the context window.
import SwiftUI

/// A larger context window for the open session, up to the model's full one. The bridge reports usage against it
/// and compacts near it, so it moves the auto-compaction threshold too.
struct ContextWindowMenu: View {
    let store: SessionStore
    let session: SessionSummary
    /// The choices listed in place, under a title, rather than in a submenu.
    var inline = false

    private static let sizes = [400_000, 600_000, 1_000_000]

    var body: some View {
        let model = session.model?.contextWindow
        let standard = session.standardWindow ?? model
        let sizes = Self.sizes.filter { size in (model.map { size <= $0 } ?? true) && size != standard }
        Picker(selection: Binding(get: { session.contextLimit ?? 0 }, set: { store.setContextLimit($0 == 0 ? nil : $0) })) {
            Text(standard.map { "Default (\(Self.short($0)))" } ?? "Default").tag(0)
            ForEach(sizes, id: \.self) { Text(Self.short($0)).tag($0) }
            if let limit = session.contextLimit, !sizes.contains(limit) { Text(Self.short(limit)).tag(limit) }
        } label: {
            Label("Context Window", systemImage: "gauge.with.dots.needle.33percent")
        }
        .modifier(PickerShape(inline: inline))
    }

    private struct PickerShape: ViewModifier {
        let inline: Bool
        func body(content: Content) -> some View {
            if inline { content.pickerStyle(.inline) } else { content.pickerStyle(.menu) }
        }
    }

    /// "272k", "1M", "1.05M".
    static func short(_ tokens: Int) -> String {
        guard tokens >= 1_000_000 else { return "\(tokens / 1000)k" }
        return (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M"
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

/// Asks for a new name for `target`, starting from its current title.
struct RenameSessionAlert: ViewModifier {
    @Binding var target: SessionSummary?
    let store: SessionStore
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let target { store.rename(target.id, to: name) }
                }
            }
            .onChange(of: target?.id) { name = target?.title ?? "" }
    }
}

extension View {
    func renameSession(_ target: Binding<SessionSummary?>, store: SessionStore) -> some View {
        modifier(RenameSessionAlert(target: target, store: store))
    }
}

extension ModelInfo {
    /// Newest first, as far as the ids tell: catalogs carry no release dates, so the version in the id decides
    /// (GPT-6.1 before GPT-5 before GPT-4.1), the full model before its mini and nano, then later dated snapshots.
    static func newestFirst(_ models: [ModelInfo], matching query: String = "") -> [ModelInfo] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? models : models.filter { $0.name.lowercased().contains(q) || $0.key.lowercased().contains(q) }
        // Each id is read once, not once a comparison: the pickers sort again at every letter typed.
        return shown.map { ($0, $0.recency) }.sorted { a, b in
            let (ka, kb) = (a.1, b.1)
            if ka.version != kb.version { return !ka.version.lexicographicallyPrecedes(kb.version) }
            if ka.size != kb.size { return ka.size < kb.size }
            if ka.date != kb.date { return ka.date > kb.date }
            return a.0.key < b.0.key
        }.map(\.0)
    }

    /// By provider, `first`'s leading and the rest in `groupOrder`, each newest first.
    static func byProvider(_ models: [ModelInfo], matching query: String = "", first: ModelInfo?) -> [(provider: String, models: [ModelInfo])] {
        let groups = Dictionary(grouping: newestFirst(models, matching: query)) { group(provider: $0.provider, id: $0.id).label }
        let lead = first?.groupLabel
        let order = groups.keys.sorted { a, b in a == lead ? true : b == lead ? false : groupOrder(a, b) }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var groupLabel: String { Self.group(provider: provider, id: id).label }

    /// The name shown within its group. Open Codex has no display names, so its ids stand in, less the group's part.
    var shortName: String { name == id ? String(id.dropFirst(Self.group(provider: provider, id: id).prefix.count)) : name }

    /// The name in a few words, for a chip: "DeepSeek V4.1 Flash" for `mistral/deepseek-v4-1-flash-1017`. A display
    /// name stays as it is. An id loses its provider and its build date, and gets its version and spelling back.
    var compactName: String { name != id && name.contains(" ") ? name : Self.compact(name) }

    /// The compact name's first words, for when even that is too long: the family, its version and one variant.
    var essentialName: String { compactName.split(separator: " ").prefix(3).joined(separator: " ") }

    /// The compact name, led by where the model comes from when another of `models` goes by the same name.
    func chipName(among models: [ModelInfo]) -> String {
        let mine = compactName
        guard models.contains(where: { $0.key != key && $0.compactName == mine }) else { return mine }
        let source = switch groupLabel {
        case "ChatGPT subscription": "ChatGPT"
        case "OpenAI API key", "Anthropic API key": "API"
        default: groupLabel
        }
        return "\(source) · \(mine)"
    }

    /// Names that a capital letter alone gets wrong.
    private static let spellings = [
        "gpt": "GPT", "glm": "GLM", "oss": "OSS", "deepseek": "DeepSeek", "mimo": "MiMo", "qwq": "QwQ",
        "chatgpt": "ChatGPT", "openai": "OpenAI", "xai": "xAI",
    ]

    static func compact(_ id: String) -> String {
        var parts = (id as NSString).lastPathComponent.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" }).map(String.init)
        // The build it was cut from says nothing to a reader: a date in one piece or three, a four-digit code, "latest".
        if parts.count > 3, parts[parts.count - 3].wholeMatch(of: /20\d{2}/) != nil,
           parts.suffix(2).allSatisfy({ $0.wholeMatch(of: /\d{2}/) != nil }) {
            parts.removeLast(3)
        } else if parts.count > 1, let last = parts.last, last == "latest" || last.wholeMatch(of: /\d{8}|\d{4}/) != nil {
            parts.removeLast()
        }
        var words: [String] = []
        var index = 0
        while index < parts.count {
            var part = parts[index].lowercased()
            // Ids write "4.1" as two parts.
            if part.wholeMatch(of: /v?\d{1,2}/) != nil, index + 1 < parts.count, parts[index + 1].wholeMatch(of: /\d{1,2}/) != nil {
                part += "." + parts[index + 1]
                index += 1
            }
            index += 1
            if let spelling = spellings[part] {
                words.append(spelling)
            } else if part.wholeMatch(of: /\d+[bkm]/) != nil {
                words.append(part.uppercased())  // 120B parameters, 32K tokens
            } else if part.first?.isNumber == true || part.wholeMatch(of: /o\d/) != nil {
                words.append(part)  // 4o, o3
            } else {
                words.append(part.prefix(1).uppercased() + part.dropFirst())
            }
        }
        // GPT and GLM carry their version on a hyphen.
        if words.count > 1, ["GPT", "GLM"].contains(words[0]), words[1].first?.isNumber == true {
            words.replaceSubrange(0...1, with: ["\(words[0])-\(words[1])"])
        }
        return words.joined(separator: " ")
    }

    /// A reasoning effort as a word: "High", and "Max" for the top one where the model has nothing above it.
    static func effortName(_ level: String?, among levels: [String] = []) -> String {
        switch level {
        case nil, "": "Default"
        case "xhigh": levels.contains("max") ? "XHigh" : "Max"
        case let level?: level.capitalized
        }
    }

    /// Subscriptions and API keys first, then the other providers alphabetically.
    static func groupOrder(_ a: String, _ b: String) -> Bool {
        let leading = ["ChatGPT subscription", "OpenAI API key", "Anthropic API key"]
        switch (leading.firstIndex(of: a), leading.firstIndex(of: b)) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// The menu a model goes in, and the part of its id that menu already says. Open Codex serves every provider
    /// under its own name, so its models go by the provider inside it; bare ids are the ChatGPT subscription's.
    static func group(provider: String, id: String) -> (label: String, prefix: String) {
        guard provider == "opencodex" else { return (provider, "") }
        guard let slash = id.firstIndex(of: "/") else { return ("ChatGPT subscription", "") }
        let inner = String(id[..<slash])
        let label = switch inner {
        case "openai-apikey": "OpenAI API key"
        case "anthropic-apikey": "Anthropic API key"
        case "mistral": "Mistral"
        case "deepseek": "DeepSeek"
        case "google": "Google"
        case "openrouter": "OpenRouter"
        case "fireworks": "Fireworks"
        case "xiaomi-mimo": "Xiaomi MiMo"
        case "xai": "xAI"
        case "groq": "Groq"
        default: inner
        }
        return (label, inner + "/")
    }

    private var recency: (version: [Int], size: Int, date: String) {
        let name = (id.lowercased() as NSString).lastPathComponent
        let parts = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == ":" })
        // The version is the first small number, optionally dotted and lettered ("6.1", "4o", "o3"). Parameter counts
        // ("120b") and date codes ("2512", "2024") are not versions.
        let version = parts.lazy.compactMap { part -> [Int]? in
            guard let match = part.wholeMatch(of: /v?[a-z]?(\d{1,2}(?:\.\d+)*)[a-z]?/), !part.hasSuffix("b") || part.count <= 2 else { return nil }
            return match.output.1.split(separator: ".").compactMap { Int($0) }
        }.first ?? []
        // Whole words: "gemini" is not a mini.
        let size = ["nano", "mini", "small", "lite", "flash"].firstIndex { parts.contains($0[...]) }.map { 5 - $0 } ?? 0
        let date = name.firstMatch(of: /\d{4}-\d{2}-\d{2}|\d{8}/).map { String($0.output) } ?? "9999"
        return (version, size, date)
    }
}

#if os(iOS)
/// The phone's model picker: a full sheet, newest models first, the current one ticked, and the session's
/// reasoning effort above them.
struct PhoneModelPicker: View {
    let store: SessionStore
    let current: ModelInfo?
    /// The session whose reasoning effort is set here too.
    var session: SessionSummary?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Provider groups shown open: the current model's at first. A search opens them all.
    @State private var open: Set<String> = []
    /// The list has answered: an empty one then says so instead of spinning.
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    Group {
                        if loaded {
                            Text("No models to switch to").font(.system(size: 14)).foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                let groups = ModelInfo.byProvider(store.models, matching: query, first: current)
                ForEach(groups, id: \.provider) { group in
                    let expanded = groups.count == 1 || !query.isEmpty || open.contains(group.provider)
                    Section {
                        if expanded { ForEach(group.models, id: \.key) { model in row(model) } }
                    } header: {
                        Button {
                            if open.remove(group.provider) == nil { open.insert(group.provider) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(group.provider)
                                Spacer()
                                Text("\(group.models.count)").monospacedDigit()
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onAppear { if let current { open.insert(current.groupLabel) } }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Palette.sidebar.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                if let session, !session.thinkingLevels.isEmpty {
                    EffortRow(store: store, session: session)
                        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
                        .background(Palette.sidebar)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .navigationTitle(session?.thinkingLevels.isEmpty == false ? "Model and Effort" : "Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task {
            await store.loadModels()
            loaded = true
        }
    }

    private func row(_ model: ModelInfo) -> some View {
                    let selected = model.key == current?.key
                    return Button {
                        if !selected { store.setModel(model) }
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.shortName).font(.system(size: 16, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Palette.accent : Palette.moon)
                                Text(model.id).font(.system(size: 12)).foregroundStyle(Palette.moon.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if let window = model.contextWindow {
                                Text(ContextWindowMenu.short(window)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            if model.reasoning { Image(systemName: "brain").font(.system(size: 13)).foregroundStyle(.tertiary) }
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.accent).opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(selected ? Palette.accent.opacity(0.08) : Palette.surface.opacity(0.6))
    }
}
#endif
