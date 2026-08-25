import RMCCore
import SwiftUI

/// A "Mac Dictionary" tab -- classic-Mac jargon (hardware, software, and UI terms) explained
/// in one browsable, searchable list, mined from the archive by `generate-glossary` (same
/// shape as Museum's `classify` and Trivia's `generate-trivia`): each term is grouped from
/// every episode where a host actually explained it, with a "play in context" jump to the real
/// moment when one resolved. Structurally close to TriviaView (FinderWindowChrome + a
/// scrollable list of cards).
struct GlossaryView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @EnvironmentObject private var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            ZStack {
                DesktopBackgroundView(theme: appearance.theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

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
                FinderWindowChrome(title: "Glossary") {
                    GlossaryContent()
                        .frame(minHeight: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: 640, maxHeight: 780)
                .padding(24)
                #else
                GlossaryContent()
                #endif
            }
            .navigationTitle("Glossary")
        }
    }
}

/// One term with every episode mention grouped together -- `generate-glossary` records one
/// `GlossaryTermResult` row per (term, episode) it was explained in, since the same term can
/// legitimately come up more than once across 19 years of episodes.
private struct GlossaryGroup: Identifiable {
    let term: String
    let expansion: String?
    let definition: String
    let mentions: [Corpus.GlossaryTermResult]
    var id: String { term.lowercased() }

    /// Groups an already-sorted (by `term`, case-insensitively) flat result list into one
    /// entry per distinct term -- a single left-to-right pass, mirroring
    /// GlossaryContent.grouped's identical "sorted input, group adjacent matches" shape.
    static func grouped(from results: [Corpus.GlossaryTermResult]) -> [GlossaryGroup] {
        var groups: [GlossaryGroup] = []
        for result in results {
            if let last = groups.last, last.term.caseInsensitiveCompare(result.term) == .orderedSame {
                groups[groups.count - 1] = GlossaryGroup(
                    term: last.term,
                    expansion: last.expansion ?? result.expansion,
                    // Longest definition wins as the representative one -- with several
                    // independently-written definitions for the same term, the longest is a
                    // reasonable proxy for "most complete" without needing another Claude call
                    // just to pick or merge one.
                    definition: result.definition.count > last.definition.count ? result.definition : last.definition,
                    mentions: last.mentions + [result]
                )
            } else {
                groups.append(GlossaryGroup(term: result.term, expansion: result.expansion, definition: result.definition, mentions: [result]))
            }
        }
        return groups
    }
}

private struct GlossaryContent: View {
    @State private var allTerms: [Corpus.GlossaryTermResult] = []
    @State private var query = ""
    @State private var expandedTerm: String?

    private var groups: [GlossaryGroup] {
        GlossaryGroup.grouped(from: allTerms)
    }

    private var filtered: [GlossaryGroup] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let needle = query.lowercased()
        return groups.filter {
            $0.term.lowercased().contains(needle)
                || ($0.expansion?.lowercased().contains(needle) ?? false)
                || $0.definition.lowercased().contains(needle)
        }
    }

    // Groups the (already alphabetically-sorted) filtered list under its first letter, in a
    // single left-to-right pass -- an A-Z jargon list reads a lot more like a real dictionary
    // with section headers than as one undifferentiated scroll.
    private var lettered: [(letter: String, groups: [GlossaryGroup])] {
        var result: [(String, [GlossaryGroup])] = []
        for group in filtered {
            let firstChar = group.term.prefix(1)
            // A single "#" section for every digit-led term ("128K Mac", "68k", "32-bit
            // clean") -- otherwise each distinct leading digit (1, 2, 3, 6...) got its own
            // one-entry section, which reads as visual noise rather than a real A-Z grouping.
            let letter = firstChar.first?.isNumber == true ? "#" : firstChar.uppercased()
            if result.last?.0 == letter {
                result[result.count - 1].1.append(group)
            } else {
                result.append((letter, [group]))
            }
        }
        return result
    }

    var body: some View {
        #if os(macOS)
        ClassicScrollView {
            innerContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ScrollView {
            innerContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    private var innerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE RETROMACCAST GLOSSARY")
                    .font(.chicago(17))
                    .foregroundStyle(Retro.amberText)
                Text("A field guide to vintage Mac jargon -- the acronyms, control panels, and startup chimes James and John assume you already know.")
                    .font(.system(size: 12))
                    .foregroundStyle(Retro.mutedText)
            }

            searchField

            if allTerms.isEmpty {
                Text("No terms mined yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Retro.mutedText)
                    .padding(.top, 8)
            } else if filtered.isEmpty {
                Text("No terms match \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 13))
                    .foregroundStyle(Retro.mutedText)
                    .padding(.top, 8)
            } else {
                ForEach(lettered, id: \.letter) { section in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(section.letter)
                            .font(.chicago(11))
                            .foregroundStyle(Retro.mutedText)
                            .padding(.bottom, 6)
                        VStack(spacing: 0) {
                            ForEach(Array(section.groups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 { Divider() }
                                GlossaryRow(
                                    group: group,
                                    isExpanded: expandedTerm == group.id,
                                    onToggle: {
                                        withAnimation(.snappy) {
                                            expandedTerm = (expandedTerm == group.id) ? nil : group.id
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Retro.cardBorder, lineWidth: 1))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            if allTerms.isEmpty {
                allTerms = Corpus.shared.glossaryTerms()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .corpusDidReload)) { _ in
            allTerms = Corpus.shared.glossaryTerms()
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Retro.mutedText)
            TextField("Search terms", text: $query)
                .font(.chicago(13))
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Retro.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Color.white)
        .overlay(Rectangle().stroke(Color.black, lineWidth: 1))
    }
}

/// One term -- collapsed to just its headword until tapped, matching the tap-to-reveal
/// interaction already established for InlinePlayer elsewhere (MuseumMomentCard,
/// TriviaCompactRow).
private struct GlossaryRow: View {
    let group: GlossaryGroup
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(group.term)
                        .font(.chicago(14))
                        .foregroundStyle(.black)
                    if let expansion = group.expansion {
                        Text(expansion)
                            .font(.system(size: 12))
                            .italic()
                            .foregroundStyle(Retro.mutedText)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Retro.mutedText)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.definition)
                        .font(.system(size: 13))
                        .foregroundStyle(.black)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("EXPLAINED ON THE SHOW")
                            .font(.chicago(10))
                            .foregroundStyle(Retro.mutedText)
                            .padding(.bottom, 4)
                        ForEach(Array(group.mentions.enumerated()), id: \.element.id) { index, mention in
                            if index > 0 { Divider() }
                            GlossaryMentionRow(mention: mention)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
    }
}

/// One episode where a term was explained -- a play button only when a real moment resolved
/// (`mention.contextStartMs != nil`), otherwise just the episode title as a plain citation.
/// Never implies a jump that isn't real -- see GlossaryTermResult's doc comment.
private struct GlossaryMentionRow: View {
    let mention: Corpus.GlossaryTermResult
    @EnvironmentObject private var player: PlayerViewModel

    private var isActive: Bool { player.activeEpisodeId == mention.episode.id }
    private var hasMoment: Bool { mention.contextStartMs != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasMoment {
                Button {
                    withAnimation(.snappy) {
                        if isActive {
                            player.collapse()
                        } else {
                            player.playInContext(mention)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(mention.episode.title)
                            .font(.chicago(12))
                            .lineLimit(1)
                            .foregroundStyle(.black)
                        Spacer(minLength: 8)
                        Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                            .foregroundStyle(Retro.amberText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(mention.episode.title)
                    .font(.chicago(12))
                    .lineLimit(1)
                    .foregroundStyle(Retro.mutedText)
            }

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    GlossaryView()
        .environmentObject(PlayerViewModel())
        .environmentObject(AppearanceManager())
}
