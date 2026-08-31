import SwiftUI

/// A decorative panel styled like a classic System 7 Finder window -- pinstripe title bar
/// with a close box and centered title tab, an optional status line, and a plain content
/// area below. Not a real window, just skeuomorphic chrome drawn inside the app's own
/// content area -- but the close box is wired up when `onClose` is provided, and `isActive`
/// swaps the title bar between pinstriped and plain to mimic how classic Mac OS visibly
/// dimmed a window's title bar the moment it lost focus to one in front of it.
struct FinderWindowChrome<Content: View>: View {
    let title: String
    var statusText: String?
    var isActive: Bool = true
    var onClose: (() -> Void)?
    /// Caller-owned, persisted drag position -- when set, dragging the title bar (real Mac
    /// OS windows only drag by their title bar, not by clicking anywhere in the content)
    /// updates this binding live as the gesture moves and leaves it there on release, so the
    /// next drag continues accumulating from wherever the window currently sits rather than
    /// resetting. nil (the default) leaves the window fixed in place, matching every caller
    /// that doesn't opt in (only Museum's cascaded category/product windows do -- the ones
    /// that can end up positioned off the bottom of a smaller window, per user feedback,
    /// where dragging is the fix rather than chasing an exact size cap that fits every
    /// window size). Deliberately caller-owned rather than internal @State: the resulting
    /// offset has to be applied at the SAME level as the cascade's own base offset, outside
    /// any `.overlay` a caller uses to attach a further-nested cascade window -- an offset
    /// applied only internally here wouldn't be visible to that overlay's layout math, so a
    /// dragged window's cascaded child would open from its old, undragged position instead
    /// of following it.
    var dragOffset: Binding<CGSize>?
    /// The lowest (most negative) `dragOffset` the caller will accept, per axis -- keeps this
    /// window's title bar (its only drag handle, close box included) from being draggable
    /// above/left of the visible content area. nil means unclamped. Applied INSIDE the drag
    /// gesture itself, not as a correction the caller applies afterward from a geometry
    /// reading: an earlier version tried exactly that (re-clamping `dragOffset` reactively
    /// once the caller's `onGeometryChange` saw an out-of-bounds frame), and it silently did
    /// nothing during an actual drag -- `titleBarDragGesture`'s own `onChanged` recomputes
    /// `dragOffset.wrappedValue` from `dragGestureStartOffset + value.translation` on every
    /// tick, unconditionally overwriting whatever the caller had just corrected it to a
    /// moment earlier.
    ///
    /// A `Binding`, not a plain `CGSize?` value -- a plain value is captured fresh each time
    /// this struct is reconstructed, but confirmed live that a reconstruction driven by
    /// `dragOffset` changing mid-gesture doesn't reliably make `titleBarDragGesture`'s
    /// already-in-flight `.onChanged` closure see the new value (dragging the title bar
    /// toward the top of the app still rendered it with no visible title bar or close box at
    /// all, exactly as the user reported, even after adding the plain-value clamp). Routing
    /// through the caller's own `Binding` getter -- the same mechanism `dragOffset` above
    /// already relies on successfully -- reads the caller's live @State on every access
    /// instead of a frozen snapshot, but the REAL bug turned out to be one level deeper than
    /// that: the caller derives this floor as `dragOffset - measuredFrame` (the window's
    /// static, non-drag base position, isolated out algebraically), and `measuredFrame` is
    /// only ever updated asynchronously via `onGeometryChange`, one render behind `dragOffset`
    /// itself during a fast, continuous drag -- so the two values being subtracted are never
    /// actually from the same instant, and the "floor" drifts further permissive (more
    /// negative) the longer a single drag continues, chasing but never reaching the true
    /// boundary. Confirmed live with a temporary debug overlay: dragging steadily upward,
    /// the reported floor kept sliding down in lockstep with the drag instead of staying
    /// fixed. Worked around below by reading this Binding's getter only ONCE, at the start of
    /// each drag gesture -- correct, not just a workaround: the floor is a static property of
    /// "where this window sits with zero drag," which genuinely can't change mid-gesture, so
    /// there's nothing to re-derive after that first read.
    var minDragOffset: Binding<CGSize>?
    @ViewBuilder let content: Content

    // True only for the duration of one continuous drag gesture -- lets titleBarDragGesture
    // capture `dragOffset`'s (and, see minDragOffset's doc comment, `minDragOffset`'s) value
    // exactly once per gesture (its value *before* this drag's own translation is added),
    // rather than on every `.onChanged` tick. Local @State, not shared with the caller --
    // purely this view's own bookkeeping for one drag session.
    @State private var isDragging = false
    @State private var dragGestureStartOffset: CGSize = .zero
    @State private var dragGestureFloor: CGSize?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(Color.black).frame(height: 1)
            if let statusText {
                HStack {
                    Text(statusText)
                        .font(.chicago(11))
                        .foregroundStyle(.black)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white)
                Rectangle().fill(Color.black.opacity(0.3)).frame(height: 1)
            }
            content
                .background(Color.white)
        }
        // Sharp square corners and no drop shadow -- a real System 7 window sits flat on the
        // desktop with a plain black outline, not a soft floating card. Rounding + shadow was
        // the single biggest thing making this read as a modern panel instead of the real
        // thing.
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1.5))
        // Pinned to light regardless of the app-level scheme (which now flips to dark for the
        // Space Gray desktop theme, for the native title bar's sake -- see RootTabView). This
        // window's own content is always a white/cream card either way, so anything inside
        // using semantic colors (.primary, .secondary) needs to keep resolving against a light
        // background, not follow the desktop out into dark mode and turn illegible-on-white.
        .preferredColorScheme(.light)
    }

    private var titleBar: some View {
        ZStack {
            // Both layers always present, cross-fading via opacity -- not an `if/else`
            // swapping which one exists. `isActive` here is a derived value (e.g.
            // `openProduct == nil` in the Museum cascade) that flips as a side effect of
            // some OTHER state change already wrapped in `withAnimation` elsewhere (closing
            // a cascaded window). An `if/else` conditional-content swap doesn't pick up that
            // ambient animation at all -- SwiftUI just swaps the two branches instantly,
            // which read as the title bar flickering/snapping mid-transition while the
            // window on top of it was still visibly animating. A plain `.opacity()` change,
            // by contrast, *is* an animatable property, so it smoothly interpolates along
            // with whatever animation is already in effect when `isActive` changes.
            Color.white
            PinstripeBackground()
                .opacity(isActive ? 1 : 0)
            HStack(spacing: 0) {
                closeBox
                    .padding(.leading, 8)
                Spacer(minLength: 8)
                titleTab
                Spacer(minLength: 8)
                zoomBox
                    .padding(.trailing, 8)
            }
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        // .simultaneousGesture, not .gesture -- this ZStack also contains the closeBox and
        // zoomBox Buttons, and a plain .gesture() here competes exclusively with their own
        // tap recognizers for the same touch. On real mouse/trackpad input a click routinely
        // carries a point or two of incidental pointer drift, which is enough to satisfy
        // this gesture's `minimumDistance: 2` -- if the drag gesture wins that exclusivity
        // race, the close box's own tap never fires and the window fails to close on that
        // click, on every FinderWindowChrome in the app (Trivia, Search, Glossary, not just
        // Museum's draggable windows), regardless of whether dragOffset is even set.
        // .simultaneousGesture lets both recognizers evaluate independently instead of
        // picking one exclusive winner, so the button's own tap still fires normally.
        .simultaneousGesture(titleBarDragGesture)
    }

    /// Always attached, even when `dragOffset` is nil -- harmless no-op then (the closures
    /// just have nothing to write to), and keeping one unconditional gesture avoids the
    /// type-erasure gymnastics of conditionally attaching a `Gesture` in SwiftUI.
    /// `minimumDistance: 2` (not the default 10) so a real drag starts responding quickly
    /// without being so sensitive that an ordinary click-to-select on this title bar
    /// misfires as a drag.
    ///
    /// `coordinateSpace: .global`, not the default `.local` -- this is the actual window
    /// being dragged, and its translation feeds straight back into an `.offset()` applied to
    /// an ANCESTOR of this title bar (the caller's whole window, so the cascade offset moves
    /// with it). With the default `.local` coordinate space, `DragGesture.translation` is
    /// measured relative to this title bar's OWN current rendered position -- which is
    /// itself shifting every frame because of the very offset this gesture is driving,
    /// turning what should be a stable 1:1 mapping into a feedback loop. Confirmed live:
    /// jitter, and the pointer visibly drifting away from the title bar the longer a drag
    /// continued. `.global` measures against a fixed screen-space reference instead, so the
    /// reported translation always matches real mouse movement regardless of how far the
    /// window (and this title bar) has already moved.
    private var titleBarDragGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                guard let dragOffset else { return }
                if !isDragging {
                    isDragging = true
                    dragGestureStartOffset = dragOffset.wrappedValue
                    // Read once, here, not on every tick below -- see minDragOffset's own
                    // doc comment for why re-reading it live mid-drag doesn't work.
                    dragGestureFloor = minDragOffset?.wrappedValue
                }
                var newOffset = CGSize(
                    width: dragGestureStartOffset.width + value.translation.width,
                    height: dragGestureStartOffset.height + value.translation.height
                )
                if let floor = dragGestureFloor {
                    newOffset.width = max(newOffset.width, floor.width)
                    newOffset.height = max(newOffset.height, floor.height)
                }
                // Skip the write entirely once the drag is pinned at the floor and the
                // mouse keeps moving past it -- every further .onChanged tick was
                // recomputing the exact same clamped value and writing it to `dragOffset`
                // again regardless, spamming identical state writes (and the resulting
                // re-layout of this whole window) dozens of times a second for as long as
                // the drag continued past the wall. Reported by the user with screenshots:
                // held at the top boundary, the window's content visibly duplicated/ghosted
                // (an extra divider line, cropped-looking icons) -- consistent with that
                // rapid, redundant-write thrashing, not with the clamp math itself (which
                // was already correct, per the earlier verified fix).
                guard newOffset != dragOffset.wrappedValue else { return }
                dragOffset.wrappedValue = newOffset
            }
            .onEnded { _ in isDragging = false }
    }

    @ViewBuilder
    private var closeBox: some View {
        let box = ZStack {
            Rectangle()
                .fill(Color.white)
            Rectangle()
                .stroke(Color.black, lineWidth: 1.2)
        }
        .frame(width: 11, height: 11)

        if let onClose {
            Button(action: onClose) { box }
                .buttonStyle(CloseBoxButtonStyle())
                // The shape alone (a bare square, per CloseBoxButtonStyle's own doc comment)
                // gives VoiceOver nothing to announce -- confirmed via grep that this whole
                // module had zero accessibility labels anywhere.
                .accessibilityLabel("Close \(title)")
        } else {
            box
        }
    }

    /// Purely decorative, matching the real thing -- classic Mac windows had a zoom box
    /// mirroring the close box. Unlike the close box, its background/border/glyph use the same
    /// blue/lavender accent as the scrollbar's thumb and arrows rather than plain black and
    /// white -- confirmed against a close-up of a real window's title bar.
    private var zoomBox: some View {
        ZStack {
            Rectangle().fill(FinderAccent.light)
            Rectangle().stroke(FinderAccent.dark, lineWidth: 1.2)
            CascadeGlyph()
        }
        .frame(width: 11, height: 11)
    }

    private var titleTab: some View {
        Text(title)
            .font(.chicago(13))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .background(Color.white)
    }
}

/// Draws the X inside the close box only while the mouse is actually held down on it --
/// a real System 7 close box is a bare square until clicked, which is what gives the click
/// its "gotcha" feedback. Internal, not private -- also reused by QuickTimePlayerChrome.swift
/// for its own close box, so the interaction can't diverge between the two window styles.
struct CloseBoxButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                if configuration.isPressed {
                    CloseBoxX()
                        .stroke(Color.black, lineWidth: 1.1)
                        .padding(3)
                }
            }
    }
}

/// A small X drawn inside the close box, classic Mac close-button style. Internal, not
/// private -- reused by QuickTimePlayerChrome.swift alongside CloseBoxButtonStyle above.
struct CloseBoxX: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}

/// The periwinkle/indigo accent classic Mac OS used for the zoom box (and matches the
/// scrollbar's thumb/arrows in ClassicScrollBar.swift -- kept as its own copy here since the
/// two files don't share a common module-visible palette yet).
enum FinderAccent {
    static let light = Color(red: 0.82, green: 0.82, blue: 0.90)
    static let dark = Color(red: 0.30, green: 0.27, blue: 0.62)
}

/// The "cascading rectangles" glyph classic Mac OS used for the zoom box -- a smaller
/// lighter-filled, bordered square up front at the top-leading corner, with a larger square
/// outline (the "zoomed" target size) behind it at the bottom-trailing corner.
struct CascadeGlyph: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(FinderAccent.dark, lineWidth: 1)
                .frame(width: 7, height: 7)
                .offset(x: 4, y: 4)
            Rectangle()
                .fill(FinderAccent.light)
                .overlay(Rectangle().stroke(FinderAccent.dark, lineWidth: 1))
                .frame(width: 6, height: 6)
        }
        .frame(width: 11, height: 11, alignment: .topLeading)
    }
}

/// Thin alternating horizontal bands, the classic Mac OS title-bar texture. Internal, not
/// private -- reused by QuickTimePlayerChrome.swift's own title bar (fills whatever size
/// it's given, so it works unchanged at that component's different title-bar height).
struct PinstripeBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(Color.black.opacity(0.22)))
                y += 2
            }
        }
    }
}
