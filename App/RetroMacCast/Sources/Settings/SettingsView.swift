import SwiftUI

/// A normal-looking macOS Preferences window (native Form/Section chrome, not the custom
/// FinderWindowChrome used elsewhere) -- a Settings window is expected to behave and look like
/// every other Mac app's Preferences window, not like a piece of retro content.
struct SettingsView: View {
    @EnvironmentObject private var updateManager: CorpusUpdateManager
    @EnvironmentObject private var appearance: AppearanceManager

    var body: some View {
        TabView {
            UpdatesSettingsTab()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
            BackgroundSettingsTab()
                .tabItem {
                    Label("Background", systemImage: "paintpalette")
                }
            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 440, height: 460)
        // The rest of the app forces light appearance too (RootTabView) -- amberText and
        // every other color here were tuned against a light/cream background, never checked
        // against Dark Mode's near-black Form backgrounds. This scene had been missing that
        // same override, so a user on system Dark Mode got the low-contrast brown-on-black
        // this fixes.
        .preferredColorScheme(.light)
    }
}

private struct UpdatesSettingsTab: View {
    @EnvironmentObject private var updateManager: CorpusUpdateManager

    var body: some View {
        Form {
            Section("Current Archive") {
                LabeledContent("Episodes") {
                    Text(updateManager.currentEpisodeCount.map { $0.formatted(.number.grouping(.automatic)) } ?? "—")
                }
                LabeledContent("Latest Episode") {
                    Text(updateManager.currentLatestEpisodeTitle ?? "—")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Section("Check for New Episodes") {
                LabeledContent("Last Checked", value: lastCheckedText)

                HStack(spacing: 10) {
                    Button {
                        Task { await updateManager.checkForUpdate() }
                    } label: {
                        if updateManager.isChecking || updateManager.isDownloading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 60)
                        } else {
                            Text("Check Now")
                                .frame(width: 60)
                        }
                    }
                    .disabled(updateManager.isChecking || updateManager.isDownloading)

                    if let status = updateManager.statusMessage {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Checks automatically about once a week. New episodes are transcribed, made searchable, and sorted into the right Museum categories -- no manual step needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var lastCheckedText: String {
        guard let date = updateManager.lastCheckedDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Links out to the show's real presence -- retromaccast.libsyn.com itself surfaces exactly
/// these (a Facebook group, an X/Twitter account, a YouTube channel, an email address, and
/// its RSS feed) in its own header, so this mirrors that rather than inventing a different
/// set. All URLs confirmed directly against the live site rather than guessed. The tagline
/// ("They're not old, they're retro.") is the show's own -- pulled from its site banner --
/// distinct from this app's own "keeping it retro for N days" line on the Home tab, which
/// stays as-is.
private struct AboutSettingsTab: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image("RMCMascot")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)
                    Text("\u{201C}They\u{2019}re not old, they\u{2019}re retro.\u{201D}")
                        .font(.chicago(14))
                        .foregroundStyle(Retro.amberText)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Follow the Show") {
                Link(destination: URL(string: "https://www.retromaccast.com")!) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: URL(string: "https://www.facebook.com/groups/92194848507/")!) {
                    Label("Facebook Group", systemImage: "person.2")
                }
                Link(destination: URL(string: "https://twitter.com/retromaccast")!) {
                    Label("X (Twitter)", systemImage: "at")
                }
                Link(destination: URL(string: "https://www.youtube.com/retromaccast")!) {
                    Label("YouTube", systemImage: "play.rectangle")
                }
                Link(destination: URL(string: "mailto:retromaccast@gmail.com")!) {
                    Label("Email the Show", systemImage: "envelope")
                }
                Link(destination: URL(string: "http://feeds.libsyn.com/18336/rss")!) {
                    Label("RSS Feed", systemImage: "dot.radiowaves.left.and.right")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// A swatch grid, not a Form -- real classic Mac OS's own Desktop Patterns control panel was
/// exactly this shape (a grid of pattern squares to click), and swatches genuinely need to be
/// seen as color, not read as a row of text like the Updates tab's settings do.
private struct BackgroundSettingsTab: View {
    @EnvironmentObject private var appearance: AppearanceManager

    private static let columns = [GridItem(.adaptive(minimum: 88), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pick a desktop background evoking a different era of Apple hardware -- the window chrome stays the same, just the backdrop changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Self.columns, spacing: 16) {
                    ForEach(DesktopTheme.all) { theme in
                        Button {
                            appearance.select(theme)
                        } label: {
                            ThemeSwatch(theme: theme, isSelected: appearance.theme.id == theme.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
    }
}

private struct ThemeSwatch: View {
    let theme: DesktopTheme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.color)
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.black.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .background(Circle().fill(.white))
                            .offset(x: 5, y: -5)
                    }
                }

            Text(theme.name)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
            Text(theme.era)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 88)
    }
}

#Preview {
    SettingsView()
        .environmentObject(CorpusUpdateManager())
        .environmentObject(AppearanceManager())
}
