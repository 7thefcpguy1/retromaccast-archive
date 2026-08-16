import SwiftUI

/// A selectable desktop background, each evoking a different Apple era. Deliberately just a
/// color swap behind the existing System 7 window chrome (not a full per-era chrome redesign)
/// -- real classic Mac OS actually had this exact feature (the Desktop Patterns control panel),
/// so it's period-authentic to offer it as one simple choice rather than a whole reskin.
struct DesktopTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let era: String
    let color: Color
    /// Drives the app window's `.preferredColorScheme` so the native title bar/toolbar text
    /// (which this app doesn't otherwise control -- it's AppKit chrome, not SwiftUI content)
    /// switches to light text automatically for a dark backdrop instead of staying the
    /// default dark-on-dark. Only Space Gray is dark enough to need this; every other theme
    /// is a light/pastel tint where dark text already reads fine.
    let isDark: Bool

    init(id: String, name: String, era: String, color: Color, isDark: Bool = false) {
        self.id = id
        self.name = name
        self.era = era
        self.color = color
        self.isDark = isDark
    }

    // Fruit-color and Bondi Blue values are pastel-softened tints of the real iMac G3 case
    // colors (matched against a reference chart of the actual product line), not invented
    // guesses -- softened so they're comfortable to look at as a full-screen backdrop rather
    // than a small plastic swatch, but the hue itself tracks the real color.
    static let all: [DesktopTheme] = [
        DesktopTheme(id: "appleII", name: "Apple II", era: "1977", color: Retro.beige),
        DesktopTheme(id: "os89", name: "Mac OS 8/9", era: "1997", color: Color(red: 0.85, green: 0.87, blue: 0.90)),
        DesktopTheme(id: "bondiBlue", name: "Bondi Blue", era: "1998", color: Color(red: 0.62, green: 0.85, blue: 0.86)),
        DesktopTheme(id: "blueberry", name: "Blueberry", era: "1999", color: Color(red: 0.62, green: 0.74, blue: 0.94)),
        DesktopTheme(id: "grape", name: "Grape", era: "1999", color: Color(red: 0.80, green: 0.70, blue: 0.88)),
        DesktopTheme(id: "tangerine", name: "Tangerine", era: "1999", color: Color(red: 1.00, green: 0.76, blue: 0.52)),
        DesktopTheme(id: "lime", name: "Lime", era: "1999", color: Color(red: 0.76, green: 0.90, blue: 0.60)),
        DesktopTheme(id: "strawberry", name: "Strawberry", era: "1999", color: Color(red: 0.96, green: 0.68, blue: 0.72)),
        DesktopTheme(id: "aquaBlue", name: "Aqua Blue", era: "Mac OS X", color: Color(red: 0.78, green: 0.88, blue: 0.98)),
        DesktopTheme(id: "titanium", name: "Titanium", era: "PowerBook G4", color: Color(red: 0.85, green: 0.85, blue: 0.87)),
        DesktopTheme(id: "spaceGray", name: "Space Gray", era: "Modern", color: Color(red: 0.25, green: 0.25, blue: 0.27), isDark: true),
    ]

    static let `default` = all[0]
}
