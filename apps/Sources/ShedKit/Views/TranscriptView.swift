// The normalized transcript in a centered reading column: messages, grouped agent activity, compactions and notes.
import CoreText
@preconcurrency import MarkdownUI
import SwiftUI

/// A run of items shown as one unit. Consecutive reasoning and tool calls become one activity group.
enum Block: Identifiable, Equatable {
    case item(Item)
    case activity(Activity)
    /// Background commands that finished back to back (the agent stopping its servers, say): one card, not a stack.
    case jobsDone([Item])

    var id: String {
        switch self {
        case .item(let item): item.id
        case .activity(let activity): activity.id
        case .jobsDone(let items): "jobs-" + (items.first?.id ?? "")
        }
    }

    /// The item it starts with, which stays in it as more arrive (an activity group can also grow backward, when an
    /// earlier page loads).
    var firstItemId: String? {
        switch self {
        case .item(let item): item.id
        case .activity(let activity): activity.steps.first?.id
        case .jobsDone(let items): items.first?.id
        }
    }

    func contains(_ itemId: String) -> Bool {
        switch self {
        case .item(let item): item.id == itemId
        case .activity(let activity): activity.steps.contains { $0.id == itemId }
        case .jobsDone(let items): items.contains { $0.id == itemId }
        }
    }
}

struct Activity: Equatable {
    struct Step: Identifiable, Equatable {
        let item: Item
        /// When the step ended: its own duration, else when the next item started.
        let duration: Double?
        var id: String { item.id }
    }

    let steps: [Step]
    /// Still the latest block of a running session.
    let live: Bool
    let duration: Double?

    var id: String { "activity-" + (steps.first?.id ?? "") }
    var toolCount: Int { steps.count { $0.item.kind == .tool } }
    var reasoningCount: Int { steps.count { $0.item.kind == .thinking } }
    var failures: Int { steps.count { $0.item.status == .error } }

    static func blocks(_ items: [Item], busy: Bool) -> [Block] {
        var blocks: [Block] = []
        var run: [(item: Item, index: Int)] = []

        // When the next thing happened, which ends a step. Hidden items count too: an empty reply still marks the end
        // of a turn, and a note (a background command finishing) starts the next one.
        func next(after index: Int) -> Double? {
            items[(index + 1)...].lazy.compactMap(\.at).first { at in at > (items[index].at ?? 0) }
        }
        // A step ends when it says it took, else when the next thing happened.
        func end(of index: Int) -> Double? {
            let item = items[index]
            if let at = item.at, let duration = item.durationMs { return at + Double(duration) }
            return next(after: index)
        }
        func flush(endingAt end: Double?, live: Bool) {
            guard !run.isEmpty else { return }
            // No step outlasts the run: reasoning shares its message's timestamp with the reply that follows it.
            let steps = run.map { item, index in
                let until = [next(after: index), end].compactMap { $0 }.min()
                return Activity.Step(item: item, duration: item.durationMs.map(Double.init) ?? zip(item.at, until).map { max(0, $1 - $0) })
            }
            let start = run.first?.item.at
            blocks.append(.activity(Activity(steps: steps, live: live, duration: zip(start, end).map { $1 - $0 })))
            run = []
        }

        for (index, item) in items.enumerated() where item.isVisible {
            if item.kind == .tool || item.kind == .thinking {
                run.append((item, index))
            } else {
                // The item after the run closes it: a reply's reasoning and text share the message's timestamp, so
                // the text can't be skipped as "the same moment" to whatever comes next, minutes later.
                let closed = run.last.flatMap { last in items[last.index].durationMs == nil ? item.at : end(of: last.index) }
                flush(endingAt: closed, live: false)
                // A bash-done notice right after another (the agent's empty replies between them are hidden) joins it.
                if item.isJobDone, let last = blocks.last {
                    switch last {
                    case .item(let previous) where previous.isJobDone:
                        blocks[blocks.count - 1] = .jobsDone([previous, item])
                        continue
                    case .jobsDone(let previous):
                        blocks[blocks.count - 1] = .jobsDone(previous + [item])
                        continue
                    default: break
                    }
                }
                blocks.append(.item(item))
            }
        }
        flush(endingAt: busy ? nil : run.last.flatMap { end(of: $0.index) }, live: busy)
        return blocks
    }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    guard let a, let b else { return nil }
    return (a, b)
}

extension Item {
    var isJobDone: Bool { kind == .note && text.hasPrefix("[bash-done") }

    var isVisible: Bool {
        switch kind {
        // Stops at the first visible character: trimming copied every message's whole text on each render.
        case .thinking, .text: text.contains { !$0.isWhitespace }
        default: true
        }
    }
}

/// Where a collapsible block starts in the transcript's content. A class so tracking it never re-renders the block;
/// it only changes when the layout above it does, not as the transcript scrolls.
final class BlockTop {
    var y: CGFloat = 0
}

/// Collapsing a block that starts above the top of the screen would leave the reader somewhere further down: this
/// brings its header back to the top instead. Called inside the collapse's animation.
struct KeepInView: Equatable {
    /// The space blocks say where they start in: the content of the scroll view that keeps them in view.
    nonisolated static let space = "keep-in-view"

    var action: @MainActor (CGFloat) -> Void = { _ in }

    @MainActor func callAsFunction(_ top: BlockTop) { action(top.y) }

    /// The transcript passes a fresh closure each time it updates. Unequal, that would invalidate every block that reads
    /// it, so the whole conversation re-rendered whenever anything changed.
    static func == (_: KeepInView, _: KeepInView) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var keepInView = KeepInView()
    /// Stops the tool call that is running, where the reader may do that.
    @Entry var stopTool: ReaderAction? = nil
    /// Restarts the session's Python kernel, where it has one the reader may restart.
    @Entry var restartKernel: ReaderAction? = nil
    /// Replies streaming in, ahead of the transcript's items.
    @Entry var liveText: LiveText? = nil
    /// Where a row's details open instead of unfolding in place: on the phone a sheet over the conversation, on the
    /// Mac a panel beside it.
    @Entry var openSheet: SheetOpener? = nil
    /// Set inside such a sheet: closes it, then does what was asked once it has gone. Going to another session from
    /// under a sheet would leave the sheet standing over it.
    @Entry var closeSheet: SheetCloser? = nil
    /// Where the conversation's mentions of subagents lead.
    @Entry var subagents: SubagentLinks? = nil
    /// Whether text can be selected where it stands. The phone's conversation says no: every selectable text is
    /// something a touch is checked against before a scroll can start, so there a long press copies instead.
    @Entry var inlineSelection = true
}

extension View {
    /// Selectable text, unless selecting in place is off here (`inlineSelection`).
    @ViewBuilder func selectable(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

/// What a row shows when its details open beside or over the conversation, rather than unfolding in it.
struct FeedSheet: Identifiable {
    let id = UUID()
    let title: String
    /// What it was opened from, where that is one thing the reader can open again: the Mac's panel closes when it is.
    let source: String?
    let content: @MainActor () -> AnyView

    init<Content: View>(title: String, source: String? = nil, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.title = title
        self.source = source
        self.content = { AnyView(content()) }
    }
}

/// Closes the sheet a view is in, then runs the action. Any two compare equal, like `SheetOpener`.
struct SheetCloser: Equatable {
    let action: @MainActor (@escaping @MainActor () -> Void) -> Void

    @MainActor func callAsFunction(then: @escaping @MainActor () -> Void) { action(then) }

    static func == (_: SheetCloser, _: SheetCloser) -> Bool { true }
}

/// The subagents of the session a conversation belongs to: what a mention of one leads to, and the way there. The
/// store is observed where a link is read, so a chip follows its subagent ending without the conversation redrawing.
struct SubagentLinks: Equatable {
    let store: SessionStore
    let parent: String

    @MainActor func link(_ mention: SubagentMention) -> SubagentLink { store.link(of: parent, to: mention) }
    @MainActor func open(_ id: String) { store.select(id) }

    static func == (a: SubagentLinks, b: SubagentLinks) -> Bool { a.store === b.store && a.parent == b.parent }
}

/// A subagent a step started, as a chip that opens it. One that has ended stays named, dimmed, and leads nowhere.
struct SubagentChip: View {
    let mention: SubagentMention
    @Environment(\.subagents) private var subagents
    @Environment(\.closeSheet) private var closeSheet

    var body: some View {
        let name = mention.name
        let link = subagents?.link(mention) ?? .pending
        Button {
            guard case .open(let id) = link, let subagents else { return }
            if let closeSheet { closeSheet { subagents.open(id) } } else { subagents.open(id) }
        } label: {
            HStack(spacing: 6) {
                AgentMark(name: name, size: 18, asleep: link == .ended)
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.moon.opacity(link == .ended ? 0.5 : 1))
                    .lineLimit(1)
                if link != .ended {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4).padding(.trailing, 10).frame(height: 26)
            .card(radius: 13, fill: Palette.raised.opacity(link == .ended ? 0.5 : 1),
                  border: link == .ended ? Palette.border.opacity(0.6) : Palette.avatar(name).opacity(0.35))
        }
        .buttonStyle(.plain)
        .allowsHitTesting(link != .ended)
        .help(link == .ended ? "\(name) has ended" : "Open subagent \(name)")
        .accessibilityLabel(link == .ended ? "\(name), ended" : "Open subagent \(name)")
        .animation(.easeOut(duration: 0.25), value: link)
    }
}

/// Opens a row's details in a sheet. Any two compare equal, like `ReaderAction`: a fresh closure changes nothing shown.
struct SheetOpener: Equatable {
    let action: @MainActor (FeedSheet) -> Void

    @MainActor func callAsFunction(_ sheet: FeedSheet) { action(sheet) }

    static func == (_: SheetOpener, _: SheetOpener) -> Bool { true }
}

/// An action the open session offers its transcript. Whether it is there is all that changes what a view shows, so
/// any two compare equal and passing a fresh closure doesn't invalidate the views that read it.
struct ReaderAction: Equatable {
    let perform: @MainActor () -> Void
    static func == (_: ReaderAction, _: ReaderAction) -> Bool { true }
}

extension View {
    /// Asks before restarting a Python kernel: whatever it held is lost.
    func confirmRestartKernel(_ isPresented: Binding<Bool>, restart: @escaping () -> Void) -> some View {
        confirmationDialog("Restart the Python kernel?", isPresented: isPresented, titleVisibility: .visible) {
            Button("Restart Kernel", role: .destructive, action: restart)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Ends whatever the kernel is still running and clears its variables and imports. The agent's next Python call starts fresh.")
        }
    }
}

extension View {
    /// Records where this view starts in the scroll view it is in, for `KeepInView`.
    func trackTop(_ top: BlockTop) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(KeepInView.space)).minY } action: { top.y = $0 }
    }
}

/// Takes the space it is offered without measuring what it holds. A scroll view asked for its size measures its whole
/// content: the composer's inset asked on every flush of a streaming reply, laying out the conversation once more.
struct FillsProposal: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }

    /// No alignment guides of its own: the default asks the content for its guides, measuring the conversation again.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

extension View {
    func fillsProposal() -> some View { FillsProposal { self } }
}

struct EmptyTranscript: View {
    let session: SessionSummary

    var body: some View {
        VStack(spacing: 12) {
            AgentMark(agent: session.agent, size: 60, working: session.status.isBusy)
                .padding(.bottom, 6)
            Text(session.isSubagent ? "Waiting for the subagent to start" : "What would you like to work on?")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Palette.moon)
            Text("\(session.agent.displayName) in \(Format.path(session.cwd))")
                .font(.system(size: 13.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// A conversation still on its way, or out of reach: said plainly, so it never passes for an empty one.
struct PendingTranscript: View {
    let text: String
    let unreachable: Bool

    var body: some View {
        VStack(spacing: 14) {
            if unreachable {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(Palette.danger)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(text).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.moon)
            if unreachable {
                Text("The conversation will appear once the connection is back.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }
}

/// One line of where an idle session stands, e.g. "Waiting on `cargo build`", opening the list it summarizes.
struct IdleLine: Identifiable, Equatable {
    let id: String
    let text: String
    let systemImage: String
    let tint: Color
    var action: (() -> Void)? = nil

    static func == (a: IdleLine, b: IdleLine) -> Bool {
        a.id == b.id && a.text == b.text && a.systemImage == b.systemImage && a.tint == b.tint && (a.action == nil) == (b.action == nil)
    }
}

struct WorkingIndicator: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Palette.accent
    var live = true

    var body: some View {
        HStack(spacing: 9) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint)
            } else {
                Ember()
            }
            Text(text).font(.system(size: 13.5)).foregroundStyle(tint).shimmer(live)
        }
        .padding(.leading, 4)
    }
}

/// Equatable so a block that hasn't changed skips its body (and its Markdown parse) when the transcript re-renders,
/// as it does on every streamed delta. The callbacks only route to the store, so they don't count.
struct BlockView: View, Equatable {
    let block: Block
    let agent: AgentKind
    let openParent: (@MainActor () -> Void)?
    /// The last block of a running turn: text still arriving.
    var streaming = false

    nonisolated static func == (a: BlockView, b: BlockView) -> Bool {
        a.block == b.block && a.agent == b.agent && a.streaming == b.streaming && (a.openParent == nil) == (b.openParent == nil)
    }

    var body: some View {
        switch block {
        case .activity:
            // A row of its own in the feed: `ActivityRow`.
            EmptyView()
        case .jobsDone(let items):
            JobsDoneGroup(notes: items.map { Note($0.text) })
        case .item(let item):
            switch item.kind {
            case .user:
                UserMessage(item: item)
            case .text:
                StreamingMarkdown(text: item.text, streaming: streaming, id: item.id)
            case .compaction:
                CompactionMarker(item: item)
            case .error:
                Label(item.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Palette.danger)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 12, fill: Palette.danger.opacity(0.08), border: Palette.danger.opacity(0.45))
            case .note:
                NoteView(note: Note(item.text), date: item.date, openParent: openParent)
            case .thinking, .tool:
                EmptyView()
            }
        }
    }
}

struct UserMessage: View {
    let item: Item
    @Environment(\.inlineSelection) private var inlineSelection

    var body: some View {
        let (text, files) = MessageAttachments.split(item.text)
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(files, id: \.self) { path in
                MediaView(url: URL(fileURLWithPath: path))
                    .frame(maxWidth: 360, alignment: .trailing)
            }
            if !text.isEmpty {
                Text(text)
                    .selectable(inlineSelection)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Palette.moon)
                    .lineSpacing(4)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [Palette.userBubble.opacity(0.95), Palette.userBubble.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Palette.userBubbleBorder, Palette.userBubbleBorder.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                    }
            }

            if item.status == .pending {
                // Sent, not yet back from the agent.
                Text("Sending…").font(.caption2).foregroundStyle(.tertiary)
            } else if let date = item.date {
                Text(Format.time(date)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .opacity(item.status == .pending ? 0.65 : 1)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 80)
    }
}

// MARK: Activity

extension Activity {
    /// What it is doing now while live, how long it worked once done.
    var headline: String {
        let activity = self
        if activity.live {
            let last = activity.steps.last.map(\.item)
            if last?.kind == .thinking { return Reasoning(last!.text).title ?? "Thinking" }
            if let last, last.kind == .tool { let d = ToolDescription(last); return d.title + (d.detail.map { " " + $0.prefix(60) } ?? "") }
            return "Working"
        }
        return activity.duration.map { $0 >= 1000 ? "Worked for \(Format.duration(ms: $0))" : "Worked" } ?? "Worked"
    }

    /// "· 18 tool calls · 6 reasoning steps".
    var counts: String {
        let activity = self
        var parts: [String] = []
        if activity.toolCount > 0 { parts.append(activity.toolCount == 1 ? "1 tool call" : "\(activity.toolCount) tool calls") }
        if activity.reasoningCount > 0 { parts.append(activity.reasoningCount == 1 ? "1 reasoning step" : "\(activity.reasoningCount) reasoning steps") }
        return parts.isEmpty ? "" : "· " + parts.joined(separator: " · ")
    }
}

/// Steps along a vertical rail, each with a status node.
struct Timeline: View {
    let steps: [Activity.Step]
    let live: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    StepNode(item: step.item, running: live && step.id == steps.last?.id)
                    Group {
                        if step.item.kind == .thinking {
                            ReasoningRow(text: step.item.text, duration: step.duration)
                        } else {
                            ToolRow(item: step.item, duration: step.duration)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -8)), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: steps.count)
        .padding(.leading, 6)
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(LinearGradient(colors: [Palette.ice.opacity(0.55), Palette.rail, live ? Palette.accent.opacity(0.7) : Palette.rail.opacity(0.4)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1.5)
                .padding(.vertical, 18)
                .padding(.leading, 6 + 10.25)
        }
    }
}

struct StepNode: View {
    let item: Item
    let running: Bool

    var body: some View {
        let tint = self.tint
        ZStack {
            // A halo drawn as a gradient, not a shadow: a shadow is a second render pass on every row while scrolling.
            if item.status == .running || item.status == .pending {
                Circle().fill(RadialGradient(colors: [tint.opacity(0.45), tint.opacity(0)], center: .center, startRadius: 8, endRadius: 17))
                    .frame(width: 34, height: 34)
            }
            Circle().fill(Palette.canvas).frame(width: 22, height: 22)
            Circle().fill(tint.opacity(0.14)).frame(width: 22, height: 22)
            Circle().strokeBorder(tint.opacity(0.6), lineWidth: 1).frame(width: 22, height: 22)
            symbol.foregroundStyle(tint)
        }
        .frame(width: 22, height: 22)
        .padding(.top, 7)
        .accessibilityHidden(true)
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: item.status)
    }

    private var tint: Color {
        if item.kind == .thinking { return Palette.lilac }
        switch item.status {
        case .error: return Palette.danger
        case .done: return Palette.ice
        default: return Palette.accent
        }
    }

    @ViewBuilder private var symbol: some View {
        if item.kind == .thinking {
            Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold))
        } else {
            switch item.status {
            case .error: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).transition(.scale)
            case .done: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).transition(.scale)
            default: Ember(size: 6)
            }
        }
    }
}

/// The square icon in front of each step.
struct StepIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Palette.ice.opacity(0.85))
            .frame(width: 24, height: 24)
            .card(radius: 7, fill: Palette.raised)
    }
}

struct ReasoningRow: View {
    let text: String
    let duration: Double?
    @State private var expanded = false
    @State private var top = BlockTop()
    @Environment(\.keepInView) private var keepInView

    var body: some View {
        let reasoning = Reasoning(text)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    if expanded { keepInView(top) }
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    StepIcon(systemName: "brain")
                    Text(reasoning.title ?? "Reasoning").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    if !expanded, reasoning.title != nil {
                        Text(reasoning.body).font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let duration, duration >= 1000 {
                        Text("Thought for \(Format.duration(ms: duration))").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Chevron(open: expanded)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                ReasoningLines(text: reasoning.body)
                    .padding(.leading, 32)
                    .padding(.bottom, 10)
            } else if reasoning.title == nil {
                // Only the first lines show: no need to lay out the rest of a long, still-growing text.
                ReasoningLines.style(Text(reasoning.body.prefix(400)))
                    .lineLimit(2)
                    .padding(.leading, 32)
                    .padding(.bottom, 10)
            }
        }
        .trackTop(top)
    }
}

/// Open reasoning, one Text per line: as it streams, only the line being written is laid out again, not everything
/// thought so far, which on a phone kept the main thread busy and the row slow to close.
struct ReasoningLines: View {
    let text: String

    static func style(_ text: Text) -> some View {
        text.font(.system(size: 13)).italic().foregroundStyle(.secondary).lineSpacing(3)
    }

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        VStack(alignment: .leading, spacing: 7) {
            Finished(lines: lines.dropLast()).equatable()
            if let last = lines.last { Self.style(Text(last)).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    /// The lines before the last, which no longer change while the reasoning streams.
    private struct Finished: View, Equatable {
        let lines: ArraySlice<Substring>

        nonisolated static func == (a: Finished, b: Finished) -> Bool { a.lines.elementsEqual(b.lines) }

        var body: some View {
            ForEach(lines.indices, id: \.self) { index in
                ReasoningLines.style(Text(lines[index])).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Where the context was compacted: a marker naming the context's size then, opening onto the summary the agent
/// carries on from.
struct CompactionMarker: View {
    let item: Item
    @State private var expanded = false
    @Environment(\.openSheet) private var openSheet

    var body: some View {
        let before = item.output.flatMap(Int.init).map { " at " + Format.tokens($0) + " tokens" } ?? ""
        VStack(spacing: 10) {
            Button {
                if let openSheet {
                    let summary = item.text
                    openSheet(FeedSheet(title: "Context compacted") {
                        StreamingMarkdown(text: summary, streaming: false)
                    })
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 10) {
                    if openSheet == nil { VStack { Divider() } }
                    HStack(spacing: 6) {
                        Label("Context compacted" + before, systemImage: "rectangle.compress.vertical")
                        if !item.text.isEmpty {
                            if openSheet != nil {
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            } else {
                                Chevron(open: expanded)
                            }
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.lilac)
                    .lineLimit(1)
                    .padding(.horizontal, 12).frame(height: 26)
                    .card(radius: 13, fill: Palette.lilac.opacity(0.08), border: Palette.lilac.opacity(0.3))
                    if openSheet == nil { VStack { Divider() } }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(item.text.isEmpty)
            if expanded {
                StreamingMarkdown(text: item.text, streaming: false)
                    .padding(14)
                    .card(radius: 12, fill: Palette.lilac.opacity(0.05), border: Palette.lilac.opacity(0.25))
                    .transition(.opacity)
            }
        }
    }
}

/// Where the compacted marker will go, while the agent condenses the conversation: it can take a minute or two.
struct CompactingMarker: View {
    @State private var start = Date.now

    var body: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            HStack(spacing: 7) {
                ProgressView().controlSize(.mini).tint(Palette.lilac)
                Text("Compacting context").shimmer(true)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.duration(ms: max(0, context.date.timeIntervalSince(start)) * 1000))
                        .monospacedDigit().foregroundStyle(Palette.lilac.opacity(0.6))
                        .contentTransition(.numericText())
                }
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.lilac)
            .lineLimit(1)
            .padding(.horizontal, 12).frame(height: 26)
            .card(radius: 13, fill: Palette.lilac.opacity(0.08), border: Palette.lilac.opacity(0.3))
            VStack { Divider() }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Chevron: View {
    let open: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? 180 : 0))
            .frame(width: 14)
    }
}

struct ToolRow: View {
    let item: Item
    let duration: Double?
    @State private var expanded = false
    @State private var top = BlockTop()
    @Environment(\.keepInView) private var keepInView
    @Environment(\.stopTool) private var stopTool
    @Environment(\.restartKernel) private var restartKernel
    @State private var confirmingStop = false
    @State private var confirmingRestart = false

    private var running: Bool { item.status == .running || item.status == .pending }

    var body: some View {
        let description = ToolDescription(item)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    if expanded { keepInView(top) }
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    StepIcon(systemName: description.icon)
                    Text(description.title).font(.system(size: 13, weight: .medium))
                    if let detail = description.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.mono(12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 8)
                    if running, let at = item.at {
                        RunningFor(since: at)
                    } else if let duration, duration >= 100 {
                        Text(Format.duration(ms: duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Chevron(open: expanded)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.toolName ?? "")

            if !description.spawned.isEmpty {
                HStack(spacing: 6) {
                    ForEach(description.spawned, id: \.self) { name in
                        SubagentChip(mention: SubagentMention(name: name, date: item.date, spawning: true, running: running))
                    }
                }
                .padding(.leading, 32)
                .padding(.bottom, 8)
            }

            let attached = ToolDescription.attachedImages(item)
            if !attached.isEmpty {
                AttachedImages(paths: attached, loaded: item.status == .done)
                    .padding(.leading, 32)
                    .padding(.bottom, 8)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let args = item.args, !args.isEmpty {
                        CodePanel(title: description.language == "python" ? "Python" : description.language == "bash" ? "Shell" : "Input",
                                  text: inputText(args), language: inputText(args) == args ? description.language : "json",
                                  lineNumbers: true)
                    }
                    if let output = item.output, !output.isEmpty {
                        CodePanel(title: item.status == .error ? "Error" : "Output", text: output, language: nil, lineNumbers: false,
                                  tint: item.status == .error ? Palette.danger : nil)
                        // Prime's answer when an interrupted cell won't stop: only a fresh kernel gets Python back.
                        if let restartKernel, output.contains("kernel is still running the previously interrupted cell") {
                            Button { confirmingRestart = true } label: {
                                Label("Restart Python Kernel", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Palette.accent)
                                    .padding(.horizontal, 12).frame(height: 28)
                                    .background(Palette.accent.opacity(0.14), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.45)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(PressStyle())
                            .confirmRestartKernel($confirmingRestart) { restartKernel.perform() }
                        }
                    } else if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Running…").font(.caption).foregroundStyle(.secondary)
                            if let at = item.at { RunningFor(since: at) }
                            Spacer(minLength: 8)
                            if let stopTool {
                                Button { confirmingStop = true } label: {
                                    Label("Stop", systemImage: "stop.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Palette.accent)
                                        .padding(.horizontal, 10).frame(height: 24)
                                        .background(Palette.accent.opacity(0.14), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Palette.accent.opacity(0.45)))
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(PressStyle())
                                .help("Stop this tool call")
                                .confirmationDialog("Stop this tool call?", isPresented: $confirmingStop, titleVisibility: .visible) {
                                    Button("Stop", role: .destructive) { stopTool.perform() }
                                    Button("Keep Waiting", role: .cancel) {}
                                } message: {
                                    Text("The agent's turn ends here. Messages you queued are sent right away so it can carry on.")
                                }
                            }
                        }
                    }
                }
                .padding(10)
                .card(radius: 12, fill: Palette.surface.opacity(0.7))
                .padding(.bottom, 10)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)), removal: .opacity))
            }
        }
        .trackTop(top)
    }

    /// Pretty-print JSON arguments; code stays as it is.
    private func inputText(_ args: String) -> String {
        if (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] != nil, args.hasPrefix("{"),
           let code = ToolDescription.code(fromArgs: args) {
            return code
        }
        guard args.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(args.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return args }
        return text
    }
}

/// How long a running call has been going, ticking every second.
struct RunningFor: View {
    /// When it started, in milliseconds since 1970.
    let since: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Format.duration(ms: max(0, context.date.timeIntervalSince1970 * 1000 - since)))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .contentTransition(.numericText())
        }
    }
}

/// Monospaced input or output: header with copy, optional line numbers and highlighting, and a fade over long content.
struct CodePanel: View {
    let title: String
    let text: String
    var language: String? = nil
    var lineNumbers = false
    var tint: Color? = nil
    @State private var showAll = false
    @State private var top = BlockTop()
    @State private var width: CGFloat = 0
    /// Python laid out to fit the panel rather than as the agent wrote it.
    @AppStorage("code.readablePython") private var readable = true
    @Environment(\.keepInView) private var keepInView

    private static let cap = 14
    private static let fontSize: CGFloat = 12
    private static let charWidth: CGFloat = {
        let font = CTFontCreateWithName(Font.monoFamily as CFString, fontSize, nil)
        var glyph = CGGlyph()
        var zero = UniChar(48)
        CTFontGetGlyphsForCharacters(font, &zero, &glyph, 1)
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        return advance > 0 ? advance : fontSize * 0.6
    }()

    private var reflows: Bool { language == "python" && readable }

    var body: some View {
        let shownText = reflows && width > 0 ? PythonLayout.readable(text, width: Int((width - 24) / Self.charWidth)) : text
        let lines = shownText.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let shown = showAll ? lines : Array(lines.prefix(Self.cap))
        let clipped = lines.count > Self.cap && !showAll
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint ?? .primary)
                Text(lines.count == 1 ? "1 line" : "\(lines.count) lines").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if language == "python" {
                    Button { readable.toggle() } label: {
                        Label(readable ? "Readable" : "As written", systemImage: readable ? "text.alignleft" : "chevron.left.forwardslash.chevron.right")
                            .font(.caption)
                            .padding(.horizontal, 8).frame(height: 22)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
                    }
                    .buttonStyle(.plain)
                    .help(readable ? "Laid out to fit: show the code as the agent wrote it" : "Show the code laid out to fit the screen")
                }
                CopyButton(text: text, label: "Copy")
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
            }
            .padding(.horizontal, 12).frame(height: 36)

            let code = HStack(alignment: .top, spacing: 14) {
                // Line numbers would count the laid-out lines, not the agent's.
                if lineNumbers && !reflows {
                    Text(shown.indices.map { String($0 + 1) }.joined(separator: "\n"))
                        .foregroundStyle(Palette.lineNumber)
                        .multilineTextAlignment(.trailing)
                }
                Text(Syntax.highlight(shown.joined(separator: "\n"), language: language))
                    .foregroundStyle(tint ?? .primary)
                    .fixedSize(horizontal: !reflows, vertical: false)
            }
            .font(.mono(Self.fontSize))
            .lineSpacing(3)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .padding(.bottom, clipped ? 26 : 0)
            Group {
                // Laid out to fit, what's still too long (a long string) wraps rather than scrolling sideways.
                if reflows { code } else { ScrollView(.horizontal, showsIndicators: false) { code } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border.opacity(0.7)))
            .overlay(alignment: .bottom) {
                if lines.count > Self.cap {
                    VStack(spacing: 0) {
                        if clipped {
                            LinearGradient(colors: [Palette.sunken.opacity(0), Palette.sunken], startPoint: .top, endPoint: .bottom)
                                .frame(height: 36)
                                .allowsHitTesting(false)
                        }
                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                if showAll { keepInView(top) }
                                showAll.toggle()
                            }
                        } label: {
                            Label(showAll ? "Show less" : "Show all \(lines.count) lines", systemImage: showAll ? "arrow.up" : "arrow.down")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).frame(height: 24)
                                .background(Palette.surface, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.border))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background(clipped ? Palette.sunken : Color.clear)
                        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                    }
                    .padding(1)
                }
            }
            .padding(.horizontal, 2)
        }
        .overlay(alignment: .leading) {
            if let tint { Rectangle().fill(tint).frame(width: 2).padding(.vertical, 40) }
        }
        .trackTop(top)
    }
}

/// Light syntax colouring for code in tool inputs and shared files: keywords, strings, comments and numbers.
enum Syntax {
    private static let keywords: [String: Set<String>] = [
        "python": ["def", "return", "await", "async", "import", "from", "as", "for", "in", "if", "elif", "else", "while", "with",
                   "try", "except", "finally", "class", "lambda", "not", "and", "or", "is", "None", "True", "False", "print", "pass", "raise", "yield"],
        "bash": ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "in", "echo", "cd", "export", "sudo"],
        "json": ["true", "false", "null"],
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch", "for", "in",
                  "while", "import", "extension", "protocol", "static", "private", "public", "self", "nil", "true", "false", "try",
                  "await", "async", "throws", "some", "where", "init"],
        "rust": ["fn", "let", "mut", "if", "else", "match", "return", "struct", "enum", "impl", "trait", "for", "in", "while", "loop",
                 "use", "mod", "pub", "self", "Self", "true", "false", "async", "await", "move", "ref", "where", "const", "static", "Some", "None", "Ok", "Err"],
        "javascript": ["function", "const", "let", "var", "if", "else", "return", "for", "of", "in", "while", "class", "new", "import",
                       "export", "from", "default", "async", "await", "true", "false", "null", "undefined", "this", "type", "interface"],
        "go": ["func", "var", "const", "if", "else", "return", "for", "range", "struct", "type", "interface", "package", "import",
               "go", "defer", "chan", "map", "switch", "case", "nil", "true", "false"],
    ]

    static func highlight(_ code: String, language: String?, limit: Int = 20_000) -> AttributedString {
        var result = AttributedString(code)
        guard let language, let words = keywords[language], code.utf16.count < limit else { return result }
        let comment: String? = switch language {
        case "json": nil
        case "python", "bash": #"#[^\n]*"#
        default: #"//[^\n]*|/\*[\s\S]*?\*/"#
        }
        let strings = #"("""[\s\S]*?"""|'''[\s\S]*?'''|"(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*')"#
        let patterns: [(String, Color)] = [
            (#"\b\d+(\.\d+)?\b"#, Palette.accent),
            (#"\b(\#(words.joined(separator: "|")))\b"#, Palette.lilac),
            // Strings and comments in one pass, so whichever starts first wins: `"https://…"` stays a string, `# it's`
            // stays a comment.
            (comment.map { "(?<comment>\($0))|\(strings)" } ?? strings, Palette.rose),
        ]
        // Later patterns win, so strings and comments override keywords inside them.
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let range = Range(match.range, in: code), let attributed = Range(range, in: result) else { continue }
                let isComment = comment != nil && match.range(withName: "comment").location != NSNotFound
                result[attributed].foregroundColor = isComment ? .secondary : color
            }
        }
        return result
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 26

    var body: some View { AgentMark(name: name, size: size) }
}

// MARK: Notes

/// Prime delivers asynchronous traffic as tagged notes: "[agent-message from child:NAME] …",
/// "[child-exited: no-reply child:NAME] …", "[task from parent] …", "[bash-done pid:N exit:N] …".
struct Note {
    enum Kind { case fromChild, childExited, fromParent, jobDone, other }

    let kind: Kind
    let tag: String
    let body: String
    let child: String?
    let exitCode: Int?

    init(_ text: String) {
        guard text.hasPrefix("["), let close = text.firstIndex(of: "]") else {
            (kind, tag, body, child, exitCode) = (.other, "", text, nil, nil)
            return
        }
        tag = String(text[text.index(after: text.startIndex)..<close])
        body = text[text.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
        child = tag.split(separator: " ").first { $0.hasPrefix("child:") }.map { String($0.dropFirst("child:".count)) }
        exitCode = tag.split(separator: " ").first { $0.hasPrefix("exit:") }.flatMap { Int($0.dropFirst("exit:".count)) }
        // Messages from the parent name it by session id: "[agent-message from 01a18c7a-…]".
        kind = if tag.hasPrefix("agent-message"), child != nil { .fromChild }
            else if tag.hasPrefix("child-exited") { .childExited }
            else if tag.hasPrefix("task from parent") || tag.hasPrefix("agent-message from") { .fromParent }
            else if tag.hasPrefix("bash-done") { .jobDone }
            else { .other }
    }
}

struct NoteView: View {
    let note: Note
    let date: Date?
    let openParent: (@MainActor () -> Void)?

    var body: some View {
        switch note.kind {
        case .fromChild:
            ReportCard(name: note.child ?? "subagent", caption: "reported", date: date, text: note.body,
                       child: note.child.map { SubagentMention(name: $0, date: date) })
        case .fromParent:
            ReportCard(name: "Parent", caption: note.tag.hasPrefix("task") ? "sent a task" : "sent a message", date: date, text: note.body,
                       icon: "arrow.turn.right.down", open: openParent)
        case .childExited:
            PausedChild(name: note.child ?? "subagent", date: date, detail: note.body)
        case .jobDone:
            JobDoneView(note: note)
        case .other:
            Label(note.tag.isEmpty ? note.body : "[\(note.tag)] \(note.body)", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// A subagent that stopped without reporting back: one quiet line like a report's, opening the subagent while it
/// can still be opened.
struct PausedChild: View {
    let name: String
    let date: Date?
    let detail: String
    @Environment(\.subagents) private var subagents

    var body: some View {
        let link = subagents?.link(SubagentMention(name: name, date: date)) ?? .pending
        Button {
            if case .open(let id) = link { subagents?.open(id) }
        } label: {
            HStack(spacing: 8) {
                Avatar(name: name, size: 22).saturation(0.4).opacity(0.8)
                (Text(name).fontWeight(.semibold).foregroundStyle(.primary)
                    + Text(" paused without a reply").foregroundStyle(.secondary))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if let date {
                    Text(Format.time(date)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
                }
                if link != .ended {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .card(radius: 11, fill: Palette.surface.opacity(0.4), border: Palette.border.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(link != .ended)
        .help(link == .ended ? "\(name) has ended" : detail.isEmpty ? "Open subagent \(name)" : detail)
        .accessibilityLabel("\(name) paused without a reply")
    }
}

/// A message between agents, as one quiet line: who, what (a one-line preview), when. Clicking it unfolds the full
/// Markdown under a rail, with Copy and Open.
struct ReportCard: View {
    let name: String
    /// What the sender did: "reported", "sent a task".
    let caption: String
    let date: Date?
    let text: String
    var icon: String? = nil
    /// The subagent that sent it, when one did: Open leads to its session while it has one.
    var child: SubagentMention? = nil
    var open: (@MainActor () -> Void)? = nil
    @State private var expanded = false
    @State private var hovering = false
    @State private var top = BlockTop()
    @Environment(\.keepInView) private var keepInView
    @Environment(\.openSheet) private var openSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let openSheet {
                    openSheet(FeedSheet(title: "\(name) \(caption)") { details })
                    return
                }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    if expanded { keepInView(top) }
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    badge
                    (Text(name).fontWeight(.semibold).foregroundStyle(.primary)
                        + Text(" \(caption)").foregroundStyle(.secondary))
                        .font(.system(size: 13))
                        .layoutPriority(1)
                    if !expanded {
                        // One line shows: the start of a long report is enough.
                        Text(ToolDescription.oneLine(String(text.prefix(300))))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if let date {
                        Text(Format.time(date)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary).fixedSize()
                    }
                    if openSheet != nil {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    } else {
                        Chevron(open: expanded)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .card(radius: 11, fill: hovering || expanded ? Palette.raised : Palette.surface.opacity(0.7),
                      border: expanded ? tint.opacity(0.45) : Palette.lit.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(expanded ? "Hide the message" : "Show the full message")

            if expanded {
                details
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)), removal: .opacity))
            }
        }
        .trackTop(top)
    }

    /// The whole message, with Copy and Open.
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            Markdown(text).markdownTheme(.agent).markdownImageProvider(.media)
            HStack(spacing: 14) {
                CopyButton(text: text, label: "Copy")
                OpenSession(child: child, open: open)
            }
        }
        .padding(16)
        .card(radius: 12, fill: Palette.surface.opacity(0.9), border: tint.opacity(0.4))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.9)).frame(width: 2).padding(.vertical, 14)
        }
    }

    private var tint: Color { icon == nil ? Palette.avatar(name) : Palette.accent }

    @ViewBuilder private var badge: some View {
        if let icon {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Palette.accent.gradient, in: Circle())
        } else {
            Avatar(name: name, size: 22)
        }
    }
}

/// "Open session" under a message between agents: the sender's session. Says so instead, quietly, once a subagent's
/// session has ended.
private struct OpenSession: View {
    let child: SubagentMention?
    let open: (@MainActor () -> Void)?
    @Environment(\.subagents) private var subagents
    @Environment(\.closeSheet) private var closeSheet

    var body: some View {
        if let child, let subagents {
            switch subagents.link(child) {
            case .open(let id): button { subagents.open(id) }
            case .pending: EmptyView()
            case .ended:
                Label("Session ended", systemImage: "moon.zzz")
                    .font(.caption).foregroundStyle(.tertiary)
                    .accessibilityLabel("\(child.name)'s session has ended")
            }
        } else if let open {
            button(open)
        }
    }

    private func button(_ action: @escaping @MainActor () -> Void) -> some View {
        Button {
            if let closeSheet { closeSheet(then: action) } else { action() }
        } label: {
            Label("Open session", systemImage: "arrow.up.forward")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.ice)
    }
}

/// What the model chose to look at: the images a call loaded into its context, as thumbnails that open full size.
struct AttachedImages: View {
    let paths: [String]
    /// Whether the call finished: until then the images are on their way into the context.
    let loaded: Bool

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(paths, id: \.self) { path in AttachedImage(path: path, loaded: loaded) }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }
}

private struct AttachedImage: View {
    let path: String
    let loaded: Bool
    @Environment(\.media) private var media
    @Environment(\.lightbox) private var lightbox
    @State private var image: CGImage?
    @State private var failed = false

    private var request: URLRequest? { media.request(for: media.url(forPath: path)) }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: thumbnailWidth(image), height: 132)
                    .clipShape(shape)
                    .transition(.opacity)
            } else {
                shape.fill(Palette.surface.opacity(0.6))
                    .frame(width: 176, height: 132)
                    .overlay {
                        Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                            .font(.system(size: 18)).foregroundStyle(Palette.lineNumber)
                    }
                    .shimmer(!failed)
            }
        }
        .overlay(shape.strokeBorder(Palette.lilac.opacity(loaded ? 0.55 : 0.3), lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.lilac)
                Text(loaded ? "In context" : "Loading").font(.system(size: 10, weight: .semibold))
                Text(name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 7).frame(height: 20)
            .background(Palette.canvas.opacity(0.82), in: Capsule())
            .padding(6)
        }
        .contentShape(shape)
        .onTapGesture {
            guard let image, let request else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                lightbox?.shown = .init(image: image, name: name, request: request)
            }
        }
        .help(path)
        .animation(.easeOut(duration: 0.3), value: image != nil)
        .task(id: request?.url) {
            guard let request else { failed = true; return }
            do { image = try await MediaCache.shared.image(for: request) } catch { failed = true }
        }
    }

    /// As wide as the image's shape asks at the strip's height, within reason.
    private func thumbnailWidth(_ image: CGImage) -> CGFloat {
        let aspect = image.height > 0 ? CGFloat(image.width) / CGFloat(image.height) : 4 / 3
        return min(max(132 * aspect, 96), 300)
    }
}
