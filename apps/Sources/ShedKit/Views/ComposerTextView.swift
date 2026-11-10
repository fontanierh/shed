#if os(macOS)
// The Mac composer's text. SwiftUI's vertical TextField re-measures and resets its whole text on every keystroke, so
// typing slows down as a long draft grows; an NSTextView lays out only what changes.
import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var maxLines = 10
    /// Return without Shift or Option.
    let submit: () -> Void
    /// Files dropped or pasted on the text, which would otherwise go in as their paths.
    let files: (PasteboardFiles) -> Void

    static let font = NSFont.systemFont(ofSize: 14.5)
    static let lineSpacing: CGFloat = 3
    /// Narrower than any character at this size, so a draft longer than ten lines of these surely fills ten.
    private static let narrowestGlyph: CGFloat = 2.5

    private static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font) + lineSpacing
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 with non-contiguous layout lays out only the lines on screen, even inside one long paragraph, where
        // TextKit 2 would lay out the whole paragraph on every keystroke.
        let textView = FileTextView(usingTextLayoutManager: false)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = NSColor(Palette.moon)
        textView.insertionPointColor = NSColor(Palette.moon)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.lineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor(Palette.moon), .paragraphStyle: paragraph]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Sized as `NSTextView.scrollableTextView()` sizes its text view: as wide as the scroll view and as tall as its
        // text. A larger limit than AppKit's own overflows the layout constraints and loops the window's layout.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 0, height: 10_000_000)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(width: 0, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Message")
        textView.string = text

        let scroll = FittedScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Only a change made outside the view (sent, restored, another session's draft) replaces its text.
        if text != context.coordinator.reported {
            textView.string = text
            context.coordinator.reported = text
            context.coordinator.version += 1
            textView.undoManager?.removeAllActions()
        }
        if focused, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        // An unbounded width is SwiftUI asking for an ideal size: answering it would size the text view, and the window, to infinity.
        guard let textView = context.coordinator.textView, let width = proposal.width, width > 0, width.isFinite else { return nil }
        let coordinator = context.coordinator
        if let measured = coordinator.measured, measured.width == width, measured.version == coordinator.version {
            return CGSize(width: width, height: measured.height)
        }
        let cap = Self.lineHeight * CGFloat(maxLines)
        var height = Self.lineHeight
        // More characters than ten lines could hold even at the narrowest glyphs: it's at the cap, and measuring would
        // lay out the whole paragraph being typed in.
        let length = textView.textStorage?.length ?? 0
        if CGFloat(length) * Self.narrowestGlyph >= width * CGFloat(maxLines) {
            height = cap
        } else if let layout = textView.layoutManager, let container = textView.textContainer {
            // Short enough to lay out whole, at the width asked about; then back to the width it has on screen.
            let shown = textView.frame.width
            textView.frame.size.width = width
            layout.ensureLayout(for: container)
            height = max(height, layout.usedRect(for: container).height)
            if scroll.contentSize.width > 0 { textView.frame.size.width = scroll.contentSize.width } else { textView.frame.size.width = shown }
        }
        height = min(height, cap)
        coordinator.measured = (width, coordinator.version, height)
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?
        /// The text last handed to SwiftUI, so its echo back is not set again.
        var reported: String
        /// Bumped whenever the text changes, so a measured height is reused until then.
        var version = 0
        var measured: (width: CGFloat, version: Int, height: CGFloat)?

        init(_ parent: ComposerTextView) {
            self.parent = parent
            self.reported = parent.text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            reported = textView.string
            version += 1
            parent.text = reported
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                parent.submit()
            }
            return true
        }

        func focusChanged(_ focused: Bool) {
            if parent.focused != focused { parent.focused = focused }
        }
    }

    /// Keeps its text exactly as wide as what it shows. Autoresizing would only carry a width SwiftUI measured with
    /// over to every later size, and the text would run under the edge.
    final class FittedScrollView: NSScrollView {
        override func tile() {
            super.tile()
            if let text = documentView, text.frame.width != contentSize.width { text.frame.size.width = contentSize.width }
        }
    }

    /// Reports focus, and hands files to the composer instead of pasting their paths.
    final class FileTextView: NSTextView {
        weak var coordinator: Coordinator?

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { coordinator?.focusChanged(true) }
            return became
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.focusChanged(false) }
            return resigned
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.hasFiles ? .copy : super.draggingEntered(sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            sender.draggingPasteboard.hasFiles ? .copy : super.draggingUpdated(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let files = sender.draggingPasteboard.files
            guard !files.isEmpty else { return super.performDragOperation(sender) }
            coordinator?.parent.files(files)
            return true
        }

        override func paste(_ sender: Any?) {
            let files = NSPasteboard.general.files
            guard !files.isEmpty else { return super.paste(sender) }
            coordinator?.parent.files(files)
        }
    }
}
#endif
