// The phone's list of the conversation's rows (`Feed`): a collection view, each row a SwiftUI view in its own cell,
// and the sheet a row's details open in.
#if os(iOS)
import SwiftUI
import UIKit

/// A row's details, over the conversation: half the screen, pulled up for all of it.
struct FeedSheetView: View {
    let sheet: FeedSheet
    @Environment(\.dismiss) private var dismiss
    /// The sheet's own viewer: the root's sits under the sheet, where an image would open out of sight.
    @State private var lightbox = Lightbox()
    @State private var enlarged = false

    var body: some View {
        @Bindable var lightbox = lightbox
        NavigationStack {
            ScrollView {
                sheet.content()
                    .frame(maxWidth: Layout.column, alignment: .leading)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Palette.canvas)
        .preferredColorScheme(.dark)
        .environment(\.lightbox, lightbox)
        .onChange(of: lightbox.shown != nil) { _, open in
            // The cover comes and goes without the system's slide: the image fades by itself, and on the way out
            // it is given the time to.
            Task {
                if !open { try? await Task.sleep(for: .milliseconds(320)) }
                guard (lightbox.shown != nil) == open else { return }
                var plain = Transaction()
                plain.disablesAnimations = true
                withTransaction(plain) { enlarged = open }
            }
        }
        .fullScreenCover(isPresented: $enlarged) {
            EnlargedImage(lightbox: lightbox)
                .presentationBackground(.clear)
        }
        .sheet(item: $lightbox.file) { file in FileViewer(file: file) }
    }
}

/// The image viewer as a cover over a sheet, fading in rather than sliding up.
private struct EnlargedImage: View {
    let lightbox: Lightbox
    @State private var visible = false

    var body: some View {
        LightboxView(lightbox: lightbox, embedded: true)
            .opacity(visible ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { visible = true } }
    }
}

// MARK: The collection view

struct FeedView: UIViewRepresentable {
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

    func makeCoordinator() -> FeedController { FeedController(state: state, metrics: metrics) }

    func makeUIView(context: Context) -> FeedCollection {
        let view = context.coordinator.make()
        handle.controller = context.coordinator
        return view
    }

    func updateUIView(_ view: FeedCollection, context: Context) {
        handle.controller = context.coordinator
        context.coordinator.update(self, environment: context.environment)
    }
}

/// A collection view that tells its controller when it lays out: where the reader is is put back in the same pass as
/// the rows change size, before anything is drawn.
final class FeedCollection: UICollectionView {
    var didLayout: (() -> Void)?
    private var laying = false

    override func layoutSubviews() {
        guard !laying else { return super.layoutSubviews() }
        laying = true
        // A row that grew (a line just written) takes its height at once. Animated, the row would lag behind its text
        // and cut the new line while it caught up.
        UIView.performWithoutAnimation { super.layoutSubviews() }
        didLayout?()
        laying = false
    }
}

@MainActor
final class FeedController: NSObject, UICollectionViewDelegate {
    private let state: FeedState
    private let metrics: ScrollMetrics
    private var collection: FeedCollection!
    private var source: UICollectionViewDiffableDataSource<Int, String>!
    private let rows = FeedRows()
    /// The ids in the order shown, header and footer included.
    private var shown: [String] = []
    private var environment = EnvironmentValues()
    /// What of the environment changes how a row looks, as it was when the cells were last configured.
    private var appearance = ""
    private var agent: AgentKind = .prime
    private var openParent: (@MainActor () -> Void)?
    private var loadEarlier: (() async -> Void)?
    private var loading: Task<Void, Never>?

    /// Keeping to the end as the conversation grows. Only the reader's own scroll changes it.
    private var following = true
    /// The row the reader is looking at, by its id and an item in it (a row whose start loads with an earlier page
    /// changes id), and where it is on screen.
    private var anchor: (id: String, item: String?, y: CGFloat)?
    /// Moving the offset ourselves: not the reader scrolling.
    private var correcting = false
    /// A snapshot going in: offsets meanwhile are the collection view's own, not the reader's.
    private var applying = false
    /// The scroll to the end animating: no correction cuts it short.
    private var jumping = false
    /// The first rows are in, and it opened at their end.
    private var seeded = false

    static let header = FeedSlot.header
    static let footer = FeedSlot.footer

    init(state: FeedState, metrics: ScrollMetrics) {
        self.state = state
        self.metrics = metrics
    }

    func make() -> FeedCollection {
        // One full-width column of self-sizing rows.
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = FeedSlot.spacing
        section.contentInsets = NSDirectionalEdgeInsets(top: FeedSlot.top, leading: 0, bottom: FeedSlot.bottom, trailing: 0)
        let layout = UICollectionViewCompositionalLayout(section: section)

        let collection = FeedCollection(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        collection.showsHorizontalScrollIndicator = false
        collection.keyboardDismissMode = .interactive
        collection.contentInsetAdjustmentBehavior = .always
        collection.selfSizingInvalidation = .enabledIncludingConstraints
        collection.didLayout = { [weak self] in self?.laidOut() }
        // Reading, not typing: a tap on the conversation puts the keyboard away, and the rows still get the tap.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        collection.addGestureRecognizer(tap)

        // One registration per kind of cell, so a cell is only ever reused for the same kind: its hosting view then
        // takes the new row in place. Across kinds UIKit replaces the content view, and logs a warning that prints
        // the whole SwiftUI environment, which cost milliseconds per cell during a fling.
        let header = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
            self?.configureHeader(cell)
        }
        let footer = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, _ in
            self?.configureFooter(cell)
        }
        let row = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            self?.configureRow(cell, id: id)
        }
        source = UICollectionViewDiffableDataSource(collectionView: collection) { collection, index, id in
            switch id {
            case Self.header: collection.dequeueConfiguredReusableCell(using: header, for: index, item: id)
            case Self.footer: collection.dequeueConfiguredReusableCell(using: footer, for: index, item: id)
            default: collection.dequeueConfiguredReusableCell(using: row, for: index, item: id)
            }
        }
        self.collection = collection
        return collection
    }

    @objc private func tapped() { collection.window?.endEditing(true) }

    // MARK: Updates

    func update(_ view: FeedView, environment: EnvironmentValues) {
        self.environment = environment
        // Cells keep the environment they were configured with: when text size or the like changes, every row is
        // configured again, in place.
        let appearance = "\(environment.dynamicTypeSize)|\(environment.legibilityWeight.map { "\($0)" } ?? "")|"
            + "\(environment.accessibilityReduceMotion)|\(environment.accessibilityDifferentiateWithoutColor)|"
            + "\(environment.colorSchemeContrast)|\(environment.layoutDirection)"
        if appearance != self.appearance {
            let first = self.appearance.isEmpty
            self.appearance = appearance
            if !first, source != nil, !shown.isEmpty {
                var snapshot = source.snapshot()
                snapshot.reconfigureItems(snapshot.itemIdentifiers)
                source.apply(snapshot, animatingDifferences: false)
            }
        }
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

        let all = (earlier ? [Self.header] : []) + ids + [Self.footer]
        guard all != shown else { return }
        shown = all
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(all)
        if !following { remember() }
        applying = true
        source.apply(snapshot, animatingDifferences: false)
        applying = false
        if !seeded, !ids.isEmpty {
            // Opens at the end.
            seeded = true
            following = true
            anchor = nil
            collection.layoutIfNeeded()
            correcting = true
            collection.contentOffset.y = endOffset
            correcting = false
        }
        collection.setNeedsLayout()
    }

    private func configureHeader(_ cell: UICollectionViewCell) {
        cell.backgroundConfiguration = .clear()
        let environment = environment, state = state
        cell.contentConfiguration = UIHostingConfiguration {
            EarlierButton(state: state) { [weak self] in self?.requestEarlier(force: true) }
                .environment(\.self, environment)
        }
        .margins(.all, 0)
    }

    private func configureFooter(_ cell: UICollectionViewCell) {
        cell.backgroundConfiguration = .clear()
        let environment = environment, state = state
        cell.contentConfiguration = UIHostingConfiguration {
            FeedFooter(state: state)
                .environment(\.self, environment)
        }
        .margins(.all, 0)
        .minSize(height: 1)
    }

    private func configureRow(_ cell: UICollectionViewCell, id: String) {
        cell.backgroundConfiguration = .clear()
        // A recycled cell may still be printing in the row it showed before.
        DitherReveal.stop(on: cell.contentView.layer)
        let environment = environment
        let row = rows[id], agent = agent, openParent = openParent
        cell.contentConfiguration = UIHostingConfiguration {
            Group {
                if let row {
                    FeedRowView(row: row, agent: agent, openParent: openParent)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .coordinateSpace(.named(InkEdge.row))
            .environment(\.self, environment)
        }
        .margins(.all, 0)
    }

    /// A row that arrived live prints in the first time it shows, if that is soon after it arrived: a reader who was
    /// elsewhere finds it simply there.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id], let arrived = row.arrived else { return }
        row.arrived = nil
        guard CACurrentMediaTime() - arrived < 1.5 else { return }
        // A reply being written prints word by word instead (`InkEdge`).
        if row.streaming, case .item(let item) = row.block, item.kind == .text, !environment.accessibilityReduceMotion { return }
        DitherReveal.play(on: cell.contentView.layer, reduceMotion: environment.accessibilityReduceMotion)
    }

    // MARK: Where the reader is

    private var insets: UIEdgeInsets { collection.adjustedContentInset }

    /// The offset at the very end: the last row just above the composer.
    private var endOffset: CGFloat { max(-insets.top, collection.contentSize.height + insets.bottom - collection.bounds.height) }

    private var readerMoving: Bool { collection.isTracking || collection.isDragging || collection.isDecelerating }

    /// Notes the first row showing and where it is on screen.
    private func remember() {
        let top = collection.contentOffset.y + insets.top
        var best: (id: String, frame: CGRect)?
        for index in collection.indexPathsForVisibleItems {
            guard let id = source.itemIdentifier(for: index), id != Self.footer, id != Self.header,
                  let frame = collection.layoutAttributesForItem(at: index)?.frame, frame.maxY > top else { continue }
            if best == nil || frame.minY < best!.frame.minY { best = (id, frame) }
        }
        anchor = best.map { ($0.id, rows[$0.id]?.block.firstItemId, $0.frame.minY - collection.contentOffset.y) }
    }

    private func anchorIndex(_ anchor: (id: String, item: String?, y: CGFloat)) -> IndexPath? {
        if let index = source.indexPath(for: anchor.id) { return index }
        guard let item = anchor.item, let row = rows.row(holding: item),
              let index = source.indexPath(for: row.id) else { return nil }
        self.anchor = (row.id, item, anchor.y)
        return index
    }

    /// After every layout: at the end while following it, else the row the reader was looking at back where it was.
    /// Moving the offset directly keeps a fling going; a scroll request would stop it.
    private func laidOut() {
        guard collection.bounds.height > 0, seeded, !jumping else { return publish() }
        var target: CGFloat?
        if following {
            if !readerMoving { target = endOffset }
        } else if let anchor, let index = anchorIndex(anchor),
                  let frame = collection.layoutAttributesForItem(at: index)?.frame {
            target = frame.minY - anchor.y
        }
        if let target, abs(target - collection.contentOffset.y) > 0.5 {
            correcting = true
            collection.contentOffset.y = target
            correcting = false
        }
        publish()
    }

    /// The rail's numbers and whether the jump button shows.
    private func publish() {
        let offset = collection.contentOffset.y + insets.top
        if metrics.offset != offset {
            metrics.offset = offset
            metrics.moved &+= 1
        }
        let content = collection.contentSize.height
        if metrics.content != content { metrics.content = content }
        let container = collection.bounds.height - insets.top - insets.bottom
        if metrics.container != container { metrics.container = container }
        let atBottom = following || endOffset - collection.contentOffset.y < 40
        if state.atBottom != atBottom { state.atBottom = atBottom }
    }

    /// From the rail: an offset measured from the top of the content.
    func scroll(to y: CGFloat) {
        // The rail takes over from a jump under way: its animation ends without a word from the scroll view.
        jumping = false
        following = y >= endOffset + insets.top - 40
        correcting = true
        collection.contentOffset.y = min(max(y - insets.top, -insets.top), endOffset)
        correcting = false
        if !following { remember() }
        publish()
    }

    func jumpToLatest() {
        following = true
        anchor = nil
        let animated = !environment.accessibilityReduceMotion
        jumping = animated
        collection.setContentOffset(CGPoint(x: 0, y: endOffset), animated: animated)
        publish()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        jumping = false
        collection.setNeedsLayout()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        jumping = false
        following = false
        remember()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !correcting, !applying else { return }
        if !following { remember() }
        publish()
        if readerMoving { requestEarlier() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }

    /// The reader let go: back within reach of the end, follow it again.
    private func settled() {
        following = endOffset - collection.contentOffset.y < 40
        if following {
            anchor = nil
            collection.setNeedsLayout()
        } else {
            remember()
        }
        publish()
        requestEarlier()
    }

    /// The page before the first item, once the reader is within a few screens of the top.
    private func requestEarlier(force: Bool = false) {
        guard state.earlier, !state.loadingEarlier, loading == nil, let loadEarlier else { return }
        if !force {
            let top = collection.contentOffset.y + insets.top
            guard top < collection.bounds.height * 4 else { return }
        }
        loading = Task { @MainActor [weak self] in
            await loadEarlier()
            self?.loading = nil
        }
    }
}

/// A reply or a message of the reader's, held: Copy, or Select Text in a sheet, in place of selecting where it stands.
struct CopyMenu: ViewModifier {
    let item: Item
    @Environment(\.liveText) private var liveText
    @Environment(\.openSheet) private var openSheet

    /// All of it, as far as it has streamed; a message's attached files stay out.
    private var text: String {
        if item.kind == .user { return MessageAttachments.split(item.text).0 }
        return liveText?.texts[item.id] ?? item.text
    }

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
            if let openSheet {
                Button("Select Text", systemImage: "text.cursor") {
                    let text = text, reply = item.kind == .text
                    openSheet(FeedSheet(title: reply ? "Reply" : "Message") {
                        if reply {
                            StreamingMarkdown(text: text, streaming: false)
                        } else {
                            Text(text).font(.system(size: 15.5)).foregroundStyle(Palette.moon).lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    })
                }
            }
        }
    }
}
#endif
