#if os(macOS)
// Files dropped or pasted onto the text being typed. AppKit hands a drop to the deepest view that takes its type, and
// the text field's editor takes files, so a file dropped on the composer's text would only paste its path. This
// editor hands files to the composer instead, which attaches them.
import AppKit
import SwiftUI

extension Notification.Name {
    /// Files dropped or pasted onto the text being edited: `object` is the window, `userInfo["files"]` the files.
    static let filesOnText = Notification.Name("filesOnText")
}

/// Files read off a pasteboard: on disk, or image data with no file behind it.
struct PasteboardFiles: @unchecked Sendable {
    var urls: [URL] = []
    var images: [(name: String, data: Data)] = []

    var isEmpty: Bool { urls.isEmpty && images.isEmpty }

    /// The files' names and contents, read off the main thread.
    func load() async -> [(name: String, data: Data)] {
        let urls = urls
        let read = await Task.detached {
            urls.compactMap { url -> (name: String, data: Data)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                      let data = try? Data(contentsOf: url) else { return nil }
                return (url.lastPathComponent, data)
            }
        }.value
        return read + images
    }
}

extension NSPasteboard {
    /// Its files and images, or nothing for plain text (a copied path stays text).
    var files: PasteboardFiles {
        var files = PasteboardFiles()
        files.urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.urls.isEmpty, availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: self), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            files.images = [("Image.png", png)]
        }
        return files
    }
}

/// The window's field editor: as AppKit's, except that files dropped or pasted on it go to the composer.
final class FileDropFieldEditor: NSTextView {
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isFieldEditor = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isFieldEditor = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.files.isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.files.isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = sender.draggingPasteboard.files
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        hand(files)
        return true
    }

    override func paste(_ sender: Any?) {
        let files = NSPasteboard.general.files
        guard !files.isEmpty else { return super.paste(sender) }
        hand(files)
    }

    private func hand(_ files: PasteboardFiles) {
        NotificationCenter.default.post(name: .filesOnText, object: window, userInfo: ["files": files])
    }
}

/// Makes `FileDropFieldEditor` the field editor of the window it's in, for its text fields.
struct FileDropFieldEditorInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class InstallerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            guard let window, !(window.delegate is FieldEditorDelegate) else { return }
            // In front of SwiftUI's own delegate, which gets everything else; kept as long as the window.
            let delegate = FieldEditorDelegate(original: window.delegate)
            objc_setAssociatedObject(window, &FieldEditorDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            window.delegate = delegate
        }
    }
}

@MainActor
private final class FieldEditorDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var key = 0
    weak var original: (any NSWindowDelegate)?
    private lazy var editor = FileDropFieldEditor(frame: .zero)

    init(original: (any NSWindowDelegate)?) {
        self.original = original
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? editor : original?.windowWillReturnFieldEditor?(sender, to: client)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
#endif
