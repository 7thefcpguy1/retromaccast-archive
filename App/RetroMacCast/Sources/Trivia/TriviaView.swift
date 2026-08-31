import RMCCore
import SwiftUI

/// A dedicated tab for browsing the trivia catalog `generate-trivia` mines from the archive --
/// structurally a near-twin of Home's `OnThisDayView` (hero spotlight + compact list below),
/// but the "featured" pick rotates by day-of-year hash over the whole catalog instead of by
/// calendar-date episode matches, and the list below shows the *entire* remaining catalog
/// (not a 5-item cap) since this tab has nothing else competing for space the way Home's
/// search results do.
struct TriviaView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                DesktopBackgroundView(theme: appearance.theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                // Same "tap anywhere else to collapse the inline player" catcher Home uses --
                // a real Button behind everything, not .onTapGesture (proven unreliable here).
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
                // Capped (see SearchView's matching comment) rather than .infinity, so a tall
                // app window shows desktop backdrop around the window instead of stretching it.
                FinderWindowChrome(title: "Trivia") {
                    triviaContent
                        .frame(minHeight: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: 640, maxHeight: 780)
                .padding(24)
                #else
                triviaContent
                #endif
            }
            .navigationTitle("Trivia")
        }
    }

    private var triviaContent: some View {
        #if os(macOS)
        ClassicScrollView {
            TriviaOfTheDayView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ScrollView {
            TriviaOfTheDayView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

private struct TriviaOfTheDayView: View {
    @State private var result: Corpus.TriviaSelection?

    var body: some View {
        // Same rule as OnThisDayView: .onAppear lives on this always-present VStack, never
        // inside an `if` -- an if-gated container that starts false produces no backing view,
        // so its .onAppear would never fire and `result` would stay nil forever.
        VStack(alignment: .leading, spacing: 14) {
            if let result {
                HStack {
                    Text("TRIVIA")
                        .font(.chicago(17))
                        .foregroundStyle(Retro.amberText)
                    Spacer()
                    Button {
                        withAnimation(.snappy) {
                            self.result = Corpus.shared.randomTriviaSelection()
                        }
                    } label: {
                        Label("New Facts", systemImage: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(Retro.amberText)
                    }
                    .buttonStyle(.plain)
                }

                TriviaHeroCard(fact: result.featured)

                if !result.more.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("MORE FROM THE ARCHIVE")
                            .font(.chicago(10))
                            .foregroundStyle(Retro.mutedText)
                            .padding(.bottom, 6)
                        ForEach(Array(result.more.enumerated()), id: \.element.id) { index, fact in
                            if index > 0 { Divider() }
                            TriviaCompactRow(fact: fact)
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            // A fresh random pick each time the tab first appears -- i.e. effectively once
            // per app launch, since the guard means switching tabs and back doesn't re-roll
            // (that's what the Refresh button above is for).
            if result == nil {
                result = Corpus.shared.randomTriviaSelection()
            }
        }
    }
}

private struct TriviaHeroCard: View {
    let fact: Corpus.TriviaResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { fact.episode != nil && player.activeEpisodeId == fact.episode?.id }

    var body: some View {
        PlayableMomentHeroCard(
            badge: "DID YOU KNOW?",
            primaryText: fact.factText,
            primaryFont: .chicago(17),
            primaryLineLimit: nil,
            secondaryText: fact.episode?.title,
            secondaryFont: .system(size: 12),
            secondaryLineLimit: 1,
            isActive: isActive,
            // nil (no play button at all) for a cross-episode aggregate fact -- there's
            // nothing for it to jump to.
            onToggle: fact.episode == nil ? nil : {
                withAnimation(.snappy) {
                    if isActive {
                        player.collapse()
                    } else {
                        player.playInContext(fact)
                    }
                }
            }
        )
    }
}

private struct TriviaCompactRow: View {
    let fact: Corpus.TriviaResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { fact.episode != nil && player.activeEpisodeId == fact.episode?.id }

    var body: some View {
        if let episode = fact.episode {
            PlayableMomentRow(
                isActive: isActive,
                onToggle: {
                    withAnimation(.snappy) {
                        if isActive {
                            player.collapse()
                        } else {
                            player.playInContext(fact)
                        }
                    }
                },
                // Chicago, matching every other episode title in the app (MuseumMomentCard,
                // the hero cards, OnThisDayCompactRow) rather than plain system font. Below
                // the tappable row, not part of it -- same as before this was extracted.
                caption: AnyView(
                    Text(episode.title)
                        .font(.chicago(11))
                        .foregroundStyle(Retro.mutedText)
                        .lineLimit(1)
                )
            ) {
                HStack(alignment: .top, spacing: 8) {
                    Text(fact.factText)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.black)
                    Spacer(minLength: 8)
                    Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                        .foregroundStyle(Retro.amberText)
                }
            }
        } else {
            // A cross-episode aggregate fact -- nothing to play, just the text. No onToggle,
            // so PlayableMomentRow renders this bare, with no button/tap target.
            PlayableMomentRow {
                Text(fact.factText)
                    .font(.system(size: 13))
                    .foregroundStyle(.black)
            }
        }
    }
}

#Preview {
    TriviaView()
        .environmentObject(PlayerViewModel())
        .environmentObject(AppearanceManager())
}
