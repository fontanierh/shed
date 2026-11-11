// The conversation: a list of rows, each a SwiftUI view of its own. Only the rows near the screen exist, and a row
// redraws only when its own block changes, so text streaming into one reply, a tool call's arguments growing or a
// reasoning step arriving costs that one row, not the conversation, and scrolling stays free.
// Rows don't unfold in place: their details open beside or over the conversation (`openSheet`), a sheet on the phone
// and a panel on the Mac. The list itself is each platform's own: a collection view (`PhoneFeed`), and a scroll view
// that places its rows itself (`MacFeed`).
import SwiftUI

/// One row of the feed: a block of the transcript. A class the row's view observes, so a change to one block redraws
/// that row alone; the feed's list of rows changes only when a block comes or goes.
@MainActor @Observable
final class FeedRow: Identifiable {
    let id: String
    var block: Block
    /// The last block of a running turn: text still arriving.
    var streaming: Bool
    /// When it arrived live, if it did and hasn't printed in yet: it prints in once, the first time it shows.
    @ObservationIgnored var arrived: CFTimeInterval?
    /// The subagents each finished step started, worked out once: a running activity redraws a dozen times a second.
    @ObservationIgnored private var spawnedBySettledStep: [String: [String]] = [:]

    /// The subagents the activity's steps started, in order.
    func spawned(_ activity: Activity) -> [SubagentMention] {
        activity.steps.flatMap { step in
            let running = step.item.status?.isInFlight == true
            let names = spawnedBySettledStep[step.id] ?? ToolDescription(step.item).spawned
            if !running { spawnedBySettledStep[step.id] = names }
            return names.map { SubagentMention(name: $0, date: step.item.date, spawning: true, running: running) }
        }
    }

    init(_ block: Block, streaming: Bool) {
        id = block.id
        self.block = block
        self.streaming = streaming
    }
}

/// The feed's rows, kept in step with the transcript's blocks.
@MainActor
final class FeedRows {
    private var rows: [String: FeedRow] = [:]

    subscript(id: String) -> FeedRow? { rows[id] }

    /// The row holding an item, whatever its id is now: a row whose start loads with an earlier page changes id.
    func row(holding item: String) -> FeedRow? { rows.values.first { $0.block.contains(item) } }

    /// Takes the blocks as they are now and returns their ids in order. Each block's row is changed in place, so only
    /// the rows whose block changed draw again. `shown` is what the feed showed before: once it is `live`, rows that
    /// come in after the last of those arrived just now, and print in.
    func take(_ blocks: [Block], busy: Bool, after shown: [String], live: Bool) -> [String] {
        var ids: [String] = []
        ids.reserveCapacity(blocks.count + 2)
        var seen = Set<String>()
        var added: [String] = []
        for (index, block) in blocks.enumerated() where seen.insert(block.id).inserted {
            let streaming = busy && index == blocks.count - 1
            if let row = rows[block.id] {
                if row.block != block { row.block = block }
                if row.streaming != streaming { row.streaming = streaming }
            } else {
                rows[block.id] = FeedRow(block, streaming: streaming)
                added.append(block.id)
            }
            ids.append(block.id)
        }
        // Rows that came in above the last one there before are history loading, which just appears.
        if live, let last = shown.last(where: { rows[$0] != nil && seen.contains($0) }), let from = ids.firstIndex(of: last) {
            for id in ids[(from + 1)...] where added.contains(id) {
                guard let row = rows[id] else { continue }
                // The reader's own message was on screen already, as it was being sent.
                if case .item(let item) = row.block, item.kind == .user { continue }
                row.arrived = CACurrentMediaTime()
            }
        }
        for id in rows.keys where !seen.contains(id) { rows[id] = nil }
        return ids
    }
}

/// What the feed's chrome shows: the jump back to the end, and what stands under the last row.
@MainActor @Observable
final class FeedState {
    /// Following the end, or close enough to it that there's nothing to jump to.
    var atBottom = true
    var busy = false
    var session: SessionSummary?
    var pending: String?
    var idle: [IdleLine] = []
    var empty = true
    var earlier = false
    var loadingEarlier = false
}

/// The SwiftUI side's way to the list: the rail and the jump button move it.
@MainActor
final class FeedHandle {
    weak var controller: FeedController?
}

/// A session's conversation: the feed, the rail beside it and the jump to the end. On the phone, also the sheet its
/// rows open; on the Mac they open in the session's side panel, which the session sets as `openSheet`.
struct TranscriptView: View {
    let items: [Item]
    let session: SessionSummary
    /// Set while the conversation hasn't arrived: what it waits on, shown instead of an empty conversation.
    var pending: String? = nil
    /// Where an idle session stands, under its last message: what it waits on, or that nothing will wake it.
    var idle: [IdleLine] = []
    var openParent: (@MainActor () -> Void)? = nil
    /// Older items not loaded yet, and how to load the next page of them.
    var earlier = 0
    var loadingEarlier = false
    var loadEarlier: (() async -> Void)? = nil

    @State private var state = FeedState()
    @State private var metrics = ScrollMetrics()
    @State private var handle = FeedHandle()
    #if os(iOS)
    @State private var sheet: FeedSheet?
    /// What to do once the sheet has gone: where a link in it leads.
    @State private var afterSheet: (@MainActor () -> Void)?
    #endif

    var body: some View {
        feed
            .overlay(alignment: .trailing) {
                ScrollRail(metrics: metrics) { y in handle.controller?.scroll(to: y) }
                    .padding(.vertical, 16)
                    .padding(.trailing, 4)
            }
            .overlay(alignment: .bottom) { JumpToLatest(state: state) { handle.controller?.jumpToLatest() } }
            #if os(iOS)
            .sheet(item: $sheet) {
                afterSheet?()
                afterSheet = nil
            } content: { sheet in
                FeedSheetView(sheet: sheet)
                    .environment(\.closeSheet, SheetCloser { then in
                        afterSheet = then
                        self.sheet = nil
                    })
            }
            #endif
    }

    #if os(iOS)
    private var feed: some View {
        list()
            // Rows open their details here rather than unfolding.
            .environment(\.openSheet, SheetOpener { sheet = $0 })
            // Under the navigation bar, as the system's own lists run: the collection view insets its content itself.
            .ignoresSafeArea(.container, edges: .top)
    }
    #else
    private var feed: some View {
        // The conversation runs on under the composer and ends above it: the list is told how much of it lies under.
        GeometryReader { proxy in
            list().under(proxy.safeAreaInsets.bottom)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
    #endif

    private func list() -> FeedView {
        FeedView(items: items, session: session, pending: pending, idle: idle, openParent: openParent,
                 earlier: earlier, loadingEarlier: loadingEarlier, loadEarlier: loadEarlier, state: state, metrics: metrics,
                 handle: handle)
    }
}

/// "Jump to latest", or "New activity" while the agent works, once the reader has scrolled up from the end.
private struct JumpToLatest: View {
    let state: FeedState
    let jump: () -> Void

    var body: some View {
        ZStack {
            if !state.atBottom {
                Button(action: jump) {
                    Label(state.busy ? "New activity" : "Jump to latest", systemImage: "arrow.down")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(state.busy ? Palette.accent : Palette.moon)
                        .padding(.horizontal, 14).frame(height: 32)
                        .card(radius: 16, fill: Palette.raised, border: state.busy ? Palette.accent.opacity(0.5) : Palette.border)
                        #if os(macOS)
                        .glow(radius: 10, on: state.busy)
                        #endif
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(PressStyle())
                .padding(.bottom, 10)
                .transition(.scale(scale: 0.8).combined(with: .opacity).combined(with: .offset(y: 12)))
            }
        }
        // Only the button springs in and out, not the conversation behind it.
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state.atBottom)
    }
}

// MARK: Rows

/// What the list holds besides the transcript's blocks.
enum FeedSlot {
    /// Before the first row: the way to the conversation before it.
    static let header = "feed-earlier"
    /// After the last: where the session stands.
    static let footer = "feed-footer"
    /// Between rows.
    static let spacing: CGFloat = 24
    /// Above the first row and under the last.
    static let top: CGFloat = 20
    static let bottom: CGFloat = 44
}

/// A block as a row: a reply, a message, or a one-line summary whose details open in a sheet or a panel.
struct FeedRowView: View {
    let row: FeedRow
    let agent: AgentKind
    let openParent: (@MainActor () -> Void)?

    var body: some View {
        Group {
            if case .activity(let activity) = row.block {
                ActivityRow(row: row, activity: activity)
            } else if case .item(let item) = row.block, item.kind == .text || item.kind == .user {
                BlockView(block: row.block, agent: agent, openParent: openParent, streaming: row.streaming)
                    .equatable()
                    .copyMenu(for: item)
            } else {
                BlockView(block: row.block, agent: agent, openParent: openParent, streaming: row.streaming)
                    .equatable()
            }
        }
        #if os(iOS)
        // Every selectable text is something a touch is checked against before a scroll can start.
        .environment(\.inlineSelection, false)
        #else
        .textSelection(.enabled)
        #endif
        .frame(maxWidth: Layout.column, alignment: .leading)
        .padding(.horizontal, Layout.gutter)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// On the phone, where text isn't selected where it stands, a hold on a reply or a message copies it. The Mac
    /// selects in place.
    @ViewBuilder func copyMenu(for item: Item) -> some View {
        #if os(iOS)
        modifier(CopyMenu(item: item))
        #else
        self
        #endif
    }
}

/// "Worked for 3m · 18 tool calls", or what it is doing now while live. Opens its steps beside the conversation,
/// where they keep up while they run. Subagents it started stay one tap away.
private struct ActivityRow: View {
    let row: FeedRow
    let activity: Activity
    @Environment(\.openSheet) private var openSheet
    #if os(macOS)
    @Environment(\.detailSelection) private var selection
    /// Its steps are what the panel beside the conversation shows: the row says so.
    private var open: Bool { selection?.sheet?.source == row.id }
    #else
    private let open = false
    #endif

    var body: some View {
        let spawned = row.spawned(activity)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let row = row
                openSheet?(FeedSheet(title: activity.live ? "Working" : activity.headline, source: row.id) {
                    ActivitySteps(row: row)
                })
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("\(activity.headline), \(activity.counts)")
            .accessibilityHint("Shows every step")
            if !spawned.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(spawned.enumerated()), id: \.offset) { _, mention in
                        SubagentChip(mention: mention)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if activity.live {
                AgentMark(symbol: "sparkle", color: Palette.accent, size: 18, working: true)
            }
            Text(activity.headline).font(.system(size: 13, weight: .medium))
                .foregroundStyle(activity.live ? Palette.accent : Palette.moon)
                .lineLimit(1)
                .shimmer(activity.live)
            Text(activity.counts).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            if activity.failures > 0 {
                Label("\(activity.failures) failed", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.danger)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !activity.live, let duration = activity.duration, duration >= 1000 {
                Text(Format.duration(ms: duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(open ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .card(radius: 12, fill: open ? Palette.raised : Palette.surface.opacity(0.7),
              border: activity.live || open ? Palette.accent.opacity(open ? 0.75 : 0.5) : Palette.lit.opacity(0.85))
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// An activity's steps, where they open: each one unfolds in place there. Follows the row, so a running activity's
/// new steps come in as they happen.
private struct ActivitySteps: View {
    let row: FeedRow

    var body: some View {
        if case .activity(let activity) = row.block {
            VStack(alignment: .leading, spacing: 12) {
                Text(activity.counts.trimmingCharacters(in: CharacterSet(charactersIn: "· ")))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Timeline(steps: activity.steps, live: activity.live && row.streaming)
            }
        }
    }
}

struct EarlierButton: View {
    let state: FeedState
    let load: () -> Void

    var body: some View {
        Button(action: load) {
            HStack(spacing: 8) {
                if state.loadingEarlier { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up") }
                Text("Earlier conversation")
            }
            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.moon)
            .padding(.horizontal, 14).frame(height: 32)
            .card(radius: 16, fill: Palette.raised, border: Palette.border)
        }
        .buttonStyle(PressStyle())
        .disabled(state.loadingEarlier)
        .frame(maxWidth: .infinity)
    }
}

/// Under the last row: an empty or still-loading conversation, the compaction underway, where an idle session stands.
struct FeedFooter: View {
    let state: FeedState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.empty {
                if let pending = state.pending {
                    if !pending.isEmpty { PendingTranscript(text: pending, unreachable: pending.hasPrefix("Can't")) }
                } else if let session = state.session {
                    EmptyTranscript(session: session)
                }
            }
            if state.session?.status == .compacting {
                CompactingMarker()
            }
            ForEach(state.idle) { line in
                if let action = line.action {
                    Button(action: action) {
                        HStack(spacing: 6) {
                            WorkingIndicator(text: line.text, systemImage: line.systemImage, tint: line.tint, live: false)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(line.tint.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    WorkingIndicator(text: line.text, systemImage: line.systemImage, tint: line.tint, live: false)
                }
            }
        }
        .frame(maxWidth: Layout.column, alignment: .leading)
        .padding(.horizontal, Layout.gutter)
        .frame(maxWidth: .infinity)
    }
}
