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
        return shown.sorted { a, b in
            let (ka, kb) = (a.recency, b.recency)
            if ka.version != kb.version { return !ka.version.lexicographicallyPrecedes(kb.version) }
            if ka.size != kb.size { return ka.size < kb.size }
            if ka.date != kb.date { return ka.date > kb.date }
            return a.key < b.key
        }
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
        let size = ["nano", "mini", "small", "lite", "flash"].firstIndex { name.contains($0) }.map { 5 - $0 } ?? 0
        let date = name.firstMatch(of: /\d{4}-\d{2}-\d{2}|\d{8}/).map { String($0.output) } ?? "9999"
        return (version, size, date)
    }
}

#if os(iOS)
/// The phone's model picker: a full sheet, newest models first, the current one ticked.
struct PhoneModelPicker: View {
    let store: SessionStore
    let current: ModelInfo?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Provider groups shown open: the current model's at first. A search opens them all.
    @State private var open: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await store.loadModels() }
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
