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
    @ViewBuilder let content: Content

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
            if isActive {
                PinstripeBackground()
            } else {
                Color.white
            }
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
/// its "gotcha" feedback.
private struct CloseBoxButtonStyle: ButtonStyle {
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

/// A small X drawn inside the close box, classic Mac close-button style.
private struct CloseBoxX: Shape {
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

/// Thin alternating horizontal bands, the classic Mac OS title-bar texture.
private struct PinstripeBackground: View {
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
