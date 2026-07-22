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
            let r = Corpus.shared.search(q, sortBy: sort)
            guard !Task.isCancelled else { return }
            results = r
        }
    }
}
