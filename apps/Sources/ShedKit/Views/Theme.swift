// Colors, sizes and the Markdown theme shared by every view.
@preconcurrency import MarkdownUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif
/// Near-black ground under a dithered beam of light; frosted glass for everything that sits on it. Electric blue for
/// what is alive or primary, orange for what needs you. Shed is dark only.
enum Palette {
    /// Behind the transcript: near-black, a touch blue.
    static let canvas = hex(0x06080C)
    /// Behind the session list: solid, so the list reads calmly beside the beam.
    static let sidebar = hex(0x0A0C11)
    /// Glass: cards, tool calls, the composer. Translucent, so the beam glows faintly through.
    static let surface = hex(0x121822, alpha: 0.78)
    /// Glass above glass: menus, the selected row, pressed things.
    static let raised = hex(0x1B2330, alpha: 0.88)
    /// Code and tool output, set into a surface.
    static let sunken = hex(0x040609, alpha: 0.92)
    /// Hairlines: lit a little brighter at the top where they edge glass.
    static let border = hex(0x252E3C)
    static let rail = hex(0x2B3442)
    static let inlineCode = hex(0x171E2A)
    /// Blue-tinted glass.
    static let userBubble = hex(0x143364, alpha: 0.86)
    static let userBubbleBorder = hex(0x4486EC)
    /// A hairline lit by the beam: the edge of glass rows and chips on the dark field.
    static let lit = hex(0x2C4C7E)
    /// The composer's glass, opaque.
    static let composer = hex(0x111A27)
    static let lineNumber = hex(0x4A5568)

    /// Cool accent: links, Prime.
    static let ice = hex(0x8CC4FF)
    /// Text: near-white.
    static let moon = hex(0xEEF1F6)
    static let periwinkle = hex(0x8E9DFF)
    static let lilac = hex(0xB59BFF)
    static let rose = hex(0xFF9EC4)
    /// Electric blue: what is alive right now, and the primary action.
    static let accent = hex(0x4C9BFF)
    static let accentDeep = hex(0x2C6BE0)
    /// Orange: what waits on you (a question, a session that wants an answer).
    static let attention = hex(0xFF8A3D)
    static let success = hex(0x3DD68C)
    static let danger = hex(0xFF6B5E)

    static let prime = ice
    static let pi = lilac
    static let deepseek = periwinkle

    static func agent(_ kind: AgentKind) -> Color {
        switch kind {
        case .pi: pi
        case .prime: prime
        case .deepseek: deepseek
        }
    }

    /// A stable spirit color per subagent name.
    static func avatar(_ name: String) -> Color {
        let colors: [Color] = [ice, attention, lilac, periwinkle, rose, hex(0x7FD0F2), success]
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return colors[abs(hash) % colors.count]
    }

    static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255,
              opacity: alpha)
    }
}

extension Font {
    /// Nordwand Mono, bundled with the app, for code, commands and paths. Falls back to the system's monospaced face.
    static let monoFamily = "Nordwand Mono"

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, size: size).weight(weight)
    }
}

enum Layout {
    /// Transcript and composer width: prose stays readable on a wide window.
    static let column: CGFloat = 760
    #if os(macOS)
    static let gutter: CGFloat = 24
    #else
    static let gutter: CGFloat = 16
    #endif
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension Theme {
    /// Assistant prose: 16 pt body, compact headings, cards for code, quiet tables.
    @MainActor static let agent = Theme()
        .text {
            FontSize(16)
            ForegroundColor(Palette.moon.opacity(0.92))
        }
        .code {
            FontFamily(.custom(Font.monoFamily))
            FontSize(.em(0.88))
            BackgroundColor(Palette.inlineCode)
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(Palette.ice) }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 28, bottom: 10)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.45))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 26, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.28))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 22, bottom: 6)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
        }
        .heading4 { configuration in
            configuration.label
                .markdownMargin(top: 18, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold) }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.36))
                .markdownMargin(top: 0, bottom: 16)
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.45))
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.ice.opacity(0.5))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle { ForegroundColor(.secondary) }
                    .padding(.leading, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: 10)
        }
        .codeBlock { configuration in
            CodeCard(language: configuration.language, code: configuration.content) {
                configuration.label
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamily(.custom(Font.monoFamily))
                        FontSize(.em(0.86))
                    }
            }
            .markdownMargin(top: 4, bottom: 16)
        }
        .table { configuration in
            // As wide as its columns want, scrolling sideways when that's wider than the screen, rather than squeezed
            // until every word breaks.
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(.horizontalBorders, color: Palette.border))
                    .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Palette.surface))
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .markdownMargin(top: 4, bottom: 16)
        }
        .tableCell { configuration in
            // A column fits its content up to 240 pt, then wraps: long cells stay readable without one column taking
            // the whole table.
            CappedWidth(cap: 240) {
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 { FontWeight(.semibold) }
                        FontSize(.em(0.93))
                    }
            }
            .padding(.vertical, 6)
                .padding(.horizontal, 10)
        }
        .thematicBreak {
            Divider().markdownMargin(top: 16, bottom: 16)
        }
}

/// Its content at its natural width up to `cap`, wrapping past it, and measured that way too: a frame with a maximum
/// width would let a table size its rows for the unwrapped text.
struct CappedWidth: SwiftUI.Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, cap, proposal.width ?? .infinity)
        return content.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// A fenced code block: language label, copy button, horizontal scrolling.
struct CodeCard<Content: View>: View {
    let language: String?
    let code: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider().overlay(Palette.border)
            ScrollView(.horizontal) {
                content.padding(12)
            }
        }
        .card(radius: 12, fill: Palette.sunken)
    }
}

struct CopyButton: View {
    let text: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                if let label { Text(copied ? "Copied" : label) }
            }
            .font(.caption)
            .foregroundStyle(copied ? AnyShapeStyle(Palette.ice) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy")
    }
}

/// A velvet capsule used in the header and below the composer; tinted when it stands for something.
struct PillStyle: ViewModifier {
    var tint: Color? = nil

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background((tint ?? Color.clear).opacity(tint == nil ? 0 : 0.14), in: Capsule())
            .card(radius: 15, fill: Palette.raised.opacity(0.7), border: tint?.opacity(0.4) ?? Palette.border)
            .foregroundStyle(tint ?? Palette.moon)
    }
}

extension View {
    func pill(tint: Color? = nil) -> some View { modifier(PillStyle(tint: tint)) }
}

enum Format {
    static func duration(ms: Double) -> String {
        let seconds = Int((ms / 1000).rounded())
        if ms < 1000 { return "\(Int(ms))ms" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m \(seconds % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// A running time at a glance: "40s", "14m", "2h 5m".
    static func elapsed(ms: Double) -> String {
        let seconds = max(0, Int(ms / 1000))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "950", "31.3K", "1M", "1.05M".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return "\((Double(n) / 1_000_000).formatted(.number.precision(.fractionLength(0...2))))M" }
        return n >= 1000 ? "\((Double(n) / 1000).formatted(.number.precision(.fractionLength(0...1))))K" : "\(n)"
    }

    /// "~/src/project" for paths under the home folder.
    static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// A segmented control in glass: the chosen segment lit blue, its highlight gliding over on a spring.
struct GlassSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 28
    /// The room beside each label. Less of it fits more segments.
    var inset: CGFloat = 12
    @Namespace private var glide
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Palette.moon : Palette.moon.opacity(hovered == option.value ? 0.85 : 0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.horizontal, inset)
                        .frame(maxWidth: .infinity, minHeight: height - 4)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: (height - 4) / 2.6, style: .continuous)
                                    .fill(LinearGradient(colors: [Palette.accent.opacity(0.42), Palette.accentDeep.opacity(0.3)],
                                                         startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: (height - 4) / 2.6, style: .continuous)
                                        .strokeBorder(Palette.accent.opacity(0.7), lineWidth: 1))
                                    .shadow(color: Palette.accent.opacity(0.35), radius: 6)
                                    .matchedGeometryEffect(id: "selection", in: glide)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
                #endif
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .card(radius: height / 2.4, fill: Palette.sunken.opacity(0.85))
    }
}
