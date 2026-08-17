import Foundation
import WebKit

/// Owns a `WKWebView` that hosts the real YouTube IFrame Player API (not a bare `<iframe>`),
/// so `QuickTimePlayerChrome`'s custom controller bar can drive and observe actual playback
/// state instead of just displaying YouTube's own controls. This is a dedicated model, not an
/// extension of `EmulatorView`'s `WebViewModel` -- that class was built for simple navigation
/// + one-way JS injection with no message bridge, and bolting a `WKScriptMessageHandler` onto
/// it would mean either polluting `EmulatorView`'s webview with a handler it never uses, or
/// branching its behavior by caller. The two consumers now want genuinely different things.
@MainActor
final class YouTubePlayerModel: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isReady = false
    @Published private(set) var volume: Double = 100 // 0-100, matches the YT API's own scale

    let webView: WKWebView
    private var cssFilter: String?
    // Off by default (also reflected in loadVideo's own cc_load_policy: 0), reapplied
    // whenever the player actually becomes ready -- cc_load_policy only governs the very
    // first load, so relying on it alone doesn't reliably keep captions off if the video
    // itself defaults to showing them; explicitly clearing the caption track via the JS
    // API on every "ready" is what actually holds it off.
    private var captionsEnabledState = false
    private var pollTimer: Timer?
    private let controller = WKUserContentController()
    private static let messageHandlerName = "playerBridge"

    override init() {
        // WKWebView snapshots its configuration at construction time -- assigning
        // config.userContentController *after* creating the WKWebView (the previous, broken
        // version of this code) silently has no effect at all, because the web view already
        // copied the configuration by then. The controller (with its message handler already
        // added) has to be wired up before the WKWebView is constructed.
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // Off by default on WKWebView -- without this, a fresh page load requires a real
        // in-page user gesture before ANY media can play, which is exactly what forced the
        // extra click on YouTube's own play icon after picking a video from the dropdown.
        // A SwiftUI Button tap outside the webview doesn't count as an in-page gesture, so
        // this has to be relaxed for loadVideo's autoplay/explicit playVideo() call to work.
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(self, name: Self.messageHandlerName)
        webView.navigationDelegate = self
    }

    /// `WKUserContentController.add(self, name:)` above holds a *strong* reference to its
    /// handler, and this model also owns the `WKWebView` that owns that controller -- a real
    /// reference cycle (model -> webView -> controller -> model). That means `deinit` would
    /// never actually fire on its own (the whole point of a cycle is nothing calls it), so
    /// cleanup can't live there -- it has to be triggered explicitly from outside. Call this
    /// from the owning view's `.onDisappear`.
    func teardown() {
        stopPolling()
        controller.removeScriptMessageHandler(forName: Self.messageHandlerName)
    }

    /// Loads a video via the real `youtube.com/iframe_api` bootstrap (not a bare `<iframe>`),
    /// so play/pause/seek/volume can be driven for real instead of just displaying YouTube's
    /// own default controls (`controls: 0` below hides those). Same `loadHTMLString(...,
    /// baseURL:)` shape proven this session for Error 152/153 -- `baseURL` deliberately isn't
    /// youtube.com itself (that produced "Error code: 152-4"); the show's own real domain is
    /// what a legitimate embed presents as its referrer/origin.
    func loadVideo(id: String) {
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
        stopPolling()

        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>html, body { margin: 0; padding: 0; background: black; }
        #player { position: absolute; top: 0; left: 0; width: 100%; height: 100%; }</style>
        </head>
        <body>
        <div id="player"></div>
        <script src="https://www.youtube.com/iframe_api"></script>
        <script>
        var player;
        // Mirrors the model's current captionsEnabledState at load time -- captions are a
        // per-*player-instance* toggle, not baked into a specific video, so whatever the
        // CAPTIONS checkbox is currently set to should carry over to every newly loaded video.
        var desiredCaptionsEnabled = \(captionsEnabledState);
        // cc_load_policy: 0 alone isn't reliable -- some videos still show captions by
        // default regardless, because the captions module can attach AFTER onReady/
        // onStateChange already fired once. onApiChange is the IFrame API's purpose-built
        // hook for "a module just became available," fired every time a new module (like
        // captions) attaches -- checking here is the reliable place to clear it, not just
        // the ready/stateChange handlers below (those stay too, as a harmless second pass).
        function suppressCaptionsIfNeeded() {
            if (!desiredCaptionsEnabled && player && player.setOption) {
                player.setOption('captions', 'track', {});
            }
        }
        function onYouTubeIframeAPIReady() {
            player = new YT.Player('player', {
                videoId: '\(id)',
                playerVars: { autoplay: 1, controls: 0, disablekb: 1, playsinline: 1, modestbranding: 1, rel: 0, cc_load_policy: 0, iv_load_policy: 3 },
                events: {
                    onReady: function(e) {
                        // autoplay: 1 alone isn't always enough to actually start playback --
                        // this explicit call is the direct trigger (mediaTypesRequiringUserActionForPlayback
                        // = [] on the Swift side is what makes this allowed without a real click).
                        player.playVideo();
                        window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({type: 'ready', duration: player.getDuration()});
                    },
                    onError: function(e) {
                        window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({type: 'error', code: e.data});
                    },
                    onStateChange: function(e) {
                        window.webkit.messageHandlers.\(Self.messageHandlerName).postMessage({type: 'stateChange', state: e.data, duration: player.getDuration()});
                    },
                    onApiChange: function(e) {
                        suppressCaptionsIfNeeded();
                    }
                }
            });
            // Belt-and-suspenders fallback -- onApiChange doesn't fire consistently across
            // every video, so this re-checks once more shortly after load in case the
            // captions module attached without an onApiChange event at all.
            setTimeout(suppressCaptionsIfNeeded, 1500);
        }
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://www.retromaccast.com"))
    }

    func play() { webView.evaluateJavaScript("player.playVideo();") }
    func pause() { webView.evaluateJavaScript("player.pauseVideo();") }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        currentTime = max(0, seconds) // reflect immediately -- polling would otherwise lag
        webView.evaluateJavaScript("player.seekTo(\(max(0, seconds)), true);")
    }

    /// The IFrame API has no true single-frame step -- this nudges by 1/30s (a reasonable
    /// stand-in for "one frame" at a typical 30fps video), the closest approximation available.
    func stepFrame(forward: Bool) {
        seek(to: currentTime + (forward ? 1.0 / 30 : -1.0 / 30))
    }

    func setVolume(_ v: Double) {
        volume = v
        webView.evaluateJavaScript("player.setVolume(\(v));")
    }

    /// Turns YouTube's closed captions on/off via the IFrame API's caption module directly,
    /// not just the `cc_load_policy` playerVar (which only affects the very first load, and
    /// isn't reliable enough on its own -- some videos still show captions by default
    /// regardless). Off by default; this is what the "CAPTIONS" checkbox in VideosView
    /// calls.
    func setCaptionsEnabled(_ enabled: Bool) {
        captionsEnabledState = enabled
        applyCaptionsState()
    }

    private func applyCaptionsState() {
        let js = captionsEnabledState
            ? "if (player && player.setOption) { player.setOption('captions', 'track', {languageCode: 'en'}); }"
            : "if (player && player.setOption) { player.setOption('captions', 'track', {}); }"
        webView.evaluateJavaScript(js)
    }

    /// Injects a CSS `filter` onto the page's root element, or clears it when `css` is nil --
    /// ported from EmulatorView's WebViewModel.applyCSSFilter (now removed there since nothing
    /// else uses it). Applied via JS rather than a native CoreImage/Metal pass because the
    /// content being filtered (a YouTube embed) is a cross-origin iframe -- there's no
    /// pixel-level access to it from outside, only DOM/CSS-level control.
    func applyCSSFilter(_ css: String?) {
        cssFilter = css
        let value = css ?? "none"
        webView.evaluateJavaScript("document.documentElement.style.filter = '\(value)';")
    }

    /// Polls `getCurrentTime()` on a timer, since the IFrame API has no push-based time-update
    /// event (unlike AVPlayer's addPeriodicTimeObserver, used for the app's own audio player in
    /// PlayerViewModel.setupTimeObserver) -- the closest equivalent available for a JS-hosted
    /// player.
    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let result = try? await self.webView.evaluateJavaScript("player.getCurrentTime();")
                if let seconds = result as? Double {
                    self.currentTime = seconds
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

extension YouTubePlayerModel: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if let newDuration = body["duration"] as? Double, newDuration > 0 {
            // Re-read on every message, not just "ready" -- getDuration() can return 0 before
            // metadata is fully loaded for some videos, so onReady alone isn't always enough.
            duration = newDuration
        }
        switch type {
        case "ready":
            isReady = true
            startPolling()
            applyCaptionsState()
        case "stateChange":
            guard let state = body["state"] as? Int else { return }
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
            isPlaying = (state == 1)
            if isReady == false { isReady = true; startPolling(); applyCaptionsState() }
        case "error":
            // Confirmed this session: YouTube error 101/150 (embedding disabled by the
            // uploader) fires here for many of this channel's videos -- YouTube renders its
            // own "Watch on YouTube" fallback inside the iframe in that case, so there's
            // nothing to recover client-side. Not specially surfaced in the UI; the
            // controller bar just stays at its default paused state (see loadVideo's doc
            // comment).
            break
        default:
            break
        }
    }
}

extension YouTubePlayerModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A fresh page load resets the DOM, which would otherwise silently drop the 8-bit
        // look the moment a new video loads while the toggle is still on.
        if let cssFilter {
            webView.evaluateJavaScript("document.documentElement.style.filter = '\(cssFilter)';")
        }
    }
}
