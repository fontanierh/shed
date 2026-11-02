// Assistant prose that streams in word by word: each word fades up on its own as it arrives.
@preconcurrency import MarkdownUI
import SwiftUI

/// Rendered block by block (paragraphs, headings, lists, code), so a growing reply only lays out its last block again.
/// While the reply streams, each word fades in as it arrives, in reading order, and the text before it stays as it is.
/// Only the blocks with a word still fading redraw on each frame, and only while one is: the rest draw once.
struct StreamingMarkdown: View {
    let text: String
    let streaming: Bool
    /// The reply's item, whose text streams in through `liveText` ahead of `text`.
    var id: String? = nil
    @Environment(\.liveText) private var liveText
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the words still fading in arrived. A class: noting an arrival doesn't redraw anything by itself.
    @State private var arrivals = Arrivals()
    /// How far the fades are known to have finished: the reply draws at rest once its last word is fully in.
    @State private var settled = Date.distantPast

    /// The text so far. Only a streaming reply reads `liveText`, so text arriving for it redraws nothing else. A word
    /// still being written is held back, so each word arrives, and fades in, whole.
    private var current: String {
        guard streaming else { return text }
        return Self.wholeWords(id.flatMap { liveText?.texts[$0] } ?? text)
    }

    var body: some View {
        // Noted as the view updates rather than after, so a word is never drawn before it is known to have just arrived.
        let blocks = arrivals.noting(Self.blocks(current), at: .now, animate: !reduceMotion && (streaming || arrivals.until > settled))
        let fading = arrivals.until > settled
        Group {
            if (streaming && !reduceMotion) || fading {
                // Every block in the same runs, whether a word of it is fading or not, so none is rebuilt as its words settle.
                TimelineView(.animation(minimumInterval: Fade.frame, paused: !fading)) { context in
                    let now = context.date.timeIntervalSinceReferenceDate
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(stride(from: 0, to: blocks.count, by: Run.length)), id: \.self) { start in
                            let indices = start..<min(start + Run.length, blocks.count)
                            Run(
                                blocks: indices.map { FadingBlock(text: blocks[$0].text, fade: arrivals.fade($0, at: now)) },
                                spacings: indices.map { Self.spacing(blocks, $0) }
                            )
                            .equatable()
                        }
                    }
                }
                // Selectable text is drawn by AppKit, which skips custom renderers: the reply is selectable once it rests.
                .textSelection(.disabled)
            } else {
                Settled(blocks: blocks).equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: arrivals.until) {
            let until = arrivals.until
            guard until > settled else { return }
            try? await Task.sleep(for: .seconds(until.timeIntervalSinceNow))
            if !Task.isCancelled { settled = until }
        }
    }

    /// The text up to its last whitespace: a word still being written isn't shown yet.
    static func wholeWords(_ text: String) -> String {
        guard let last = text.lastIndex(where: \.isWhitespace) else { return "" }
        return String(text[...last])
    }

    /// The blocks of a reply at rest.
    private struct Settled: View, Equatable {
        let blocks: [Block]

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { index in
                    MarkdownBlock(text: blocks[index].text).equatable()
                        .padding(.top, StreamingMarkdown.spacing(blocks, index))
                }
            }
        }
    }

    /// A run of a streaming reply's blocks. Once its words have all faded in it stays equal, so neither a frame of the
    /// fade nor the reply growing below it walks its blocks again: a long reply costs its few live runs, not its length.
    private struct Run: View, Equatable {
        static let length = 8
        let blocks: [FadingBlock]
        let spacings: [CGFloat]

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks.indices, id: \.self) { index in
                    blocks[index].equatable().padding(.top, spacings[index])
                }
            }
        }
    }

    /// A block of a streaming reply, drawn again only when its text grows or a word of it is fading.
    private struct FadingBlock: View, Equatable {
        let text: String
        let fade: Fade

        var body: some View {
            MarkdownBlock(text: text).equatable().textRenderer(fade)
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

    private static func isFence(_ line: Substring) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Top-level blocks: runs of lines between blank lines, with fenced code kept whole.
    /// Memoized: the view and its arrivals ask for the same text's blocks several times per update.
    @MainActor static func blocks(_ text: String) -> [Block] {
        if let hit = recent.first(where: { $0.text == text }) { return hit.blocks }
        let blocks = blockTexts(text).map { Block(text: $0, kind: kind($0)) }
        recent = [(text, blocks)] + recent.prefix(3)
        return blocks
    }

    @MainActor private static var recent: [(text: String, blocks: [Block])] = []

    static func blockTexts(_ text: String) -> [String] {
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

    fileprivate enum Kind: Equatable { case heading(Int), code, table, rule, quote, other }

    private static func kind(_ block: String) -> Kind {
        let first = block.prefix { $0 != "\n" }.drop { $0 == " " }
        if isFence(first) { return .code }
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

    /// The block's last run of text as rendered, markup aside: the text that grows as the block streams in.
    /// Only an estimate of MarkdownUI's own text; when it misses, `Fade` leaves that text as it is.
    static func visibleText(_ block: Block) -> String { texts(block).last ?? "" }

    /// The block's runs of text as rendered: one for most blocks, one per item for a list.
    static func texts(_ block: Block) -> [String] {
        if block.kind == .code {
            // The code between the fences, as the code block shows it.
            let lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
            return [lines.prefix { !isFence($0) }.joined(separator: "\n")]
        }
        var lines = block.text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.drop { $0 == " " || $0 == "\t" } }
        if case .heading = block.kind { lines = [lines[0].drop { $0 == "#" }.drop { $0 == " " }] }
        if case .quote = block.kind { lines = lines.map { $0.drop { $0 == ">" }.drop { $0 == " " } } }
        // A list renders each item as its own text, without its marker.
        var items: [[Substring]] = []
        for line in lines {
            if let marker = listMarker(line) { items.append([line.dropFirst(marker)]) } else if items.isEmpty { items = [[line]] } else { items[items.count - 1].append(line) }
        }
        return items.map { item in
            let inline = item.joined(separator: "\n")
            let plain = (try? AttributedString(markdown: inline, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                .map { String($0.characters) } ?? inline
            // Markdown drops the whitespace a paragraph ends with.
            return String(plain[..<(plain.lastIndex { !$0.isWhitespace }.map(plain.index(after:)) ?? plain.startIndex)])
        }
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
}

/// When each word of a streaming reply arrived, per block, for as long as one may still be fading in.
@MainActor
final class Arrivals {
    /// A block's last text so far, and when its words arrived.
    struct Track: Equatable {
        /// The text's length as rendered, in UTF-16 code units: how `Fade` tells it from the block's other texts.
        var length = 0
        /// Where each word ends, and when it arrived, in reading order.
        var words: [(end: Int, at: TimeInterval)] = []
        /// Another text of the block is as long: this one draws as it is.
        var ambiguous = false

        /// Words are only ever added, so the last one tells two tracks of a block apart.
        static func == (a: Track, b: Track) -> Bool {
            a.length == b.length && a.ambiguous == b.ambiguous && a.words.count == b.words.count
                && a.words.last?.end == b.words.last?.end && a.words.last?.at == b.words.last?.at
        }
    }

    /// When the last word noted is fully in.
    private(set) var until = Date.distantPast
    /// The blocks as last noted; nil before the first time, whose text was there before anything streamed.
    private var blocks: [StreamingMarkdown.Block]?
    /// The texts of the blocks that have streamed in, as rendered.
    private var plains: [Int: String] = [:]
    private var tracks: [Int: Track] = [:]
    private var latest: TimeInterval = 0

    /// How to draw a block at `now`: with its words' fades while one is in flight, else as it is.
    fileprivate func fade(_ block: Int, at now: TimeInterval) -> Fade {
        guard let track = tracks[block], let last = track.words.last, last.at + Fade.duration > now else { return Fade(track: nil, now: 0) }
        return Fade(track: track, now: now)
    }

    /// `blocks`, with the words that arrived in them since the last time noted; the same blocks again change nothing.
    func noting(_ blocks: [StreamingMarkdown.Block], at date: Date, animate: Bool) -> [StreamingMarkdown.Block] {
        guard blocks != self.blocks else { return blocks }
        let before = self.blocks
        self.blocks = blocks
        guard animate, let before else {
            plains = [:]
            tracks = [:]
            return blocks
        }
        let now = date.timeIntervalSinceReferenceDate
        tracks = tracks.filter { $0.value.words.last.map { $0.at + Fade.duration > now } == true }
        for index in blocks.indices where index >= before.count || before[index] != blocks[index] {
            let texts = StreamingMarkdown.texts(blocks[index])
            let plain = texts.last ?? ""
            // What the block showed before, worked out only now for one that was there before anything streamed.
            let previous = plains[index] ?? (index < before.count ? StreamingMarkdown.visibleText(before[index]) : "")
            // A new list item, or text written over: its words arrive from its start.
            let grew = plain.hasPrefix(previous)
            var track = grew ? tracks[index] ?? Track() : Track()
            let ends = Self.wordEnds(in: plain, from: grew ? previous.utf16.count : 0)
            // A batch of words lands at once: spread them over the time until the next, so they flow in one by one.
            let gap = ends.isEmpty ? 0 : min(Fade.stagger, Fade.batch / Double(ends.count))
            for end in ends {
                latest = max(now, latest + gap)
                track.words.append((end, latest))
            }
            track.length = plain.utf16.count
            // `Fade` knows the text it draws only by its length: another text of the block as long would fade along with it.
            track.ambiguous = texts.dropLast().contains { $0.utf16.count == track.length }
            tracks[index] = track
            plains[index] = plain
        }
        until = max(until, Date(timeIntervalSinceReferenceDate: latest + Fade.duration))
        return blocks
    }

    /// Where each word that ends after `start` ends, in UTF-16 code units; the text's end counts as one.
    private static func wordEnds(in text: String, from start: Int) -> [Int] {
        var ends: [Int] = []
        var offset = 0
        var inWord = false
        for character in text {
            if character.isWhitespace {
                if inWord, offset > start { ends.append(offset) }
                inWord = false
            } else {
                inWord = true
            }
            offset += character.utf16.count
        }
        if inWord, offset > start { ends.append(offset) }
        return ends
    }
}

/// Draws a block's growing text with each word fading up from the moment it arrived. Text the track doesn't describe
/// (the block's other texts, or this one if its length was misjudged) draws as it is.
private struct Fade: TextRenderer, Equatable {
    let track: Arrivals.Track?
    let now: TimeInterval

    /// How long a word takes to fade in, and how far apart the words of one batch start.
    static let duration = 0.5
    static let stagger = 0.03
    /// How often streamed text arrives: the words of one batch spread over it.
    static let batch = 0.08
    /// At most 60 frames a second: the fade looks the same, at half the redraws of a 120 Hz display.
    static let frame = 1.0 / 60

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let slices = layout.flatMap { line in line.flatMap { run in run } }
        guard let track, !track.ambiguous, let first = slices.first?.characterIndices.first,
              let last = slices.last?.characterIndices.last, first.distance(to: last) + 1 == track.length,
              let fading = track.words.firstIndex(where: { $0.at + Self.duration > now }) else {
            for line in layout { context.draw(line) }
            return
        }
        // Everything before the first word still fading is fully in.
        let settled = fading == 0 ? 0 : track.words[fading - 1].end
        var word = fading
        for line in layout {
            if let end = line.last?.last?.characterIndices.last.map({ first.distance(to: $0) }), end < settled {
                context.draw(line)
                continue
            }
            for slice in line.flatMap({ run in run }) {
                guard let index = slice.characterIndices.first.map({ first.distance(to: $0) }) else { continue }
                if index < settled { context.draw(slice); continue }
                while word < track.words.count, track.words[word].end <= index { word += 1 }
                // Past the last word noted (whitespace after it): nothing to draw.
                guard word < track.words.count else { continue }
                let shown = min(max((now - track.words[word].at) / Self.duration, 0), 1)
                guard shown > 0 else { continue }
                var glyph = context
                glyph.opacity = 1 - (1 - shown) * (1 - shown)
                glyph.draw(slice)
            }
        }
    }
}
