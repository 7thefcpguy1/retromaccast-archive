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

    /// Escapes a string for safe embedding inside a single-quoted JavaScript string literal.
    /// Used anywhere a JS template below interpolates a value that traces back to real data
    /// (a video id from `Corpus`, a CSS filter string) rather than a hardcoded literal --
    /// without this, a value containing a `'`, `\`, or `</script>` could break out of the
    /// string literal (or the `<script>` block itself) and run arbitrary JS in the page. Not
    /// currently reachable in practice (video ids are regex-shaped `[A-Za-z0-9_-]{11}` by the
    /// time they reach here, and the app's own single CSS-filter caller passes a hardcoded
    /// constant), but every one of these values ultimately originates from the downloaded
    /// corpus, not a compile-time literal, so a malformed or corrupted entry there shouldn't
    /// be able to inject script.
    private static func jsStringLiteral(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "</", with: "<\\/")
    }

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

    /// Stops whatever's currently playing (via `stop()`) -- called from the owning view's
    /// `.onDisappear`, which fires on every tab switch away from Videos. Confirmed live this
    /// session that `VideosView`'s `@StateObject` (and its `@State` selection) survives a tab
    /// switch -- `.onDisappear`/`.onAppear` fire on visibility, but this is the *same* model
    /// instance for the whole app session, not a one-time final teardown -- so this
    /// deliberately does NOT remove the script message handler (an earlier version of this
    /// method did; confirmed live that permanently killed the JS->Swift bridge on the very
    /// first tab switch, since nothing ever re-adds it, leaving the tab in a black, unplayable
    /// state on return). `WKUserContentController.add(self, name:)` does hold a strong
    /// reference back to this model (model -> webView -> controller -> model, a real cycle
    /// `deinit` alone could never break), but since this object lives for the app's entire
    /// session regardless, that cycle is harmless -- there's no earlier point where it's
    /// actually supposed to be freed.
    func teardown() {
        stop()
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
                videoId: '\(Self.jsStringLiteral(id))',
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
        // Started after loadHTMLString, not before -- starting it first left a narrow window
        // where the very first tick(s) could still read the *previous* video's `player` JS
        // var (the old page's DOM/JS context is still live until the new page finishes
        // loading over it). Polling's own `player &&` guards already make it safe to run
        // before the new page's `player` var exists, so there's no reason to also risk it
        // reading the old one.
        startPolling()
    }

    func play() { webView.evaluateJavaScript("player.playVideo();") }
    func pause() { webView.evaluateJavaScript("player.pauseVideo();") }
    func togglePlayPause() { isPlaying ? pause() : play() }

    /// Unloads whatever video is currently playing and resets to the idle state -- called
    /// when the selection is cleared (year changed, "-- Select a video --" picked, or the
    /// window's close box clicked). `loadVideo`'s own reset only ever ran on the way INTO a
    /// new video; clearing the selection back to nil skipped it entirely, so the previously
    /// loaded video (and its polling timer) just kept running -- invisibly, behind the idle
    /// placeholder image, since the webview itself isn't torn down just because SwiftUI
    /// stops rendering it. Confirmed live: play/pause and the scrubber kept driving that
    /// stale video's real playback (including audible sound) with no video selected at all.
    /// Reloading a blank page (not just calling `pause()`) actually discards the YT player
    /// instance, rather than leaving it paused-but-loaded and quietly consuming resources.
    func stop() {
        stopPolling()
        isReady = false
        isPlaying = false
        currentTime = 0
        duration = 0
        webView.loadHTMLString("<!DOCTYPE html><html><body style=\"margin:0;background:#000;\"></body></html>", baseURL: nil)
    }

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
        webView.evaluateJavaScript("document.documentElement.style.filter = '\(Self.jsStringLiteral(value))';")
    }

    /// Polls time/duration/play-state together on a timer -- the IFrame API has no push-based
    /// time-update event (unlike AVPlayer's addPeriodicTimeObserver, used for the app's own
    /// audio player in PlayerViewModel.setupTimeObserver), and this is also the actual source
    /// of truth for `isReady`/`isPlaying`/`duration` now, not just `currentTime`: confirmed
    /// this session that the one-shot 'ready'/'stateChange' postMessage calls (see
    /// WKScriptMessageHandler below) can be delayed by a real, if uncommon, race on a
    /// freshly-loaded page -- the underlying YouTube player was demonstrably already playing
    /// while those messages hadn't arrived yet, leaving the play/pause icon and scrubber stuck
    /// at their initial state for 15+ seconds. Called unconditionally from `loadVideo` (not
    /// gated behind 'ready' first), and the guarded `player &&` checks below make it safe to
    /// start polling before the JS `player` var even exists yet -- so a dropped message can no
    /// longer strand the UI the way it did before.
    private static let pollJS = """
        (function() {
            if (!player) { return null; }
            return JSON.stringify({
                t: (player.getCurrentTime ? player.getCurrentTime() : null),
                d: (player.getDuration ? player.getDuration() : null),
                s: (player.getPlayerState ? player.getPlayerState() : null)
            });
        })();
        """

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // One JS round-trip per tick, not three sequential ones -- each
                // evaluateJavaScript call is a real WKWebView IPC hop, so three awaited calls
                // back-to-back nearly tripled this timer's real-world latency for no benefit;
                // the three values were always read together anyway.
                guard let json = try? await self.webView.evaluateJavaScript(Self.pollJS) as? String,
                      let data = json.data(using: .utf8),
                      let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                if let seconds = result["t"] as? Double {
                    self.currentTime = seconds
                }
                if let newDuration = result["d"] as? Double, newDuration > 0 {
                    self.duration = newDuration
                }
                if let state = result["s"] as? Int {
                    // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
                    self.isPlaying = (state == 1)
                    if !self.isReady {
                        self.isReady = true
                        self.applyCaptionsState()
                    }
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
    /// A best-effort *fast path* only now -- `startPolling()` (see its doc comment) is the
    /// actual source of truth, so a message arriving late or not at all just costs up to one
    /// 0.25s poll interval of latency rather than stranding the UI.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if let newDuration = body["duration"] as? Double, newDuration > 0 {
            duration = newDuration
        }
        switch type {
        case "ready":
            isReady = true
            applyCaptionsState()
        case "stateChange":
            guard let state = body["state"] as? Int else { return }
            // YT.PlayerState: -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
            isPlaying = (state == 1)
            if isReady == false { isReady = true; applyCaptionsState() }
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
            webView.evaluateJavaScript("document.documentElement.style.filter = '\(Self.jsStringLiteral(cssFilter))';")
        }
    }
}
