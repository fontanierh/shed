// Messages sent while the agent works, shown above the composer until they are delivered.
import SwiftUI

extension Queue {
    /// What the reader would recognize as waiting: Prime also queues its own notices (a subagent that exited or was
    /// cancelled, a message from another agent, a goal's continuation) for the end of the turn, and an agent pursuing a
    /// goal rarely ends one, so they would sit in the bar for good. They show in the transcript once delivered.
    var forReader: Queue {
        Queue(steering: steering.filter { !Self.isNotice($0) }, followUp: followUp.filter { !Self.isNotice($0) })
    }

    private static func isNotice(_ text: String) -> Bool {
        text.hasPrefix("Agent message received:") || text.hasPrefix("[goal") || Note(text).kind != .other
    }
}

/// Messages waiting for the agent: steering is delivered at the next step, follow-ups when it finishes.
struct QueuedMessages: View {
    let queue: Queue
    @State private var expanded = false

    private var entries: [(steering: Bool, text: String)] {
        queue.steering.map { (true, $0) } + queue.followUp.map { (false, $0) }
    }

    var body: some View {
        let entries = entries
        VStack(alignment: .leading, spacing: 0) {
            // One line however many are waiting: how many, and the latest.
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    icon(steering: !queue.steering.isEmpty)
                    Text(summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                        .monospacedDigit().contentTransition(.numericText())
                    if !expanded, let last = entries.last {
                        Text(last.text).font(.system(size: 12.5)).foregroundStyle(Palette.moon.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if entries.count > 1 || expanded { Chevron(open: expanded) }
                }
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entries.count < 2 && !expanded)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.steering ? "arrow.up.right" : "text.append")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent.opacity(0.8))
                                    .frame(width: 22)
                                Text(entry.text).font(.system(size: 12.5)).foregroundStyle(Palette.moon).lineLimit(3)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .card(radius: 14, fill: Palette.surface.opacity(0.9))
        .onChange(of: entries.isEmpty) { if $1 { expanded = false } }
    }

    /// "Steering", "3 pending", "2 steering · 1 queued".
    private var summary: String {
        let (steering, queued) = (queue.steering.count, queue.followUp.count)
        if steering + queued == 1 { return steering == 1 ? "Steering" : "Queued" }
        if steering > 0, queued > 0 { return "\(steering) steering · \(queued) queued" }
        return "\(steering + queued) pending"
    }

    private func icon(steering: Bool) -> some View {
        Image(systemName: steering ? "arrow.up.right" : "text.append")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .frame(width: 22, height: 22)
            .background(Palette.accent.opacity(0.14), in: Circle())
    }
}
