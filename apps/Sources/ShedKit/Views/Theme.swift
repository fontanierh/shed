// Colors, sizes and the Markdown theme shared by every view.
@preconcurrency import MarkdownUI
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif
/// Moonlight on blue-black velvet; amber for whatever is alive right now. Shed is dark only.
enum Palette {
    /// Behind the transcript.
    static let canvas = hex(0x0A0F17)
    /// Behind the session list, a touch lighter than the transcript.
    static let sidebar = hex(0x0D131D)
    /// Cards: tool calls, reports, the composer.
    static let surface = hex(0x131B27)
    /// A card that sits above another: menus, the selected row.
    static let raised = hex(0x18222F)
    /// Code and tool output, set into a surface.
    static let sunken = hex(0x080C13)
    static let border = hex(0x1F2A3A)
    static let rail = hex(0x2A3B55)
    static let inlineCode = hex(0x1A2433)
    /// Ice-blue glass.
    static let userBubble = hex(0x15284A)
    static let userBubbleBorder = hex(0x2A4A7A)
    static let lineNumber = hex(0x44536B)

    /// Moonlight: the cool accent, links, Prime.
    static let ice = hex(0x9CC2F5)
    /// Near-white text with a blue cast.
    static let moon = hex(0xE4ECF7)
    static let periwinkle = hex(0x8A9EF0)
    static let lilac = hex(0xB9A2F2)
    static let rose = hex(0xF0A3C4)
    /// Firefly amber: live and active things only.
    static let amber = hex(0xF5B95C)
    static let ember = hex(0xE8913A)
    static let danger = hex(0xF07F7F)

    static let prime = ice
    static let pi = lilac

    static func agent(_ kind: AgentKind) -> Color { kind == .pi ? pi : prime }

    /// A stable spirit color per subagent name.
    static func avatar(_ name: String) -> Color {
        let colors: [Color] = [ice, amber, lilac, periwinkle, rose, hex(0x7FD0F2)]
        let hash = name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return colors[abs(hash) % colors.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
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
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.horizontalBorders, color: Palette.border))
                .markdownTableBackgroundStyle(.alternatingRows(Color.clear, Palette.surface))
                .markdownMargin(top: 4, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    FontSize(.em(0.93))
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
        }
        .thematicBreak {
            Divider().markdownMargin(top: 16, bottom: 16)
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
