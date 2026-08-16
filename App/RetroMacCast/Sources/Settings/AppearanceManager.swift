import SwiftUI

/// Owns which `DesktopTheme` is active, persisted across launches. Shared between the main
/// window and Settings the same way `CorpusUpdateManager` is -- one instance created in
/// `RetroMacCastApp` and injected into both via `.environmentObject`.
@MainActor
final class AppearanceManager: ObservableObject {
    @Published private(set) var theme: DesktopTheme

    private static let selectedThemeIDKey = "AppearanceManager.selectedThemeID"

    init() {
        let savedID = UserDefaults.standard.string(forKey: Self.selectedThemeIDKey)
        theme = DesktopTheme.all.first(where: { $0.id == savedID }) ?? .default
    }

    func select(_ theme: DesktopTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.id, forKey: Self.selectedThemeIDKey)
    }
}
