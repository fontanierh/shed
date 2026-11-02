#if os(macOS)
// The parts of the window that stand in for its hidden title bar.
import AppKit
import SwiftUI

/// Moves the window when dragged and acts on a double click, as a title bar does.
///
/// The window is otherwise not movable. A movable window whose content runs under its title bar works out, every time
/// any of its views moves or resizes, which of them block dragging it, walking all of them: a streaming reply grows
/// the conversation ten times a second, and that walk was a sixth of the time the window stalled for.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class DragView: NSView {
        override func viewDidMoveToWindow() {
            window?.isMovable = false
        }

        /// A title bar drags a window that isn't in front, too.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.performMiniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
                return
            }
            window.isMovable = true
            window.performDrag(with: event)
            // The window server may still be moving it: let it go once the button is up.
            Self.whenReleased { [weak window] in window?.isMovable = false }
        }

        private static func whenReleased(_ action: @escaping @MainActor () -> Void) {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                timer.invalidate()
                MainActor.assumeIsolated(action)
            }
        }
    }
}
#endif
