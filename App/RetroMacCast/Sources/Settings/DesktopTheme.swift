import SwiftUI

/// A selectable desktop background, each evoking a different Apple era. Deliberately just a
/// backdrop swap behind the existing System 7 window chrome (not a full per-era chrome
/// redesign) -- real classic Mac OS actually had this exact feature (the Desktop Patterns
/// control panel), so it's period-authentic to offer it as one simple choice rather than a
/// whole reskin. Each theme's `background` renders a distinct, original pattern/gradient (see
/// DesktopBackgroundView.swift) rather than a flat fill -- 1-bit dither and woven patterns for
/// the earliest eras, a soft radial glow for the translucent-plastic iMac/Aqua years, brushed
/// grain for titanium -- rather than real Apple desktop-picture photography.
struct DesktopTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let era: String
    let background: DesktopBackgroundStyle
    /// A single representative color for this theme -- used wherever a flat swatch fill is
    /// genuinely all that's needed (there's no such use left in the app itself now that
    /// DesktopBackgroundView renders the real `background` everywhere, but kept as a stable,
    /// simple color identity for the theme).
    let color: Color
    /// Drives the app window's `.preferredColorScheme` so the native title bar/toolbar text
    /// (which this app doesn't otherwise control -- it's AppKit chrome, not SwiftUI content)
    /// switches to light text automatically for a dark backdrop instead of staying the
    /// default dark-on-dark. Only Space Gray is dark enough to need this; every other theme
    /// is a light/pastel tint where dark text already reads fine.
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

    // Fruit-color and Bondi Blue values are pastel-softened tints of the real iMac G3 case
    // colors (matched against a reference chart of the actual product line), not invented
    // guesses -- softened so they're comfortable to look at as a full-screen backdrop rather
    // than a small plastic swatch, but the hue itself tracks the real color. Each `center`
    // in a `.radialGlow` is that same base color blended roughly halfway to white, not a
    // separately invented tone -- keeps the glow reading as "this color, lit up" rather than
    // an unrelated highlight.
    static let all: [DesktopTheme] = [
        DesktopTheme(
            id: "appleII", name: "Apple II", era: "1977",
            background: .dithered(fg: Color(red: 0.90, green: 0.84, blue: 0.74), bg: Retro.beige, mask: 0x8000200008000200),
            color: Retro.beige
        ),
        DesktopTheme(
            id: "os89", name: "Mac OS 8/9", era: "1997",
            background: .woven(fg: Color(red: 0.62, green: 0.65, blue: 0.70), bg: Color(red: 0.85, green: 0.87, blue: 0.90)),
            color: Color(red: 0.85, green: 0.87, blue: 0.90)
        ),
        DesktopTheme(
            id: "bondiBlue", name: "Bondi Blue", era: "1998",
            background: .radialGlow(center: Color(red: 0.81, green: 0.93, blue: 0.93), edge: Color(red: 0.62, green: 0.85, blue: 0.86)),
            color: Color(red: 0.62, green: 0.85, blue: 0.86)
        ),
        DesktopTheme(
            id: "blueberry", name: "Blueberry", era: "1999",
            background: .radialGlow(center: Color(red: 0.81, green: 0.87, blue: 0.97), edge: Color(red: 0.62, green: 0.74, blue: 0.94)),
            color: Color(red: 0.62, green: 0.74, blue: 0.94)
        ),
        DesktopTheme(
            id: "grape", name: "Grape", era: "1999",
            background: .radialGlow(center: Color(red: 0.90, green: 0.85, blue: 0.94), edge: Color(red: 0.80, green: 0.70, blue: 0.88)),
            color: Color(red: 0.80, green: 0.70, blue: 0.88)
        ),
        DesktopTheme(
            id: "tangerine", name: "Tangerine", era: "1999",
            background: .radialGlow(center: Color(red: 1.00, green: 0.88, blue: 0.76), edge: Color(red: 1.00, green: 0.76, blue: 0.52)),
            color: Color(red: 1.00, green: 0.76, blue: 0.52)
        ),
        DesktopTheme(
            id: "lime", name: "Lime", era: "1999",
            background: .radialGlow(center: Color(red: 0.88, green: 0.95, blue: 0.80), edge: Color(red: 0.76, green: 0.90, blue: 0.60)),
            color: Color(red: 0.76, green: 0.90, blue: 0.60)
        ),
        DesktopTheme(
            id: "strawberry", name: "Strawberry", era: "1999",
            background: .radialGlow(center: Color(red: 0.98, green: 0.84, blue: 0.86), edge: Color(red: 0.96, green: 0.68, blue: 0.72)),
            color: Color(red: 0.96, green: 0.68, blue: 0.72)
        ),
        DesktopTheme(
            id: "aquaBlue", name: "Aqua Blue", era: "Mac OS X",
            background: .radialGlow(center: Color(red: 0.93, green: 0.97, blue: 1.00), edge: Color(red: 0.78, green: 0.88, blue: 0.98)),
            color: Color(red: 0.78, green: 0.88, blue: 0.98)
        ),
        DesktopTheme(
            id: "titanium", name: "Titanium", era: "PowerBook G4",
            background: .brushed(base: Color(red: 0.85, green: 0.85, blue: 0.87), lineColor: .black),
            color: Color(red: 0.85, green: 0.85, blue: 0.87)
        ),
        DesktopTheme(
            id: "spaceGray", name: "Space Gray", era: "Modern",
            background: .radialGlow(center: Color(red: 0.34, green: 0.34, blue: 0.37), edge: Color(red: 0.25, green: 0.25, blue: 0.27)),
            color: Color(red: 0.25, green: 0.25, blue: 0.27), isDark: true
        ),
    ]

    static let `default` = all[0]
}
