import SwiftUI

enum Retro {
    static let beige = Color(red: 0.980, green: 0.933, blue: 0.855)
    static let amberText = Color(red: 0.388, green: 0.219, blue: 0.008)
    static let cardBorder = Color.black.opacity(0.12)
    /// Explicit stand-in for `.secondary`/`.primary` in a couple of specific spots
    /// (OnThisDayView's "ALSO FROM THIS DAY" list, TriviaView's "MORE FROM THE ARCHIVE" list)
    /// where those semantic colors were confirmed -- by swapping in an explicit color and
    /// watching the text reappear -- to render fully invisible, while every other `.secondary`
    /// usage in the app (the hero cards right next to these, Museum's synthesized paragraphs)
    /// renders fine. Root cause not fully pinned down (some SwiftUI colorScheme-resolution
    /// quirk specific to inline conditional content within a larger view's body, on top of
    /// this app's per-theme `.preferredColorScheme` override elsewhere), but explicit colors
    /// are a reliable, low-risk fix regardless -- applied only to the confirmed-broken spots,
    /// not swept across the whole app, since everywhere else `.secondary` already works.
    static let mutedText = Color.black.opacity(0.55)
}

extension Font {
    static func chicago(_ size: CGFloat) -> Font {
        .custom("ChicagoFLF", size: size)
    }
}

func formatTimestamp(_ ms: Int) -> String {
    let totalSeconds = ms / 1000
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}
