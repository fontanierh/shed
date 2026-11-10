// One beam behind every page of the phone app. Moving between pages, it doesn't cut from one place to the other:
// it travels, swinging and bending into its new pose over a moment while the page slides in above it.
// The beam is still drawn by `Dither.render`, so the move is a short run of in-between renderings played by Core
// Animation, cross-dissolving from one to the next. They are rendered together off the main thread, ahead of the moves
// a page can make, smaller than the screen (the same 2 pt dots, fewer pixels each), and kept for the next time.
#if os(iOS)
import QuartzCore
import SwiftUI
import UIKit

/// Where the beam lies and how it looks.
struct BeamPose: Hashable, Sendable {
    var beam: Double
    var anchor: UnitPoint
    var shape: BeamShape

    /// A conversation: low along the bottom edge, with a faint haze of dots behind the text.
    static let conversation = BeamPose(beam: 0.62, anchor: UnitPoint(x: 0.4, y: 1.0), shape: .floor)
    /// The session list: exactly the conversation's beam, mirrored to rise to the left. Opening a session, it tips
    /// through level to the other side, the same beam the whole way.
    static let list = conversation.mirrored

    /// The same beam reflected left to right: the anchor across the middle, the angle negated. The bend and the warm
    /// side follow, since both are measured across the beam.
    var mirrored: BeamPose {
        var pose = self
        pose.anchor.x = 1 - anchor.x
        pose.shape.angle = -shape.angle
        return pose
    }

    func spec(width: Int, height: Int, scale: CGFloat, base: UInt32) -> DitherSpec {
        DitherSpec(width: width, height: height, scale: scale, beam: beam, anchorX: anchor.x, anchorY: anchor.y, base: base, shape: shape)
    }

    /// Partway from `a` to `b`. The angle takes the short way round.
    static func mix(_ a: BeamPose, _ b: BeamPose, _ t: Double) -> BeamPose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var turn = b.shape.angle - a.shape.angle
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let shape = BeamShape(angle: a.shape.angle + turn * t, bend: m(a.shape.bend, b.shape.bend),
                              spread: m(a.shape.spread, b.shape.spread), warm: m(a.shape.warm, b.shape.warm),
                              length: m(a.shape.length, b.shape.length), heat: m(a.shape.heat, b.shape.heat),
                              haze: m(a.shape.haze, b.shape.haze))
        return BeamPose(beam: m(a.beam, b.beam), anchor: UnitPoint(x: m(a.anchor.x, b.anchor.x), y: m(a.anchor.y, b.anchor.y)), shape: shape)
    }
}

/// The phone's shared ground: put it behind the navigation stack and give the pages a clear background.
struct BeamStage: UIViewRepresentable {
    var pose: BeamPose
    /// Every pose the beam may move to, so each move is ready before it's needed.
    var poses: [BeamPose] = []
    var base: Color = Palette.canvas

    func makeUIView(context: Context) -> BeamStageView { BeamStageView() }
    func updateUIView(_ view: BeamStageView, context: Context) {
        view.base = Dither.rgb(base)
        view.move(to: pose)
        view.warm = poses
    }
}

final class BeamStageView: UIView {
    var base: UInt32 = 0
    private let image = CALayer()
    /// Where the beam is shown, or heading.
    private var pose: BeamPose?
    private var built: CGSize = .zero
    /// Bumped by each move and size change: a rendering that comes back late doesn't overwrite a newer one.
    private var generation = 0

    /// In-between renderings per move, and how long it takes.
    nonisolated private static let frames = 12
    private static let duration: CFTimeInterval = 0.65
    /// Back to the list, a little quicker, in step with the conversation gliding away.
    private static let back: CFTimeInterval = 0.45

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        image.anchorPoint = .zero
        image.position = .zero
        image.magnificationFilter = .nearest
        image.minificationFilter = .nearest
        layer.addSublayer(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private var scale: CGFloat { traitCollection.displayScale }

    /// The rendering size for the view, in pixels at `scale`, rounded up as `DitherSpec` wants.
    private func pixels(_ s: CGFloat) -> (Int, Int) {
        let step = DitherSpec.step
        func up(_ v: CGFloat) -> Int { (Int((v * s).rounded(.up)) + step - 1) / step * step }
        return (up(bounds.width), up(bounds.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != built else { return }
        built = bounds.size
        layer.backgroundColor = CGColor(srgbRed: CGFloat(base >> 16 & 0xFF) / 255, green: CGFloat(base >> 8 & 0xFF) / 255,
                                        blue: CGFloat(base & 0xFF) / 255, alpha: 1)
        if let pose { show(pose) }
        prepare()
    }

    func move(to target: BeamPose) {
        guard target != pose else { return }
        let from = pose
        pose = target
        guard built != .zero else { return }
        guard let from, !UIAccessibility.isReduceMotionEnabled else { show(target); return }
        travel(from: from, to: target)
    }

    /// Straight to a pose, no move: the first one, and after a size change.
    private func show(_ pose: BeamPose) {
        generation += 1
        let mine = generation
        image.removeAnimation(forKey: "travel")
        let (w, h) = pixels(scale)
        let spec = pose.spec(width: w, height: h, scale: scale, base: base)
        if let cg = Dither.cached(spec) { set(cg, spec: spec); prepare(); return }
        if let near = Dither.nearest(spec) { set(near, spec: spec) }
        let target = Ref(self)
        Task.detached(priority: .userInitiated) {
            guard let cg = Dither.render(spec) else { return }
            Dither.store(spec, cg)
            await MainActor.run {
                guard let view = target.view, view.generation == mine else { return }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.25)
                view.set(cg, spec: spec)
                CATransaction.commit()
                view.prepare()
            }
        }
    }

    private func set(_ cg: CGImage, spec: DitherSpec) {
        // Sized from the spec, not the image: an in-between rendering has fewer pixels for the same points.
        image.bounds = CGRect(x: 0, y: 0, width: CGFloat(spec.width) / spec.scale, height: CGFloat(spec.height) / spec.scale)
        image.contents = cg
    }

    /// The moves the beam may make from here, prepared ahead so that one starts the moment it's asked for.
    var warm: [BeamPose] = [] { didSet { if warm != oldValue { prepare() } } }

    /// The in-between renderings of a move, at half the screen's pixels (1.5 on a 3× phone, where a 2 pt dot is
    /// still 3 pixels), evenly spaced from one pose to the other. A move back plays them backwards.
    private struct Morph: Hashable, Sendable {
        var from: BeamPose, to: BeamPose
        var width: Int, height: Int, scale: CGFloat, base: UInt32
    }
    nonisolated(unsafe) private static var morphs: [Morph: [CGImage]] = [:]
    nonisolated private static let lock = NSLock()

    nonisolated private static func middles(_ m: Morph) -> [CGImage]? {
        lock.lock(); defer { lock.unlock() }
        if let frames = morphs[m] { return frames }
        var back = m
        swap(&back.from, &back.to)
        return morphs[back]?.reversed()
    }

    nonisolated private static func render(_ m: Morph) async -> [CGImage] {
        if let done = middles(m) { return done }
        let n = frames
        let low = m.scale / 2, lw = m.width / 2, lh = m.height / 2
        let out: [CGImage] = await withTaskGroup(of: (Int, CGImage?).self) { group in
            for i in 1..<n {
                group.addTask {
                    let pose = BeamPose.mix(m.from, m.to, Double(i) / Double(n))
                    return (i, Dither.render(pose.spec(width: lw, height: lh, scale: low, base: m.base)))
                }
            }
            var out = [CGImage?](repeating: nil, count: n)
            for await (i, cg) in group { out[i] = cg }
            return out.compactMap { $0 }
        }
        // Full-size renderings of both ends too: those are where the move starts and lands.
        for pose in [m.from, m.to] {
            let spec = pose.spec(width: m.width, height: m.height, scale: m.scale, base: m.base)
            if Dither.cached(spec) == nil, let cg = Dither.render(spec) { Dither.store(spec, cg) }
        }
        keep(m, out)
        return out
    }

    nonisolated private static func keep(_ m: Morph, _ frames: [CGImage]) {
        lock.lock(); defer { lock.unlock() }
        // Only the moves of the current size are worth keeping.
        morphs = morphs.filter { $0.key.width == m.width && $0.key.height == m.height }
        morphs[m] = frames
    }

    private func morph(_ from: BeamPose, _ to: BeamPose) -> Morph {
        let (w, h) = pixels(scale)
        return Morph(from: from, to: to, width: w, height: h, scale: scale, base: base)
    }

    private func prepare() {
        guard built != .zero, let pose else { return }
        for other in warm where other != pose {
            let m = morph(pose, other)
            guard Self.middles(m) == nil else { continue }
            Task.detached(priority: .utility) { _ = await Self.render(m) }
        }
    }

    private func travel(from: BeamPose, to: BeamPose) {
        generation += 1
        let mine = generation
        let m = morph(from, to)
        let end = to.spec(width: m.width, height: m.height, scale: m.scale, base: m.base)
        let start = image.contents.map { $0 as! CGImage }
        if let middle = Self.middles(m), let last = Dither.cached(end) {
            play([start].compactMap { $0 } + middle + [last], end: end, duration: to == .list ? Self.back : Self.duration)
            return
        }
        let target = Ref(self)
        Task.detached(priority: .userInitiated) {
            let middle = await Self.render(m)
            guard let last = Dither.cached(end) else { return }
            await MainActor.run {
                guard let view = target.view, view.generation == mine else { return }
                view.play([start].compactMap { $0 } + middle + [last], end: end, duration: to == .list ? Self.back : Self.duration)
            }
        }
    }

    private func play(_ frames: [CGImage], end: DitherSpec, duration: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        set(frames[frames.count - 1], spec: end)
        CATransaction.commit()
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.duration = duration
        animation.calculationMode = .linear
        // Off at once, settling slowly: the beam answers the tap, then glides into place.
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.6, 0.3, 1)
        image.add(animation, forKey: "travel")
        prepare()
    }

    /// The view, held weakly across the render task.
    private final class Ref: @unchecked Sendable {
        weak var view: BeamStageView?
        init(_ view: BeamStageView) { self.view = view }
    }
}

extension EnvironmentValues {
    /// On the phone a page's ground is the shared `BeamStage` behind it, so the page draws none of its own.
    @Entry var beamStage = false
}
#endif
