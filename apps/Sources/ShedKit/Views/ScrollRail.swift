// A moonlit rail on the transcript's edge: where you are in the conversation, and a handle to travel through it.
import SwiftUI

/// The scroll metrics the rail draws from. A reference type so that scrolling redraws only the rail, never the transcript.
@Observable
final class ScrollMetrics {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var container: CGFloat = 0
    /// Bumped on every scroll so the rail can brighten and then rest.
    var moved = 0
    /// Until when the transcript is easing to its end along with the keyboard. No view reads it.
    var easingUntil = Date.distantPast
    /// Until when the keyboard is sliding in or out, so the transcript's size changes are its doing.
    var keyboardUntil = Date.distantPast

    var scrollable: Bool { content > container + 1 }
    var visible: CGFloat { scrollable ? container / content : 1 }
    var progress: CGFloat { scrollable ? min(max(offset / (content - container), 0), 1) : 0 }
}

struct ScrollRail: View {
    let metrics: ScrollMetrics
    /// Scrolls to an absolute content offset.
    let scrollTo: (CGFloat) -> Void

    @State private var awake = false
    @State private var hovering = false
    @State private var dragging = false
    @State private var dragStart: CGFloat = 0

    private var active: Bool { awake || hovering || dragging }

    var body: some View {
        GeometryReader { proxy in
            let track = proxy.size.height
            let thumb = max(36, track * metrics.visible)
            let y = (track - thumb) * metrics.progress
            ZStack(alignment: .top) {
                // The rail itself: a faint thread, lit a little more toward the thumb.
                Capsule()
                    .fill(LinearGradient(colors: [Palette.rail.opacity(0.05), Palette.rail.opacity(0.7), Palette.rail.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)

                // The thumb: a sliver of moonlight with a firefly at its heart.
                Capsule()
                    .fill(LinearGradient(colors: [Palette.ice.opacity(0.25), Palette.moon.opacity(active ? 0.95 : 0.7), Palette.ice.opacity(0.25)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: hovering || dragging ? 5 : 3, height: thumb)
                    .overlay {
                        Circle()
                            .fill(Palette.amber)
                            .frame(width: 4, height: 4)
                            .shadow(color: Palette.amber.opacity(0.9), radius: 4)
                            .opacity(active ? 1 : 0)
                    }
                    .shadow(color: Palette.ice.opacity(active ? 0.55 : 0), radius: 6)
                    .offset(y: y)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if !dragging { dragging = true; dragStart = metrics.offset }
                                let range = track - thumb
                                guard range > 0 else { return }
                                let scale = (metrics.content - metrics.container) / range
                                scrollTo(min(max(dragStart + value.translation.height * scale, 0), metrics.content - metrics.container))
                            }
                            .onEnded { _ in dragging = false }
                    )
            }
            .frame(width: 14)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering = $0 }
            .opacity(metrics.scrollable ? (active ? 1 : 0.75) : 0)
            .animation(.easeOut(duration: 0.25), value: active)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering || dragging)
        }
        .frame(width: 14)
        .task(id: metrics.moved) {
            guard metrics.moved > 0 else { return }
            awake = true
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { awake = false }
        }
    }
}
