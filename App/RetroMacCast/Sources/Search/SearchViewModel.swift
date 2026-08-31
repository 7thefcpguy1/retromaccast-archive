import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var sortOrder: SearchSortOrder = .relevance
    @Published var results: [Corpus.SearchResult] = []

    private var searchTask: Task<Void, Never>?

    func onQueryChange() {
        runSearch(debounced: true)
    }

    func onSortChange() {
        runSearch(debounced: false)
    }

    private func runSearch(debounced: Bool) {
        searchTask?.cancel()
        let q = query
        let sort = sortOrder
        searchTask = Task {
            if debounced {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }
            // Detached, not called inline -- a plain (non-detached) Task created from this
            // @MainActor method still runs on the main actor, so the synchronous
            // Corpus.shared.search() call below used to block the main thread for its full
            // duration. Its worst-case fallback path (Corpus.findMatchingSegment scanning
            // every transcript segment across up to 30 result episodes) is real enough to
            // visibly stall the UI on a multi-word query that doesn't verbatim-match. Corpus
            // itself isn't MainActor-isolated (GRDB's DatabaseQueue already serializes its
            // own access), so running the actual read on a background thread is safe. This
            // doesn't make an in-flight search truly interruptible mid-query (GRDB has no
            // cooperative-cancellation hook for a synchronous `dbQueue.read` call) -- a
            // superseded search still runs to completion in the background rather than
            // stopping partway -- but it no longer blocks the UI thread while doing so, and
            // the `Task.isCancelled` check right below still discards its result if a newer
            // query has since started.
            let r = await Task.detached(priority: .userInitiated) {
                Corpus.shared.search(q, sortBy: sort)
            }.value
            guard !Task.isCancelled else { return }
            results = r
        }
    }
}
