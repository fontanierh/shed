// The rain while a conversation loads, on Core Animation: the render server moves it, so it keeps falling while the
// app is busy laying out the conversation that ends it.
import QuartzCore
import SwiftUI
#if os(iOS)
import UIKit
typealias RainBase = UIView
#else
import AppKit
typealias RainBase = NSView
#endif

/// The loading rain of `Materialize`, drop for drop: the same drops (where, how long, how fast) and the same fade in
/// and out, each a layer the render server animates. From `stop` no new drop starts, and those already falling finish.
struct WaitingRain {
    /// When the rain started: drops born before now are already partway down.
    let start: Date
    /// When the last new drops start.
    let stop: Date?

    @MainActor fileprivate func update(_ view: RainView) {
        view.start = start
        if let stop { view.stop(at: stop) }
    }
}

#if os(iOS)
extension WaitingRain: UIViewRepresentable {
    func makeUIView(context: Context) -> RainView { RainView() }
    func updateUIView(_ view: RainView, context: Context) { update(view) }
}
#else
extension WaitingRain: NSViewRepresentable {
    func makeNSView(context: Context) -> RainView { RainView() }
    func updateNSView(_ view: RainView, context: Context) { update(view) }
}
#endif

final class RainView: RainBase {
    var start = Date.now
    /// Each drop's layer, its animation, and when it first falls, in media time.
    private var drops: [(layer: CALayer, fall: CAAnimationGroup, begin: CFTimeInterval)] = []
    private var built: CGSize = .zero
    private var stopped = false

    /// The rain repeats after this long: a load rarely lasts that long, and a drop that comes back comes back elsewhere
    /// in the pattern than where the eye last saw it.
    static let period: CFTimeInterval = 4
    /// Drops started a second on a phone's screen, any phone's. A bigger page gets more, to rain as thickly, up to
    /// `widest` times.
    static let rate = 130.0
    static let phone: CGFloat = 440 * 956
    static let widest = 6.0
    /// Trails with different gaps, as the drawn rain's thin out at random.
    static let variants = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(iOS)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        #else
        wantsLayer = true
        layer?.masksToBounds = true
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !stopped, bounds.width > 40, bounds.height > 40, bounds.size != built else { return }
        build(on: layer, scale: window?.screen.scale ?? traitCollection.displayScale, upsideDown: false)
    }
    #else
    /// Measured from the top, like the page the rain falls down.
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !stopped, let layer, let window, bounds.width > 40, bounds.height > 40, bounds.size != built else { return }
        // AppKit turns a layer's picture over where the view is measured from the top: the drops are drawn the other
        // way up to come out right.
        build(on: layer, scale: window.backingScaleFactor, upsideDown: layer.contentsAreFlipped())
    }
    #endif

    /// Media time of a date.
    private static func media(_ date: Date) -> CFTimeInterval { CACurrentMediaTime() + date.timeIntervalSinceNow }

    private func build(on stage: CALayer, scale: CGFloat, upsideDown: Bool) {
        built = bounds.size
        for drop in drops { drop.layer.removeFromSuperlayer() }
        drops = []
        let cell = Materialize.cell
        let cols = Int(bounds.width / cell), rows = Int(bounds.height / cell)
        let sprites = (0..<Self.variants).map { Self.sprite(variant: $0, scale: scale, upsideDown: upsideDown) }
        let origin = Self.media(start)
        // A window's layers keep their own time on the Mac.
        let shift = stage.convertTime(CACurrentMediaTime(), from: nil) - CACurrentMediaTime()
        let rate = Self.rate * min(Self.widest, max(1, Double(bounds.width * bounds.height / Self.phone)))
        let count = Int(Self.period * rate)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for i in 0..<count {
            // Hashes of its number: the same drops each time the rain is built.
            let length = 70 + 170 * Materialize.hash(i, 3)
            let life = length / Materialize.speed
            let col = Int(Materialize.hash(i, 2) * Double(cols))
            let top = Int(Materialize.hash(i, 4) * Double(rows) * 0.75) - 20

            let layer = CALayer()
            layer.contents = sprites[Int(Materialize.hash(i, 5) * Double(Self.variants)) % Self.variants]
            layer.contentsScale = scale
            layer.magnificationFilter = .nearest
            // The head is the sprite's bottom cell, `top` cells down: the sprite is placed by its middle, which is the
            // same point whichever way up the layer counts.
            let middle = CGFloat(top + 1) * cell - 3.5 * cell
            layer.bounds = CGRect(x: 0, y: 0, width: cell, height: 7 * cell)
            layer.position = CGPoint(x: CGFloat(col) * cell + cell / 2, y: middle)
            layer.opacity = 0

            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = middle
            fall.toValue = middle + CGFloat(length) * cell
            fall.duration = life
            // In over its first cells, out over its last.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.62, 0.62, 0]
            fade.keyTimes = [0, NSNumber(value: 12 / length), NSNumber(value: (length - 40) / length), 1]
            fade.duration = life

            let group = CAAnimationGroup()
            group.animations = [fall, fade]
            group.duration = Self.period
            group.repeatCount = .infinity
            let begin = origin + Double(i) / rate
            group.beginTime = begin + shift
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            layer.add(group, forKey: "fall")
            stage.addSublayer(layer)
            drops.append((layer, group, begin))
        }
    }

    /// From `date`, no new drop starts; a drop falling then, or starting before it, falls to its end.
    func stop(at date: Date) {
        guard !stopped else { return }
        stopped = true
        let cutoff = Self.media(date), now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for drop in drops {
            drop.layer.removeAnimation(forKey: "fall")
            guard drop.begin <= cutoff else { continue }
            // The last fall to start before the cutoff, played once if it isn't already over.
            let cycle = drop.begin + ((cutoff - drop.begin) / Self.period).rounded(.down) * Self.period
            let life = drop.fall.animations?.first?.duration ?? 0
            guard cycle + life > now, let last = drop.fall.copy() as? CAAnimationGroup else { continue }
            last.repeatCount = 1
            last.duration = life
            last.beginTime = cycle + drop.layer.convertTime(now, from: nil) - now
            drop.layer.add(last, forKey: "fall")
        }
    }

    /// A drop: a faint pale head with a soft trail above it, cooling and thinning out, as `Materialize.drop` draws it.
    /// `upsideDown`: head first, for a layer that shows its picture turned over.
    private static func sprite(variant: Int, scale: CGFloat, upsideDown: Bool) -> CGImage? {
        let cell = Materialize.cell
        let dot = cell - 1 / max(scale, 1)
        let width = Int((cell * scale).rounded()), height = Int((7 * cell * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Measured from the top, in points.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        for k in 0..<7 {
            // Past the second cell, a trail cell is there or not at random, thinner the further up.
            guard k < 2 || Materialize.hash(variant, k, 29) < 1 - Double(k) / 8 else { continue }
            let hue = k == 0 ? 0.13 : 0.3 + 0.1 * Double(k)
            let color = Dither.color(hue).opacity(1 - Double(k) / 7).resolve(in: EnvironmentValues())
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: CGFloat(upsideDown ? k : 6 - k) * cell, width: dot, height: dot))
        }
        return context.makeImage()
    }
}
