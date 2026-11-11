// Assistant prose, rendered block by block.
@preconcurrency import MarkdownUI
import SwiftUI

/// Rendered block by block (paragraphs, headings, lists, code), so a growing reply only lays out its last block again.
/// A streaming reply grows word by word, and its new words print in at the writing edge (`InkEdge`).
struct StreamingMarkdown: View {
    let text: String
    let streaming: Bool
    /// The reply's item, whose text streams in through `liveText` ahead of `text`.
    var id: String? = nil
    @Environment(\.liveText) private var liveText
    @Environment(\.inlineSelection) private var inlineSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Whether this view showed the reply being written: on the phone its last words, which come as it ends, then
    /// print in too. On the Mac the reply turns selectable as it ends, which builds it anew.
    @State private var written = Written()

    private final class Written { var seen = false }

    /// The text so far. Only a streaming reply reads `liveText`, so text arriving for it redraws nothing else.
    /// A word still being written waits until it is whole.
    private var current: String {
        guard streaming else { return text }
        return InkEdge.settled(id.flatMap { liveText?.texts[$0] } ?? text)
    }

    var body: some View {
        let blocks = Self.blocks(current)
        if streaming { written.seen = true }
        return Group {
            if streaming || !inlineSelection {
                // Selectable once it rests: every selectable text is something a touch is checked against.
                Settled(blocks: blocks, inked: written.seen && !reduceMotion).equatable().textSelection(.disabled)
            } else {
                Settled(blocks: blocks).equatable().textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The blocks of a reply at rest.
    private struct Settled: View, Equatable {
        let blocks: [Block]
        /// Still being written: the blocks it ends with print their new words in.
        var inked = false

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { index in
                    Group {
                        // The last two: a block's last words often come with the first of the next.
                        if inked, index >= blocks.count - 2 {
                            MarkdownBlock(text: blocks[index].text).equatable().modifier(InkEdgeReader())
                        } else {
                            MarkdownBlock(text: blocks[index].text).equatable()
                        }
                    }
                    .padding(.top, StreamingMarkdown.spacing(blocks, index))
                }
            }
        }
    }

    /// One block, parsed and laid out again only when its own text changes.
    private struct MarkdownBlock: View, Equatable {
        let text: String

        var body: some View {
            Markdown(text)
                .markdownTheme(.agent)
                .markdownImageProvider(.media)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Blocks

    struct Block: Equatable {
        let text: String
        fileprivate let kind: Kind
    }

    private struct Fence {
        let char: Character
        let count: Int
    }

    /// CommonMark opening code fence: up to 3 leading spaces, 3+ ` or ~, and no ` in a backtick fence's info string.
    private static func openingFence(_ line: Substring) -> Fence? {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return nil }
        let rest = line.dropFirst(spaces)
        guard let mark = rest.first, mark == "`" || mark == "~" else { return nil }
        let count = rest.prefix { $0 == mark }.count
        guard count >= 3 else { return nil }
        let info = rest.dropFirst(count)
        if mark == "`", info.contains("`") { return nil }
        return Fence(char: mark, count: count)
    }

    /// CommonMark closing code fence: up to 3 leading spaces, at least `fence.count` matching marks, then whitespace only.
    private static func closesFence(_ line: Substring, _ fence: Fence) -> Bool {
        let spaces = line.prefix { $0 == " " }.count
        guard spaces <= 3 else { return false }
        let rest = line.dropFirst(spaces)
        let count = rest.prefix { $0 == fence.char }.count
        guard count >= fence.count else { return false }
        return rest.dropFirst(count).allSatisfy(\.isWhitespace)
    }

    /// Top-level blocks: runs of lines between blank lines, with fenced code kept whole.
    /// Memoized: the view asks for the same text's blocks at every update. A streaming reply
    /// only grows, which changes nothing before its last block: it is split again from there, not from its start.
    @MainActor static func blocks(_ rawText: String) -> [Block] {
        let text = rawText.contains("\r\n") ? rawText.replacingOccurrences(of: "\r\n", with: "\n") : rawText
        if let hit = recent.first(where: { $0.text == text }) { return hit.blocks }
        var blocks: [Block]
        if let base = recent.first(where: { !$0.blocks.isEmpty && text.hasPrefix($0.text) }) {
            let tail = text.utf8.dropFirst(base.lastStart)
            blocks = base.blocks.dropLast() + blockTexts(String(Substring(tail))).map { Block(text: $0, kind: kind($0)) }
        } else {
            blocks = blockTexts(text).map { Block(text: $0, kind: kind($0)) }
        }
        // Where the last block starts: it ends the text, but for blank lines.
        let lastStart = blocks.last.flatMap { last in text.range(of: last.text, options: .backwards) }
            .map { text.utf8.distance(from: text.startIndex, to: $0.lowerBound) } ?? 0
        recent = [(text, blocks, lastStart)] + recent.prefix(3)
        return blocks
    }

    @MainActor private static var recent: [(text: String, blocks: [Block], lastStart: Int)] = []

    static func blockTexts(_ rawText: String) -> [String] {
        let text = rawText.contains("\r\n") ? rawText.replacingOccurrences(of: "\r\n", with: "\n") : rawText
        var blocks: [String] = []
        var current: [Substring] = []
        var activeFence: Fence?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let fence = activeFence {
                current.append(line)
                if closesFence(line, fence) { activeFence = nil }
            } else if let fence = openingFence(line) {
                activeFence = fence
                current.append(line)
            } else if line.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    fileprivate enum Kind: Equatable { case heading(Int), code, table, rule, quote, other }

    private static func kind(_ block: String) -> Kind {
        let firstLine = block.prefix { $0 != "\n" }
        if openingFence(firstLine) != nil { return .code }
        let first = firstLine.drop { $0 == " " }
        if first.hasPrefix("#") {
            let level = first.prefix { $0 == "#" }.count
            if level <= 6, first.dropFirst(level).first == " " { return .heading(level) }
        }
        if first.hasPrefix("|") { return .table }
        if first.hasPrefix(">") { return .quote }
        // A rule is a short line: don't copy a whole paragraph to find out it isn't one.
        guard first.utf8.count <= 80 else { return .other }
        let compact = first.filter { !$0.isWhitespace }
        if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) { return .rule }
        return .other
    }

    /// Space above a block: the theme's margins between it and the one before, as a single document would collapse them.
    private static func spacing(_ blocks: [Block], _ index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let bottom: CGFloat = switch blocks[index - 1].kind {
        case .heading(1): 10
        case .heading(2): 8
        case .heading: 6
        case .quote: 10
        default: 16
        }
        let top: CGFloat = switch blocks[index].kind {
        case .heading(1): 28
        case .heading(2): 26
        case .heading(3): 22
        case .heading: 18
        case .code, .table: 4
        case .rule: 16
        default: 0
        }
        return max(bottom, top)
    }
}
