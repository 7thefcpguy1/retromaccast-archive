import SwiftUI

/// A selectable desktop background -- real classic Mac OS actually had this exact feature (the
/// Desktop Patterns control panel), just a grid of pattern swatches to click with no names
/// shown at all, so this deliberately follows the same period-authentic shape rather than
/// captioning each option. `accessibilityName` exists purely for VoiceOver, never rendered as
/// visible text.
///
/// Every `background` here is either a real historical pattern (Mac 128K's actual System 1-3
/// default `PAT` resource -- a small functional bitmask, not creative artwork) or a real
/// user-supplied tile image, not a procedurally-invented approximation.
struct DesktopTheme: Identifiable, Equatable {
    let id: String
    let accessibilityName: String
    let background: DesktopBackgroundStyle
    /// A single representative color for this theme -- kept as a stable, simple color identity
    /// even though nothing in the app currently renders it directly.
    let color: Color
    /// Drives the app window's `.preferredColorScheme` so the native title bar/toolbar text
    /// switches to light text automatically for a dark backdrop instead of staying the default
    /// dark-on-dark.
    let isDark: Bool

    static func == (lhs: DesktopTheme, rhs: DesktopTheme) -> Bool { lhs.id == rhs.id }

    init(id: String, accessibilityName: String, background: DesktopBackgroundStyle, color: Color, isDark: Bool = false) {
        self.id = id
        self.accessibilityName = accessibilityName
        self.background = background
        self.color = color
        self.isDark = isDark
    }

    static let all: [DesktopTheme] = [
        // The real System 1-3 default desktop pattern (PAT resource #0): a plain 50%
        // black/white checker dither -- 1984's 128K Mac display was pure 1-bit, no gray, no
        // tint, just alternating pixels.
        DesktopTheme(
            id: "mac128k", accessibilityName: "Mac 128K checkerboard",
            background: .dithered(fg: .black, bg: .white, mask: 0xAA55AA55AA55AA55),
            color: Color(white: 0.75)
        ),
        // "Flying Cats" (System 7.5.3, 1995) -- a real user-supplied tile image, not a
        // procedural approximation.
        DesktopTheme(
            id: "system7", accessibilityName: "Flying cats pattern",
            background: .tiledImage(name: "System7FlyingCat"),
            color: Color(red: 0.55, green: 0.70, blue: 0.95)
        ),
        DesktopTheme(
            id: "circuitBoard", accessibilityName: "Circuit board pattern",
            background: .tiledImage(name: "TileCircuitBoard"),
            color: Color(red: 0.05, green: 0.20, blue: 0.10), isDark: true
        ),
        DesktopTheme(
            id: "ripple", accessibilityName: "Teal ripple pattern",
            background: .tiledImage(name: "TileRipple"),
            color: Color(red: 0.25, green: 0.65, blue: 0.60)
        ),
        DesktopTheme(
            id: "weave", accessibilityName: "Purple woven pattern",
            background: .tiledImage(name: "TileWeave"),
            color: Color(red: 0.35, green: 0.30, blue: 0.55), isDark: true
        ),
        DesktopTheme(
            id: "granite", accessibilityName: "Blue granite pattern",
            background: .tiledImage(name: "TileGranite"),
            color: Color(red: 0.15, green: 0.20, blue: 0.55), isDark: true
        ),
        DesktopTheme(
            id: "bubbles", accessibilityName: "Purple bubbles pattern",
            background: .tiledImage(name: "TileBubbles"),
            color: Color(red: 0.30, green: 0.10, blue: 0.65), isDark: true
        ),
        DesktopTheme(
            id: "confetti", accessibilityName: "Confetti shapes pattern",
            background: .tiledImage(name: "TileConfetti"),
            color: Color(red: 0.95, green: 0.95, blue: 0.85)
        ),
        DesktopTheme(
            id: "tinyGuy", accessibilityName: "Tiny lavender checker pattern",
            background: .tiledImage(name: "TinyGuy"),
            color: Color(red: 0.65, green: 0.65, blue: 0.85)
        ),
    ]

    static let `default` = all[0]
}
