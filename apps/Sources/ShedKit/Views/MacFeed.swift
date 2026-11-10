// The Mac's list of the conversation's rows (`Feed`): a scroll view that places the rows itself, each a SwiftUI view
// in a hosting view of its own. Only the rows within a screen of the reader are there at all; the others are a height
// kept from when they last were (or a guess until then). A row that changes size moves the ones after it by setting
// their frames, which costs nothing, where a SwiftUI stack laid the whole conversation out again.
#if os(macOS)
import AppKit
import SwiftUI

struct FeedView: NSViewRepresentable {
    let items: [Item]
    let session: SessionSummary
    let pending: String?
    let idle: [IdleLine]
    let openParent: (@MainActor () -> Void)?
    let earlier: Int
    let loadingEarlier: Bool
    let loadEarlier: (() async -> Void)?
    let state: FeedState
    let metrics: ScrollMetrics
    let handle: FeedHandle
    /// How much of the view's foot lies under the composer: the conversation shows through it, and ends above it.
    var under: CGFloat = 0

    func under(_ height: CGFloat) -> FeedView {
        var view = self
        view.under = height
        return view
    }

    func makeCoordinator() -> FeedController { FeedController(state: state, metrics: metrics) }

    func makeNSView(context: Context) -> FeedScrollView {
        handle.controller = context.coordinator
        return context.coordinator.make()
    }

    func updateNSView(_ view: FeedScrollView, context: Context) {
        handle.controller = context.coordinator
        context.coordinator.update(self, environment: context.environment)
    }
}

/// Tells its controller when the reader scrolls. Taking the wheel's events itself also keeps the scrolling on the
/// main thread, in step with the rows being placed.
final class FeedScrollView: NSScrollView {
    weak var controller: FeedController?

    override func scrollWheel(with event: NSEvent) {
        controller?.readerScrolls()
        super.scrollWheel(with: event)
    }
}

/// The rows' container, measured from the top like the conversation.
private final class FeedDocument: NSView {
    override var isFlipped: Bool { true }
}

/// One row's place in the list: its SwiftUI view, in a layer of its own so it can print in.
final class FeedCell: NSView {
    let host: NSHostingController<FeedCellRoot>
    var id: String

    override var isFlipped: Bool { true }

    init(id: String, root: FeedCellRoot) {
        self.id = id
        host = NSHostingController(rootView: root)
        // The list sizes the cell: the hosting view asks for nothing itself.
        host.sizingOptions = []
        // Rows pass under the window's bar as they scroll, where a hosting view would otherwise push its content down.
        host.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        host.view.frame = bounds
        host.view.autoresizingMask = [.width, .height]
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// How tall the row is at `width`.
    func height(at width: CGFloat) -> CGFloat {
        host.sizeThatFits(in: CGSize(width: width, height: .infinity)).height
    }
}

/// What a cell shows.
struct FeedCellRoot: View {
    enum Content {
        case row(FeedRow, AgentKind, (@MainActor () -> Void)?)
        case header(FeedState, @MainActor () -> Void)
        case footer(FeedState)
    }

    let id: String
    let content: Content
    let environment: EnvironmentValues
    /// The row took another height.
    let resized: @MainActor (CGFloat) -> Void

    var body: some View {
        RowFit {
            Group {
                switch content {
                case .row(let row, let agent, let openParent): FeedRowView(row: row, agent: agent, openParent: openParent)
                case .header(let state, let load): EarlierButton(state: state, load: load)
                case .footer(let state): FeedFooter(state: state)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { resized($0) }
            // A cell that showed another row before starts this one afresh.
            .id(id)
        }
        .coordinateSpace(.named(InkEdge.row))
        .environment(\.self, environment)
    }
}

/// A row in its cell: as wide as the cell, as tall as it needs, from the cell's top. The cell takes a row's new
/// height a moment after the row does (text streams into it without the list hearing of it), and a row centred in a
/// cell not yet its size would stand half a line too high meanwhile.
private struct RowFit: SwiftUI.Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        // Shown, it fills its cell. Measured (offered all the height there is), it says what it needs.
        if let offered = proposal.height, offered < 1_000_000 { return CGSize(width: width, height: offered) }
        let height = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

@MainActor
final class FeedController: NSObject {
    private let state: FeedState
    private let metrics: ScrollMetrics
    private let scroll = FeedScrollView()
    private let document = FeedDocument()
    private var clip: NSClipView { scroll.contentView }
    private let rows = FeedRows()
    /// The ids in the order shown, header and footer included.
    private var shown: [String] = []
    /// Where each of `shown` starts, from the top of the content.
    private var tops: [CGFloat] = []
    /// How tall each row was when last there, at the width of the time.
    private var heights: [String: CGFloat] = [:]
    /// The rows that are there: those near the screen.
    private var cells: [String: FeedCell] = [:]
    /// Cells of rows that went out of reach, for the next rows to come in.
    private var spare: [FeedCell] = []
    private var environment = EnvironmentValues()
    /// What of the environment changes how a row looks, as it was when the cells were last given their rows.
    private var appearance = ""
    private var agent: AgentKind = .prime
    private var openParent: (@MainActor () -> Void)?
    private var loadEarlier: (() async -> Void)?
    private var loading: Task<Void, Never>?
    private var under: CGFloat = 0
    private var width: CGFloat = 0
    /// The rows' height, with the space above the first and under the last.
    private var content: CGFloat = 0

    /// Keeping to the end as the conversation grows. Only the reader's own scroll changes it.
    private var following = true
    /// The row the reader is looking at, by its id and an item in it (a row whose start loads with an earlier page
    /// changes id), and where it is on screen: put back whenever rows change size or come in above it, as long as
    /// they aren't following the end.
    private var anchor: (id: String, item: String?, y: CGFloat)?
    /// Moving the offset ourselves: not the reader scrolling.
    private var correcting = false
    /// The reader's fingers or their fling have the scroll view.
    private var live = false
    private var settling: DispatchWorkItem?
    /// The scroll to the end animating: no correction cuts it short.
    private var jumping = false
    /// The first rows are in, and it opened at their end.
    private var seeded = false
    /// Placing the rows; a row that changes size meanwhile is placed again before it ends.
    private var placing = false
    private var stale = false
    /// Where the offset was when last looked at: a move up from there is the reader's.
    private var last: CGFloat = 0

    /// A row never seen is taken to be this tall.
    private static let guess: CGFloat = 120

    init(state: FeedState, metrics: ScrollMetrics) {
        self.state = state
        self.metrics = metrics
    }

    func make() -> FeedScrollView {
        scroll.controller = self
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        // The rail beside the conversation shows where the reader is.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        // A layer of its own, for the mask the conversation opens under (`Materialize`).
        scroll.wantsLayer = true
        clip.drawsBackground = false
        document.autoresizingMask = []
        scroll.documentView = document
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(sized), name: NSView.frameDidChangeNotification, object: clip)
        return scroll
    }

    // MARK: Updates

    func update(_ view: FeedView, environment: EnvironmentValues) {
        self.environment = environment
        // Cells keep the environment they were given their row with: when what changes a row's look does, every
        // cell is given its row again, in place.
        let appearance = "\(environment.accessibilityReduceMotion)|\(environment.accessibilityDifferentiateWithoutColor)|"
            + "\(environment.colorSchemeContrast)|\(environment.legibilityWeight.map { "\($0)" } ?? "")|\(environment.controlActiveState)"
        let restyled = appearance != self.appearance && !self.appearance.isEmpty
        self.appearance = appearance
        agent = view.session.agent
        openParent = view.openParent
        loadEarlier = view.loadEarlier

        let busy = view.session.status.isBusy
        if state.busy != busy { state.busy = busy }
        if state.session != view.session { state.session = view.session }
        if state.pending != view.pending { state.pending = view.pending }
        if state.idle != view.idle { state.idle = view.idle }
        if state.empty != view.items.isEmpty { state.empty = view.items.isEmpty }
        let earlier = view.earlier > 0 && view.loadEarlier != nil
        if state.earlier != earlier { state.earlier = earlier }
        if state.loadingEarlier != view.loadingEarlier { state.loadingEarlier = view.loadingEarlier }

        // Rows that come in once the feed is open arrived now: they print in.
        let ids = rows.take(Activity.blocks(view.items, busy: busy), busy: busy, after: shown, live: seeded)
        let all = (earlier ? [FeedSlot.header] : []) + ids + [FeedSlot.footer]
        if restyled { for (id, cell) in cells { cell.host.rootView = root(for: id) } }
        guard all != shown || view.under != under else { return }
        if !following, seeded { remember() }
        shown = all
        under = view.under
        let listed = Set(all)
        for id in heights.keys where !listed.contains(id) { heights[id] = nil }
        for (id, cell) in cells where !listed.contains(id) { retire(cell) }
        if !seeded, !ids.isEmpty {
            // Opens at the end.
            seeded = true
            following = true
            anchor = nil
        }
        place()
    }

    private func root(for id: String) -> FeedCellRoot {
        let content: FeedCellRoot.Content = switch id {
        case FeedSlot.header: .header(state) { [weak self] in self?.requestEarlier(force: true) }
        case FeedSlot.footer: .footer(state)
        default: rows[id].map { .row($0, agent, openParent) } ?? .footer(FeedState())
        }
        return FeedCellRoot(id: id, content: content, environment: environment) { [weak self] height in
            self?.resized(id, to: height)
        }
    }

    // MARK: Placing the rows

    private func height(of id: String) -> CGFloat {
        if let height = heights[id] { return height }
        return id == FeedSlot.footer ? 0 : id == FeedSlot.header ? 32 : Self.guess
    }

    /// On whole pixels, so no row's text lands between two.
    private func snapped(_ height: CGFloat) -> CGFloat {
        let scale = scroll.window?.backingScaleFactor ?? 2
        return (height * scale).rounded(.up) / scale
    }

    /// A row took another height by itself: text streaming in, a step unfolding.
    private func resized(_ id: String, to height: CGFloat) {
        guard cells[id] != nil else { return }
        let height = snapped(height)
        guard abs((heights[id] ?? -1) - height) > 0.01 else { return }
        heights[id] = height
        if placing { stale = true } else { place() }
    }

    /// The offset at the very end: the last row just above the composer.
    private var endOffset: CGFloat { max(0, content + under - clip.bounds.height) }

    /// Puts every row where it stands, brings in the ones near the screen, and keeps the reader where they were: at
    /// the end while following it, else with the row they were looking at where it was.
    private func place() {
        guard !placing else { stale = true; return }
        let size = clip.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        placing = true
        defer { placing = false }
        if size.width != width {
            // The rows that are there say how tall they are now; the others keep their height as a guess.
            width = size.width
            for (id, cell) in cells { heights[id] = snapped(cell.height(at: width)) }
        }
        var offset = clip.bounds.origin.y
        // Bringing a row in measures it, which moves the rows after it and may bring others within reach.
        for _ in 0..<6 {
            stale = false
            var y = FeedSlot.top
            tops.removeAll(keepingCapacity: true)
            for id in shown {
                tops.append(y)
                // A row with nothing in it takes no room, nor the space after a row.
                let height = height(of: id)
                if height > 0 { y += height + FeedSlot.spacing }
            }
            content = max(FeedSlot.top, y - FeedSlot.spacing) + FeedSlot.bottom
            offset = clip.bounds.origin.y
            if seeded, !jumping {
                if following {
                    if !live { offset = endOffset }
                } else if let anchor, let index = index(of: anchor) {
                    offset = min(max(0, tops[index] - anchor.y), endOffset)
                } else if !live {
                    offset = min(offset, endOffset)
                }
            }
            if !mount(around: offset, height: size.height), !stale { break }
        }
        let total = max(content + under, size.height)
        if document.frame.size != NSSize(width: size.width, height: total) {
            correcting = true
            document.setFrameSize(NSSize(width: size.width, height: total))
            correcting = false
        }
        for (index, id) in shown.enumerated() {
            guard let cell = cells[id] else { continue }
            let frame = NSRect(x: 0, y: tops[index], width: size.width, height: height(of: id))
            if cell.frame != frame { cell.frame = frame }
        }
        if abs(offset - clip.bounds.origin.y) > 0.01 {
            correcting = true
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(clip)
            correcting = false
        }
        last = clip.bounds.origin.y
        publish()
    }

    /// Brings in the rows within a screen of what shows at `offset` and lets go of those two screens away. True when
    /// a row brought in turned out another height than it was taken for.
    private func mount(around offset: CGFloat, height: CGFloat) -> Bool {
        var changed = false
        let near = (offset - height)...(offset + 2 * height)
        let far = (offset - 2 * height)...(offset + 3 * height)
        for (index, id) in shown.enumerated() {
            let top = tops[index], bottom = top + self.height(of: id)
            if bottom >= near.lowerBound, top <= near.upperBound {
                guard cells[id] == nil else { continue }
                let cell = cell(for: id)
                let measured = snapped(cell.height(at: width))
                if heights[id] != measured {
                    heights[id] = measured
                    changed = true
                }
            } else if bottom < far.lowerBound || top > far.upperBound, let cell = cells[id] {
                retire(cell)
            }
        }
        return changed
    }

    private func cell(for id: String) -> FeedCell {
        let cell: FeedCell
        if let reused = spare.popLast() {
            cell = reused
            cell.id = id
            cell.host.rootView = root(for: id)
        } else {
            cell = FeedCell(id: id, root: root(for: id))
        }
        cell.frame = NSRect(x: 0, y: 0, width: width, height: height(of: id))
        document.addSubview(cell)
        cells[id] = cell
        printIn(cell)
        return cell
    }

    /// A row that arrived live prints in the first time it shows, if that is soon after it arrived: a reader who was
    /// elsewhere finds it simply there.
    private func printIn(_ cell: FeedCell) {
        guard let layer = cell.layer, let row = rows[cell.id], let arrived = row.arrived else { return }
        row.arrived = nil
        guard CACurrentMediaTime() - arrived < 1.5 else { return }
        // A reply being written prints word by word instead (`InkEdge`).
        if row.streaming, case .item(let item) = row.block, item.kind == .text, !environment.accessibilityReduceMotion { return }
        DitherReveal.play(on: layer, reduceMotion: environment.accessibilityReduceMotion)
    }

    private func retire(_ cell: FeedCell) {
        cells[cell.id] = nil
        // It may still be printing in the row it showed.
        if let layer = cell.layer { DitherReveal.stop(on: layer) }
        cell.removeFromSuperview()
        if spare.count < 12 { spare.append(cell) }
    }

    // MARK: Where the reader is

    /// Notes the first row showing and where it is on screen.
    private func remember() {
        let offset = clip.bounds.origin.y
        for (index, id) in shown.enumerated() where index < tops.count && id != FeedSlot.header && id != FeedSlot.footer {
            guard tops[index] + height(of: id) > offset else { continue }
            anchor = (id, rows[id]?.block.firstItemId, tops[index] - offset)
            return
        }
        anchor = nil
    }

    private func index(of anchor: (id: String, item: String?, y: CGFloat)) -> Int? {
        if let index = shown.firstIndex(of: anchor.id) { return index }
        guard let item = anchor.item, let row = rows.row(holding: item), let index = shown.firstIndex(of: row.id) else { return nil }
        self.anchor = (row.id, item, anchor.y)
        return index
    }

    /// The rail's numbers and whether the jump button shows.
    private func publish() {
        let offset = clip.bounds.origin.y
        if metrics.offset != offset {
            metrics.offset = offset
            metrics.moved &+= 1
        }
        if metrics.content != content { metrics.content = content }
        let container = clip.bounds.height - under
        if metrics.container != container { metrics.container = container }
        let atBottom = following || endOffset - offset < 40
        if state.atBottom != atBottom { state.atBottom = atBottom }
    }

    /// The view took another size: the window resized, the panel beside it opened, the composer grew.
    @objc private func sized() {
        guard !correcting else { return }
        place()
    }

    /// The wheel or the trackpad is about to move the conversation.
    fileprivate func readerScrolls() {
        live = true
        jumping = false
        // A trackpad says when the fingers and the fling are done; a wheel just stops.
        settling?.cancel()
        let settle = DispatchWorkItem { [weak self] in self?.settled() }
        settling = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: settle)
    }

    @objc private func scrolled() {
        guard !correcting, !placing, seeded else { return }
        let offset = clip.bounds.origin.y
        let up = offset < last - 0.5
        if !jumping {
            // Only the reader scrolls up: that stops it following the end.
            if up { following = false }
            if !following { remember() }
        }
        place()
        if up { requestEarlier() }
    }

    /// The reader let go: back within reach of the end, follow it again.
    private func settled() {
        live = false
        settling = nil
        guard seeded, !jumping else { return }
        following = endOffset - clip.bounds.origin.y < 40
        if following { anchor = nil } else { remember() }
        place()
        requestEarlier()
    }

    /// From the rail: an offset measured from the top of the content.
    func scroll(to y: CGFloat) {
        jumping = false
        following = y >= endOffset - 40
        correcting = true
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), endOffset)))
        scroll.reflectScrolledClipView(clip)
        correcting = false
        if following { anchor = nil } else { remember() }
        place()
    }

    func jumpToLatest() {
        let from = clip.bounds.origin.y
        following = true
        anchor = nil
        live = false
        // To the end at once, which measures the rows there; then back to within a screen of it, to glide the rest.
        place()
        let end = endOffset
        let start = max(from, end - clip.bounds.height)
        guard end - start > 1, !environment.accessibilityReduceMotion else { return }
        correcting = true
        clip.scroll(to: NSPoint(x: 0, y: start))
        correcting = false
        jumping = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: end))
            scroll.reflectScrolledClipView(clip)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.jumping = false
                self.place()
            }
        }
    }

    /// The page before the first item, once the reader is within a few screens of the top.
    private func requestEarlier(force: Bool = false) {
        guard state.earlier, !state.loadingEarlier, loading == nil, let loadEarlier else { return }
        if !force {
            guard clip.bounds.origin.y < clip.bounds.height * 4 else { return }
        }
        loading = Task { @MainActor [weak self] in
            await loadEarlier()
            self?.loading = nil
        }
    }
}
#endif
