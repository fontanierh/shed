// Shed's ground: near-black with a beam of light running through it, cool blue on one side and hot orange on the
// other. On the beam it is drawn the way a halftone print would be, in dots; away from it the dots melt into a smooth
// glow that fades to the plain dark.
// It is rendered once per size off the main thread and cached, and stays still: an animated layer under the
// window would make every blurred card above it re-blur on each frame, and scrolling would pay for it.
import QuartzCore
import SwiftUI

/// What one rendering depends on. Sizes are in pixels, rounded up so a window resized by a few points reuses it.
struct DitherSpec: Hashable, Sendable {
    var width: Int
    var height: Int
    var scale: CGFloat
    /// 0: dots only, no beam. 1: the full beam.
    var beam: Double
    /// Where the beam crosses, in unit coordinates of the view.
    var anchorX: Double
    var anchorY: Double
    var base: UInt32
    /// The beam's shape (see `BeamShape`).
    var shape: BeamShape

    /// Rounded up to this many pixels: resizing re-renders only past a step, and the dots stay put meanwhile.
    static let step = 128
}

/// Which way the beam runs and how wide its cool side spreads.
struct BeamShape: Hashable, Sendable {
    /// Radians from the x axis; the warm edge is on the side `angle + 90°` points to.
    var angle: Double
    /// How much it curves toward its cool side, away from the anchor.
    var bend: Double
    /// How far the cool side reaches, as a fraction of the view's diagonal.
    var spread: Double
    /// How wide the hot fringe past the warm edge is, same unit.
    var warm: Double = 0.018
    /// How far along it the beam carries before fading, same unit.
    var length: Double = 0.75
    /// Above 1, the yellows, oranges and reds take more of the width.
    var heat: Double = 1

    /// Through the middle of the window, falling left to right, warm side below: the home page.
    static let sweep = BeamShape(angle: 0.5, bend: 0.22, spread: 0.36)
    /// Down the right edge, cool side toward the content, warm side against the edge: behind a conversation.
    static let edge = BeamShape(angle: -1.86, bend: 0.3, spread: 0.15, warm: 0.045, length: 1.4, heat: 1.7)
}

enum Dither {
    /// Recent renderings, newest last.
    nonisolated(unsafe) private static var cache: [(DitherSpec, CGImage)] = []
    private static let lock = NSLock()

    static func cached(_ spec: DitherSpec) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.first { $0.0 == spec }?.1
    }

    /// The closest rendering of the same look, to stretch while the right one renders.
    static func nearest(_ spec: DitherSpec) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return cache.last { $0.0.beam == spec.beam && $0.0.base == spec.base && $0.0.scale == spec.scale && $0.0.shape == spec.shape }?.1
    }

    static func store(_ spec: DitherSpec, _ image: CGImage) {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll { $0.0 == spec }
        cache.append((spec, image))
        if cache.count > 8 { cache.removeFirst(cache.count - 8) }
    }

    /// 4×4 Bayer thresholds.
    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }

    private struct RGB {
        var r, g, b: Double
        init(_ hex: UInt32) {
            r = Double(hex >> 16 & 0xFF) / 255
            g = Double(hex >> 8 & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }
        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
        static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
        static func * (a: RGB, k: Double) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
        func mix(_ o: RGB, _ t: Double) -> RGB { self * (1 - t) + o * t }
    }

    /// The beam's colors across it, from its hard warm edge (0) out over the cool side (1).
    private static let stops: [(Double, RGB)] = [
        (0, RGB(0xFF3A1E)), (0.025, RGB(0xFF6424)), (0.065, RGB(0xFFA43A)), (0.12, RGB(0xFFDB98)),
        (0.21, RGB(0x8ADCFF)), (0.38, RGB(0x3A9BFF)), (0.68, RGB(0x2457D8)), (1, RGB(0x172F80)),
    ]

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private static func ramp(_ t: Double) -> RGB {
        var previous = stops[0]
        for stop in stops.dropFirst() {
            if t <= stop.0 { return previous.1.mix(stop.1, (t - previous.0) / (stop.0 - previous.0)) }
            previous = stop
        }
        return previous.1
    }

    static func render(_ spec: DitherSpec) -> CGImage? {
        let w = spec.width, h = spec.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let base = RGB(spec.base)
        // Fill the gaps between dots with the base color.
        let br = UInt8(base.r * 255), bg = UInt8(base.g * 255), bb = UInt8(base.b * 255)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = br; pixels[i + 1] = bg; pixels[i + 2] = bb; pixels[i + 3] = 255
        }

        // Chunky square dots, a 2 pt grid with a one-pixel gap: a print you can see the dots of.
        let cell = max(3, Int((2 * spec.scale).rounded()))
        let dot = cell - 1
        // The beam: a line through the anchor, falling about 27° from left to right, measured in points so its angle
        // doesn't change with the window's shape.
        let ptW = Double(w) / spec.scale, ptH = Double(h) / spec.scale
        let diag = (ptW * ptW + ptH * ptH).squareRoot()
        let angle = spec.shape.angle
        let dirX = cos(angle), dirY = sin(angle)
        let nX = -dirY, nY = dirX
        let ax = spec.anchorX * ptW, ay = spec.anchorY * ptH

        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 33) / Double(1 << 31)
        }

        let cols = w / cell + 1, rows = h / cell + 1
        for row in 0..<rows {
            for col in 0..<cols {
                let px = col * cell, py = row * cell
                let x = (Double(px) + Double(cell) / 2) / spec.scale, y = (Double(py) + Double(cell) / 2) / spec.scale
                let dx = x - ax, dy = y - ay
                // Along the beam, and across it (negative: the cool side), bent a little like light over a horizon
                // so it sweeps through a corner instead of slicing the window in two.
                let along = (dx * dirX + dy * dirY) / diag
                let across = (dx * nX + dy * nY) / diag - spec.shape.bend * along * along
                let reach = pow(max(0, 1 - pow((along - 0.02) / spec.shape.length, 2)), 0.6)
                let t = min(1, max(0, -across / spec.shape.spread))
                let hue = spec.shape.heat == 1 ? t : pow(t, spec.shape.heat)
                // Full at the warm edge with a soft red fringe past it, thinning out slowly over the cool side.
                // Past the warm edge the light doesn't stop: a tight red fringe, then a long soft decay into the dark.
                let fringe = 0.75 * exp(-pow(across / spec.shape.warm, 2)) + 0.3 * exp(-across / (spec.shape.warm * 3.5))
                let light = (across > 0 ? min(0.75, fringe) : pow(1 - t, 0.85)) * reach * spec.beam
                // Random thresholds with a little order in them: noisy like a print, not a grid pattern.
                let threshold = 0.55 * random() + 0.45 * bayer[(row & 3) * 4 + (col & 3)]

                // Two layers. A smooth glow of the beam's colour fills every pixel and fades to the base colour
                // away from it. On the beam itself that glow breaks into dots: how dotted a spot is follows how
                // lit it is, so the print texture melts into a plain gradient as the light falls off, and the dark
                // field stays clean.
                let tone = ramp(hue)
                // A wide, faint bloom past the beam's own reach, so the light spills into the dark instead of
                // stopping at a line.
                let bloom = (across > 0 ? exp(-across / (spec.shape.warm * 9)) : exp(-(-across) / (spec.shape.spread * 0.9)))
                    * reach * spec.beam
                let glow = 0.62 * pow(light, 0.95) + 0.16 * bloom
                let smooth = base.mix(tone, min(1, glow)) * (1 + (random() - 0.5) * 0.012)
                let dotted = smoothstep(0.38, 0.85, light)
                // Under and between the dots the glow dims a little: the dots sit on light, not on black.
                let gap = smooth.mix(base, 0.38 * dotted)
                // The hot core shines: dots near the cream band brighten toward white.
                let shine = exp(-pow((hue - 0.1) / 0.08, 2)) * dotted
                var lit: RGB?
                if dotted > 0, light > threshold {
                    let c = tone * (0.9 + 0.14 * random())
                    let jitter = RGB(r: c.r + (random() - 0.5) * 0.05, g: c.g + (random() - 0.5) * 0.05, b: c.b + (random() - 0.5) * 0.05)
                    let ink = jitter.mix(RGB(r: 1, g: 0.97, b: 0.9), 0.35 * shine) * (1 + 0.12 * shine)
                    lit = gap.mix(ink, dotted)
                }
                func bytes(_ c: RGB) -> (UInt8, UInt8, UInt8) {
                    (UInt8(min(255, max(0, c.r * 255))), UInt8(min(255, max(0, c.g * 255))), UInt8(min(255, max(0, c.b * 255))))
                }
                let (gr, gg, gb) = bytes(gap)
                let (lr, lg, lb) = lit.map(bytes) ?? (gr, gg, gb)
                for yy in py..<min(h, py + cell) {
                    var i = (yy * w + px) * 4
                    for xx in px..<min(w, px + cell) {
                        let onDot = yy < py + dot && xx < px + dot
                        pixels[i] = onDot ? lr : gr; pixels[i + 1] = onDot ? lg : gg; pixels[i + 2] = onDot ? lb : gb
                        i += 4
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func rgb(_ color: Color) -> UInt32 {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ v: Float) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(resolved.red) << 16 | byte(resolved.green) << 8 | byte(resolved.blue)
    }
}

/// A layer handed to the render task and only touched again back on the main actor.
private final class LayerRef: @unchecked Sendable {
    let layer: CALayer
    let scale: CGFloat
    init(layer: CALayer, scale: CGFloat) { self.layer = layer; self.scale = scale }
}

/// The dithered ground, with the beam breathing slowly and a glint of light drifting along it.
struct DitherField: AmbientLayers {
    var beam: Double
    var anchor: UnitPoint
    var base: UInt32
    var shape: BeamShape = .sweep

    func install(on host: CALayer, size: CGSize, scale: CGFloat) {
        let step = DitherSpec.step
        func up(_ v: CGFloat) -> Int { (Int((v * scale).rounded(.up)) + step - 1) / step * step }
        let spec = DitherSpec(width: up(size.width), height: up(size.height), scale: scale, beam: beam,
                              anchorX: anchor.x, anchorY: anchor.y, base: base, shape: shape)
        host.backgroundColor = CGColor(srgbRed: CGFloat(base >> 16 & 0xFF) / 255, green: CGFloat(base >> 8 & 0xFF) / 255,
                                       blue: CGFloat(base & 0xFF) / 255, alpha: 1)

        let image = CALayer()
        image.anchorPoint = .zero
        image.position = .zero
        image.contentsScale = scale
        image.magnificationFilter = .nearest
        image.minificationFilter = .nearest
        func show(_ cg: CGImage, exact: Bool) {
            image.bounds = CGRect(x: 0, y: 0, width: exact ? CGFloat(cg.width) / scale : size.width,
                                  height: exact ? CGFloat(cg.height) / scale : size.height)
            image.contents = cg
        }
        host.addSublayer(image)
        if let cg = Dither.cached(spec) {
            show(cg, exact: true)
        } else {
            if let near = Dither.nearest(spec) { show(near, exact: false) }
            let target = LayerRef(layer: image, scale: scale)
            Task.detached(priority: .utility) {
                guard let cg = Dither.render(spec) else { return }
                Dither.store(spec, cg)
                await MainActor.run {
                    // Rebuilt since (another size): that build has its own rendering coming.
                    let image = target.layer
                    guard image.superlayer != nil else { return }
                    CATransaction.begin()
                    CATransaction.setAnimationDuration(0.25)
                    image.bounds = CGRect(x: 0, y: 0, width: CGFloat(cg.width) / target.scale, height: CGFloat(cg.height) / target.scale)
                    image.contents = cg
                    CATransaction.commit()
                }
            }
        }

    }
}

#if os(macOS)
extension DitherField: NSViewRepresentable {
    func makeNSView(context: Context) -> AmbientView { AmbientView() }
    func updateNSView(_ view: AmbientView, context: Context) { configure(view) }
}
#else
extension NSValue {
    convenience init(point: CGPoint) { self.init(cgPoint: point) }
}

extension DitherField: UIViewRepresentable {
    func makeUIView(context: Context) -> AmbientView { AmbientView() }
    func updateUIView(_ view: AmbientView, context: Context) { configure(view) }
}
#endif
