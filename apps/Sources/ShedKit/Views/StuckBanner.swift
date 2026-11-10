// The warning above the composer when a tool call or a background command looks stuck, with the way out.
import SwiftUI

/// A tool call or background command that looks stuck, why, and the way out, above the composer.
struct StuckBanner: View {
    let store: SessionStore
    let session: SessionSummary
    let stuck: Stuck
    @State private var confirming = false

    /// The bridge's reason as a sentence, naming the computer it runs on.
    static func phrase(_ reason: String, on computer: String?) -> String {
        var text = computer.map { reason.replacingOccurrences(of: "this Mac", with: $0) } ?? reason
        if let last = text.last, !".!?".contains(last) { text += "." }
        return text.sentenceCased
    }

    private var what: String {
        stuck.isToolCall ? ToolDescription.python(code: stuck.command).detail ?? ToolDescription.shortCommand(stuck.command, limit: 60)
            : ToolDescription.shortCommand(stuck.command, limit: 60)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.attention).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(stuck.isToolCall ? "This tool call looks stuck" : "A background command looks stuck")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.moon)
                    if let probability = stuck.probability {
                        Text("\(Int((probability * 100).rounded()))% sure")
                            .font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(Palette.attention)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.attention.opacity(0.14), in: Capsule())
                            .help("How likely the stall check judged it stuck")
                    }
                }
                Text(Self.phrase(stuck.reason, on: store.environment(of: session.id)?.name))
                    .font(.caption).foregroundStyle(Palette.moon.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Text(what).font(.mono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if !session.readOnly, stuck.isToolCall || stuck.jobId != nil {
                Button { confirming = true } label: {
                    Text(stuck.isToolCall ? "Stop" : "Cancel")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.attention)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Palette.attention.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(Palette.attention.opacity(0.45)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .confirmationDialog(stuck.isToolCall ? "Stop this tool call?" : "Cancel this command?", isPresented: $confirming,
                                    titleVisibility: .visible) {
                    Button(stuck.isToolCall ? "Stop" : "Cancel Command", role: .destructive) { act() }
                    Button("Keep Waiting", role: .cancel) {}
                } message: {
                    Text(stuck.isToolCall ? "The agent's turn ends here. Messages you queued are sent right away so it can carry on."
                         : "The agent is told the command ended, and carries on.")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12, fill: Palette.attention.opacity(0.08), border: Palette.attention.opacity(0.4))
    }

    private func act() {
        if stuck.isToolCall {
            store.stopTool()
        } else if let jobId = stuck.jobId {
            let store = store, id = session.id
            Task { await store.killJob(id, jobId) }
        }
    }
}
