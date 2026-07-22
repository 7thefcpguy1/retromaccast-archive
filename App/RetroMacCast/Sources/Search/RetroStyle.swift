import SwiftUI

enum Retro {
    static let beige = Color(red: 0.980, green: 0.933, blue: 0.855)
    static let amberText = Color(red: 0.388, green: 0.219, blue: 0.008)
    static let cardBorder = Color.black.opacity(0.12)
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
