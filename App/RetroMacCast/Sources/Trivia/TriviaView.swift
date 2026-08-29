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
        VStack(spacing: 14) {
            Text("DID YOU KNOW?")
                .font(.chicago(11))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Retro.amberText)
                .clipShape(Capsule())

            Text(fact.factText)
                .font(.chicago(17))
                .foregroundStyle(Retro.amberText)
                .multilineTextAlignment(.center)

            if let episode = fact.episode {
                Text(episode.title)
                    .font(.system(size: 12))
                    // Explicit, fixed color, not semantic `.secondary` -- same dark-desktop-
                    // theme invisible-text bug fixed live in MuseumView.swift (this card sits
                    // on FinderWindowChrome's permanently-white/cream card, whose own
                    // .preferredColorScheme(.light) pin doesn't reliably override the real
                    // window's dark appearance for descendant content on macOS).
                    .foregroundStyle(Retro.mutedText)
                    .lineLimit(1)

                Button {
                    withAnimation(.snappy) {
                        if isActive {
                            player.collapse()
                        } else {
                            player.playInContext(fact)
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

private struct TriviaCompactRow: View {
    let fact: Corpus.TriviaResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { fact.episode != nil && player.activeEpisodeId == fact.episode?.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let episode = fact.episode {
                Button {
                    withAnimation(.snappy) {
                        if isActive {
                            player.collapse()
                        } else {
                            player.playInContext(fact)
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(fact.factText)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.black)
                        Spacer(minLength: 8)
                        Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(Retro.amberText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Chicago, matching every other episode title in the app (MuseumMomentCard,
                // the hero cards, OnThisDayCompactRow) rather than plain system font.
                Text(episode.title)
                    .font(.chicago(11))
                    .foregroundStyle(Retro.mutedText)
                    .lineLimit(1)
            } else {
                // A cross-episode aggregate fact -- nothing to play, just the text.
                Text(fact.factText)
                    .font(.system(size: 13))
                    .foregroundStyle(.black)
            }

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    TriviaView()
        .environmentObject(PlayerViewModel())
        .environmentObject(AppearanceManager())
}
