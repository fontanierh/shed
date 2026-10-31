// Ambient motion drawn by Core Animation. It runs in the render server, so it never wakes SwiftUI: a TimelineView
// redrawing a Canvas re-laid out the whole window on every tick, and each tick cost a frame while scrolling.
import QuartzCore
import SwiftUI

#if os(macOS)
import AppKit
typealias AmbientBase = NSView
#else
import UIKit
typealias AmbientBase = UIView
#endif

/// A view that hands its layer to `build` whenever its size changes, and otherwise leaves the animations alone.
final class AmbientView: AmbientBase {
    var build: ((CALayer, CGSize, CGFloat) -> Void)?
    /// What the layers were built from; a new one rebuilds them.
    var config: AnyHashable?
    private var built: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if os(macOS)
        wantsLayer = true
        layer?.masksToBounds = true
        #else
        isUserInteractionEnabled = false
        clipsToBounds = true
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    #if os(macOS)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); rebuild() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); rebuild(force: true) }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    #else
    override func layoutSubviews() { super.layoutSubviews(); rebuild() }
    private var scale: CGFloat { traitCollection.displayScale }
    #endif

    func rebuild(force: Bool = false) {
        let host: CALayer? = layer
        guard let host, bounds.width > 0, bounds.height > 0, force || bounds.size != built else { return }
        built = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.sublayers?.forEach { $0.removeFromSuperlayer() }
        build?(host, bounds.size, scale)
        CATransaction.commit()
    }
}

/// An endless loop sampled from `value` over one period. It picks up where the clock is, so a rebuild doesn't jump.
private func loop(_ keyPath: String, period: Double, samples: Int = 60, value: (Double) -> Double) -> CAKeyframeAnimation {
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    animation.values = (0...samples).map { value(Double($0) / Double(samples) * period) }
    animation.duration = period
    animation.calculationMode = .cubic
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    animation.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
    return animation
}

private func glowLayer(_ color: CGColor, alpha: CGFloat, diameter: CGFloat, scale: CGFloat) -> CAGradientLayer {
    let glow = CAGradientLayer()
    glow.type = .radial
    glow.colors = [color.copy(alpha: alpha) ?? color, color.copy(alpha: 0) ?? color]
    glow.startPoint = CGPoint(x: 0.5, y: 0.5)
    glow.endPoint = CGPoint(x: 1, y: 1)
    glow.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    glow.contentsScale = scale
    return glow
}

private func dotLayer(_ color: CGColor, diameter: CGFloat) -> CALayer {
    let dot = CALayer()
    dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    dot.cornerRadius = diameter / 2
    dot.backgroundColor = color
    return dot
}

/// Ambient views share one representable shape: configure, then rebuild only when the configuration changes.
protocol AmbientLayers: Hashable {
    func install(on host: CALayer, size: CGSize, scale: CGFloat)
}

extension AmbientLayers {
    @MainActor func configure(_ view: AmbientView) {
        guard view.config != AnyHashable(self) else { return }
        view.config = AnyHashable(self)
        view.build = { host, size, scale in install(on: host, size: size, scale: scale) }
        view.rebuild(force: true)
    }
}

/// Fireflies drifting and twinkling: each one a soft halo around a bright core, on its own slow loops.
struct FireflyField: AmbientLayers {
    struct Fly: Hashable {
        let x, y, dx, dy, speed, phase, size: Double
        let color: CGColor
    }

    let flies: [Fly]
    /// A centered band to keep clear: the flies keep to the margins either side.
    let clear: CGFloat?
    /// Reduce Motion: hold still.
    let still: Bool

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        let margin = clear.map { (size.width - $0) / 2 }
        for fly in flies {
            let glow = fly.size * 5
            if let margin, margin <= glow * 2 + 8 { continue }
            func x(_ angle: Double) -> Double {
                guard let margin else { return fly.x * size.width + sin(angle) * fly.dx }
                let inner = margin - glow * 2
                let along = (fly.x < 0.5 ? fly.x * 2 : (fly.x - 0.5) * 2) * inner + glow + sin(angle) * min(fly.dx, inner / 4)
                let clamped = min(max(along, glow), margin - glow)
                return fly.x < 0.5 ? clamped : size.width - clamped
            }
            func y(_ angle: Double) -> Double { fly.y * size.height + cos(angle * 0.8) * fly.dy }
            let rate = 0.6 + fly.speed * 4
            func twinkle(_ t: Double) -> Double { 0.45 + 0.55 * (0.5 + 0.5 * sin(t * rate + fly.phase * 3)) }

            let body = CALayer()
            body.bounds = CGRect(x: 0, y: 0, width: glow * 2, height: glow * 2)
            body.position = CGPoint(x: x(fly.phase), y: y(fly.phase))
            body.opacity = Float(twinkle(0))
            let halo = glowLayer(fly.color, alpha: 0.35, diameter: glow * 2, scale: scale)
            halo.position = CGPoint(x: glow, y: glow)
            let core = dotLayer(fly.color.copy(alpha: 0.9) ?? fly.color, diameter: fly.size)
            core.position = CGPoint(x: glow, y: glow)
            body.addSublayer(halo)
            body.addSublayer(core)
            host.addSublayer(body)

            guard !still else { continue }
            body.add(loop("position.x", period: 2 * .pi / fly.speed) { t in x(t * fly.speed + fly.phase) }, forKey: "x")
            body.add(loop("position.y", period: 2 * .pi / (0.8 * fly.speed)) { t in y(t * fly.speed + fly.phase) }, forKey: "y")
            body.add(loop("opacity", period: 2 * .pi / rate, value: twinkle), forKey: "twinkle")
        }
    }
}

/// A faint line with a firefly gliding along it, back and forth.
struct TrailField: AmbientLayers {
    let still: Bool

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        let ice = Palette.ice.resolve(in: EnvironmentValues()).cgColor
        let amber = Palette.amber.resolve(in: EnvironmentValues()).cgColor
        let moon = Palette.moon.resolve(in: EnvironmentValues()).cgColor
        let mid = size.height / 2

        let line = CAGradientLayer()
        line.colors = [ice.copy(alpha: 0) ?? ice, ice.copy(alpha: 0.35) ?? ice, ice.copy(alpha: 0) ?? ice]
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        line.frame = CGRect(x: 0, y: mid - 0.5, width: size.width, height: 1)
        host.addSublayer(line)

        // Eased ping-pong along the line.
        func x(_ t: Double) -> Double { size.width * (0.08 + 0.84 * (sin(t * 1.4) + 1) / 2) }
        let firefly = CALayer()
        firefly.bounds = CGRect(x: 0, y: 0, width: 56, height: 18)
        firefly.position = CGPoint(x: x(0), y: mid)
        let tail = CAGradientLayer()
        tail.colors = [amber.copy(alpha: 0) ?? amber, amber.copy(alpha: 0.8) ?? amber, amber.copy(alpha: 0) ?? amber]
        tail.startPoint = CGPoint(x: 0, y: 0.5)
        tail.endPoint = CGPoint(x: 1, y: 0.5)
        tail.frame = CGRect(x: 0, y: 8, width: 56, height: 2)
        tail.cornerRadius = 1
        let glow = glowLayer(amber, alpha: 0.55, diameter: 18, scale: scale)
        glow.position = CGPoint(x: 28, y: 9)
        let dot = dotLayer(moon, diameter: 5)
        dot.position = CGPoint(x: 28, y: 9)
        [tail, glow, dot].forEach(firefly.addSublayer)
        host.addSublayer(firefly)

        guard !still else { return }
        firefly.add(loop("position.x", period: 2 * .pi / 1.4, value: x), forKey: "x")
    }
}

/// A soft glow breathing behind something at work: a working spirit, a lit lantern.
struct PulseField: AmbientLayers {
    let color: Color
    /// Seconds per breath.
    var period = 1.8
    var still = false

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        let glow = glowLayer(color.resolve(in: EnvironmentValues()).cgColor, alpha: 0.55, diameter: min(size.width, size.height), scale: scale)
        glow.position = CGPoint(x: size.width / 2, y: size.height / 2)
        glow.opacity = 0.7
        host.addSublayer(glow)
        guard !still else { return }
        glow.add(loop("opacity", period: period) { t in 0.45 + 0.55 * (0.5 - 0.5 * cos(t / period * 2 * .pi)) }, forKey: "breath")
        glow.add(loop("transform.scale", period: period) { t in 0.86 + 0.14 * (0.5 - 0.5 * cos(t / period * 2 * .pi)) }, forKey: "swell")
    }
}

/// A ring rippling out from a point and fading, again and again: an ember at work.
struct RippleField: AmbientLayers {
    let color: Color
    /// The ember's diameter; the ring starts there.
    let diameter: CGFloat
    var still = false

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        guard !still else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter), transform: nil)
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = CGPoint(x: size.width / 2, y: size.height / 2)
        ring.fillColor = nil
        ring.strokeColor = color.resolve(in: EnvironmentValues()).cgColor
        ring.lineWidth = 1
        ring.contentsScale = scale
        host.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.4
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ripple")
    }
}

/// An arc chasing its tail.
struct SpinField: AmbientLayers {
    let color: Color
    var lineWidth: CGFloat = 2
    var still = false

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        let side = min(size.width, size.height) - lineWidth
        let arc = CAShapeLayer()
        arc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        arc.position = CGPoint(x: size.width / 2, y: size.height / 2)
        arc.path = CGPath(ellipseIn: arc.bounds, transform: nil)
        arc.strokeStart = 0.15
        arc.strokeEnd = 0.85
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = lineWidth
        arc.strokeColor = color.resolve(in: EnvironmentValues()).cgColor
        arc.contentsScale = scale
        host.addSublayer(arc)
        guard !still else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 0.9
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "turn")
    }
}

/// A band of light sweeping across, left to right. Masked to text, it is the shimmer of something in progress.
struct SweepField: AmbientLayers {
    let color: Color
    var period = 1.8
    var still = false

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        guard !still else { return }
        let cg = color.resolve(in: EnvironmentValues()).cgColor
        let band = CAGradientLayer()
        band.colors = [cg.copy(alpha: 0) ?? cg, cg.copy(alpha: 0.85) ?? cg, cg.copy(alpha: 0) ?? cg]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let width = max(30, size.width * 0.45)
        band.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        band.position = CGPoint(x: -width, y: size.height / 2)
        host.addSublayer(band)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width / 2 - size.width * 0.2
        move.toValue = size.width * 1.2 + width / 2
        move.duration = period
        move.repeatCount = .infinity
        move.isRemovedOnCompletion = false
        band.add(move, forKey: "sweep")
    }
}

#if os(macOS)
extension FireflyField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}

extension TrailField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}

extension PulseField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}

extension RippleField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}

extension SpinField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}

extension SweepField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}
#else
extension FireflyField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}

extension TrailField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}

extension PulseField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}

extension RippleField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}

extension SpinField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}

extension SweepField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}
#endif
