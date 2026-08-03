import SwiftUI

/// Drop-in replacement for `ScrollView { content }` that draws a period-accurate System 7
/// vertical scrollbar (dithered track, dithered blue thumb, arrow buttons) alongside the
/// content instead of the modern floating indicator. No horizontal bar -- nothing in this app
/// ever scrolls horizontally, so it would be pure dead weight. Reading live scroll position
/// uses `onScrollGeometryChange` (macOS 15+); driving the ScrollView from the thumb's drag
/// gesture or the arrow buttons uses `ScrollPosition.scrollTo(y:)` -- both confirmed against
/// the actual SDK interface, since the exact method names aren't reliably documented anywhere
/// else yet.
///
/// The look here was checked directly against a real System 7.5.3 window rendered by the
/// Infinite Mac emulator in this app's own Emulator tab -- the thumb and arrows turned out to
/// use the *same* checkerboard dither as the track, just tinted blue instead of gray/black, and
/// (like the window frame itself) everything is sharp-cornered -- no rounding anywhere.
struct ClassicScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var offsetY: CGFloat = 0
    @State private var scrollPosition = ScrollPosition()

    private let barThickness: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                content
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, newValue in
                contentHeight = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.containerSize.height
            } action: { _, newValue in
                viewportHeight = newValue
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, newValue in
                offsetY = newValue
            }

            ClassicVerticalScrollBar(
                contentHeight: contentHeight,
                viewportHeight: viewportHeight,
                offsetY: offsetY,
                scrollPosition: $scrollPosition
            )
            .frame(width: barThickness)
        }
    }
}

private struct ClassicVerticalScrollBar: View {
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let offsetY: CGFloat
    @Binding var scrollPosition: ScrollPosition

    private let arrowSize: CGFloat = 15
    /// How far one arrow-button click nudges the content.
    private let nudge: CGFloat = 28

    private var scrollableDistance: CGFloat { max(contentHeight - viewportHeight, 1) }

    private func scroll(to y: CGFloat) {
        scrollPosition.scrollTo(y: min(max(y, 0), scrollableDistance))
    }

    // The original Mac scrollbar thumb was a fixed size regardless of window/content length --
    // it didn't stretch to represent the visible fraction the way modern scrollbars do.
    private let thumbHeight: CGFloat = 22

    // Frozen the moment a drag starts, so the thumb tracks the pointer 1:1 -- computing the
    // drag target from the *live* thumbY (which itself moves every time `scroll(to:)` runs)
    // compounded every frame, so the thumb ran away from the pointer instead of following it.
    @State private var dragStartOffsetY: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let trackHeight = max(geo.size.height - arrowSize * 2, 0)
            let needsScrolling = contentHeight > viewportHeight + 1
            let maxThumbTravel = max(trackHeight - thumbHeight, 0)
            let scrollFraction = min(1, max(0, offsetY / scrollableDistance))
            let thumbY = maxThumbTravel * scrollFraction

            VStack(spacing: 0) {
                ScrollArrowButton(rotation: .degrees(0)) { scroll(to: offsetY - nudge) }
                    .frame(width: geo.size.width, height: arrowSize)

                ZStack(alignment: .top) {
                    DitheredPattern()
                        .onTapGesture { location in
                            // Click above/below the thumb to page by a full viewport, like
                            // clicking a classic Mac scrollbar track.
                            let page = viewportHeight > 0 ? viewportHeight : 100
                            scroll(to: offsetY + (location.y < thumbY ? -page : page))
                        }
                    if needsScrolling {
                        ThumbTexture()
                            .overlay(Rectangle().stroke(ScrollAccent.dark, lineWidth: 2))
                            .frame(height: thumbHeight)
                            .offset(y: thumbY)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard maxThumbTravel > 0 else { return }
                                        let startY = dragStartOffsetY ?? offsetY
                                        if dragStartOffsetY == nil { dragStartOffsetY = startY }
                                        let startThumbY = (min(1, max(0, startY / scrollableDistance))) * maxThumbTravel
                                        let draggedFraction = (startThumbY + value.translation.height) / maxThumbTravel
                                        scroll(to: min(max(draggedFraction, 0), 1) * scrollableDistance)
                                    }
                                    .onEnded { _ in
                                        dragStartOffsetY = nil
                                    }
                            )
                    }
                }
                .frame(height: trackHeight)
                .clipped()

                ScrollArrowButton(rotation: .degrees(180)) { scroll(to: offsetY + nudge) }
                    .frame(width: geo.size.width, height: arrowSize)
            }
        }
    }
}

/// The periwinkle/indigo tint classic Mac OS used for an active scrollbar's thumb and arrows --
/// lighter and more pastel than earlier passes assumed. `light` is the fill/ridge tone, `dark`
/// the edge/border tone.
private enum ScrollAccent {
    static let light = Color(red: 0.64, green: 0.64, blue: 0.90)
    static let dark = Color(red: 0.30, green: 0.27, blue: 0.62)
}

/// The thumb's real construction, per a high-resolution close-up of a real System 7 scrollbar:
/// a bold indigo border, then a plain gray margin, then an inset lavender panel with a few
/// horizontal ridge lines -- not full-bleed stripes edge to edge, and not the track's
/// checkerboard dither.
private struct ThumbTexture: View {
    var body: some View {
        ZStack {
            Color(white: 0.78)
            RidgedStripes()
                .padding(3)
        }
    }
}

private struct RidgedStripes: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ScrollAccent.light))
            var path = Path()
            let stripeHeight: CGFloat = 2
            let gap: CGFloat = 2
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: stripeHeight))
                y += stripeHeight + gap
            }
            context.fill(path, with: .color(ScrollAccent.dark))
        }
    }
}

/// The 1-bit checkerboard dither classic Mac OS textured its scrollbars with -- a true
/// 50%-density checker (not a sparse stipple) at a 2pt cell size, matching how a 1-bit pattern
/// reads when doubled for a modern display. `background`/`tint` let the same pattern serve
/// both the gray track and the blue thumb/arrows, which turned out to share one dither engine
/// just recolored, per a real System 7.5.3 window rendered in this app's own Emulator tab.
/// Built as one filled Path (not one fill call per cell) so it stays cheap to draw.
private struct DitheredPattern: View {
    var background: Color = .white
    var tint: Color = .black.opacity(0.4)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))
            var path = Path()
            let cell: CGFloat = 2
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + col) % 2 == 0 {
                        path.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
            context.fill(path, with: .color(tint))
        }
        .contentShape(Rectangle())
    }
}

private struct ScrollArrowButton: View {
    let rotation: Angle
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Rectangle().fill(Color.white)
                Rectangle().stroke(Color.black.opacity(0.55), lineWidth: 1)
                PixelArrowGlyph()
                    .frame(width: 9, height: 10)
                    .rotationEffect(rotation)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The arrow authored as a coarse pixel grid rather than a smooth vector `Shape` -- a real
/// System 7 close-up shows the flared arrowhead's diagonal edges as a genuine staircase of
/// dots, not an anti-aliased line, because it really was a small bitmap sprite. Edge cells
/// (anything touching an "off" neighbor) get the darker outline tone; fully-surrounded cells
/// get the lighter fill tone, matching the two-tone look in that close-up.
private struct PixelArrowGlyph: View {
    private static let grid: [[Bool]] = [
        [false, false, false, false, true, false, false, false, false],
        [false, false, false, true, true, true, false, false, false],
        [false, false, true, true, true, true, true, false, false],
        [false, true, true, true, true, true, true, true, false],
        [true, true, true, true, true, true, true, true, true],
        [false, false, false, true, true, true, false, false, false],
        [false, false, false, true, true, true, false, false, false],
        [false, false, false, true, true, true, false, false, false],
        [false, false, false, true, true, true, false, false, false],
        [false, false, false, true, true, true, false, false, false],
    ]

    var body: some View {
        Canvas { context, size in
            let rows = Self.grid.count
            let cols = Self.grid[0].count
            let cellWidth = size.width / CGFloat(cols)
            let cellHeight = size.height / CGFloat(rows)

            var fillPath = Path()
            var edgePath = Path()

            for row in 0..<rows {
                for col in 0..<cols where Self.grid[row][col] {
                    let rect = CGRect(
                        x: CGFloat(col) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    )
                    if isOn(row - 1, col) && isOn(row + 1, col) && isOn(row, col - 1) && isOn(row, col + 1) {
                        fillPath.addRect(rect)
                    } else {
                        edgePath.addRect(rect)
                    }
                }
            }
            context.fill(fillPath, with: .color(ScrollAccent.light))
            context.fill(edgePath, with: .color(ScrollAccent.dark))
        }
    }

    private func isOn(_ row: Int, _ col: Int) -> Bool {
        guard row >= 0, row < Self.grid.count, col >= 0, col < Self.grid[0].count else { return false }
        return Self.grid[row][col]
    }
}
