import SwiftUI

/// Shared "featured highlight" card shell -- Home's `OnThisDayHeroCard` and Trivia's
/// `TriviaHeroCard` used to each independently reimplement this exact badge + headline +
/// secondary-text + play-button + `InlinePlayer` + card-chrome structure almost verbatim.
/// What's genuinely different between the two callers (badge text, headline/secondary font
/// sizes and line limits, what the secondary text actually shows -- Home's own episode show
/// notes vs. Trivia's episode-title caption under a fact -- and whether a play button exists
/// at all, since Trivia's cross-episode aggregate facts have nothing to jump to) is threaded
/// through as parameters instead. `onToggle == nil` omits the play button (and, since
/// `isActive` can only ever be true when there's something to be active about, effectively
/// the `InlinePlayer` too) entirely, rather than every caller needing its own guard.
struct PlayableMomentHeroCard: View {
    let badge: String
    let primaryText: String
    let primaryFont: Font
    let primaryLineLimit: Int?
    var secondaryText: String? = nil
    var secondaryFont: Font = .system(size: 13)
    var secondaryLineLimit: Int? = nil
    var isActive: Bool = false
    var onToggle: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Text(badge)
                .font(.chicago(11))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Retro.amberText)
                .clipShape(Capsule())

            Text(primaryText)
                .font(primaryFont)
                .foregroundStyle(Retro.amberText)
                .multilineTextAlignment(.center)
                .lineLimit(primaryLineLimit)

            if let secondaryText {
                Text(secondaryText)
                    .font(secondaryFont)
                    // Fixed color, not semantic `.secondary` -- same dark-desktop-theme
                    // invisible-text bug fixed live in MuseumView.swift.
                    .foregroundStyle(Retro.mutedText)
                    .multilineTextAlignment(.center)
                    .lineLimit(secondaryLineLimit)
            }

            if let onToggle {
                Button(action: onToggle) {
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

/// Shared "tap to play/collapse this moment, show the InlinePlayer while active" row shell --
/// Home's `OnThisDayCompactRow` and Trivia's `TriviaCompactRow` used to each independently
/// reimplement this isActive/toggle/InlinePlayer/padding wrapper. The row's own tappable
/// content is genuinely different between the two callers (title + trailing date vs.
/// fact-text + inline play icon), so it isn't forced into one shared, heavily-parameterized
/// layout -- only the part that was truly identical moved here. `caption`, when given, renders
/// BELOW `content` but outside its tap target (matching TriviaCompactRow's original behavior,
/// where the episode-title line under the fact was never itself part of the tappable area).
/// `onToggle == nil` renders `content` bare, with no button and no tap target at all -- for
/// Trivia's cross-episode aggregate facts, which have nothing to play.
struct PlayableMomentRow<Content: View>: View {
    var isActive: Bool = false
    var onToggle: (() -> Void)? = nil
    var caption: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let onToggle {
                Button(action: onToggle) {
                    content()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                content()
            }

            caption

            if isActive {
                InlinePlayer()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
}
