// A reply streaming in prints at its writing edge: a short halftone front runs along each line over the words that
// just came, leaving them solid behind it, and carries on from where it was when more come. The same for every agent,
// since it only looks at where the laid out text is new. Played by the render server on the row's layer, like
// `DitherReveal`.
import SwiftUI

/// One laid out line of a block: which of the block's texts it belongs to, which of its lines, and where it stands.
struct InkLine: Equatable {
    var text: Int
    var line: Int
    var rect: CGRect
}

enum InkEdge {
    /// The front is over the words of an update this long after they come: longer when lines come at once, at `pace`.
    static let shortest: CFTimeInterval = 0.12
    static let longest: CFTimeInterval = 0.28
    static let pace: CGFloat = 3000
    /// Words that come while the front is still on the ones before wait their turn; it then goes over them at least
    /// this fast, quicker than updates come, so it catches up.
    static let least: CFTimeInterval = 0.05
    /// How wide the front is: what it covers in `tail`, so its dots show as long at any speed.
    static let tail: CFTimeInterval = 0.045
    static func front(at speed: CGFloat) -> CGFloat {
        speed * tail < 48 ? 32 : speed * tail < 96 ? 64 : 128
    }
    /// The space of the row a reply is in: where its blocks say they stand.
    static let row = "ink.row"
    /// More new lines than this at once is a block arriving whole: it prints as one piece.
    static let most = 10

    /// Where the text is new since `old`: the stretch each line grew by, and each new line whole.
    /// Nil when text already shown moved or went away (a reflow): nothing then prints, it is simply there.
    static func fresh(from old: [InkLine], to new: [InkLine]) -> [CGRect]? {
        var before: [Int: CGRect] = [:]
        for line in old { before[line.text << 20 | line.line] = line.rect }
        var strips: [CGRect] = []
        var kept = 0
        for line in new {
            let now = line.rect
            guard let was = before[line.text << 20 | line.line] else {
                if now.width > 0.5 { strips.append(now) }
                continue
            }
            kept += 1
            guard abs(was.minX - now.minX) < 0.5, abs(was.minY - now.minY) < 0.5, now.maxX > was.maxX - 0.5 else { return nil }
            if now.maxX > was.maxX + 0.5 {
                strips.append(CGRect(x: was.maxX, y: now.minY, width: now.maxX - was.maxX, height: now.height))
            }
        }
        // Only a block's last texts and their last lines are read, so lines leave at the top as it grows: those have
        // not gone away. Any other line that is no longer there has.
        var firstLine: [Int: Int] = [:]
        for line in new { firstLine[line.text] = min(firstLine[line.text] ?? line.line, line.line) }
        let firstText = firstLine.keys.min()
        let stayed = before.keys.filter { key in
            let (text, line) = (key >> 20, key & ((1 << 20) - 1))
            guard let firstText, text >= firstText else { return firstText == nil }
            return firstLine[text].map { line >= $0 } ?? true
        }.count
        guard kept == stayed else { return nil }
        if strips.count > most { return [strips.reduce(strips[0]) { $0.union($1) }] }
        return strips
    }

    /// The text without a last word still being written, so a word shows once and doesn't move to the next line as it
    /// grows. Text without spaces (or one very long word) shows as it comes.
    static func settled(_ text: String) -> String {
        var end = text.endIndex
        var length = 0
        while end > text.startIndex {
            let before = text.index(before: end)
            let character = text[before]
            if character.isWhitespace { break }
            guard character.isLetter || character.isNumber || character == "'" || character == "’", length < 24 else { return text }
            end = before
            length += 1
        }
        return String(text[..<end])
    }

    /// The lines of a block's texts, in the space `proxy` measures.
    static func lines(_ layouts: Text.LayoutKey.Value, in proxy: GeometryProxy) -> [InkLine] {
        var lines: [InkLine] = []
        // The last texts and their last lines: where a block grows.
        for index in layouts.indices.suffix(6) {
            let origin = proxy[layouts[index].origin]
            let layout = layouts[index].layout
            for line in layout.indices.suffix(40) {
                let rect = layout[line].typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y)
                lines.append(InkLine(text: index, line: line, rect: rect))
            }
        }
        return lines
    }
}

#if os(iOS)
import UIKit
private typealias InkAnchorBase = UIView
#else
import AppKit
private typealias InkAnchorBase = NSView
#endif

/// Reads where a block's text lies and prints what is new.
struct InkEdgeReader: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
            GeometryReader { proxy in
                InkEdgeAnchor(lines: InkEdge.lines(layouts, in: proxy), origin: proxy.frame(in: .named(InkEdge.row)).origin)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

#if os(iOS)
private struct InkEdgeAnchor: UIViewRepresentable {
    let lines: [InkLine]
    /// Where the block stands in its row.
    let origin: CGPoint

    func makeUIView(context: Context) -> InkAnchorView { InkAnchorView() }
    func updateUIView(_ view: InkAnchorView, context: Context) { view.show(lines, at: origin) }
}
#else
private struct InkEdgeAnchor: NSViewRepresentable {
    let lines: [InkLine]
    /// Where the block stands in its row.
    let origin: CGPoint

    func makeNSView(context: Context) -> InkAnchorView { InkAnchorView() }
    func updateNSView(_ view: InkAnchorView, context: Context) { view.show(lines, at: origin) }
}
#endif

/// Remembers a block's lines and prints the new ones on the row it is in.
private final class InkAnchorView: InkAnchorBase {
    private var lines: [InkLine]?
    /// Strips to print once this view is in its row.
    private var waiting: [CGRect] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        #endif
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `origin` is where the block stands in the row as SwiftUI lays it out. This view's own place can't tell: a row
    /// that just grew holds its content off its place until the list has made room for it.
    func show(_ new: [InkLine], at origin: CGPoint) {
        defer { lines = new }
        var strips: [CGRect]
        if let lines {
            guard let fresh = InkEdge.fresh(from: lines, to: new) else { return }
            strips = fresh
        } else {
            // A block seen for the first time prints if it is just beginning; a longer one was there already (the
            // reader came back to it).
            guard new.count <= 3 else { return }
            strips = new.map(\.rect).filter { $0.width > 0.5 }
        }
        guard !strips.isEmpty else { return }
        strips = strips.map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        if let row, waiting.isEmpty {
            InkEdge.print(strips, on: row, scale: scale)
        } else {
            // Not in its row yet. It is put there before it is first drawn, and the strips must be covered by then,
            // or the words show for a frame before they print.
            waiting += strips
            DispatchQueue.main.async { [weak self] in self?.printWaiting() }
        }
    }

    private func printWaiting() {
        guard !waiting.isEmpty, window != nil, let row else { return }
        let strips = waiting
        waiting = []
        InkEdge.print(strips, on: row, scale: scale)
    }

    #if os(iOS)
    override func didMoveToWindow() {
        super.didMoveToWindow()
        printWaiting()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        printWaiting()
    }

    private var scale: CGFloat { traitCollection.displayScale }

    /// The layer of the row this block is in.
    private var row: CALayer? {
        var view = superview
        while let current = view {
            if let cell = current as? UICollectionViewCell { return cell.contentView.layer }
            view = current.superview
        }
        return nil
    }
    #else
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        printWaiting()
    }

    override func layout() {
        super.layout()
        printWaiting()
    }

    /// Never in the way of the text under it: clicks and selections go through.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The layer of the row this block is in.
    private var row: CALayer? {
        var view = superview
        while let current = view {
            if let cell = current as? FeedCell { return cell.layer }
            view = current.superview
        }
        return nil
    }
    #endif
}

extension InkEdge {
    /// Prints `strips` (in the space of the row whose `layer` this is) in. Everything else of the row stays as it is.
    @MainActor static func print(_ strips: [CGRect], on layer: CALayer, scale: CGFloat) {
        let mask: InkMask
        if let current = layer.mask as? InkMask {
            mask = current
        } else if layer.mask == nil {
            mask = InkMask()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.mask = mask
            CATransaction.commit()
        } else {
            // The whole row is printing in: its words come with it.
            return
        }
        mask.add(strips, on: layer, scale: scale)
    }
}

/// Shows all of a row but the strips being printed, which the front runs over one after another.
private final class InkMask: CALayer {
    private let base = CAShapeLayer()
    private var live: [(rect: CGRect, layer: CALayer, ends: CFTimeInterval)] = []
    /// When the front reaches the end of the last strip it was given.
    private var head: CFTimeInterval = 0

    override init() {
        super.init()
        base.fillColor = CGColor(gray: 0, alpha: 1)
        addSublayer(base)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    @MainActor func add(_ strips: [CGRect], on host: CALayer, scale: CGFloat) {
        let clock = CACurrentMediaTime()
        // On whole pixels, so the edges of what is printed stay sharp.
        let rects = strips.map { strip in
            let top = (strip.minY * scale).rounded() / scale, bottom = (strip.maxY * scale).rounded() / scale
            return CGRect(x: strip.minX.rounded(.down), y: top, width: strip.maxX.rounded(.up) - strip.minX.rounded(.down), height: bottom - top)
        }
        let length = rects.reduce(0) { $0 + $1.width }
        guard length > 0 else { return }
        // One front for the lot: along the first strip, then the next, at one speed, after the strips before.
        let start = max(clock, head)
        let end = max(start + InkEdge.least, clock + min(max(Double(length / InkEdge.pace), InkEdge.shortest), InkEdge.longest))
        let speed = length / (end - start)
        let front = InkEdge.front(at: speed)
        let dither = DitherReveal.front(front)
        let shift = host.convertTime(clock, from: nil) - clock
        var done: CGFloat = 0
        var last = clock
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for rect in rects {
            let piece = CALayer()
            piece.frame = rect
            piece.masksToBounds = true
            // What is printed, with the front ahead of it: it comes in from the left until the strip is covered.
            let runner = CALayer()
            runner.frame = CGRect(x: 0, y: 0, width: rect.width + front, height: rect.height)
            let solid = CALayer()
            solid.frame = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            solid.backgroundColor = CGColor(gray: 0, alpha: 1)
            let dots = CALayer()
            dots.frame = CGRect(x: rect.width, y: 0, width: front, height: rect.height)
            dots.backgroundColor = dither
            runner.addSublayer(solid)
            runner.addSublayer(dots)
            let begins = start + Double(done / speed), takes = Double((rect.width + front) / speed)
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = runner.position.x - rect.width - front
            run.toValue = runner.position.x
            run.duration = takes
            run.beginTime = begins + shift
            run.fillMode = .backwards
            run.timingFunction = CAMediaTimingFunction(name: .linear)
            runner.add(run, forKey: "ink")
            piece.addSublayer(runner)
            addSublayer(piece)
            live.append((rect, piece, begins + takes))
            last = max(last, begins + takes)
            done += rect.width
        }
        head = end
        redraw(over: host.bounds)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + (last - clock) + 0.03) { [weak self, weak host] in
            guard let self, let host, host.mask === self else { return }
            self.settle(on: host)
        }
    }

    /// Strips that are solid join the rest; with none left, the row needs no mask.
    @MainActor private func settle(on host: CALayer) {
        let clock = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        live.removeAll { strip in
            guard strip.ends <= clock + 0.01 else { return false }
            strip.layer.removeFromSuperlayer()
            return true
        }
        if live.isEmpty { host.mask = nil } else { redraw(over: host.bounds) }
        CATransaction.commit()
    }

    /// All of the row, and well past it since it grows as it is written, but the strips.
    private func redraw(over bounds: CGRect) {
        frame = CGRect(origin: .zero, size: bounds.size)
        let all = CGPath(rect: CGRect(x: -40, y: -40, width: max(bounds.width, 500) + 80, height: max(bounds.height, 900) + 4000), transform: nil)
        let holes = CGMutablePath()
        for strip in live { holes.addRect(strip.rect) }
        base.path = all.subtracting(holes, using: .winding)
    }
}
