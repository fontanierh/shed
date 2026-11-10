// A session's model and reasoning effort: the chip under the composer, the picker it opens, and the tag in lists.
import SwiftUI

/// The model and its reasoning effort in one chip below the composer. As room runs out the effort's word goes,
/// then the name's later words; the name's first words and the effort's bars always stay.
struct ModelChip: View, Equatable {
    let model: ModelInfo?
    /// The models on offer, to tell apart two that go by the same name.
    let models: [ModelInfo]
    let level: String?
    let levels: [String]

    var body: some View {
        let name = model?.chipName(among: models) ?? "No model"
        let short = model?.essentialName ?? name
        ViewThatFits(in: .horizontal) {
            label(name, word: true)
            label(name)
            label(short)
            label(short, squeezed: true)
        }
    }

    private func label(_ name: String, word: Bool = false, squeezed: Bool = false) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "cube").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.moon.opacity(0.75))
            Text(name).lineLimit(1).truncationMode(.middle).foregroundStyle(Palette.moon)
                .fixedSize(horizontal: !squeezed, vertical: false)
            if !levels.isEmpty {
                Capsule().fill(Palette.moon.opacity(0.18)).frame(width: 1, height: 12)
                EffortBars(level: EffortBars.level(of: level, in: levels))
                if word {
                    Text(ModelInfo.effortName(level, among: levels)).lineLimit(1).fixedSize()
                        .foregroundStyle(Palette.moon.opacity(0.75))
                }
            }
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 12).frame(height: 30)
        .card(radius: 15, fill: Palette.surface.opacity(0.85), border: Palette.lit.opacity(0.8))
        .contentShape(Capsule())
    }
}

/// Signal bars for the reasoning effort; the lit ones glow blue.
struct EffortBars: View {
    let level: Double

    /// A level's position among its model's, 0...1.
    static func level(of current: String?, in levels: [String]) -> Double {
        guard let current, let index = levels.firstIndex(of: current), levels.count > 1 else { return 0.5 }
        return Double(index) / Double(levels.count - 1)
    }

    var body: some View {
        let lit = Int((level * 3).rounded()) + 1
        // Four bars written out, not a `ForEach`: the chip is measured again while the composer animates, off the
        // main thread, and a `ForEach`'s closure made here may only run on it.
        HStack(alignment: .bottom, spacing: 1.5) {
            bar(0, lit: lit)
            bar(1, lit: lit)
            bar(2, lit: lit)
            bar(3, lit: lit)
        }
        .frame(height: 12)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: lit)
    }

    private func bar(_ index: Int, lit: Int) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(index < lit ? Palette.accent : Palette.rail)
            .frame(width: 2.5, height: 4 + CGFloat(index) * 2.5)
    }
}

struct ModelPicker: View {
    let store: SessionStore
    let current: ModelInfo?
    /// The session whose reasoning effort is set here too.
    var session: SessionSummary?
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
            if let session, !session.thinkingLevels.isEmpty {
                EffortRow(store: store, session: session).padding(.horizontal, 10).padding(.bottom, 8)
            }
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

/// The reasoning effort, above the models in their picker. Choosing one applies it and leaves the picker open.
struct EffortRow: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        let levels = session.thinkingLevels
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                EffortBars(level: EffortBars.level(of: session.thinkingLevel, in: levels))
                Text("Effort").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            GlassSegments(options: levels.map { ($0, ModelInfo.effortName($0, among: levels)) },
                          selection: Binding(get: { session.thinkingLevel ?? "" }, set: { store.setThinking($0) }),
                          height: 32, inset: levels.count > 4 ? 4 : 12)
        }
    }
}

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
