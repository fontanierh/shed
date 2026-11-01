// Shed's look: moonlit blue-black velvet, fine grain, drifting fireflies, and little spirits for agents.
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Velvet: a deep blue-black ground with soft moonlight and a faint warm glow, under fine grain.
struct Velvet: View {
    var base: Color = Palette.canvas
    /// Where the moonlight comes from.
    var light: UnitPoint = .topTrailing

    var body: some View {
        ZStack {
            base
            RadialGradient(colors: [Palette.ice.opacity(0.07), .clear], center: light, startRadius: 0, endRadius: 700)
            RadialGradient(colors: [Palette.amber.opacity(0.035), .clear], center: .bottomLeading, startRadius: 0, endRadius: 520)
            Grain()
        }
        .drawingGroup()
        .ignoresSafeArea()
    }
}

/// Fine film grain, tiled. One noise tile is made once and shared.
struct Grain: View {
    var opacity: Double = 0.07

    var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(opacity)
                .blendMode(.overlay)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static let tile: CGImage? = {
        let size = 192
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<(size * size) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: seed >> 56)
            pixels[i * 4] = v
            pixels[i * 4 + 1] = v
            pixels[i * 4 + 2] = v
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// A few fireflies drifting slowly and twinkling. Purely decorative; still under Reduce Motion.
struct Fireflies: View {
    var count = 7
    /// The share of warm amber flies; the rest are moonlight blue.
    var warm = 0.35
    var seed: UInt64 = 1
    /// Width of a centered band to keep clear, so flies never drift behind text. The flies live in the margins either side.
    var clear: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Fly {
        let x, y, dx, dy, speed, phase, size: Double
        let warm: Bool
    }

    private var flies: [Fly] {
        var state = seed &* 0x2545F4914F6CDD1D | 1
        func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 10_000) / 10_000
        }
        return (0..<count).map { _ in
            Fly(x: next(), y: next(), dx: 10 + next() * 26, dy: 8 + next() * 22, speed: 0.05 + next() * 0.09,
                phase: next() * .pi * 2, size: 1.6 + next() * 1.8, warm: next() < warm)
        }
    }

    var body: some View {
        FireflyField(flies: flies.map { fly in
            FireflyField.Fly(x: fly.x, y: fly.y, dx: fly.dx, dy: fly.dy, speed: fly.speed, phase: fly.phase, size: fly.size,
                             color: (fly.warm ? Palette.amber : Palette.ice).resolve(in: EnvironmentValues()).cgColor)
        }, clear: clear, still: reduceMotion)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A small leaf sprig, drawn: the Shed motif.
struct Sprig: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        // Stem, curving up and to the right.
        var stem = Path()
        stem.move(to: p(0.18, 1))
        stem.addQuadCurve(to: p(0.62, 0.02), control: p(0.22, 0.4))
        path.addPath(stem.strokedPath(StrokeStyle(lineWidth: max(1, w * 0.025), lineCap: .round)))
        // Leaves along the stem, alternating sides.
        let leaves: [(Double, Double, Double, Double)] = [
            (0.2, 0.86, -0.9, 0.2), (0.23, 0.7, 0.75, 0.21), (0.27, 0.54, -0.8, 0.19),
            (0.33, 0.39, 0.7, 0.17), (0.41, 0.25, -0.7, 0.15), (0.5, 0.13, 0.6, 0.13), (0.62, 0.02, -0.2, 0.11),
        ]
        for (x, y, angle, length) in leaves {
            let base = p(x, y)
            let tip = CGPoint(x: base.x + cos(angle - .pi / 2) * length * w * 1.6 * (angle < 0 ? -1 : 1) * -1,
                              y: base.y - abs(sin(angle - .pi / 2)) * length * h * 0.9)
            let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
            let normal = CGPoint(x: -(tip.y - base.y) * 0.32, y: (tip.x - base.x) * 0.32)
            var leaf = Path()
            leaf.move(to: base)
            leaf.addQuadCurve(to: tip, control: CGPoint(x: mid.x + normal.x, y: mid.y + normal.y))
            leaf.addQuadCurve(to: base, control: CGPoint(x: mid.x - normal.x, y: mid.y - normal.y))
            path.addPath(leaf)
        }
        return path
    }
}

/// Two leaves rising from a stem: Shed's mark.
struct Sprout: View {
    var size: CGFloat = 26

    var body: some View {
        SproutShape()
            .fill(LinearGradient(colors: [Palette.moon, Palette.ice, Palette.periwinkle], startPoint: .topTrailing, endPoint: .bottomLeading))
            .frame(width: size, height: size)
            .shadow(color: Palette.ice.opacity(0.5), radius: size * 0.18)
            .accessibilityHidden(true)
    }
}

/// In a unit square: a curved stem, a small leaf to the left and a larger one to the right.
struct SproutShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        // Stem: a slim tapered curve.
        path.move(to: p(0.47, 0.96))
        path.addQuadCurve(to: p(0.5, 0.52), control: p(0.44, 0.74))
        path.addLine(to: p(0.54, 0.52))
        path.addQuadCurve(to: p(0.52, 0.96), control: p(0.5, 0.74))
        path.closeSubpath()
        // Left leaf.
        path.move(to: p(0.49, 0.6))
        path.addQuadCurve(to: p(0.04, 0.34), control: p(0.16, 0.66))
        path.addQuadCurve(to: p(0.49, 0.6), control: p(0.36, 0.22))
        path.closeSubpath()
        // Right leaf, larger and higher.
        path.move(to: p(0.53, 0.56))
        path.addQuadCurve(to: p(0.97, 0.06), control: p(0.52, 0.12))
        path.addQuadCurve(to: p(0.53, 0.56), control: p(0.94, 0.5))
        path.closeSubpath()
        return path
    }
}

/// An agent as a little round spirit: a soft glowing body and two dot eyes. While it works, an amber glow breathes
/// behind it, drawn by Core Animation so a working agent never redraws the window frame by frame.
struct Spirit: View {
    var color: Color
    var size: CGFloat = 22
    var working = false
    /// Asleep: eyes closed, for empty and disconnected states.
    var asleep = false
    /// Off where the view is clipped to its own frame (the Dynamic Island), which would cut the glow off square.
    var glow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(
                RadialGradient(colors: [color.mix(with: .white, by: 0.22), color, color.mix(with: .black, by: 0.25)],
                               center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75)
            )
            // Soft rim light from the moon.
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: max(0.5, size * 0.03))
            eyes
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(glow ? 0.35 : 0), radius: size * 0.18)
        .background {
            if working {
                PulseField(color: Palette.amber, still: reduceMotion)
                    .frame(width: size * 2.1, height: size * 2.1)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var eyes: some View {
        let eye = Color(red: 0.06, green: 0.08, blue: 0.14)
        HStack(spacing: size * 0.2) {
            ForEach(0..<2, id: \.self) { _ in
                if asleep {
                    Capsule().fill(eye).frame(width: size * 0.16, height: max(1, size * 0.045))
                } else {
                    Capsule().fill(eye).frame(width: size * 0.11, height: size * 0.15)
                }
            }
        }
        .offset(y: size * 0.02)
        .overlay(alignment: .center) {
            if size >= 20, !asleep {
                Smile().stroke(eye.opacity(0.85), style: StrokeStyle(lineWidth: max(1, size * 0.045), lineCap: .round))
                    .frame(width: size * 0.18, height: size * 0.07)
                    .offset(y: size * 0.17)
            }
        }
    }

    private struct Smile: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 2))
            return path
        }
    }
}

extension Color {
    /// `mix(with:by:)` exists from macOS 15; this keeps call sites short.
    fileprivate func mix(with other: Color, by amount: Double) -> Color { self.mix(with: other, by: amount, in: .perceptual) }
}

/// A soft amber glow behind something live: the active row, the send button.
struct GlowModifier: ViewModifier {
    var color: Color = Palette.amber
    var radius: CGFloat = 10
    var on = true

    func body(content: Content) -> some View {
        content.shadow(color: on ? color.opacity(0.45) : .clear, radius: on ? radius : 0)
    }
}

extension View {
    func glow(_ color: Color = Palette.amber, radius: CGFloat = 10, on: Bool = true) -> some View {
        modifier(GlowModifier(color: color, radius: radius, on: on))
    }

    /// A raised card: velvet surface, a hairline border lit from above, and a soft inner light.
    func card(radius: CGFloat = 12, fill: Color = Palette.surface, border: Color = Palette.border) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [fill.opacity(0.98), fill.opacity(0.88)], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [border.mix(with: .white, by: 0.12), border], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
    }
}

/// Light sweeping across text, like a firefly passing: for things in progress. The sweep runs in Core Animation.
struct Shimmer: ViewModifier {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    SweepField(color: Palette.moon)
                        .blendMode(.plusLighter)
                        .mask(content)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool = true) -> some View { modifier(Shimmer(active: active)) }
}
