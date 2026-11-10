// A conversation arriving. While it loads, slender streams of the beam's own dither rain down the empty page. When
// it arrives, the rain builds it: the transcript is snapshotted out of sight to learn which cells of the dot grid
// hold its text, bubbles and cards, and every one of those cells gets a drop that falls down its column, lands on
// it and sits there as a dot of the beam's colour, hot then cooling, until it turns into the real thing.
// Every dot sits on the 2 pt grid the backdrop uses and takes the beam's colours, so it reads as the same print.
// Drawn only while it plays: a Canvas on the animation timeline, gone once the conversation is shown.
import SwiftUI

struct Materialize: View {
    /// Waiting for the conversation.
    var loading: Bool
    /// Keeps the conversation out of sight from the start of the wait until it starts printing, when the mask takes
    /// over: the conversation is on screen the moment it arrives, a frame before a mask could go on.
    @Binding var veiled: Bool
    @State private var rainStart: Date = .now
    @State private var revealStart: Date?
    @State private var playing = false
    /// Where the arrived conversation's content is, read from its snapshot; nil until read, or if it couldn't be.
    @State private var layout: Layout?
    /// Between the conversation arriving and its snapshot: everything stays covered.
    @State private var capturing = false
    @State private var probe = Probe()
    @Environment(\.displayScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let cell: CGFloat = 2
    @State private var arrival: Task<Void, Never>?
    /// How long the cover takes to lift when the conversation's layout couldn't be read.
    static let lift = 0.5

    var body: some View {
        ZStack {
            if playing && !reduceMotion {
                // The loading rain on Core Animation: it keeps falling while the conversation is laid out, which
                // holds the app for a moment as it arrives. It thins out as the conversation starts printing.
                WaitingRain(start: rainStart, stop: revealStart.map { $0.addingTimeInterval(0.35) })
                    // A new wait, a new rain: one that has stopped doesn't start again.
                    .id(rainStart)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
                // The printing (and the mask it moves) needs the conversation's layout: drawn here, from its arrival.
                if capturing || revealStart != nil { printing }
            }
        }
        .onChange(of: playing) { _, on in
            if !on { probe.unmask(); veiled = false }
        }
        .onDisappear {
            arrival?.cancel()
            probe.unmask()
        }
        .background { ProbeView(probe: probe) }
        .onChange(of: loading, initial: true) { _, now in
            // Reduce Motion: no rain, and nothing hidden for it to print.
            if reduceMotion {
                veiled = false
                return
            }
            if now {
                arrival?.cancel()
                veiled = true
                // Already under way: the first streams are partway down when the page appears.
                rainStart = .now.addingTimeInterval(-0.45)
                revealStart = nil
                layout = nil
                capturing = false
                playing = true
            } else if playing, revealStart == nil, !capturing {
                capturing = true
                arrival = Task { await arrive() }
            }
        }
    }

    /// The conversation is in, still covered: give it a moment to lay out at its end, read where its content is,
    /// then let the rain print it.
    private func arrive() async {
        // Read as soon as the conversation has laid out, its height the same two frames running: the snapshot costs
        // a frame, better taken right behind the conversation's own arrival than as a second hitch later.
        var read: (content: [Double], cols: Int, rows: Int)?
        var last: CGFloat = -1
        for _ in 0..<30 {
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            let height = probe.contentHeight
            guard height > 0, height == last else { last = height; continue }
            // Once: a conversation with nothing lit reads as nothing every time, and each read costs a frame.
            read = probe.read(cell: Self.cell)
            break
        }
        guard !Task.isCancelled else { return }
        layout = read.map { Layout(content: $0.content, cols: $0.cols, rows: $0.rows) }
        // The mask takes over from the veil, on the conversation that was just read: nothing shows until a drop lands.
        probe.mask(layout == nil ? .faded(0) : .cells([UInt8](repeating: 0, count: layout!.cols * layout!.rows),
                                                       cols: layout!.cols, rows: layout!.rows, top: 0, bottom: 0), cell: Self.cell)
        veiled = false
        capturing = false
        let started = Date.now
        revealStart = started
        do { try await Task.sleep(for: .seconds((layout?.duration ?? Self.lift) + 0.1)) } catch { return }
        if revealStart == started { playing = false; revealStart = nil; layout = nil }
    }

    /// The drops that build the conversation, and the mask that shows it cell by cell.
    private var printing: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.identity)
    }

    // MARK: Drawing

    /// Dots gathered by colour, so a frame is a few dozen fills rather than thousands.
    struct Ink {
        var paths: [Int: Path] = [:]
        let dot: CGFloat
        mutating func dot(_ col: Int, _ row: Int, hue: Double, alpha: Double) {
            guard alpha > 0.04 else { return }
            let key = Int((min(1, max(0, hue)) * 23).rounded()) * 8 + Int((min(1, alpha) * 7).rounded())
            paths[key, default: Path()].addRect(CGRect(x: CGFloat(col) * Materialize.cell, y: CGFloat(row) * Materialize.cell,
                                                       width: dot, height: dot))
        }
        func fill(_ context: inout GraphicsContext) {
            for (key, path) in paths {
                let hue = Double(key / 8) / 23, alpha = Double(key % 8) / 7
                context.fill(path, with: .color(Dither.color(hue).opacity(alpha)))
            }
        }
    }

    /// A stable pseudo-random number in 0..<1 for a cell (and anything else worth telling apart).
    nonisolated static func hash(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
        var h = UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= UInt64(bitPattern: Int64(c)) &* 0x1656_67B1_9E37_79F9
        h ^= h >> 29; h &*= 0xBF58_476D_1CE4_E5B9; h ^= h >> 32
        return Double(h >> 11) / Double(1 << 53)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let cols = Int(size.width / Self.cell), rows = Int(size.height / Self.cell)
        guard cols > 20, rows > 20 else { return }
        var ink = Ink(dot: Self.cell - 1 / max(scale, 1))
        let r = revealStart.map { now.timeIntervalSince($0) }
        // The conversation is hidden by masking it, cell by cell, not by painting over it: the beam behind the page
        // keeps showing through, as it does once the conversation is in.
        if capturing {
            probe.mask(.hidden, cell: Self.cell)
        } else if let r, let layout, layout.cols == cols {
            let edges = layout.edges(at: r)
            probe.mask(.cells(layout.mask(at: r), cols: layout.cols, rows: layout.rows, top: edges.top, bottom: edges.bottom),
                       cell: Self.cell)
            print(&ink, layout, elapsed: r)
        } else if let r {
            // The layout couldn't be read: the conversation simply fades in while the rain falls on.
            let lift = min(1, r / Self.lift)
            probe.mask(.faded(lift * lift * (3 - 2 * lift)), cell: Self.cell)
        }
        ink.fill(&context)
    }

    /// How fast every drop falls, in cells a second: the rain keeps the same pace from loading to landing.
    nonisolated static let speed = 380.0

    /// A falling drop: a faint pale head with a soft trail above it, cooling and thinning out.
    static func drop(_ ink: inout Ink, col: Int, head y: Int, alpha a: Double) {
        for k in 0..<7 where y - k >= 0 {
            guard k < 2 || hash(col, y - k, 29) < 1 - Double(k) / 8 else { continue }
            ink.dot(col, y - k, hue: k == 0 ? 0.13 : 0.3 + 0.1 * Double(k), alpha: a * (1 - Double(k) / 7))
        }
    }

}

// MARK: Printing the conversation

extension Materialize {
    /// The arrived conversation on the dot grid, and the rain that builds it: a drop for each lit cell, falling down
    /// its column from well above, landing on the cell and staying there as a dot of the beam's colour until it turns
    /// into the real thing.
    struct Layout {
        let cols: Int, rows: Int
        /// When each cell stops being masked and shows the conversation.
        let shows: [Float]
        let drops: [Drop]
        let duration: Double

        struct Drop {
            var col: Int32, row: Int32
            /// When it lands, how long it falls, and from how many cells above.
            var lands: Float, falls: Float, height: Int32
            /// How strongly it marks its cell: text densely, a card's dim fill faintly.
            var weight: Float
        }

        init(content: [Double], cols: Int, rows: Int) {
            self.cols = cols; self.rows = rows
            var shows = [Float](repeating: .infinity, count: cols * rows)
            var drops: [Drop] = []
            var end: Float = 0
            for row in 0..<rows {
                // Rain everywhere at once, the top of the page a little ahead of the bottom, landing more and more
                // often: few drops land at first, then most, so it thickens rather than bursts.
                let base = Float(row) / Float(rows) * 0.25
                for col in 0..<cols {
                    let v = content[row * cols + col]
                    let h = Float(Materialize.hash(col, row, 101)), h2 = Float(Materialize.hash(col, row, 103))
                    guard v > 0.05 else {
                        // Nothing read here, but it shows with the rain all the same: whatever the snapshot missed or
                        // saw only faintly dissolves in with its neighbours rather than appearing at the end.
                        let show = 0.15 + base + 0.6 * h.squareRoot() + 0.36 + 0.1 * h2
                        shows[row * cols + col] = show
                        end = max(end, show)
                        continue
                    }
                    let height = Int32(25 + 65 * Materialize.hash(col, row, 109))
                    let falls = Float(Double(height) / Materialize.speed)
                    let lands = falls + base + 0.6 * h.squareRoot() + 0.04 * h2
                    let weight = Float(min(1, (v - 0.05) / 0.4))
                    // A drop for most of the text, a few for a card's fill; the rest simply appear as their
                    // neighbours land.
                    let dropped = Float(Materialize.hash(col, row, 107)) < 0.06 + 0.4 * weight
                    if dropped {
                        drops.append(Drop(col: Int32(col), row: Int32(row), lands: lands, falls: falls,
                                          height: height, weight: weight))
                    }
                    // Seen as a dot for a moment after landing, then as itself; a cell without a drop of its own
                    // waits for its neighbours' to land.
                    let show = lands + (dropped ? 0.22 + 0.16 * h2 : 0.36 + 0.1 * h2)
                    shows[row * cols + col] = show
                    end = max(end, show)
                }
            }
            self.shows = shows
            self.drops = drops
            duration = Double(end) + 0.05
        }
    }

    func print(_ ink: inout Ink, _ layout: Layout, elapsed: Double) {
        let t = Float(elapsed), cols = layout.cols
        for drop in layout.drops {
            let col = Int(drop.col), row = Int(drop.row)
            let show = layout.shows[row * cols + col]
            if t >= show { continue }
            let since = t - drop.lands
            if since >= 0 {
                // Landed: a dot of the beam's colour on the cell, hot as it lands, cooling until the text shows.
                let k = Double(min(1, since / max(0.01, show - drop.lands)))
                ink.dot(col, row, hue: 0.09 + 0.5 * k, alpha: Double(0.7 + 0.3 * drop.weight) * (1 - 0.25 * k))
            } else if since > -drop.falls {
                // Falling, at the same pace as the loading rain, fading in over its first cells.
                let fallen = Float(drop.height) * (1 + since / drop.falls)
                let y = row - Int(Float(drop.height) - fallen)
                // Many more of these than of the loading rain, so each is fainter: the rain as a whole keeps its
                // brightness, and what grows is what has landed.
                Self.drop(&ink, col: col, head: y, alpha: Double(0.16 + 0.1 * drop.weight) * Double(min(1, fallen / 10)))
            }
        }
    }
}

extension Materialize.Layout {
    /// One byte a cell: opaque where the conversation shows, clear where it's still waiting for its drop.
    func mask(at elapsed: Double) -> [UInt8] {
        let t = Float(elapsed)
        return shows.map { $0 > t ? 0 : 255 }
    }

    /// How much of the conversation past the top or bottom of the grid shows (under the navigation bar, say): as much
    /// as of the grid's first or last rows.
    func edges(at elapsed: Double) -> (top: Double, bottom: Double) {
        let t = Float(elapsed), band = min(12, rows)
        func shown(_ range: Range<Int>) -> Double {
            var n = 0
            for row in range { for col in 0..<cols where shows[row * cols + col] <= t { n += 1 } }
            return Double(n) / Double(max(1, range.count * cols))
        }
        return (shown(0..<band), shown((rows - band)..<rows))
    }
}

/// How much of the conversation shows while it materialises.
enum Reveal {
    case hidden
    case faded(Double)
    case cells([UInt8], cols: Int, rows: Int, top: Double, bottom: Double)
}

#if os(iOS)
import UIKit

/// Finds the conversation on screen under the effect and reads which grid cells hold something.
@MainActor final class Probe {
    weak var view: UIView?
    /// The conversation's scroll view while it's masked, and the mask.
    private weak var masked: UIScrollView?
    /// The scroll view last read.
    private weak var chosen: UIScrollView?
    /// The mask, over the whole scroll view: the grid's cells where the rain falls, and bands above and below it
    /// (under the navigation bar, say) that come in with the grid's first and last rows.
    private let shape = CALayer()
    /// The view the mask is on.
    private weak var maskHost: UIView?
    private let grid = CALayer()
    private let above = CALayer()
    private let below = CALayer()

    /// Hides the conversation, or the parts of it not yet printed. The mask sits on the scroll view itself, so the
    /// page around it, the beam included, is untouched.
    @discardableResult
    func mask(_ reveal: Reveal, cell: CGFloat) -> Bool {
        // Until the conversation is printing, look again each time: while it arrives, the empty page it replaces is
        // still fading out, and it's the new one that must be hidden.
        // Once read, the conversation that was read.
        let found: UIScrollView?
        if case .hidden = reveal { found = find() } else { found = chosen ?? masked ?? find() }
        guard let view, let scroll = found else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // On the scroll view's container, so a snapshot of the scroll view itself still sees the conversation.
        let host: UIView = Self.host(of: scroll) ?? scroll
        if masked !== scroll || maskHost !== host {
            maskHost?.layer.mask = nil
            masked?.layer.mask = nil
            masked = scroll
            if grid.superlayer == nil {
                grid.magnificationFilter = .nearest
                for band in [above, below] { band.backgroundColor = UIColor.black.cgColor }
                shape.addSublayer(grid); shape.addSublayer(above); shape.addSublayer(below)
            }
            host.layer.mask = shape
            maskHost = host
        }
        // The whole scroll view, wherever its bounds sit as it scrolls.
        shape.frame = host.bounds
        let area = view.convert(view.bounds, to: host)
        grid.frame = area
        above.frame = CGRect(x: host.bounds.minX, y: host.bounds.minY, width: host.bounds.width, height: max(0, area.minY - host.bounds.minY))
        below.frame = CGRect(x: host.bounds.minX, y: area.maxY, width: host.bounds.width, height: max(0, host.bounds.maxY - area.maxY))
        switch reveal {
        case .hidden:
            grid.contents = nil; grid.backgroundColor = nil
            above.opacity = 0; below.opacity = 0
        case .faded(let amount):
            grid.contents = nil; grid.backgroundColor = UIColor.black.withAlphaComponent(amount).cgColor
            above.opacity = Float(amount); below.opacity = Float(amount)
        case .cells(let alpha, let cols, let rows, let top, let bottom):
            grid.backgroundColor = nil
            above.opacity = Float(top); below.opacity = Float(bottom)
            // Premultiplied RGBA, every channel the cell's alpha: only the alpha matters to a mask.
            var rgba = [UInt8](repeating: 0, count: alpha.count * 4)
            for (i, a) in alpha.enumerated() where a > 0 { rgba[i * 4] = a; rgba[i * 4 + 1] = a; rgba[i * 4 + 2] = a; rgba[i * 4 + 3] = a }
            grid.contents = CGDataProvider(data: Data(rgba) as CFData).flatMap {
                CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)
            }
            // The image covers whole cells only; the strip past the last one shows.
            grid.contentsGravity = .topLeft
            grid.contentsScale = 1 / cell
        }
        return true
    }

    /// How tall the conversation is laid out, to know when it has settled.
    var contentHeight: CGFloat { find()?.contentSize.height ?? 0 }

    func unmask() {
        maskHost?.layer.mask = nil
        masked?.layer.mask = nil
        masked = nil
        maskHost = nil
        chosen = nil
    }

    /// Where the mask goes: the scroll view's container when it holds just the scroll view, so that a snapshot of
    /// the scroll view itself still sees the conversation; the scroll view otherwise.
    private static func host(of scroll: UIScrollView?) -> UIView? {
        guard let scroll else { return nil }
        if let parent = scroll.superview, parent.subviews.count == 1, parent.bounds.size == scroll.bounds.size { return parent }
        return scroll
    }

    /// The conversation's scroll view: of the visible ones filling most of this area, the one holding the most. The
    /// arriving conversation and the empty page it replaces are both there for a moment.
    private func find() -> UIScrollView? {
        guard let view, let window = view.window else { return nil }
        let frame = view.convert(view.bounds, to: window)
        var best: UIScrollView?
        func visible(_ v: UIView) -> Bool {
            var v: UIView? = v
            while let u = v { if u.isHidden || u.alpha < 0.01 || u.layer.opacity < 0.01 { return false }; v = u.superview }
            return true
        }
        func walk(_ v: UIView, veiled: Bool) {
            if let s = v as? UIScrollView {
                let f = s.convert(s.bounds, to: window).intersection(frame)
                if f.width * f.height > frame.width * frame.height * 0.5, veiled || visible(s),
                   s.contentSize.height >= best?.contentSize.height ?? 0 { best = s }
            }
            for sub in v.subviews { walk(sub, veiled: veiled) }
        }
        // Close by first: the conversation beside this view, veiled or not. Then anywhere visible.
        var near = view.superview
        for _ in 0..<4 {
            guard let v = near else { break }
            walk(v, veiled: true)
            if best != nil { return best }
            near = v.superview
        }
        walk(window, veiled: false)
        return best
    }

    func read(cell: CGFloat) -> (content: [Double], cols: Int, rows: Int)? {
        guard let view, let scroll = find() else { return nil }
        chosen = scroll
        let cols = Int(view.bounds.width / cell), rows = Int(view.bounds.height / cell)
        guard cols > 0, rows > 0 else { return nil }
        // Read without the mask that hides it meanwhile, in case it sits on the scroll view itself.
        let mask = scroll.layer.mask
        scroll.layer.mask = nil
        defer { scroll.layer.mask = mask }
        let origin = scroll.convert(scroll.bounds, to: view).origin
        // As the screen shows it: SwiftUI draws its text through Metal on a device, which a layer's own
        // `render(in:)` misses, while a view snapshot catches it. The layer is the fallback.
        func draw(_ snapshot: Bool) -> [UInt8]? {
            var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                // UIKit's way up.
                ctx.translateBy(x: 0, y: CGFloat(rows))
                ctx.scaleBy(x: 1, y: -1)
                if snapshot {
                    // Straight into a rect one pixel a cell, so the snapshot is taken small rather than shrunk.
                    UIGraphicsPushContext(ctx)
                    defer { UIGraphicsPopContext() }
                    return scroll.drawHierarchy(in: CGRect(x: origin.x / cell, y: origin.y / cell, width: scroll.bounds.width / cell,
                                                           height: scroll.bounds.height / cell), afterScreenUpdates: false)
                }
                ctx.scaleBy(x: 1 / cell, y: 1 / cell)
                ctx.translateBy(x: origin.x - scroll.bounds.origin.x, y: origin.y - scroll.bounds.origin.y)
                scroll.layer.render(in: ctx)
                return true
            }
            guard drawn else { return nil }
            let lit = stride(from: 0, to: pixels.count, by: 4).contains { max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2]) > 13 }
            return lit ? pixels : nil
        }
        let snap = draw(true)
        guard let pixels = snap ?? draw(false) else { return nil }
        // Brightness as it shows on the dark page: the premultiplied colour, so a faint fill counts for little.
        let content = (0..<(cols * rows)).map { i in
            Double(max(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])) / 255
        }
        return content.contains { $0 > 0.05 } ? (content, cols, rows) : nil
    }
}

private struct ProbeView: UIViewRepresentable {
    let probe: Probe
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probe.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { probe.view = view }
}
#else
import AppKit

/// Finds the conversation in the window under the effect and reads which grid cells hold something.
@MainActor final class Probe {
    weak var view: NSView?
    /// The conversation's list while it's masked.
    private weak var masked: FeedScrollView?
    /// The list last read.
    private weak var chosen: FeedScrollView?
    /// The mask, over the whole list: the grid's cells where the rain falls, and bands above and below it (under the
    /// composer) that come in with the grid's first and last rows.
    private let shape = CALayer()
    private let grid = CALayer()
    private let above = CALayer()
    private let below = CALayer()

    nonisolated init() {}

    /// Hides the conversation, or the parts of it not yet printed. The mask sits on the list itself, so the page
    /// around it, the beam included, is untouched.
    @discardableResult
    func mask(_ reveal: Reveal, cell: CGFloat) -> Bool {
        // Until the conversation is printing, look again each time: it's the arriving one that must be hidden.
        let found: FeedScrollView?
        if case .hidden = reveal { found = find() } else { found = chosen ?? masked ?? find() }
        guard let view, let scroll = found, let layer = scroll.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if masked !== scroll {
            masked?.layer?.mask = nil
            masked = scroll
            if grid.superlayer == nil {
                grid.magnificationFilter = .nearest
                grid.contentsGravity = .resize
                for band in [above, below] { band.backgroundColor = CGColor(gray: 0, alpha: 1) }
                shape.addSublayer(grid); shape.addSublayer(above); shape.addSublayer(below)
            }
            layer.mask = shape
        }
        // A view's layer counts as the view does. The list counts from its top or its bottom as AppKit has it.
        let bounds = scroll.bounds
        shape.frame = bounds
        let area = view.convert(view.bounds, to: scroll)
        let over = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, area.minY - bounds.minY))
        let under = CGRect(x: bounds.minX, y: area.maxY, width: bounds.width, height: max(0, bounds.maxY - area.maxY))
        above.frame = scroll.isFlipped ? over : under
        below.frame = scroll.isFlipped ? under : over
        switch reveal {
        case .hidden:
            grid.frame = area
            grid.contents = nil; grid.backgroundColor = nil
            above.opacity = 0; below.opacity = 0
        case .faded(let amount):
            grid.frame = area
            grid.contents = nil; grid.backgroundColor = CGColor(gray: 0, alpha: amount)
            above.opacity = Float(amount); below.opacity = Float(amount)
        case .cells(let alpha, let cols, let rows, let top, let bottom):
            grid.backgroundColor = nil
            above.opacity = Float(top); below.opacity = Float(bottom)
            // Whole cells only, from the top left of the area.
            let height = CGFloat(rows) * cell
            grid.frame = CGRect(x: area.minX, y: scroll.isFlipped ? area.minY : area.maxY - height, width: CGFloat(cols) * cell, height: height)
            // Premultiplied RGBA, every channel the cell's alpha: only the alpha matters to a mask. The first row is
            // the top of the page; where AppKit shows a layer's picture turned over, it is given turned over.
            let turned = layer.contentsAreFlipped()
            var rgba = [UInt8](repeating: 0, count: alpha.count * 4)
            for row in 0..<rows {
                let to = (turned ? rows - 1 - row : row) * cols
                for col in 0..<cols {
                    let a = alpha[row * cols + col]
                    guard a > 0 else { continue }
                    let i = (to + col) * 4
                    rgba[i] = a; rgba[i + 1] = a; rgba[i + 2] = a; rgba[i + 3] = a
                }
            }
            grid.contents = CGDataProvider(data: Data(rgba) as CFData).flatMap {
                CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent)
            }
        }
        return true
    }

    /// How tall the conversation is laid out, to know when it has settled.
    var contentHeight: CGFloat { find()?.documentView?.frame.height ?? 0 }

    func unmask() {
        masked?.layer?.mask = nil
        masked = nil
        chosen = nil
    }

    /// The conversation's list: of those filling most of this area, the one holding the most.
    private func find() -> FeedScrollView? {
        guard let view, let root = view.window?.contentView else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        var best: FeedScrollView?
        func walk(_ v: NSView) {
            if let list = v as? FeedScrollView {
                let shared = list.convert(list.bounds, to: nil).intersection(frame)
                if shared.width * shared.height > frame.width * frame.height * 0.5,
                   list.documentView?.frame.height ?? 0 >= best?.documentView?.frame.height ?? 0 { best = list }
                return
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return best
    }

    func read(cell: CGFloat) -> (content: [Double], cols: Int, rows: Int)? {
        guard let view, let scroll = find() else { return nil }
        chosen = scroll
        let cols = Int(view.bounds.width / cell), rows = Int(view.bounds.height / cell)
        guard cols > 0, rows > 0 else { return nil }
        // Read without the mask that hides it meanwhile.
        let mask = scroll.layer?.mask
        scroll.layer?.mask = nil
        defer { scroll.layer?.mask = mask }
        // Whole cells, from the top left of the area, drawn one pixel a cell so the picture is taken small.
        let area = view.convert(view.bounds, to: scroll)
        let height = CGFloat(rows) * cell
        let rect = CGRect(x: area.minX, y: scroll.isFlipped ? area.minY : area.maxY - height, width: CGFloat(cols) * cell, height: height)
        guard let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cols, pixelsHigh: rows, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: cols * 4, bitsPerPixel: 32)
        else { return nil }
        picture.size = rect.size
        scroll.cacheDisplay(in: rect, to: picture)
        guard let pixels = picture.bitmapData else { return nil }
        // Brightness as it shows on the dark page: the premultiplied colour, so a faint fill counts for little.
        let content = (0..<(cols * rows)).map { i in
            Double(max(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2])) / 255
        }
        return content.contains { $0 > 0.05 } ? (content, cols, rows) : nil
    }
}

private struct ProbeView: NSViewRepresentable {
    let probe: Probe

    func makeNSView(context: Context) -> NSView {
        let view = Passive()
        probe.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { probe.view = view }

    private final class Passive: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
