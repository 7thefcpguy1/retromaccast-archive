import Foundation
import AVFoundation
import RMCCore

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var activeEpisodeId: Int?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTimeMs: Int = 0
    @Published var durationMs: Int?
    @Published var errorMessage: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var stopAtMs: Int?
    private let crawler = LibsynCrawler()
    private var loadToken = UUID()

    init() {
        setvbuf(stdout, nil, _IONBF, 0) // stdout is fully buffered when not a tty, and this
        // app never exits to flush it -- keep unbuffered so future debug prints show up live.
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func playInContext(_ result: Corpus.SearchResult) {
        guard let startMs = result.contextStartMs else { return }
        load(episodeId: result.episode.id, startMs: startMs, stopAtMs: result.contextEndMs)
    }

    func playInContext(_ item: Corpus.CollectionItemResult) {
        guard let startMs = item.contextStartMs else { return }
        load(episodeId: item.episode.id, startMs: startMs, stopAtMs: item.contextEndMs)
    }

    /// Plays a whole episode from the start -- for entry points like "On This Day" that
    /// surface a full episode rather than a specific transcript-matched moment.
    func playEpisode(_ episode: Episode) {
        load(episodeId: episode.id, startMs: 0, stopAtMs: nil)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    /// Called when the user finishes dragging the scrubber -- seeks and resumes playback
    /// from wherever they dropped it, whether that's earlier, later, or back to 0:00.
    func seek(toMs ms: Int) {
        guard let player else { return }
        currentTimeMs = ms
        player.seek(to: CMTime(seconds: Double(ms) / 1000, preferredTimescale: 600))
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    func collapse() {
        loadToken = UUID() // invalidate any in-flight load
        player?.pause()
        removeTimeObserver()
        player = nil
        stopAtMs = nil
        activeEpisodeId = nil
        isPlaying = false
        isLoading = false
        durationMs = nil
        errorMessage = nil
    }

    private func load(episodeId: Int, startMs: Int, stopAtMs: Int?) {
        collapse()
        activeEpisodeId = episodeId
        isLoading = true
        let token = UUID()
        loadToken = token

        Task {
            do {
                guard let urlString = try await crawler.resolveAudioURL(itemId: episodeId),
                      let url = URL(string: urlString) else {
                    guard loadToken == token else { return }
                    errorMessage = "Couldn't find audio for this episode."
                    isLoading = false
                    return
                }
                guard loadToken == token else { return } // user moved on while we were resolving

                let asset = AVURLAsset(url: url)
                // Force the asset to resolve before seeking -- seeking right after creating
                // the AVPlayerItem races its internal readiness over the network. Lose that
                // race (slower connection, bigger file) and the seek silently no-ops, so
                // playback starts from 0:00 instead of the intended clip position. Loading
                // duration first forces AVFoundation to fully resolve the asset, so the
                // AVPlayerItem created from it becomes ready near-instantly.
                let duration = try? await asset.load(.duration)
                guard loadToken == token else { return }

                let item = AVPlayerItem(asset: asset)
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer
                self.stopAtMs = stopAtMs

                let startTime = CMTime(seconds: Double(startMs) / 1000, preferredTimescale: 600)
                var seeked = await newPlayer.seek(to: startTime)
                guard loadToken == token else { return }
                if !seeked {
                    // Interrupted (e.g. still buffering) -- one retry rather than silently
                    // falling back to 0:00.
                    seeked = await newPlayer.seek(to: startTime)
                    guard loadToken == token else { return }
                }

                newPlayer.play()
                isPlaying = true
                isLoading = false
                setupTimeObserver(player: newPlayer)

                if let duration, duration.isNumeric {
                    durationMs = Int(duration.seconds * 1000)
                }
            } catch {
                guard loadToken == token else { return }
                errorMessage = "Couldn't load audio: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    private func setupTimeObserver(player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let ms = Int(time.seconds * 1000)
            self.currentTimeMs = ms
            // Checked here rather than via AVPlayer's addBoundaryTimeObserver -- that API
            // proved unreliable in testing (confirmed via logging: it silently never fired
            // even with a normal ~12s context window). This periodic observer is proven to
            // fire reliably, so the stop condition rides along with it.
            if let stopAtMs = self.stopAtMs, ms >= stopAtMs {
                self.stopAtMs = nil // one-time trigger -- once hit, playback is free to
                // continue past it without stopping again (e.g. if the user later scrubs
                // back over the same point).
                self.player?.pause()
                self.isPlaying = false
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }
}
