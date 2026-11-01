// Files the agents hand the user (`![notes](/path/on/the/mac/notes.md)`, or a plain link to one): a card in the reply
// that opens a viewer, Markdown rendered and code highlighted, with the file to download.
import CoreText
@preconcurrency import MarkdownUI
import QuickLook
import SwiftUI

#if os(macOS)
import Quartz
#else
import UIKit
#endif

/// The file open in the viewer.
struct ShownFile: Identifiable {
    let id = UUID()
    /// As the agent wrote it, to resolve the file's own relative links and images against.
    let url: URL
    let request: URLRequest
    /// Where the file's own embeds load from: the session it was shared in.
    let media: MediaSource
    var name: String { url.lastPathComponent }
}

/// How the viewer shows a file, by its name.
enum FileKind: Equatable {
    case markdown
    /// Text, with the language to colour it as, if known.
    case code(String?)
    /// Anything else: Quick Look's preview (PDF, office documents, images), or the text if it turns out to be text.
    case other

    init(_ name: String) {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["md", "markdown", "mdx"].contains(ext) { self = .markdown; return }
        if let language = Self.languages[ext] { self = .code(language); return }
        if Self.text.contains(ext) || Self.textNames.contains(name) { self = .code(nil); return }
        self = .other
    }

    private static let languages: [String: String] = [
        "py": "python", "sh": "bash", "bash": "bash", "zsh": "bash", "json": "json", "jsonl": "json", "ipynb": "json",
        "swift": "swift", "rs": "rust", "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
        "ts": "javascript", "tsx": "javascript", "go": "go",
    ]
    private static let text: Set<String> = [
        "txt", "log", "csv", "tsv", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml", "html", "htm", "css", "scss",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "rb", "php", "sql", "r", "lua", "diff", "patch", "tex",
        "fish", "proto", "graphql", "lock",
    ]
    private static let textNames: Set<String> = ["Makefile", "Dockerfile", "README", "LICENSE", "Gemfile", "Procfile"]

    var label: String {
        switch self {
        case .markdown: "Markdown"
        case .code(let language?): language == "json" ? "JSON" : language.capitalized
        case .code(nil): "Text"
        case .other: "File"
        }
    }

    var symbol: String {
        switch self {
        case .markdown: "doc.richtext"
        case .code(nil): "doc.plaintext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

/// Fetches a file to a temporary folder under its own name, so it can be previewed, shared or saved as itself.
func downloadFile(_ request: URLRequest, name: String) async throws -> URL {
    let (file, response) = try await URLSession.shared.download(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw MediaError(status: http.statusCode) }
    let folder = FileManager.default.temporaryDirectory.appending(path: "Shed/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appending(path: name.isEmpty ? "file" : name)
    try FileManager.default.moveItem(at: file, to: destination)
    return destination
}

#if os(iOS)
/// The share sheet for a downloaded file, with Save to Files, over whatever is showing.
@MainActor
func shareFile(_ url: URL) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    guard var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    share.popoverPresentationController?.sourceView = top.view
    share.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
    top.present(share, animated: true)
}
#endif

extension Lightbox {
    func open(_ url: URL, media: MediaSource) {
        guard let request = media.request(for: url) else { return }
        file = ShownFile(url: url, request: request, media: media)
    }
}

/// Links in a reply to a path on the agents' Mac (`[the notes](/Users/…/notes.md)`) open in the viewer, not a browser.
struct FileLinks: ViewModifier {
    @Environment(\.media) private var media
    @Environment(\.lightbox) private var lightbox

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            guard url.scheme == nil || url.scheme == "file", let lightbox, media.request(for: url) != nil else { return .systemAction }
            lightbox.open(url, media: media)
            return .handled
        })
    }
}

extension View {
    func fileLinks() -> some View { modifier(FileLinks()) }
}

// MARK: The card

/// A file in a reply: its kind, name and size. Opens the viewer.
struct FileCard: View {
    let url: URL
    let request: URLRequest
    @State private var size: Int64?
    @State private var failure: String?
    @Environment(\.media) private var media
    @Environment(\.lightbox) private var lightbox

    var body: some View {
        let kind = FileKind(url.lastPathComponent)
        if let failure {
            MediaMissing(text: "\(url.lastPathComponent): \(failure)")
        } else {
            Button { lightbox?.open(url, media: media) } label: {
                HStack(spacing: 12) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Palette.amber)
                        .frame(width: 38, height: 38)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.amber.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Palette.amber.opacity(0.25)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Palette.moon)
                            .lineLimit(1).truncationMode(.middle)
                        Text([kind.label, size.map { $0.formatted(.byteCount(style: .file)) }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.lineNumber)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: 420)
                .card(radius: 14, fill: Palette.raised.opacity(0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Open \(url.lastPathComponent)")
            .contextMenu {
                Button("Open") { lightbox?.open(url, media: media) }
                Button("Download…") { saveMedia(request, name: url.lastPathComponent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: request.url) {
                // The size, and whether it's there at all, without fetching it.
                var head = request
                head.httpMethod = "HEAD"
                guard let (_, response) = try? await URLSession.shared.data(for: head), let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 404 { failure = MediaError(status: 404).localizedDescription }
                if http.expectedContentLength >= 0, (200..<300).contains(http.statusCode) { size = http.expectedContentLength }
            }
        }
    }
}

// MARK: The viewer

struct FileViewer: View {
    let file: ShownFile
    @State private var local: URL?
    @State private var shown: Shown?
    @State private var failure: String?
    @AppStorage("files.renderMarkdown") private var rendered = true
    @AppStorage("files.wrapLines") private var wrap = true
    @Environment(\.dismiss) private var dismiss

    enum Shown {
        case markdown(String)
        case code(String, [AttributedString])
        case preview
    }

    /// Larger text goes to Quick Look, which pages through it without laying it all out at once.
    private static let textLimit = 2 << 20

    var body: some View {
        let kind = FileKind(file.name)
        VStack(spacing: 0) {
            header(kind)
            Divider().overlay(Palette.border)
            Group {
                if let failure {
                    ContentUnavailableView(failure, systemImage: "doc.questionmark", description: Text(file.url.path))
                } else if let shown, let local {
                    content(shown, local: local)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.canvas)
        .environment(\.media, file.media)
        .fileLinks()
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 860, minHeight: 460, idealHeight: 760)
        #else
        .presentationDragIndicator(.visible)
        #endif
        .task(id: file.id) { await load(kind) }
    }

    private func header(_ kind: FileKind) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.moon).lineLimit(1).truncationMode(.middle)
                Text((file.url.path as NSString).deletingLastPathComponent)
                    .font(.mono(10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if case .markdown = shown {
                toggle(rendered ? "Rendered" : "Source", systemImage: rendered ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") { rendered.toggle() }
            }
            if case .code = shown {
                toggle(wrap ? "Wrap" : "No wrap", systemImage: wrap ? "text.alignleft" : "arrow.left.and.right") { wrap.toggle() }
            }
            switch shown {
            case .markdown(let text), .code(let text, _):
                CopyButton(text: text).frame(width: 30, height: 30)
            default: EmptyView()
            }
            if let local {
                #if os(macOS)
                MediaButton(systemImage: "arrow.down.to.line", help: "Download") { saveLocal(local) }
                #else
                MediaButton(systemImage: "square.and.arrow.up", help: "Save or share") { shareFile(local) }
                #endif
            }
            MediaButton(systemImage: "xmark", help: "Close (Esc)") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        #if os(iOS)
        .padding(.top, 6)
        #endif
    }

    private func toggle(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 8).frame(height: 26)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.border))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(_ shown: Shown, local: URL) -> some View {
        switch shown {
        case .markdown(let text) where rendered:
            ScrollView {
                // Relative links and images in the file resolve next to it.
                Markdown(text, baseURL: file.url.deletingLastPathComponent())
                    .markdownTheme(.agent)
                    .markdownImageProvider(.media)
                    .textSelection(.enabled)
                    .frame(maxWidth: Layout.column, alignment: .leading)
                    .padding(.horizontal, Layout.gutter).padding(.vertical, 18)
                    .frame(maxWidth: .infinity)
            }
        case .markdown(let text):
            CodeLines(lines: Syntax.highlight(text, language: nil).lines(), wrap: wrap)
        case .code(_, let lines):
            CodeLines(lines: lines, wrap: wrap)
        case .preview:
            QuickLookView(url: local)
        }
    }

    private func load(_ kind: FileKind) async {
        do {
            let local = try await downloadFile(file.request, name: file.name)
            let size = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let text = size <= Self.textLimit ? (try? Data(contentsOf: local)).flatMap(Self.text) : nil
            self.local = local
            if case .markdown = kind, let text {
                shown = .markdown(text)
            } else if let text {
                // A file of no known kind that turns out to be text (`.env.example`, `NOTES`) shows as text too.
                let language: String? = if case .code(let language) = kind { language } else { nil }
                let lines = await Task.detached { Syntax.highlight(text, language: language, limit: 400_000).lines() }.value
                shown = .code(text, lines)
            } else {
                shown = .preview
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    /// The file's text, if it is text: UTF-8 with no NUL bytes.
    private static func text(_ data: Data) -> String? {
        guard !data.prefix(8192).contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    #if os(macOS)
    private func saveLocal(_ local: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: local, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    #endif
}

/// Text a line at a time, numbered: laid out lazily, so a long file opens at once. Wrapped to the screen, or scrolling
/// sideways as written.
private struct CodeLines: View {
    let lines: [AttributedString]
    let wrap: Bool

    private static let fontSize: CGFloat = 12.5
    private static let charWidth: CGFloat = {
        let font = CTFontCreateWithName(Font.monoFamily as CFString, fontSize, nil)
        var glyph = CGGlyph()
        var zero = UniChar(48)
        CTFontGetGlyphsForCharacters(font, &zero, &glyph, 1)
        let advance = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1)
        return advance > 0 ? advance : fontSize * 0.6
    }()

    var body: some View {
        let digits = String(lines.count).count
        ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(index + 1))
                            .foregroundStyle(Palette.lineNumber)
                            .fixedSize()
                            .frame(minWidth: CGFloat(digits) * Self.charWidth, alignment: .trailing)
                        Text(lines[index].characters.isEmpty ? " " : lines[index])
                            .foregroundStyle(Palette.moon)
                            .fixedSize(horizontal: !wrap, vertical: true)
                            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                    }
                }
            }
            .font(.mono(Self.fontSize))
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Palette.sunken)
    }
}

extension AttributedString {
    /// Split at newlines, keeping each line's colours.
    func lines() -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = startIndex
        var index = startIndex
        while index < endIndex {
            if characters[index] == "\n" {
                lines.append(AttributedString(self[start..<index]))
                start = characters.index(after: index)
            }
            index = characters.index(after: index)
        }
        lines.append(AttributedString(self[start..<endIndex]))
        if lines.count > 1, lines.last?.characters.isEmpty == true { lines.removeLast() }
        return lines
    }
}

// MARK: Quick Look

#if os(macOS)
private struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }
}
#else
private struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#endif
