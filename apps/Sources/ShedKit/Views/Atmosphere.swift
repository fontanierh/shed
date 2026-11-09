// Shed's look: a dithered beam of light on near-black, frosted glass on top, agents as small lit tiles.
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The ground every screen sits on: fine dots on near-black and, unless `beam` is 0, the diagonal beam of light.
struct Backdrop: View {
    /// How strong the beam is: 1 on the home page, less behind text, 0 for plain dots.
    var beam: Double = 1
    var base: Color = Palette.canvas
    /// Where the beam crosses the view.
    var anchor = UnitPoint(x: 0.46, y: 0.52)
    var shape: BeamShape = .sweep

    var body: some View {
        DitherField(beam: beam, anchor: anchor, base: Dither.rgb(base), shape: shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }
}

/// Shed's mark: a gabled roof over upright boards.
struct ShedMark: View {
    var size: CGFloat = 26
    var color: Color = Palette.moon

    var body: some View {
        ShedShape()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: Palette.accent.opacity(0.35), radius: size * 0.2)
            .accessibilityHidden(true)
    }
}

/// In a unit square: a roof stroke, then four boards on a sill.
struct ShedShape: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        var roof = Path()
        roof.move(to: p(0.05, 0.42))
        roof.addLine(to: p(0.5, 0.1))
        roof.addLine(to: p(0.95, 0.42))
        path.addPath(roof.strokedPath(StrokeStyle(lineWidth: rect.width * 0.1, lineCap: .round, lineJoin: .round)))
        // Boards: the outer two a little shorter, following the eaves.
        let boards: [(Double, Double)] = [(0.17, 0.5), (0.355, 0.42), (0.545, 0.42), (0.73, 0.5)]
        for (x, top) in boards {
            path.addRoundedRect(in: CGRect(origin: p(x, top), size: CGSize(width: rect.width * 0.105, height: rect.height * (0.86 - top))),
                                cornerSize: CGSize(width: rect.width * 0.03, height: rect.width * 0.03))
        }
        path.addRoundedRect(in: CGRect(origin: p(0.12, 0.86), size: CGSize(width: rect.width * 0.76, height: rect.height * 0.07)),
                            cornerSize: CGSize(width: rect.width * 0.03, height: rect.width * 0.03))
        return path
    }
}

/// An agent or a subagent as a small glass tile lit in its hue: a rounded square with the agent's glyph, or a circle
/// with a subagent's initial. While it works, a blue ring keeps rippling out of it, drawn by Core Animation so a
/// working agent never redraws the window.
struct AgentMark: View {
    enum Glyph: Equatable {
        case agent(AgentKind)
        case initial(String)
        case symbol(String)
    }

    var glyph: Glyph
    var color: Color
    var size: CGFloat = 22
    var working = false
    /// Stopped or out of reach: dimmed.
    var asleep = false
    /// Off where the view is clipped to its own frame (the Dynamic Island), which would cut the glow off square.
    var glow = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(agent: AgentKind, size: CGFloat = 22, working: Bool = false, asleep: Bool = false, glow: Bool = true) {
        self.glyph = .agent(agent)
        self.color = Palette.agent(agent)
        self.size = size
        self.working = working
        self.asleep = asleep
        self.glow = glow
    }

    /// A subagent, by its name: a stable hue and its initial.
    init(name: String, size: CGFloat = 22, working: Bool = false, asleep: Bool = false) {
        self.glyph = .initial(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
        self.color = Palette.avatar(name)
        self.size = size
        self.working = working
        self.asleep = asleep
    }

    init(symbol: String, color: Color, size: CGFloat = 22, working: Bool = false, asleep: Bool = false, glow: Bool = true) {
        self.glyph = .symbol(symbol)
        self.color = color
        self.size = size
        self.working = working
        self.asleep = asleep
        self.glow = glow
    }

    private var isRound: Bool { if case .initial = glyph { true } else { false } }
    /// Glows only at sizes where it shows: a shadow is an extra render pass, and the transcript scrolls dozens of
    /// small marks.
    private var lit: Bool { size >= 24 }

    var body: some View {
        let shape = isRound ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        ZStack {
            shape.fill(Palette.canvas)
            shape.fill(LinearGradient(colors: [color.opacity(0.42), color.opacity(0.14)], startPoint: .top, endPoint: .bottom))
            shape.fill(RadialGradient(colors: [color.opacity(0.35), .clear], center: UnitPoint(x: 0.5, y: 0.3),
                                      startRadius: 0, endRadius: size * 0.7))
            // A stroke straddles the edge; clipping to the shape keeps its inner half, a hairline inside the tile.
            shape.stroke(LinearGradient(colors: [color.mix(with: .white, by: 0.4, in: .perceptual).opacity(0.85), color.opacity(0.25)],
                                        startPoint: .top, endPoint: .bottom), lineWidth: 2 * max(0.75, size * 0.035))
                .clipShape(shape)
            glyphView
                .foregroundStyle(color.mix(with: .white, by: 0.55, in: .perceptual))
                .shadow(color: color.opacity(lit ? 0.9 : 0), radius: lit ? size * 0.12 : 0)
        }
        .frame(width: size, height: size)
        .opacity(asleep ? 0.5 : 1)
        .saturation(asleep ? 0.3 : 1)
        .shadow(color: color.opacity(lit && glow && !asleep ? 0.3 : 0), radius: lit ? size * 0.22 : 0)
        .background {
            if working {
                RippleField(color: Palette.accent, diameter: size, cornerRadius: isRound ? size / 2 : size * 0.3, still: reduceMotion)
                    .frame(width: size * 2.2, height: size * 2.2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var glyphView: some View {
        switch glyph {
        case .agent(.pi):
            Text("π").font(.system(size: size * 0.6, weight: .semibold, design: .rounded)).offset(y: -size * 0.03)
        case .agent(.prime):
            Image(systemName: "sparkle").font(.system(size: size * 0.48, weight: .semibold))
        case .agent(.deepseek):
            Image(systemName: "water.waves").font(.system(size: size * 0.42, weight: .semibold))
        case .initial(let letter):
            Text(letter.isEmpty ? "·" : letter).font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.46, weight: .medium))
        }
    }
}

/// A soft glow behind something live: the send button, the selected row.
struct GlowModifier: ViewModifier {
    var color: Color = Palette.accent
    var radius: CGFloat = 10
    var on = true

    func body(content: Content) -> some View {
        // No shadow at all when off: even a clear one is an extra render pass.
        if on { content.shadow(color: color.opacity(0.45), radius: radius) } else { content }
    }
}

extension View {
    func glow(_ color: Color = Palette.accent, radius: CGFloat = 10, on: Bool = true) -> some View {
        modifier(GlowModifier(color: color, radius: radius, on: on))
    }

    /// Glass: a translucent dark fill the beam's color glows through, a hairline lit from above, and a faint sheen
    /// along the top edge. `frost` also blurs the dots behind it, for large surfaces that sit on the bright beam (the
    /// home cards, the composers); a blur re-renders on every frame something moves under it, so the many small cards
    /// that scroll in a transcript don't frost.
    func card(radius: CGFloat = 14, fill: Color = Palette.surface, border: Color = Palette.border, frost: Bool = false) -> some View {
        self
            .background {
                if frost {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                }
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [fill, fill.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.045), .clear], startPoint: .top, endPoint: .center))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [border.mix(with: .white, by: 0.22, in: .perceptual), border.opacity(0.7)],
                                                 startPoint: .top, endPoint: .bottom),
                                  lineWidth: 1)
            }
    }
}

/// Light sweeping across text, for things in progress. The sweep runs in Core Animation.
struct Shimmer: ViewModifier {
    var active: Bool
    var color: Color = Palette.moon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            content
                .overlay {
                    SweepField(color: color)
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
    func shimmer(_ active: Bool = true, color: Color = Palette.moon) -> some View { modifier(Shimmer(active: active, color: color)) }
}
