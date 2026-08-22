import SwiftUI

/// Root navigation shell. `.sidebarAdaptable` renders this as a bottom tab bar on iPhone
/// and as a native sidebar on Mac/iPad from one shared declaration -- the platform-idiomatic
/// choice on each, without hand-building two separate navigation structures. Requires
/// iOS 18 / macOS 15 minimum, which is why the deployment targets were bumped for this.
struct RootTabView: View {
    // Owned here rather than per-tab so all three tabs share one player -- a moment
    // played from any tab keeps its state if the user switches tabs.
    @StateObject private var player = PlayerViewModel()
    // Same reasoning -- owned at the root and shared, so Home can switch to the Museum tab
    // and land on a specific product from its "Featured Collection" card.
    @StateObject private var navigator = AppNavigator()
    @EnvironmentObject private var appearance: AppearanceManager

    var body: some View {
        TabView(selection: $navigator.selectedTab) {
            Tab("Home", systemImage: "magnifyingglass", value: AppNavigator.Tab.home) {
                SearchView()
            }
            Tab("Museum", systemImage: "building.columns", value: AppNavigator.Tab.museum) {
                MuseumView()
            }
            Tab("Emulators", systemImage: "desktopcomputer", value: AppNavigator.Tab.emulators) {
                EmulatorView()
            }
            Tab("Videos", systemImage: "play.rectangle", value: AppNavigator.Tab.videos) {
                VideosView()
            }
            Tab("Trivia", systemImage: "lightbulb", value: AppNavigator.Tab.trivia) {
                TriviaView()
            }
        }
        .environmentObject(player)
        .environmentObject(navigator)
        .tabViewStyle(.sidebarAdaptable)
        .navigationTitle("RetroMacCast") // set once, here, rather than per-tab -- each tab
        // hosts its own NavigationStack, and a per-tab .navigationTitle would override this
        // and change the window title when switching tabs, which is the exact quirk this fixes.
        // Drives the native title bar's text/control color, not our own content -- see
        // FinderWindowChrome's matching .preferredColorScheme(.light) override, which pins
        // every actual window's content (always a white/cream card, period-authentic
        // regardless of desktop theme) back to light no matter what this says.
        .preferredColorScheme(appearance.theme.isDark ? .dark : .light)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

#Preview {
    RootTabView()
        .environmentObject(AppearanceManager())
}
