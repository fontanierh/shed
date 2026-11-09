// The rain while a conversation loads, on Core Animation: the render server moves it, so it keeps falling while the
// app is busy laying out the conversation that ends it.
#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// The loading rain of `Materialize`, drop for drop: the same drops (where, how long, how fast) and the same fade in
/// and out, each a layer the render server animates. From `stop` no new drop starts, and those already falling finish.
struct WaitingRain: UIViewRepresentable {
    /// When the rain started: drops born before now are already partway down.
    let start: Date
    /// When the last new drops start.
    let stop: Date?

    func makeUIView(context: Context) -> RainView { RainView() }

    func updateUIView(_ view: RainView, context: Context) {
        view.start = start
        if let stop { view.stop(at: stop) }
    }
}

final class RainView: UIView {
    var start = Date.now
    /// Each drop's layer, its animation, and when it first falls, in media time.
    private var drops: [(layer: CALayer, fall: CAAnimationGroup, begin: CFTimeInterval)] = []
    private var built: CGSize = .zero
    private var stopped = false

    /// The rain repeats after this long: a load rarely lasts that long, and a drop that comes back comes back elsewhere
    /// in the pattern than where the eye last saw it.
    static let period: CFTimeInterval = 4
    /// Drops started a second, as `Materialize.rain` does.
    static let rate = 130.0
    /// Trails with different gaps, as the drawn rain's thin out at random.
    static let variants = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !stopped, bounds.width > 40, bounds.height > 40, bounds.size != built else { return }
        build()
    }

    /// Media time of a date.
    private static func media(_ date: Date) -> CFTimeInterval { CACurrentMediaTime() + date.timeIntervalSinceNow }

    private func build() {
        built = bounds.size
        for drop in drops { drop.layer.removeFromSuperlayer() }
        drops = []
        let cell = Materialize.cell
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let cols = Int(bounds.width / cell), rows = Int(bounds.height / cell)
        let sprites = (0..<Self.variants).map { Self.sprite(variant: $0, scale: scale) }
        let origin = Self.media(start)
        let count = Int(Self.period * Self.rate)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for i in 0..<count {
            // As in `Materialize.rain`: the same hashes, so the same drops.
            let length = 70 + 170 * Materialize.hash(i, 3)
            let life = length / Materialize.speed
            let col = Int(Materialize.hash(i, 2) * Double(cols))
            let top = Int(Materialize.hash(i, 4) * Double(rows) * 0.75) - 20

            let layer = CALayer()
            layer.contents = sprites[Int(Materialize.hash(i, 5) * Double(Self.variants)) % Self.variants]
            layer.contentsScale = scale
            layer.magnificationFilter = .nearest
            // The head is the sprite's bottom cell: positioned by its bottom edge.
            layer.anchorPoint = CGPoint(x: 0, y: 1)
            layer.bounds = CGRect(x: 0, y: 0, width: cell, height: 7 * cell)
            layer.position = CGPoint(x: CGFloat(col) * cell, y: CGFloat(top + 1) * cell)
            layer.opacity = 0

            let fall = CABasicAnimation(keyPath: "position.y")
            fall.fromValue = CGFloat(top + 1) * cell
            fall.toValue = CGFloat(Double(top + 1) + length) * cell
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
            let begin = origin + Double(i) / Self.rate
            group.beginTime = begin
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            layer.add(group, forKey: "fall")
            self.layer.addSublayer(layer)
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
            last.beginTime = cycle
            drop.layer.add(last, forKey: "fall")
        }
    }

    /// A drop: a faint pale head with a soft trail above it, cooling and thinning out, as `Materialize.drop` draws it.
    private static func sprite(variant: Int, scale: CGFloat) -> CGImage? {
        let cell = Materialize.cell
        let dot = cell - 1 / max(scale, 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: cell, height: 7 * cell), format: format).image { context in
            for k in 0..<7 {
                // Past the second cell, a trail cell is there or not at random, thinner the further up.
                guard k < 2 || Materialize.hash(variant, k, 29) < 1 - Double(k) / 8 else { continue }
                let hue = k == 0 ? 0.13 : 0.3 + 0.1 * Double(k)
                let color = UIColor(Dither.color(hue).opacity(1 - Double(k) / 7))
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fill(CGRect(x: 0, y: CGFloat(6 - k) * cell, width: dot, height: dot))
            }
        }.cgImage
    }
}
#endif
