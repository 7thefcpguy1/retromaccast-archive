import SwiftUI
import CoreText

@main
struct RetroMacCastApp: App {
    init() {
        registerChicagoFont()
    }

    var body: some Scene {
        WindowGroup {
            SearchView()
        }
    }
}

private func registerChicagoFont() {
    guard let url = Bundle.main.url(forResource: "ChicagoFLF", withExtension: "ttf") else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
