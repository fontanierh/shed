// On the Mac a row's details open in a panel on the right of the conversation, which stays where it is and keeps
// streaming beside it. Its left edge drags to make it wider or narrower, and it stays as wide the next time. The phone
// shows the same details in a sheet (`FeedSheetView`).
#if os(macOS)
import SwiftUI

/// What the session's panel shows. Rows read it to mark the one whose details are open, and only they redraw when it
/// changes.
@MainActor @Observable final class DetailSelection {
    var sheet: FeedSheet?
    /// How wide the session's area is, the conversation and the panel together. Only the panel reads it.
    var area: CGFloat = 0

    /// Opens `sheet`, or closes the panel when it already shows what `sheet` was opened from.
    func toggle(_ sheet: FeedSheet) {
        if let source = sheet.source, source == self.sheet?.source { self.sheet = nil } else { self.sheet = sheet }
    }
}

extension EnvironmentValues {
    /// The panel beside the conversation a view is in.
    @Entry var detailSelection: DetailSelection? = nil
}

struct DetailPanel: View {
    let sheet: FeedSheet
    let selection: DetailSelection
    let close: () -> Void
    @State private var position = ScrollPosition(edge: .top)
    @State private var offset: CGFloat = 0
    /// The width it was last left at.
    @AppStorage("detail.width") private var stored = Double(DetailPanel.standard)
    /// While its edge is dragged: the width the drag started from, and the width it is at.
    @State private var dragged: (from: CGFloat, to: CGFloat)?
    @State private var overEdge = false

    /// Wide enough for a diff or a command's output.
    static let standard: CGFloat = 460
    static let narrowest: CGFloat = 320
    /// What the conversation keeps beside it, however far the edge is dragged.
    static let conversation: CGFloat = 380

    private var width: CGFloat { fit(dragged?.to ?? CGFloat(stored)) }

    /// A width the panel can have: the window may have narrowed since it was chosen.
    private func fit(_ width: CGFloat) -> CGFloat {
        min(max(width, Self.narrowest), max(Self.narrowest, selection.area - Self.conversation))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                sheet.content()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .coordinateSpace(.named(KeepInView.space))
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, new in offset = new }
            // A step folded away from above the top of the panel comes back to the top, not somewhere further down.
            .environment(\.keepInView, KeepInView { top in
                if top < offset { position.scrollTo(y: max(0, top - 12)) }
            })
            // Each row's details start at their top.
            .id(sheet.id)
        }
        .frame(width: width)
        .background {
            // Glass like the header's, darker: the beam runs behind it, and text has to read over it.
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Palette.canvas.opacity(0.8))
                .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            // Lit while the edge is under the pointer or being dragged.
            let held = overEdge || dragged != nil
            (held ? Palette.accent.opacity(0.8) : Palette.border.mix(with: .white, by: 0.08, in: .perceptual))
                .frame(width: held ? 2 : 1).ignoresSafeArea()
                .animation(.easeOut(duration: 0.15), value: held)
        }
        .overlay(alignment: .leading) { edge.ignoresSafeArea() }
    }

    /// The edge to drag: a strip inside the panel's left edge, so the conversation's own edge stays its own.
    private var edge: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { overEdge = $0 }
            .gesture(
                // Measured in the window: the edge moves under the pointer as it is dragged.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let from = dragged?.from ?? width
                        dragged = (from, fit(from - drag.translation.width))
                    }
                    .onEnded { _ in
                        if let dragged { stored = Double(dragged.to.rounded()) }
                        dragged = nil
                    }
            )
            .onTapGesture(count: 2) { stored = Double(Self.standard) }
            .help("Drag to resize, double-click to reset")
            .accessibilityElement()
            .accessibilityLabel("Details width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                stored = Double(fit(width + (direction == .increment ? 40 : -40)))
            }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(sheet.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.moon)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.moon.opacity(0.8))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (esc)")
            .accessibilityLabel("Close details")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        // The session header's height, so the two read as one bar.
        .frame(height: 52)
        .background { WindowDragArea().ignoresSafeArea(edges: .top) }
        .overlay(alignment: .bottom) {
            Palette.border.mix(with: .white, by: 0.08, in: .perceptual).frame(height: 1)
        }
    }
}
#endif
