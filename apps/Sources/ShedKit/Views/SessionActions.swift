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

    /// By provider, `first` leading and the rest alphabetical, each newest first.
    static func byProvider(_ models: [ModelInfo], matching query: String = "", first: String?) -> [(provider: String, models: [ModelInfo])] {
        let groups = Dictionary(grouping: newestFirst(models, matching: query), by: \.provider)
        let order = groups.keys.sorted { a, b in a == first ? true : b == first ? false : a < b }
        return order.map { ($0, groups[$0] ?? []) }
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

    var body: some View {
        NavigationStack {
            List {
                if store.models.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                ForEach(ModelInfo.byProvider(store.models, matching: query, first: current?.provider), id: \.provider) { group in
                    Section(group.provider) {
                        ForEach(group.models, id: \.key) { model in row(model) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Velvet(base: Palette.sidebar).ignoresSafeArea())
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
                                Text(model.name).font(.system(size: 16, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Palette.amber : Palette.moon)
                                Text(model.id).font(.system(size: 12)).foregroundStyle(Palette.moon.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            if let window = model.contextWindow {
                                Text(ContextWindowMenu.short(window)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            if model.reasoning { Image(systemName: "brain").font(.system(size: 13)).foregroundStyle(.tertiary) }
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.amber).opacity(selected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .listRowBackground(selected ? Palette.amber.opacity(0.08) : Palette.surface.opacity(0.6))
    }
}
#endif
