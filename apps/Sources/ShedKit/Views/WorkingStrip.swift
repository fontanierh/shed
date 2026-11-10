// The line above the Mac's composer while the agent works: what it is doing now, and for how long.
import SwiftUI

/// While the agent works: its mark, what it's doing now, and for how long, along a trail of light.
struct WorkingStrip: View {
    let store: SessionStore
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 10) {
            AgentMark(agent: session.agent, size: 20, working: true)
            Text(session.status == .compacting ? "Compacting context" : "\(session.agent.displayName) is working")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.moon)
                .shimmer(color: session.status == .compacting ? Palette.lilac : Palette.accent)
                .fixedSize()
            LightTrail()
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

/// A faint line with a spark of light gliding along it, back and forth.
struct LightTrail: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TrailField(still: reduceMotion)
            .accessibilityHidden(true)
    }
}
