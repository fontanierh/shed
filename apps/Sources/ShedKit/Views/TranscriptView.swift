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

/// Where the transcript's blocks were last laid out, in its content's coordinates. A block that has been measured and is
/// a few screens away from the reader draws as an empty space of its height: in one stack, a block that changes size
/// (a streaming reply, 12 times a second) moves every block after it and re-checks every block before it, down to each
/// line of text, so a reader deep in a long conversation kept the main thread busy. The heights are the ones measured,
/// so the scroll view's content stays exactly as tall and nothing moves when a block comes back. A class, so measuring
/// never re-renders the transcript.
final class BlockFrames {
    private var frames: [String: (frame: CGRect, since: Date)] = [:]
    /// The width blocks lay out at now. A height measured at another width no longer holds.
    private var width: CGFloat = 0

    /// The heights to hold for the blocks outside `near`; the others draw.
    func held(_ ids: [String], near: Range<CGFloat>?) -> [String: CGFloat] {
        guard let near else { return [:] }
        var held: [String: CGFloat] = [:]
        for id in ids {
            // A height only just measured may not hold yet: on the Mac, selectable text lays out again a moment later.
            if let (frame, since) = frames[id], frame.width == width, -since.timeIntervalSinceNow > 0.5,
               !near.overlaps(frame.minY..<frame.maxY + 1) { held[id] = frame.height }
        }
        return held
    }

    func known(_ id: String) -> Bool { frames[id] != nil }

    func height(of id: String) -> CGFloat? { frames[id]?.frame.height }

    /// Drawn blocks span the column, so any of them gives its width.
    func measured(_ id: String, _ frame: CGRect) {
        if let known = frames[id], known.frame.size == frame.size {
            frames[id]?.frame.origin = frame.origin
        } else {
            frames[id] = (frame, .now)
        }
        width = frame.width
    }

    /// A block held as a space moved with the blocks above it; its height and width are still the drawn ones.
    func moved(_ id: String, to y: CGFloat) { frames[id]?.frame.origin.y = y }
}

/// The stretch of the transcript's content that is drawn, in its content's coordinates; measured blocks outside it are
/// held as spaces. Every drawn block costs on each frame of a scroll (its layout, its display list, the accessibility
/// and focus walks over its text), and drawing one again costs its whole layout at once, so the band moves half a
/// screen at a time and a reader hovering at a boundary swaps nothing.
struct Band: Equatable {
    var near: Range<CGFloat>
    /// How tall the content is, in screens: a change re-checks which blocks are far enough to hold.
    var content: Int

    /// How far behind the reader, in screens, the band lets go while they scroll. On iPhone the band is trimmed back
    /// while they rest instead, so a fling only ever adds blocks.
    #if os(iOS)
    private static let behind: CGFloat = 4
    #else
    private static let behind: CGFloat = 2
    #endif

    /// While the reader scrolls: grows toward where they are heading once they come within a screen of its edge.
    static func following(_ band: Band?, offset: CGFloat, container: CGFloat, content: CGFloat) -> Band {
        let unit = container / 2
        let ahead = container, behind = Self.behind * container
        let top = offset, bottom = offset + container
        var near = band?.near ?? (top - ahead)..<(bottom + ahead)
        while near.lowerBound > top - ahead { near = (near.lowerBound - unit)..<near.upperBound }
        while near.upperBound < bottom + ahead { near = near.lowerBound..<(near.upperBound + unit) }
        while near.lowerBound + unit <= top - behind { near = (near.lowerBound + unit)..<near.upperBound }
        while near.upperBound - unit >= bottom + behind { near = near.lowerBound..<(near.upperBound - unit) }
        return Band(near: near, content: Int(content / container))
    }

    /// While the reader rests, one step at a time: draws three screens above them and two below, ready for their next
    /// move, and lets go of what is further. Nil once there is nothing left to do.
    func settling(offset: CGFloat, container: CGFloat, height: CGFloat) -> Band? {
        let unit = container / 2
        let top = offset, bottom = offset + container
        var near = self.near
        if near.lowerBound > max(0, top - 3 * container) {
            near = (near.lowerBound - unit)..<near.upperBound
        } else if near.upperBound < min(height, bottom + 2 * container) {
            near = near.lowerBound..<(near.upperBound + unit)
        } else if near.lowerBound + unit <= top - 4 * container {
            near = (near.lowerBound + unit)..<near.upperBound
        } else if near.upperBound - unit >= bottom + 3 * container {
            near = near.lowerBound..<(near.upperBound - unit)
        } else {
            return nil
        }
        return Band(near: near, content: content)
    }
}

/// Collapsing a block that starts above the top of the screen would leave the reader somewhere further down: this
/// brings its header back to the top instead. Called inside the collapse's animation.
struct KeepInView: Equatable {
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
    /// Where a row's details open instead of unfolding in place: on the phone, a sheet over the conversation.
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

/// What a row shows when its details open in a sheet, rather than unfolding in the conversation.
struct FeedSheet: Identifiable {
    let id = UUID()
    let title: String
    let content: @MainActor () -> AnyView

    init<Content: View>(title: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.title = title
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
    /// Records where this view starts in the transcript, for `KeepInView`.
    func trackTop(_ top: BlockTop) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TranscriptView.content)).minY } action: { top.y = $0 }
    }
}

#if os(iOS)
/// The UIScrollView behind the transcript's ScrollView. A class, so finding it never re-renders the transcript.
@MainActor final class ScrollViewHandle {
    weak var view: UIScrollView? {
        didSet { if view !== oldValue { watch() } }
    }
    /// Counts the reader's rests: work done while they rest stops when a newer rest takes over.
    var rest = 0
    /// Blocks are going in above the reader: what they are looking at stays put as the content grows.
    var placing = false
    /// The reader follows the end, and nothing is moving the scroll view: the end stays put.
    var following = true
    private var watching: NSKeyValueObservation?

    /// Moves the offset as the scroll view takes the content's new height, in that same pass. Moved from SwiftUI's
    /// report of the change instead, a frame was sometimes drawn with the new height and the old offset, which showed as
    /// the conversation jumping for a frame and back.
    private func watch() {
        watching = view?.observe(\.contentSize, options: [.old, .new]) { [weak self] view, change in
            guard let old = change.oldValue?.height, let new = change.newValue?.height, old != new else { return }
            MainActor.assumeIsolated { self?.resized(view, by: new - old) }
        }
    }

    private func resized(_ view: UIScrollView, by change: CGFloat) {
        if placing {
            // By exactly what was added, so a fling or a finger carries on: `scrollTo` would end it.
            view.contentOffset.y += change
        } else if following {
            let inset = view.adjustedContentInset
            view.contentOffset.y = max(-inset.top, view.contentSize.height + inset.bottom - view.bounds.height)
        }
    }
}

/// Zero-sized, inside the scroll view's content: finds the UIScrollView above it (SwiftUI's own) as soon as it is in a
/// window, so the transcript can move the offset the UIKit way, which keeps a fling or a finger going.
private struct ScrollViewFinder: UIViewRepresentable {
    let handle: ScrollViewHandle

    final class Finder: UIView {
        var handle: ScrollViewHandle?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view = superview
            while let v = view, !(v is UIScrollView) { view = v.superview }
            handle?.view = view as? UIScrollView
        }
    }

    func makeUIView(context: Context) -> Finder {
        let finder = Finder()
        finder.handle = handle
        finder.isUserInteractionEnabled = false
        return finder
    }

    func updateUIView(_ finder: Finder, context: Context) { finder.handle = handle }
}
#endif

/// Equatable on what it shows: the session's summary changes with every event of the session and its subagents (its
/// cost, what it is doing), and the callbacks are new closures each time, so otherwise every such change laid out the
/// whole conversation again. The callbacks only route to the store, so they don't count.
struct TranscriptView: View, Equatable {
    nonisolated static func == (a: TranscriptView, b: TranscriptView) -> Bool {
        a.items == b.items && a.session.id == b.session.id && a.session.agent == b.session.agent
            && a.session.status.isBusy == b.session.status.isBusy && a.session.isSubagent == b.session.isSubagent
            && (a.session.status == .compacting) == (b.session.status == .compacting)
            && a.session.cwd == b.session.cwd && a.pending == b.pending && a.idle == b.idle && a.earlier == b.earlier
            && a.loadingEarlier == b.loadingEarlier && (a.openParent == nil) == (b.openParent == nil)
            && (a.loadEarlier == nil) == (b.loadEarlier == nil)
    }

    nonisolated static let content = "transcript"

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

    /// Following the end of the transcript. Only the reader's own scrolling changes it: content growing below doesn't.
    @State private var atBottom = true
    /// Opens at the end. The bottom edge counts the composer's inset, so the last line is never left behind it.
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var metrics = ScrollMetrics()
    /// Idle unless the reader is dragging or the scroll view is still settling.
    @State private var phase = ScrollPhase.idle
    /// The first item of the first block laid out. Only the end of a long conversation is laid out at first, and more
    /// as the reader scrolls up: SwiftUI walks every block on each frame anything animates, so a session of hundreds of
    /// blocks kept the main thread busy even at rest. Fixed once set, so the window only grows: new blocks join at the
    /// end, and the blocks above what the reader is looking at never shift.
    @State private var shownFrom: String?
    /// Where the reader was when blocks were added above them, until the scroll view has measured them.
    @State private var revealing: Reveal?
    /// Set once the transcript has first appeared: blocks arriving after that spring in, the ones it opens with don't.
    @State private var opened = false
    /// Where each block was last laid out. Writing it never re-renders the transcript.
    @State private var frames = BlockFrames()
    /// The screen the reader is on, and how tall the content is, both counted in screens: which blocks are near enough
    /// to draw changes only when one of them does.
    @State private var band: Band?
    #if os(iOS)
    /// The scroll view underneath, for moving its offset without ending a fling.
    @State private var scroller = ScrollViewHandle()
    #endif

    /// Blocks laid out when a session opens.
    /// On iPhone fewer: they all lay out as the conversation arrives, under the rain that brings it in, and the
    /// blocks before them come in once it rests.
    #if os(iOS)
    private static let window = 16
    #else
    private static let window = 40
    #endif
    /// Blocks added each time the reader nears the top. Few at a time: each new block lays out in full before it can be
    /// held as a space, and a big batch landing mid-scroll is a visible stutter. On iPhone a reveal costs no momentum
    /// and settles within a frame, so they come smaller and more often.
    #if os(iOS)
    private static let step = 4
    /// How long a reveal may still settle after its first measurement, before the next may start.
    private static let settle: TimeInterval = 0.1
    /// How far from the top, in screens, the blocks before the window are brought in: runway for a fast fling.
    private static let runway: CGFloat = 6
    /// How far from the top, in screens, the blocks before the window are brought in while the reader rests: laying
    /// them out then costs nothing they can feel, and a fling up rarely has to lay any out on its way.
    private static let reserve: CGFloat = 14
    #else
    private static let step = 12
    private static let settle: TimeInterval = 0.6
    private static let runway: CGFloat = 4
    #endif

    /// Blocks just added above the reader: where they were before, as the scroll view measures the new ones. A class:
    /// it is updated on each frame of a scroll while they settle, and written back to state as a struct it ran the
    /// whole transcript's body every one of those frames.
    private final class Reveal {
        var offset: CGFloat
        var content: CGFloat
        /// Until when the new blocks may still be settling, from the first time they were measured.
        var until: Date?
        /// Offsets asked of the scroll view so far.
        var issued: [CGFloat] = []
        let started = Date.now

        /// Settled, or never grew the content at all.
        var done: Bool { if let until { Date.now > until } else { Date.now > started + 1 } }

        init(offset: CGFloat, content: CGFloat) {
            self.offset = offset
            self.content = content
        }
    }

    /// What the follow logic needs from the scroll view's geometry.
    private struct Scroll: Equatable {
        var offset: CGFloat
        var content: CGFloat
        var container: CGFloat
        /// The offset at the very end: the last line just above the composer.
        var maxOffset: CGFloat
        var distanceToEnd: CGFloat { maxOffset - offset }
    }

    var body: some View {
        let all = Activity.blocks(items, busy: session.status.isBusy)
        let start = Self.start(of: all, from: shownFrom)
        let blocks = all[start...]
        // Worked out here rather than in each row: the rows only run again when what they capture changes.
        let held = frames.held(blocks.map(\.id), near: band?.near)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if blocks.isEmpty {
                    if let pending {
                        // Empty: something else is showing that it loads.
                        if !pending.isEmpty { PendingTranscript(text: pending, unreachable: pending.hasPrefix("Can't")) }
                    } else {
                        EmptyTranscript(session: session)
                    }
                }
                if start > 0 || (earlier > 0 && loadEarlier != nil) {
                    Button { showEarlier() } label: {
                        HStack(spacing: 8) {
                            if loadingEarlier { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up") }
                            Text("Earlier conversation")
                        }
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Palette.moon)
                        .padding(.horizontal, 14).frame(height: 32)
                        .card(radius: 16, fill: Palette.raised, border: Palette.border)
                    }
                    .buttonStyle(PressStyle())
                    .disabled(loadingEarlier)
                    .frame(maxWidth: .infinity)
                }
                ForEach(blocks) { block in
                    let last = block.id == blocks.last?.id
                    Group {
                        if let height = held[block.id] {
                            // Measured, and screens away from the reader: only its height takes part in the layout. A
                            // reply streaming far below them keeps the height it had until they come near it.
                            Color.clear.frame(height: height)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.content)).minY } action: { frames.moved(block.id, to: $0) }
                        } else {
                            BlockView(block: block, agent: session.agent, openParent: openParent,
                                      streaming: session.status.isBusy && last)
                                .equatable()
                                // Coming back from being held as a space isn't arriving.
                                .modifier(Arrival(animate: opened && last && !frames.known(block.id)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(macOS)
                                .modifier(Returning(height: frames.height(of: block.id)))
                                #endif
                                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.content)) } action: { frames.measured(block.id, $0) }
                        }
                    }
                    // Swapped in place: a fade would leave it see-through until an animation runs.
                    .transition(.identity)
                    .id(block.id)
                }
                if session.status == .compacting {
                    CompactingMarker()
                        .transition(.opacity)
                }
                if !idle.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(idle) { line in
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
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: Layout.column, alignment: .leading)
            .padding(.horizontal, Layout.gutter)
            .padding(.top, 20)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
            // Exactly as wide as the screen: a block that lays out wider can't make the conversation drift sideways.
            .containerRelativeFrame(.horizontal)
            .coordinateSpace(.named(Self.content))
            // On iPhone only the prose is selectable (set where it is drawn): every selectable text is something a
            // touch must be checked against before the scroll can start.
            #if os(macOS)
            .textSelection(.enabled)
            #endif
            .environment(\.keepInView, KeepInView { top in
                // Measured from the top of the content, like the offset: 0 is the content's top at the top of the screen.
                if top < metrics.offset {
                    // Up to the block's top: the reader is reading there now, not at the end.
                    atBottom = false
                    position.scrollTo(y: max(0, top - 12))
                }
            })
            #if os(iOS)
            .background(ScrollViewFinder(handle: scroller).frame(width: 0, height: 0))
            #endif
        }
        #if os(iOS)
        // Told rather than asked: a closure reading this view's state from the handle saw it as it was when made.
        .onChange(of: atBottom, initial: true) { _, now in scroller.following = now && phase == .idle }
        #endif
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollPosition($position)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.35
            metrics.keyboardUntil = .now + duration + 0.15
        }
        #endif
        .onScrollPhaseChange { _, new in
            phase = new
            #if os(iOS)
            scroller.following = atBottom && new == .idle
            #endif
            // A drag that ended in the empty space past the end, before it could spring back.
            if new == .idle { pullBackToEnd() }
            #if os(iOS)
            if new == .idle {
                // The reader let go: back within reach of the end, follow it again (nothing moved them there while
                // their finger or fling had the scroll view).
                let end = max(0, metrics.content - metrics.container)
                if end - metrics.offset < 40 {
                    if !atBottom { atBottom = true }
                    if abs(end - metrics.offset) > 0.5 { position.scrollTo(y: end) }
                }
                prefill()
            }
            #endif
        }
        .onChange(of: items.isEmpty, initial: true) { _, empty in
            // Opening: lay out the end of the conversation, and keep to that start from now on.
            guard shownFrom == nil, !empty else { return }
            let all = Activity.blocks(items, busy: session.status.isBusy)
            shownFrom = all[max(0, all.count - Self.window)...].first?.firstItemId
            opened = true
            #if os(iOS)
            // The reader hasn't touched it yet: get the blocks around them ready (after the rain, if it plays).
            prefill()
            #endif
        }
        .onScrollGeometryChange(for: Scroll.self) { geometry in
            // The container already leaves out the insets (the composer, and on iPhone the navigation bar), but the offset
            // starts above the top one: measure from the top of the content.
            Scroll(offset: geometry.contentOffset.y + geometry.contentInsets.top, content: geometry.contentSize.height,
                   container: geometry.containerSize.height, maxOffset: geometry.contentSize.height - geometry.containerSize.height)
        } action: { old, new in
            metrics.content = new.content
            metrics.container = new.container
            if new.offset != old.offset {
                metrics.offset = new.offset
                metrics.moved &+= 1
            }
            if new.container > 0 {
                let band = Band.following(self.band, offset: new.offset, container: new.container, content: new.content)
                if band != self.band { self.band = band }
            }
            if let reveal = revealing, reveal.done { endReveal() }
            #if os(iOS)
            if let reveal = revealing, scroller.view != nil {
                // Blocks just went in above: the scroll view handle has already moved the offset by what they added
                // (`anchor`). Only how long they may still settle is kept here.
                if new.content != reveal.content {
                    reveal.content = new.content
                    reveal.until = reveal.until ?? .now + Self.settle
                }
                return
            }
            #endif
            if let reveal = revealing, new.content != reveal.content {
                // Blocks just went in above: keep what the reader was looking at where it was. They lay out again a
                // moment later, a little taller (on the Mac, their selectable text), so this holds for a moment.
                if new.offset != old.offset, !reveal.issued.isEmpty, !reveal.issued.contains(where: { abs($0 - new.offset) < 0.5 }) {
                    // The reader scrolled meanwhile: keep their move. (Landing where an earlier request pointed means
                    // the latest one was dropped, so it goes out again.)
                    reveal.offset = new.offset - (old.content - reveal.content)
                }
                let target = reveal.offset + new.content - reveal.content
                if abs(new.offset - target) > 0.5 {
                    position.scrollTo(y: target)
                    reveal.issued.append(target)
                }
                reveal.until = reveal.until ?? .now + Self.settle
                return
            }
            // Reading up toward the top: bring in the blocks before it, a few screens ahead, so the smaller batches
            // land before the reader gets there.
            // On iPhone only the reader's own scroll counts: the scroll view settling as the conversation arrives isn't
            // reading up, and while they rest `prefill` brings the blocks in.
            if new.offset < old.offset, new.offset < new.container * Self.runway, revealing == nil, !loadingEarlier,
               !Self.hasPhases || Self.readerMoving(phase) { showEarlier() }
            // A scroll toward the end that landed short: when the content grows twice in a row, the second request can be
            // dropped while the first is still being applied.
            #if os(iOS)
            if Self.readerMoving(phase) {
                // The reader's finger or fling has the scroll view: nothing here moves it, as any scroll request ends a
                // fling. Scrolling up stops following; letting go near the end picks it up again.
                if atBottom, new.offset < old.offset - 1 { atBottom = false }
                return
            }
            if new.container != old.container, new.content == old.content, atBottom || new.offset > max(0, new.maxOffset) + 0.5 {
                // The screen resized under a still transcript. When the keyboard is coming or going (its notification
                // lands just after the resize), the composer slides with it: move the end along with it, rather than
                // jump there ahead of it and leave a gap above the rising keyboard. Otherwise just keep to the end.
                metrics.easingUntil = .now + 0.1
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(40))
                    // The reader took hold of the scroll view meanwhile: theirs.
                    guard !Self.readerMoving(phase) else { metrics.easingUntil = .distantPast; return }
                    let end = max(0, metrics.content - metrics.container)
                    if Date.now < metrics.keyboardUntil {
                        metrics.easingUntil = .now + 0.45
                        withAnimation(.spring(response: 0.36, dampingFraction: 1)) { position.scrollTo(y: end) }
                    } else {
                        metrics.easingUntil = .distantPast
                        position.scrollTo(y: end)
                    }
                }
                return
            }
            // While that scroll eases in, its own steps aren't the reader scrolling, nor the end moving away.
            if Date.now < metrics.easingUntil { return }
            if atBottom, phase == .idle, let scrollView = scroller.view {
                // Following the end. As the content grows or shrinks, the handle keeps the offset there (`anchor`);
                // anything else that moved it (SwiftUI settling its opening position) is undone here, in this frame. A
                // scroll request lands a frame or more later, and by then blocks may have come in above, so it landed
                // short and left the last reply behind the composer.
                let end = max(0, new.maxOffset)
                if new.content == old.content, abs(new.offset - end) > 0.5 { scrollView.contentOffset.y += end - new.offset }
                return
            }
            #endif
            // Only the app's own scroll toward the end can land short: the reader's drag or fling stops where it stops, and
            // snapping it to the end from within the last few points fights their finger.
            let landedShort = new.offset > old.offset && new.distanceToEnd > 0.5 && !Self.readerMoving(phase)
            if phase == .idle, new.offset > max(0, new.maxOffset) + 0.5 {
                // Past the end with nothing below: the content shrank under a still scroll view (a run folding into
                // its summary, a block collapsing, the keyboard going away). Bring the end back down to the composer.
                if !atBottom { atBottom = true }
                position.scrollTo(y: max(0, new.maxOffset))
            } else if new.distanceToEnd < 40 {
                // At (or back at) the end, however it got there.
                if !atBottom { atBottom = true }
                if new.maxOffset != old.maxOffset || landedShort, new.distanceToEnd > 0.5 { position.scrollTo(y: new.maxOffset) }
            } else if new.maxOffset != old.maxOffset || landedShort {
                // New output, a growing block, or a resized window: stay at the end if the reader was there.
                // While reading further up, nothing moves.
                if atBottom { position.scrollTo(y: new.maxOffset) }
            } else if atBottom, new.offset < old.offset - 1, Self.readerMoving(phase) || !Self.hasPhases {
                // Only the reader scrolls up, by dragging (or the rail, below). The scroll view moves on its own too, as a
                // streaming reply lays out again: that mustn't stop it following the end.
                atBottom = false
            }
        }
        .overlay(alignment: .trailing) {
            ScrollRail(metrics: metrics) { y in
                if y < metrics.content - metrics.container - 40 { atBottom = false }
                position.scrollTo(y: y)
            }
                .padding(.vertical, 16)
                .padding(.trailing, 4)
        }
        .overlay(alignment: .bottom) {
            ZStack {
            if !atBottom {
                Button {
                    atBottom = true
                    withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Label(session.status.isBusy ? "New activity" : "Jump to latest", systemImage: "arrow.down")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(session.status.isBusy ? Palette.accent : Palette.moon)
                        .padding(.horizontal, 14).frame(height: 32)
                        .card(radius: 16, fill: Palette.raised, border: session.status.isBusy ? Palette.accent.opacity(0.5) : Palette.border)
                        .glow(radius: 10, on: session.status.isBusy)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(PressStyle())
                .padding(.bottom, 10)
                .transition(.scale(scale: 0.8).combined(with: .opacity).combined(with: .offset(y: 12)))
            }
            }
            // Only the button springs in and out: on the whole transcript, this animated its layout every time the
            // reader crossed the end.
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: atBottom)
        }
    }

    /// Where the window starts: the block holding `shownFrom`, or the last `window` blocks before it is set.
    private static func start(of blocks: [Block], from item: String?) -> Int {
        if let item, let index = blocks.firstIndex(where: { $0.contains(item) }) { return index }
        return max(0, blocks.count - window)
    }

    /// Lays out the blocks before the first one shown, loading the page before the first item when none are left,
    /// and keeps what the reader was looking at in place.
    private func showEarlier() {
        let start = Self.start(of: Activity.blocks(items, busy: session.status.isBusy), from: shownFrom)
        if start > 0 {
            reveal()
        } else if earlier > 0, let loadEarlier {
            Task {
                await loadEarlier()
                // This view still holds the items from before the page arrived: on iPhone the next scroll step, or the
                // rest that follows, brings the new blocks in from the fresh ones.
                #if os(macOS)
                reveal()
                #endif
            }
        }
    }

    private func endReveal() {
        revealing = nil
        #if os(iOS)
        scroller.placing = false
        #endif
    }

    private func reveal() {
        let all = Activity.blocks(items, busy: session.status.isBusy)
        let start = Self.start(of: all, from: shownFrom)
        guard start > 0, let first = all[max(0, start - Self.step)].firstItemId else { return }
        revealing = Reveal(offset: metrics.offset, content: metrics.content)
        #if os(iOS)
        scroller.placing = true
        #endif
        shownFrom = first
    }

    #if os(iOS)

    /// While the reader rests, a step at a time: brings in the blocks above until there are `reserve` screens of them,
    /// then draws the blocks around the reader, so their next move mostly scrolls through blocks already laid out.
    /// Stops as soon as they touch the screen again.
    private func prefill() {
        scroller.rest &+= 1
        let rest = scroller.rest
        Task { @MainActor in
            for _ in 0..<160 {
                try? await Task.sleep(for: .milliseconds(100))
                guard rest == scroller.rest, phase == .idle, metrics.container > 0 else { return }
                // The conversation is still raining in: every frame goes to the rain.
                if Materialize.active { continue }
                if let reveal = revealing {
                    guard reveal.done else { continue }
                    endReveal()
                }
                if loadingEarlier { continue }
                if metrics.offset < metrics.container * Self.reserve {
                    let start = Self.start(of: Activity.blocks(items, busy: session.status.isBusy), from: shownFrom)
                    if start > 0 || (earlier > 0 && loadEarlier != nil) {
                        showEarlier()
                        continue
                    }
                }
                guard let next = band?.settling(offset: metrics.offset, container: metrics.container, height: metrics.content) else { return }
                band = next
            }
        }
    }
    #endif

    /// On iPhone a scroll the reader makes has a phase; the scroll view's own adjustments don't. A Mac's mouse wheel
    /// may report none, so there phases tell nothing.
    private static var hasPhases: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The reader is dragging, or their fling is still running.
    private static func readerMoving(_ phase: ScrollPhase) -> Bool {
        hasPhases && (phase == .tracking || phase == .interacting || phase == .decelerating)
    }

    private func pullBackToEnd() {
        let end = max(0, metrics.content - metrics.container)
        if metrics.offset > end + 0.5 { position.scrollTo(y: end) }
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

/// A block drawn again after being held as a space keeps at least the height it had, for a moment: on the Mac its
/// selectable text first lays out a little shorter, which moved everything below it for a frame as the reader scrolled.
/// Only the height it came back with counts: a block drawn all along may grow and shrink as it likes.
private struct Returning: ViewModifier {
    @State private var height: CGFloat?

    init(height: CGFloat?) { _height = State(initialValue: height) }

    func body(content: Content) -> some View {
        content
            .frame(minHeight: height, alignment: .top)
            .task {
                guard height != nil else { return }
                try? await Task.sleep(for: .seconds(0.5))
                height = nil
            }
    }
}

/// A block arriving at the end springs in. Only the block itself animates: an animation on the whole transcript moved
/// every block's frame on every frame until it settled, which in a long conversation kept the main thread busy.
private struct Arrival: ViewModifier {
    @State private var shown: Bool

    init(animate: Bool) { _shown = State(initialValue: !animate) }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { shown = true }
            }
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
        case .activity(let activity):
            ActivityView(activity: activity)
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

/// "Worked for 3m · 18 tool calls · 6 reasoning steps", expanding into a timeline of every step.
struct ActivityView: View {
    let activity: Activity
    @State private var expanded: Bool?
    @State private var top = BlockTop()
    @Environment(\.keepInView) private var keepInView

    private var isExpanded: Bool { expanded ?? activity.live }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                    if isExpanded { keepInView(top) }
                    expanded = !isExpanded
                }
            } label: {
                header.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(headline), \(counts)")
            .accessibilityHint(isExpanded ? "Collapse" : "Expand")

            if isExpanded {
                Timeline(steps: activity.steps, live: activity.live)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            } else {
                // Keep what matters visible when collapsed: failures and subagents started here.
                let notable = activity.steps.filter { $0.item.status == .error || !ToolDescription($0.item).spawned.isEmpty }
                if !notable.isEmpty {
                    Timeline(steps: notable, live: false)
                }
            }
        }
        .trackTop(top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)
            if activity.live {
                AgentMark(symbol: "sparkle", color: Palette.accent, size: 18, working: true)
            }
            Text(headline).font(.system(size: 13, weight: .medium))
                .foregroundStyle(activity.live ? Palette.accent : Palette.moon)
                .lineLimit(1)
                .shimmer(activity.live)
                .contentTransition(.opacity)
            Text(counts).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.numericText())
            if activity.failures > 0 {
                Label("\(activity.failures) failed", systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.danger)
            }
            Spacer(minLength: 8)
            if !activity.live, let duration = activity.duration, duration >= 1000 {
                Text(Format.duration(ms: duration)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .card(radius: 12, fill: Palette.surface.opacity(isExpanded ? 0.95 : 0.7),
              border: activity.live ? Palette.accent.opacity(0.5) : Palette.lit.opacity(isExpanded ? 1 : 0.85))
        .glow(radius: 8, on: activity.live)
        .animation(.easeOut(duration: 0.3), value: activity.live)
    }

    private var headline: String { activity.headline }

    private var counts: String { activity.counts }
}

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
