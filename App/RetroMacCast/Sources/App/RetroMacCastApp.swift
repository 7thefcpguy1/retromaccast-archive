import SwiftUI
import CoreText

@main
struct RetroMacCastApp: App {
    // Owned here, not in RootTabView, so the same instance is shared between the main
    // window and the macOS-only Settings scene below.
    @StateObject private var updateManager = CorpusUpdateManager()

    init() {
        setvbuf(stdout, nil, _IONBF, 0) // stdout is fully buffered when not a tty (and this
        // app never exits to flush it) -- disable buffering so debug prints actually show up
        // when redirected to a log file.
        registerChicagoFont()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(updateManager)
                .task {
                    // Weekly-by-default: this only actually hits the network if 7+ days
                    // have passed since the last check, so a normal launch is a no-op.
                    await updateManager.checkIfDue()
                }
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(updateManager)
        }
        #endif
    }
}

private func registerChicagoFont() {
    guard let url = Bundle.main.url(forResource: "ChicagoFLF", withExtension: "ttf") else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
}
