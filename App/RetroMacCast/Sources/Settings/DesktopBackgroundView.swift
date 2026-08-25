import SwiftUI

/// How a `DesktopTheme` actually paints the app's full-screen backdrop -- deliberately
/// original, procedurally-drawn art (gradients, dithered/woven Canvas patterns) rather than
/// real Apple desktop-picture photography, consistent with how every other piece of this app's
/// chrome is hand-drawn rather than using real Apple assets (the Chicago-style bitmap font,
/// hand-drawn glyphs, DitheredPattern, PinstripeBackground). Modeled on the three rendering
/// paradigms the user's classic_mac_wallpapers_spec.md lays out across eras -- 1-bit dither,
/// tiled pattern, smooth gradient -- adapted to this app's own background only. Deliberately
/// does NOT touch the spec's `NSWorkspace.setDesktopImageURL` real-system-wallpaper API or
/// download any remote imagery; this only ever repaints this app's own window content.
enum DesktopBackgroundStyle {
    /// A plain flat fill.
    case flat(Color)
    /// An 8x8 1-bit pattern tiled edge-to-edge with hard, unblurred edges -- matching how the
    /// real System 1-6 Desktop Patterns control panel rendered its `PAT ` resources. `mask`'s
    /// bit layout is one row per byte, MSB-first, top row first -- same convention as the
    /// spec's `ClassicPatternRenderer.create1BitPattern`.
    case dithered(fg: Color, bg: Color, mask: UInt64)
    /// A diagonal woven crosshatch -- the System 7/8 Desktop Patterns look (a fine two-tone
    /// weave), extending this app's existing pinstripe technique into two axes.
    case woven(fg: Color, bg: Color)
    /// A soft radial glow from a lighter center tone out to the theme's base color -- evokes
    /// the translucent, lit-from-within look of the late-90s colored iMac plastics and Mac OS
    /// X's Aqua glass, without recreating any specific copyrighted artwork.
    case radialGlow(center: Color, edge: Color)
    /// Fine horizontal banding at varying opacity -- a brushed-aluminum grain, for the
    /// PowerBook G4 titanium era.
    case brushed(base: Color, lineColor: Color)
    /// Scattered flecks in a mix of colors over a base tone -- Mac OS 8's real default
    /// "Granite" desktop pattern (per the spec doc: "specks of charcoal, quartz, and mid-tone
    /// grey"), which reads as organic stone speckle rather than a regular repeating motif.
    case speckled(base: Color, speckColors: [Color])
}

/// Renders any `DesktopBackgroundStyle` -- shared by both the app's real full-screen
/// backgrounds (every tab) and the small swatch preview in Settings, so the picker always
/// shows exactly what you'll actually get.
struct DesktopBackgroundView: View {
    let theme: DesktopTheme

    var body: some View {
        switch theme.background {
        case .flat(let color):
            color
        case .radialGlow(let center, let edge):
            // endRadius scales with the view's own size, not a fixed point value -- a fixed
            // 1000pt radius reads as a rich glow across a full window but was nearly invisible
            // shrunk into a 64pt Settings swatch (that radius is ~15x the swatch's own size,
            // so only its near-uniform center ever showed). Scaling relatively means the
            // swatch preview always shows the same gradient shape the real background has.
            GeometryReader { geo in
                RadialGradient(
                    colors: [center, edge], center: .center,
                    startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.75
                )
            }
        case .dithered(let fg, let bg, let mask):
            DitheredMaskCanvas(fg: fg, bg: bg, mask: mask)
        case .woven(let fg, let bg):
            WovenCanvas(fg: fg, bg: bg)
        case .brushed(let base, let lineColor):
            BrushedCanvas(base: base, lineColor: lineColor)
        case .speckled(let base, let speckColors):
            SpeckledCanvas(base: base, speckColors: speckColors)
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

/// A diagonal two-tone weave, not a plain checkerboard -- cycling through a 4-cell phase
/// (rather than DitheredPattern's 2-cell alternation) is what reads as woven fabric/plastic
/// rather than a flat checker at this larger cell size.
private struct WovenCanvas: View {
    let fg: Color
    let bg: Color
    private let cell: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(bg))
            var path = Path()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    let phase = (row + col) % 4
                    if phase == 0 || phase == 1 {
                        path.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
            context.fill(path, with: .color(fg.opacity(0.32)))
        }
    }
}

/// Fine horizontal lines at a deterministically-varying opacity -- reads as brushed-aluminum
/// grain rather than uniform ruling. `sin` of a scaled index is just a cheap, seeded way to get
/// pseudo-random-looking variation without an actual RNG (which would re-roll every redraw).
/// Scatters small flecks of `speckColors` over `base` at deterministic (not truly random,
/// same reasoning as `BrushedCanvas`) positions -- a coarse grid of candidate spots, each
/// either skipped or given a jittered, colored fleck based on a cheap hash of its own
/// coordinates, so the result looks like natural stone grain rather than a regular motif.
private struct SpeckledCanvas: View {
    let base: Color
    let speckColors: [Color]
    private let cellSize: CGFloat = 7

    private func hash(_ x: Int, _ y: Int) -> Double {
        let raw = sin(Double(x) * 12.9898 + Double(y) * 78.233) * 43758.5453
        return raw - raw.rounded(.down) // fractional part, always in [0, 1)
    }

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var col = 0
                var x: CGFloat = 0
                while x < size.width {
                    let h = hash(col, row)
                    if h > 0.62 { // ~38% of cells get a fleck -- dense enough to read as
                        // texture, sparse enough that individual specks stay distinguishable.
                        let jitterX = hash(col * 3 + 1, row) * cellSize
                        let jitterY = hash(col, row * 3 + 1) * cellSize
                        let speckSize = 1 + hash(col * 5, row * 5) * 1.5
                        let colorIndex = Int(hash(col * 7, row * 11) * Double(speckColors.count)) % max(speckColors.count, 1)
                        let rect = CGRect(x: x + jitterX, y: y + jitterY, width: speckSize, height: speckSize)
                        context.fill(Path(ellipseIn: rect), with: .color(speckColors[colorIndex]))
                    }
                    x += cellSize
                    col += 1
                }
                y += cellSize
                row += 1
            }
        }
    }
}

private struct BrushedCanvas: View {
    let base: Color
    let lineColor: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            var y: CGFloat = 0
            var i = 0
            while y < size.height {
                let opacity = 0.04 + 0.05 * abs(sin(Double(i) * 12.9898).truncatingRemainder(dividingBy: 1))
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(lineColor.opacity(opacity)))
                y += 1.5
                i += 1
            }
        }
    }
}
