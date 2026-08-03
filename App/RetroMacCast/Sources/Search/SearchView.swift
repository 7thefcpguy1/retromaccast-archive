import RMCCore
import SwiftUI

struct SearchView: View {
    @StateObject private var viewModel = SearchViewModel()
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                Retro.beige
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                // A real Button behind everything else, not a plain .onTapGesture -- two
                // earlier attempts with .onTapGesture-based catchers (chained directly on
                // the ScrollView, then as a .background layer) never fired at all. Buttons
                // have proven reliable for gesture priority throughout this app; a card
                // header Button sitting on top still wins when a tap lands directly on it,
                // since hit-testing checks the topmost view first.
                if player.activeEpisodeId != nil {
                    Button {
                        withAnimation(.snappy) {
                            player.collapse()
                        }
                    } label: {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                }

                #if os(macOS)
                // Same Finder-window chrome as Museum/Emulator -- a fixed min height (rather
                // than sizing to content, like the Museum icon grid does) since this content
                // scrolls and would otherwise collapse the window to zero height.
                FinderWindowChrome(title: "Home") {
                    homeContent
                        .frame(minHeight: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: 640, maxHeight: .infinity)
                .padding(24)
                #else
                homeContent
                #endif
            }
            .searchable(text: $viewModel.query, prompt: "Search 20 years of episodes...")
            .onChange(of: viewModel.query) { _, _ in
                player.collapse()
                viewModel.onQueryChange()
            }
        }
    }

    private var homeContent: some View {
        ZStack {
            if !viewModel.query.isEmpty && viewModel.results.isEmpty {
                Image("RMCMascot")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .allowsHitTesting(false)
            }

            #if os(macOS)
            // A period-accurate System 7 scrollbar (dithered track, bordered thumb, arrow
            // buttons) instead of the modern floating indicator -- fits the rest of the
            // Finder-window chrome. Real scrolling still comes from the ScrollView underneath;
            // this rides along as a live-updating readout of its position.
            ClassicScrollView {
                resultsContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            ScrollView {
                resultsContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.query.isEmpty {
                HomeHeaderView()
                OnThisDayView()
            } else {
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

                ForEach(viewModel.results) { result in
                    ResultCard(result: result)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The mascot + a live tagline ("keeping it retro for N days and counting"), computed from
/// the earliest episode's air date. Always renders its container unconditionally (unlike
/// OnThisDayView's content below it) so there's no risk of the same onAppear-never-fires
/// trap -- the tagline text itself just has a placeholder fallback while daysCount loads.
private struct HomeHeaderView: View {
    @State private var daysCount: Int?

    var body: some View {
        VStack(spacing: 10) {
            Image("RMCMascot")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
            Text(tagline)
                .font(.chicago(17))
                .foregroundStyle(Retro.amberText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 6)
        .onAppear {
            if daysCount == nil {
                daysCount = Corpus.shared.daysSinceFirstEpisode()
            }
        }
    }

    private var tagline: String {
        guard let daysCount else { return "James and John, keeping it retro." }
        let formatted = daysCount.formatted(.number.grouping(.automatic))
        return "James and John, keeping it retro for \(formatted) days and counting."
    }
}

/// A featured spotlight rather than a scrolling list -- one hero pick with real visual
/// weight, plus a short, compact strip for anything else from the same window. Capped at
/// 5 total: a flat list of every match (the +/-3-day fallback routinely pulls a dozen-plus
/// after 20 years of weekly episodes) read as a wall of text, not an inviting daily moment.
struct OnThisDayView: View {
    @State private var result: Corpus.OnThisDayResult?

    private static let maxShown = 5

    var body: some View {
        // .onAppear below is on this VStack specifically -- it must be a container that
        // always exists, not a Group wrapping only the conditional. A Group whose sole
        // content is an initially-false `if` produces no backing view at all, so its
        // .onAppear never fires and `result` stays nil forever (found the hard way).
        VStack(alignment: .leading, spacing: 14) {
            if let result, !result.episodes.isEmpty {
                // Prefer an episode with real show notes for the hero slot -- a chunk of
                // episodes have empty showNotesHTML, and the hero is the one place that
                // needs real description text to feel inviting rather than a bare date.
                let hero = result.episodes.first(where: { !$0.showNotesHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? result.episodes[0]
                let rest = result.episodes.filter { $0.id != hero.id }.prefix(Self.maxShown - 1)

                Text("THIS WEEK IN RETROMACCAST HISTORY")
                    .font(.chicago(17))
                    .foregroundStyle(Retro.amberText)

                OnThisDayHeroCard(episode: hero)

                if !rest.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("ALSO FROM THIS DAY")
                            .font(.chicago(10))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                        ForEach(Array(rest.enumerated()), id: \.element.id) { index, episode in
                            if index > 0 { Divider() }
                            OnThisDayCompactRow(episode: episode)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Retro.cardBorder, lineWidth: 1))
                }
            }
        }
        .onAppear {
            if result == nil {
                result = Corpus.shared.onThisDay()
            }
        }
    }
}

private func yearsAgoLabel(for episode: Episode) -> String {
    guard episode.pubDate.count == 10, let year = Int(episode.pubDate.prefix(4)) else { return episode.pubDate }
    let currentYear = Calendar.current.component(.year, from: Date())
    let diff = currentYear - year
    if diff <= 0 { return "This year" }
    return diff == 1 ? "1 year ago" : "\(diff) years ago"
}

/// Show notes come from the RSS feed as HTML (tags, &nbsp;, <a href> links) -- render
/// through NSAttributedString's HTML parser rather than hand-rolled tag stripping so
/// entities decode correctly and link text survives without its markup or URL.
private func plainText(fromHTML html: String) -> String {
    guard let data = html.data(using: .utf8) else { return html }
    let attributed = try? NSAttributedString(
        data: data,
        options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
        documentAttributes: nil
    )
    let text = (attributed?.string ?? html).trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = 200
    guard text.count > limit else { return text }
    let cutoff = text.index(text.startIndex, offsetBy: limit)
    let lastSpace = text[..<cutoff].lastIndex(of: " ") ?? cutoff
    return text[..<lastSpace].trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
}

private struct OnThisDayHeroCard: View {
    let episode: Episode
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == episode.id }

    var body: some View {
        VStack(spacing: 14) {
            Text(yearsAgoLabel(for: episode).uppercased())
                .font(.chicago(11))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Retro.amberText)
                .clipShape(Capsule())

            Text(episode.title)
                .font(.chicago(20))
                .foregroundStyle(Retro.amberText)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if !episode.showNotesHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(plainText(fromHTML: episode.showNotesHTML))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }

            Button {
                withAnimation(.snappy) {
                    if isActive {
                        player.collapse()
                    } else {
                        player.playEpisode(episode)
                    }
                }
            } label: {
                Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Retro.amberText)
            }
            .buttonStyle(.plain)

            if isActive {
                InlinePlayer()
                    .frame(maxWidth: 320)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(isActive ? Retro.amberText.opacity(0.4) : Retro.cardBorder, lineWidth: isActive ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

private struct OnThisDayCompactRow: View {
    let episode: Episode
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) {
                    if isActive {
                        player.collapse()
                    } else {
                        player.playEpisode(episode)
                    }
                }
            } label: {
                HStack {
                    Text(episode.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer()
                    Text(yearsAgoLabel(for: episode))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
}

struct ResultCard: View {
    let result: Corpus.SearchResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == result.episode.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // A real Button, not a bare .onTapGesture on the whole card -- the old version
            // wrapped InlinePlayer's buttons (play/pause, "Play full episode") inside the
            // same .onTapGesture as the header, and the card's gesture ate their taps before
            // the buttons ever saw them. Scoping this to just the header, as its own Button,
            // leaves InlinePlayer untouched below.
            Button {
                withAnimation(.snappy) {
                    if isActive {
                        player.collapse()
                    } else {
                        player.playInContext(result)
                    }
                }
            } label: {
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
    }
}

struct InlinePlayer: View {
    @EnvironmentObject private var player: PlayerViewModel
    @State private var isDragging = false
    @State private var dragMs: Double = 0

    var body: some View {
        Group {
            if player.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let error = player.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 10) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 22))
                    }
                    .buttonStyle(.plain)

                    if let durationMs = player.durationMs {
                        Slider(
                            value: Binding(
                                get: { isDragging ? dragMs : Double(player.currentTimeMs) },
                                set: { dragMs = $0 }
                            ),
                            in: 0...Double(max(durationMs, 1)),
                            onEditingChanged: { editing in
                                isDragging = editing
                                if editing {
                                    dragMs = Double(player.currentTimeMs)
                                } else {
                                    player.seek(toMs: Int(dragMs))
                                }
                            }
                        )
                        .tint(Retro.amberText)
                    } else {
                        // Duration hasn't loaded yet -- rendering the slider before we know
                        // the real range pinned its thumb to 100% (range was 0...currentTime,
                        // so "current position" was always the range's own max), then jumped
                        // once duration arrived. Simpler to just not show it until we know.
                        ProgressView()
                            .controlSize(.mini)
                            .frame(maxWidth: .infinity)
                    }

                    Text(timeLabel)
                        .font(.chicago(11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 84, alignment: .trailing)
                }
            }
        }
        .padding(.top, 6)
    }

    private var timeLabel: String {
        let elapsed = formatTimestamp(isDragging ? Int(dragMs) : player.currentTimeMs)
        guard let durationMs = player.durationMs else { return elapsed }
        return "\(elapsed) / \(formatTimestamp(durationMs))"
    }
}

#Preview {
    SearchView()
}
