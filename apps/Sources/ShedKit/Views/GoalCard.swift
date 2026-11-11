// A session's goal, shown above the composer while it is in force.
import SwiftUI

/// The goal the agent keeps working toward across turns: what it is, how far it has gone, and a way to drop it.
struct GoalCard: View {
    let goal: Goal
    let cancel: (() -> Void)?
    @State private var expanded = false
    @State private var confirming = false
    /// The objective a cancel was sent for, until the goal goes away (a running turn takes it at its next step).
    @State private var cancelling: String?

    private var tint: Color { goal.status == "active" ? Palette.accent : Palette.attention }

    private var state: String {
        if cancelling == goal.objective { return "Cancelling…" }
        switch goal.status {
        case "active": return "Goal"
        case "paused": return "Goal paused"
        case "budget_limited": return "Goal out of budget"
        default: return "Goal"
        }
    }

    /// "12.9K tokens · 3m", with the budget when there is one.
    private var usage: String {
        let tokens = goal.tokenBudget.map { "\(Format.tokens(goal.tokensUsed)) / \(Format.tokens($0)) tokens" }
            ?? "\(Format.tokens(goal.tokensUsed)) tokens"
        return "\(tokens) · \(Format.duration(ms: Double(goal.timeUsedSeconds) * 1000))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                            .frame(width: 22, height: 22)
                            .background(tint.opacity(0.14), in: Circle())
                        Text(state).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                        if !expanded {
                            Text(goal.objective).font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.7)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Chevron(open: expanded)
                    }
                    .frame(minHeight: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if cancelling == goal.objective {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 22)
                } else if cancel != nil {
                    Button { confirming = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.moon.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Palette.moon.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cancel the goal")
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(goal.objective).font(.system(size: 12.5)).foregroundStyle(Palette.moon).textSelection(.enabled)
                    Text(usage).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Palette.moon.opacity(0.5))
                    if let reason = goal.lastReason, goal.status != "active" {
                        Text(reason).font(.system(size: 11.5)).foregroundStyle(Palette.attention.opacity(0.85))
                    }
                }
                .padding(.leading, 30).padding(.top, 6).padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .card(radius: 14, fill: Palette.surface.opacity(0.9))
        .confirmationDialog("Cancel this goal?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Cancel Goal", role: .destructive) {
                cancelling = goal.objective
                cancel?()
            }
            Button("Keep Working", role: .cancel) {}
        } message: {
            Text("The agent stops pursuing it after its current step.")
        }
    }
}
