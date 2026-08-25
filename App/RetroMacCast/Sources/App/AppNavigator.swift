import SwiftUI

/// Shared cross-tab navigation state -- specifically for Home's "Featured Collection" card,
/// which needs to switch to the Museum tab AND land on one specific product's cascaded
/// window, not just bring the tab to the front. `RootTabView`'s `TabView` previously had no
/// selection binding at all (each tab just sat there, switched by the system's own tab UI),
/// so there was no way for one tab to programmatically navigate into another -- this is the
/// minimum shared state needed to do that, injected once at the root and read by whichever
/// views need to trigger or react to a cross-tab jump.
@MainActor
final class AppNavigator: ObservableObject {
    enum Tab: Hashable {
        case home, museum, emulators, videos, trivia, glossary
    }

    @Published var selectedTab: Tab = .home

    /// The Museum product slug (`MuseumProduct.id`) to land on once the Museum tab is
    /// showing. `MuseumView`/`MuseumCategoryView` consume this via `.onChange` (not just
    /// `.onAppear`, which -- confirmed the hard way elsewhere in this app, see
    /// `SearchView.HomeHeaderView`'s doc comment -- doesn't reliably re-fire on a tab that's
    /// already mounted from a previous visit) and clear it back to nil once the right
    /// category + product windows have actually opened, so switching to Museum manually
    /// afterward doesn't replay the same jump.
    @Published var pendingMuseumProductId: String?

    func openMuseumProduct(slug: String) {
        pendingMuseumProductId = slug
        selectedTab = .museum
    }
}
