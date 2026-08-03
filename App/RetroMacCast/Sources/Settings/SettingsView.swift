import SwiftUI

/// A normal-looking macOS Preferences window (native Form/Section chrome, not the custom
/// FinderWindowChrome used elsewhere) -- a Settings window is expected to behave and look like
/// every other Mac app's Preferences window, not like a piece of retro content.
struct SettingsView: View {
    @EnvironmentObject private var updateManager: CorpusUpdateManager

    var body: some View {
        TabView {
            UpdatesSettingsTab()
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .frame(width: 440, height: 280)
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

#Preview {
    SettingsView()
        .environmentObject(CorpusUpdateManager())
}
