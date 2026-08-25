import SwiftUI

/// A selectable desktop background, each a real era of classic Mac OS's own default/iconic
/// desktop pattern -- real classic Mac OS actually had this exact feature (the Desktop Patterns
/// control panel), so it's period-authentic to offer it as one simple backdrop swap behind the
/// existing System 7 window chrome, rather than a full per-era chrome redesign.
///
/// Sourcing note, since accuracy matters here more than for this app's other invented chrome:
/// the 128K Mac and System 7 entries recreate real, well-documented, simple 1-bit/tiled
/// `PAT `-resource-style patterns -- small functional bitmasks, not creative artwork, so
/// reproducing their actual historical bit/color values (the System 7 one sourced from the
/// user's own classic_mac_wallpapers_spec.md, which attributes it by name to that exact OS
/// release) carries essentially no copyright concern. Mac OS 8's "Granite" speckle is the same
/// story. Mac OS 9 and early Mac OS X's REAL desktop pictures, by contrast, were genuine
/// designed/rendered artwork Apple created and owns (photography and illustration, not a tiny
/// data mask) -- those two are deliberately labeled as original evocations of the era's look in
/// their own doc comments below, not attempts at a literal reproduction.
struct DesktopTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let era: String
    let background: DesktopBackgroundStyle
    /// A single representative color for this theme -- kept as a stable, simple color identity
    /// even though nothing in the app currently renders it directly (DesktopBackgroundView
    /// renders the real `background` everywhere a backdrop is shown).
    let color: Color
    /// Drives the app window's `.preferredColorScheme` so the native title bar/toolbar text
    /// (which this app doesn't otherwise control -- it's AppKit chrome, not SwiftUI content)
    /// switches to light text automatically for a dark backdrop instead of staying the
    /// default dark-on-dark.
    let isDark: Bool

    static func == (lhs: DesktopTheme, rhs: DesktopTheme) -> Bool { lhs.id == rhs.id }

    init(id: String, name: String, era: String, background: DesktopBackgroundStyle, color: Color, isDark: Bool = false) {
        self.id = id
        self.name = name
        self.era = era
        self.background = background
        self.color = color
        self.isDark = isDark
    }

    static let all: [DesktopTheme] = [
        // The real System 1-3 default desktop pattern (PAT resource #0): a plain 50%
        // black/white checker dither, since 1984's 128K Mac display was pure 1-bit -- no gray,
        // no tint, just alternating pixels. AA55AA55AA55AA55 is the same mask the user's spec
        // doc's own catalog lists for this exact pattern/era.
        DesktopTheme(
            id: "mac128k", name: "Mac 128K", era: "1984",
            background: .dithered(fg: .black, bg: .white, mask: 0xAA55AA55AA55AA55),
            color: Color(white: 0.75)
        ),
        // "Denim Weave" -- per the spec doc's own catalog: System 7.0 (1991), 32x32, "Blue
        // dithered indigo denim texture."
        DesktopTheme(
            id: "system7", name: "System 7", era: "1991",
            background: .woven(fg: Color(red: 0.15, green: 0.20, blue: 0.38), bg: Color(red: 0.30, green: 0.40, blue: 0.58)),
            color: Color(red: 0.30, green: 0.40, blue: 0.58)
        ),
        // "Granite Counter" -- per the spec doc's own catalog: Mac OS 8.0 (1997), 64x64,
        // "Specks of charcoal, quartz, and mid-tone grey."
        DesktopTheme(
            id: "macOS8", name: "Mac OS 8", era: "1997",
            background: .speckled(
                base: Color(red: 0.72, green: 0.72, blue: 0.74),
                speckColors: [Color(white: 0.25), Color(white: 0.92), Color(red: 0.58, green: 0.58, blue: 0.62)]
            ),
            color: Color(red: 0.72, green: 0.72, blue: 0.74)
        ),
        // Mac OS 9's real default desktop picture was genuine designed artwork, not a simple
        // data-mask pattern -- this is an original evocation of its soft platinum/blue-gray
        // palette, not a reproduction of any specific real image.
        DesktopTheme(
            id: "macOS9", name: "Mac OS 9", era: "1999",
            background: .radialGlow(center: Color(red: 0.75, green: 0.78, blue: 0.85), edge: Color(red: 0.52, green: 0.56, blue: 0.68)),
            color: Color(red: 0.52, green: 0.56, blue: 0.68)
        ),
        // Same story as Mac OS 9 -- the real Aqua "blue swirl" desktop picture was commissioned
        // Apple artwork, not a functional pattern. This is an original evocation of Aqua's
        // glassy blue palette, not a reproduction of the actual wallpaper.
        DesktopTheme(
            id: "earlyOSX", name: "Mac OS X", era: "2001",
            background: .radialGlow(center: Color(red: 0.93, green: 0.97, blue: 1.00), edge: Color(red: 0.55, green: 0.75, blue: 0.95)),
            color: Color(red: 0.55, green: 0.75, blue: 0.95)
        ),
    ]

    static let `default` = all[0]
}
