// Assistant prose that settles in calm chunks while it streams, instead of ticking in token by token.
import MarkdownUI
import SwiftUI

/// Rendered block by block (paragraphs, headings, lists, code), so a growing reply only redraws its last block.
/// While the turn streams, incoming text is held back and released a clause or sentence at a time, and each chunk
/// sweeps in reading order: its first characters surface first, each settling out of a soft blur, while the text
/// before it stays untouched. Code blocks are only released once their fence closes, so they always arrive whole.
struct StreamingMarkdown: View {
    let text: String
    let streaming: Bool
    /// Revealed so far, or nil once the reveal has caught up (or never ran) and the text renders as is.
    @State private var shown: String?
    /// What was revealed before the latest chunk.
    @State private var settled = ""
    /// How far the latest chunk has faded in.
    @State private var progress = 1.0
    @State private var target = ""
    @State private var live = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Time between chunks, and how long each one takes to fade in: a chunk has fully settled before the next begins.
    private static let beat = 0.8
    private static let fade = 0.74
    /// Characters per second at a steady pace; the reveal only speeds up to keep the hold-back under `maxLag` seconds.
    private static let pace = 300.0
    private static let maxLag = 3.5

    var body: some View {
        let blocks = Self.blocks(shown ?? text)
        let before = shown == nil ? [] : Self.blocks(settled)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                let block = blocks[index]
                Group {
                    if shown == nil || index < before.count - 1 || (index == before.count - 1 && before[index] == block) {
                        markdown(block)
                    } else if index < before.count {
                        // The last block grew: only its last run of text has new characters, from where it ended before.
                        markdown(block)
                            .textRenderer(Sweep(progress: progress, tail: (Self.visibleLength(block), Self.visibleLength(before[index]))))
                            // Selectable text is drawn by AppKit and skips custom renderers; it is selectable again once settled.
                            .textSelection(.disabled)
                    } else if Self.kind(block) == .code {
                        markdown(block).opacity(progress)
                    } else {
                        markdown(block).textRenderer(Sweep(progress: progress, tail: nil)).textSelection(.disabled)
                    }
                }
                .padding(.top, index == 0 ? 0 : Self.gap(after: blocks[index - 1], before: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, now in target = now }
        .onChange(of: streaming, initial: true) { _, now in live = now }
        .task {
            guard streaming, !reduceMotion else { return }
            // Text already there when the view appears was read before; only what arrives from now on is revealed.
            shown = text
            settled = text
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.beat))
                guard let current = shown else { return }
                guard target.hasPrefix(current) else {
                    // Rewritten rather than extended: show it as it is now.
                    shown = target; settled = target
                    continue
                }
                let backlog = target.count - current.count
                if backlog == 0 {
                    if !live { shown = nil; return }
                    continue
                }
                let budget = Int(max(Self.pace, Double(backlog) / Self.maxLag) * Self.beat)
                guard let next = Self.release(from: target, after: current.count, budget: budget, final: !live) else { continue }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) {
                    settled = current
                    shown = next
                    progress = 0
                }
                // Let the starting frame land before fading toward the end.
                try? await Task.sleep(for: .milliseconds(16))
                withAnimation(.easeOut(duration: Self.fade)) { progress = 1 }
            }
        }
    }

    private func markdown(_ string: String) -> some View {
        Markdown(string)
            .markdownTheme(.agent)
            .markdownImageProvider(.media)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Blocks

    private static func isFence(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Top-level blocks: runs of lines between blank lines, with fenced code kept whole.
    static func blocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var fenced = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isFence(line) { fenced.toggle() }
            if !fenced, line.allSatisfy(\.isWhitespace) {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }

    private enum Kind: Equatable { case heading(Int), code, table, rule, quote, other }

    private static func kind(_ block: String) -> Kind {
        let first = block.prefix { $0 != "\n" }.drop { $0 == " " }
        if isFence(first) { return .code }
        if first.hasPrefix("#") {
            let level = first.prefix { $0 == "#" }.count
            if level <= 6, first.dropFirst(level).first == " " { return .heading(level) }
        }
        if first.hasPrefix("|") { return .table }
        if first.hasPrefix(">") { return .quote }
        let compact = first.filter { !$0.isWhitespace }
        if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) { return .rule }
        return .other
    }

    /// The theme's margins between two blocks, as a single document would collapse them.
    private static func gap(after previous: String, before next: String) -> CGFloat {
        let bottom: CGFloat = switch kind(previous) {
        case .heading(1): 10
        case .heading(2): 8
        case .heading: 6
        case .quote: 10
        default: 16
        }
        let top: CGFloat = switch kind(next) {
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

    /// Characters in the block's last run of text as rendered, markup aside: what the sweep counts in.
    /// Only an estimate of MarkdownUI's own text; when it misses, the sweep leaves that text alone.
    static func visibleLength(_ block: String) -> Int {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map { $0.drop { $0 == " " || $0 == "\t" } }
        if case .heading = kind(block) { lines = [lines[0].drop { $0 == "#" }.drop { $0 == " " }] }
        if case .quote = kind(block) { lines = lines.map { $0.drop { $0 == ">" }.drop { $0 == " " } } }
        // A list renders each item as its own text: keep the last item, without its marker.
        if let item = lines.lastIndex(where: { listMarker($0) != nil }) {
            lines = Array(lines[item...])
            lines[0] = lines[0].dropFirst(listMarker(lines[0])!)
        }
        let inline = lines.joined(separator: "\n")
        let plain = (try? AttributedString(markdown: inline, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? inline
        return plain.utf16.count
    }

    /// The length of a list item's marker and the space after it, if the line starts one.
    private static func listMarker(_ line: Substring) -> Int? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " { return 2 }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count < 10 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        return digits.count + 2
    }

    // MARK: Release

    /// The text up to a natural break roughly `budget` characters past `start`, or nil when no clean break has arrived yet.
    /// A trailing half-written word or clause is held back while the stream is live, and so is an unclosed code block.
    static func release(from text: String, after start: Int, budget: Int, final: Bool) -> String? {
        let chars = Array(text)
        let end = chars.count
        let want = min(end, start + max(budget, 8))
        if final && want == end { return text }

        func isBreak(_ i: Int) -> Bool {
            // A break after chars[i - 1].
            guard i > start, i <= end else { return false }
            if i == end { return final }
            let c = chars[i - 1]
            return c == "\n" || ((".!?:;,".contains(c)) && chars[i].isWhitespace)
        }
        func isSpace(_ i: Int) -> Bool { i > start && i < end && chars[i].isWhitespace && !chars[i - 1].isWhitespace }

        // Prefer the nearest clause break around the budget, looking a little ahead first, then back.
        let reach = min(end, want + 60)
        var cut = (want...reach).first(where: isBreak) ?? stride(from: want, to: start + budget / 3, by: -1).first(where: isBreak)
        // A long clause: settle for a word boundary.
        if cut == nil { cut = stride(from: want, to: start, by: -1).first(where: isSpace) }
        guard var i = cut else { return final ? text : nil }

        // Never cut inside a code block: carry on to the end of its closing fence, or wait for it.
        let lines = String(chars[..<i]).split(separator: "\n", omittingEmptySubsequences: false)
        if lines.filter(isFence).count % 2 == 1 {
            var offset = 0
            var closed = false
            for line in String(chars[i...]).split(separator: "\n", omittingEmptySubsequences: false) {
                offset += line.count + 1
                if isFence(line) { closed = true; break }
            }
            guard closed else { return final ? text : nil }
            i = min(end, i + offset)
        }
        return String(chars[..<i])
    }
}

/// Draws text so that characters surface in reading order as `progress` goes from 0 to 1: a soft front a few
/// characters wide moves through, each character rising out of a slight blur as it passes.
private struct Sweep: TextRenderer {
    var progress: Double
    /// For a block that grew: the rendered length of its last text, and where the new characters start in it.
    /// Any other text in the block, or this one if the estimate is off, is drawn as it is. Nil sweeps all of it.
    var tail: (total: Int, start: Int)?

    /// Characters the soft front spans.
    private static let soft = 16.0

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run } }
        guard let first = slices.first?.characterIndices.first, progress < 1 else {
            for line in layout { context.draw(line) }
            return
        }
        let length = (slices.last?.characterIndices.last).map { first.distance(to: $0) + 1 } ?? 0
        var start = 0
        if let tail {
            // Another text of the block, or a miscount: nothing here is new for sure, so leave it be.
            guard tail.total == length, tail.start < length else {
                for line in layout { context.draw(line) }
                return
            }
            start = tail.start
        }
        let front = progress * (Double(length - start) + Self.soft)
        for slice in slices {
            guard let index = slice.characterIndices.first.map({ first.distance(to: $0) }) else { continue }
            let shown = index < start ? 1 : min(max((front - Double(index - start)) / Self.soft, 0), 1)
            if shown >= 1 {
                context.draw(slice)
            } else if shown > 0 {
                var glyph = context
                glyph.opacity = shown
                glyph.translateBy(x: 0, y: (1 - shown) * 3)
                glyph.addFilter(.blur(radius: (1 - shown) * 2.5))
                glyph.draw(slice)
            }
        }
    }
}
