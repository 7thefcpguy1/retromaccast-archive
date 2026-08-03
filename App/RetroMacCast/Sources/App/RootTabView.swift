import SwiftUI

/// Root navigation shell. `.sidebarAdaptable` renders this as a bottom tab bar on iPhone
/// and as a native sidebar on Mac/iPad from one shared declaration -- the platform-idiomatic
/// choice on each, without hand-building two separate navigation structures. Requires
/// iOS 18 / macOS 15 minimum, which is why the deployment targets were bumped for this.
struct RootTabView: View {
    // Owned here rather than per-tab so all three tabs share one player -- a moment
    // played from any tab keeps its state if the user switches tabs.
    @StateObject private var player = PlayerViewModel()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "magnifyingglass") {
                SearchView()
            }
            Tab("Museum", systemImage: "building.columns") {
                MuseumView()
            }
            Tab("Emulator", systemImage: "desktopcomputer") {
                EmulatorView()
            }
        }
        .environmentObject(player)
        .tabViewStyle(.sidebarAdaptable)
        .navigationTitle("RetroMacCast") // set once, here, rather than per-tab -- each tab
        // hosts its own NavigationStack, and a per-tab .navigationTitle would override this
        // and change the window title when switching tabs, which is the exact quirk this fixes.
        .preferredColorScheme(.light)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

#Preview {
    RootTabView()
}
