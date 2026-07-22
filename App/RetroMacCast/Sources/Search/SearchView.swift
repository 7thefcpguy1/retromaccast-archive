import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @StateObject private var player = PlayerViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !viewModel.query.isEmpty {
                        HStack {
                            Text("\(viewModel.results.count) moments found")
                                .font(.chicago(13))
                                .foregroundStyle(Retro.amberText)
                            Spacer()
                            Picker("Sort", selection: $viewModel.sortOrder) {
                                ForEach(SearchSortOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .onChange(of: viewModel.sortOrder) { _, _ in viewModel.onSortChange() }
                        }
                    }

                    ForEach(viewModel.results) { result in
                        ResultCard(result: result)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Retro.beige)
            .navigationTitle("RetroMacCast")
            .searchable(text: $viewModel.query, prompt: "Search 20 years of episodes...")
            .onChange(of: viewModel.query) { _, _ in
                player.collapse()
                viewModel.onQueryChange()
            }
        }
        .environmentObject(player)
        .preferredColorScheme(.light)
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

struct ResultCard: View {
    let result: Corpus.SearchResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == result.episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(result.episode.title)
                    .font(.chicago(13))
                    .lineLimit(1)
                Spacer()
                if let ms = result.timestampMs {
                    Text(formatTimestamp(ms))
                        .font(.chicago(11))
                        .foregroundStyle(.secondary)
                }
            }
            if let snippet = result.snippet {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(isActive ? Retro.amberText.opacity(0.4) : Retro.cardBorder, lineWidth: isActive ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.snappy) {
                if isActive {
                    player.collapse()
                } else {
                    player.playInContext(result)
                }
            }
        }
    }
}

private struct InlinePlayer: View {
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        HStack(spacing: 10) {
            if player.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let error = player.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)

                Text(formatTimestamp(player.currentTimeMs))
                    .font(.chicago(11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                if !player.isFullEpisode {
                    Button("Play full episode") {
                        player.playFullEpisode()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 6)
    }
}

#Preview {
    SearchView()
}
