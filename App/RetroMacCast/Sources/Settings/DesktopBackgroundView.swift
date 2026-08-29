import SwiftUI

/// How a `DesktopTheme` actually paints the app's full-screen backdrop. Every theme in
/// `DesktopTheme.all` is either the real historical Mac 128K 1-bit checker (`.dithered`) or a
/// real bundled tile image (`.tiledImage`) -- see `DesktopTheme`'s own doc comment. Earlier
/// revisions of this enum also had procedurally-drawn `.flat`/`.woven`/`.radialGlow`/
/// `.brushed`/`.speckled` cases for a fabricated-pattern design that was later replaced
/// wholesale with real historical/user-supplied imagery (per the session that built this);
/// nothing ever constructs those anymore, so they (and their Canvas renderers) were removed
/// rather than left as dead code.
enum DesktopBackgroundStyle {
    /// An 8x8 1-bit pattern tiled edge-to-edge with hard, unblurred edges -- matching how the
    /// real System 1-6 Desktop Patterns control panel rendered its `PAT ` resources. `mask`'s
    /// bit layout is one row per byte, MSB-first, top row first.
    case dithered(fg: Color, bg: Color, mask: UInt64)
    /// Tiles a real bundled image (an Assets.xcassets imageset name) edge-to-edge at its
    /// native size, unscaled -- for a user-supplied tile image rather than a procedurally-
    /// drawn one, e.g. System 7's "Flying Cats" pattern.
    case tiledImage(name: String)
}

/// Renders any `DesktopBackgroundStyle` -- shared by both the app's real full-screen
/// backgrounds (every tab) and the small swatch preview in Settings, so the picker always
/// shows exactly what you'll actually get.
struct DesktopBackgroundView: View {
    let theme: DesktopTheme

    var body: some View {
        switch theme.background {
        case .dithered(let fg, let bg, let mask):
            DitheredMaskCanvas(fg: fg, bg: bg, mask: mask)
        case .tiledImage(let name):
            // .tile repeats the image at its own native pixel size rather than stretching to
            // fill -- exactly the seamless-repeat behavior real ppat-resource tiling used.
            // .interpolation(.none) keeps every tile's edges crisp or so, matching the sharp,
            // unblurred pixel look this app uses everywhere else (Chicago font, hand-drawn
            // glyphs) rather than a smoothed/blurred repeat.
            Image(name)
                .resizable(resizingMode: .tile)
                .interpolation(.none)
        }
    }
}

/// Tiles an 8x8 1-bit mask edge-to-edge -- see `DesktopBackgroundStyle.dithered`'s doc comment
/// for the bit layout. `cell` is larger than `DitheredPattern`'s 2pt (built for a thin
/// scrollbar track) since an 8x8 motif needs more room to actually read as a pattern rather
/// than noise when tiled across a full window.
private struct DitheredMaskCanvas: View {
    let fg: Color
    let bg: Color
    let mask: UInt64
    private let cell: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            var path = Path()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                let bitRow = row % 8
                let rowByte = UInt8((mask >> ((7 - bitRow) * 8)) & 0xFF)
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    let bitCol = col % 8
                    if (rowByte >> (7 - bitCol)) & 0x01 == 1 {
                        path.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
            context.fill(path, with: .color(fg))
        }
    }
}
