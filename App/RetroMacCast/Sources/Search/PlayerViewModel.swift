import Foundation
import AVFoundation
import RMCCore

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var activeEpisodeId: Int?
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTimeMs: Int = 0
    @Published var isFullEpisode = false
    @Published var errorMessage: String?

    private var player: AVPlayer?
    private var boundaryObserver: Any?
    private var timeObserver: Any?
    private let crawler = LibsynCrawler()
    private var loadToken = UUID()

    init() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    func playInContext(_ result: Corpus.SearchResult) {
        guard let startMs = result.contextStartMs, let endMs = result.contextEndMs else { return }
        load(episodeId: result.episode.id, startMs: startMs, stopAtMs: endMs)
    }

    func playFullEpisode() {
        isFullEpisode = true
        removeBoundaryObserver()
        player?.play()
        isPlaying = true
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

    func collapse() {
        loadToken = UUID() // invalidate any in-flight load
        player?.pause()
        removeTimeObserver()
        removeBoundaryObserver()
        player = nil
        activeEpisodeId = nil
        isPlaying = false
        isLoading = false
        isFullEpisode = false
        errorMessage = nil
    }

    private func load(episodeId: Int, startMs: Int, stopAtMs: Int) {
        collapse()
        activeEpisodeId = episodeId
        isLoading = true
        isFullEpisode = false
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

                let item = AVPlayerItem(url: url)
                let newPlayer = AVPlayer(playerItem: item)
                player = newPlayer

                let startTime = CMTime(seconds: Double(startMs) / 1000, preferredTimescale: 600)
                _ = await newPlayer.seek(to: startTime)
                guard loadToken == token else { return }

                newPlayer.play()
                isPlaying = true
                isLoading = false
                setupTimeObserver(player: newPlayer)
                setupBoundary(player: newPlayer, stopAtMs: stopAtMs)
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
            self?.currentTimeMs = Int(time.seconds * 1000)
        }
    }

    private func setupBoundary(player: AVPlayer, stopAtMs: Int) {
        let boundaryTime = CMTime(seconds: Double(stopAtMs) / 1000, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundaryTime)], queue: .main) { [weak self] in
            guard let self, !self.isFullEpisode else { return }
            self.player?.pause()
            self.isPlaying = false
        }
    }

    private func removeTimeObserver() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func removeBoundaryObserver() {
        if let boundaryObserver { player?.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }
}
