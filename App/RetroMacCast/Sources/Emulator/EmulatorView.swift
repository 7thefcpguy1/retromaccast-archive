import SwiftUI
import WebKit

/// A real classic Mac, right in the app -- backed by Infinite Mac (infinitemac.org), a free,
/// open project that runs Basilisk II / SheepShaver / Mini vMac compiled to WebAssembly and
/// sources ROMs/system software itself. This just displays their hosted page in a WebView;
/// no emulator code ships in this app, which is what keeps this simple (no GPL exposure, no
/// asking the user for a ROM). Loads the full site (release picker and all) rather than a
/// fixed-size /embed instance -- letting the user pick their own machine/OS is the fun part.
struct EmulatorView: View {
    @EnvironmentObject private var appearance: AppearanceManager
    @StateObject private var webModel = WebViewModel()
    private static let infiniteMacURL = URL(string: "https://infinitemac.org")!

    var body: some View {
        NavigationStack {
            ZStack {
                appearance.theme.color.ignoresSafeArea()
                #if os(macOS)
                // Capped, not unlimited (an earlier version had no cap at all, which left an
                // awkward dead zone on the right once the app window was resized wide, since
                // infinitemac.org's own page layout doesn't stretch past roughly this width
                // and is left- rather than center-aligned within whatever viewport it's given).
                // 1200 is comfortably past what its widest sub-page needs (the LLM-driven
                // "Infinite Monkey" mode, the original reason the old 820 cap was too narrow),
                // so both problems -- content clipped, and content stranded in a sea of empty
                // window -- are covered by the same number.
                FinderWindowChrome(title: "Emulators", statusText: "Powered by Infinite Mac") {
                    VStack(spacing: 0) {
                        BrowserToolbar(webModel: webModel, homeURL: Self.infiniteMacURL)
                        Divider()
                        WebView(model: webModel)
                            .frame(minHeight: 480, maxHeight: .infinity)
                    }
                }
                // Height capped too (see SearchView's matching comment), not .infinity.
                .frame(maxWidth: 1360, maxHeight: 780)
                .frame(maxWidth: .infinity)
                .padding(24)
                #else
                VStack(spacing: 0) {
                    BrowserToolbar(webModel: webModel, homeURL: Self.infiniteMacURL)
                    Divider()
                    WebView(model: webModel)
                }
                #endif
            }
            .navigationTitle("Emulators")
            .onAppear {
                // Guard so switching tabs and back doesn't reload from scratch, losing
                // whatever machine/session the user had running.
                if webModel.webView.url == nil {
                    webModel.load(Self.infiniteMacURL)
                }
            }
        }
    }
}

/// Back/forward/home controls for the embedded browser -- without this, following any link
/// off the Infinite Mac picker page (which the site itself does, e.g. into "Infinite Monkey"
/// mode) was a dead end: no back button, and macOS's WKWebView doesn't enable its
/// swipe-to-go-back gesture by default either.
private struct BrowserToolbar: View {
    @ObservedObject var webModel: WebViewModel
    let homeURL: URL

    var body: some View {
        HStack(spacing: 16) {
            Button { webModel.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!webModel.canGoBack)

            Button { webModel.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!webModel.canGoForward)

            Button { webModel.load(homeURL) } label: {
                Image(systemName: "house")
            }

            Spacer()

            if webModel.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(Retro.amberText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
    }
}

/// Owns the single long-lived `WKWebView` instance and tracks its navigation state, so both
/// the `WebView` representable and the toolbar buttons above can share one source of truth --
/// `canGoBack`/`canGoForward` drive the buttons' enabled state, refreshed on every navigation
/// event via the `WKNavigationDelegate` callbacks below.
@MainActor
final class WebViewModel: NSObject, ObservableObject {
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false

    let webView: WKWebView

    override init() {
        webView = WKWebView()
        super.init()
        webView.navigationDelegate = self
        #if os(macOS)
        // A natural bonus alongside the explicit buttons -- trackpad two-finger swipe to go
        // back, matching how every other browser on the Mac behaves. Off by default on
        // WKWebView, unlike Safari.
        webView.allowsBackForwardNavigationGestures = true
        #endif
    }

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
}

extension WebViewModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }

    // A pre-commit failure (no network, host unreachable) calls this instead of didFail --
    // without it, isLoading never clears and the toolbar's spinner runs forever.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
    }
}

#if os(macOS)
private struct WebView: NSViewRepresentable {
    @ObservedObject var model: WebViewModel

    func makeNSView(context: Context) -> WKWebView {
        model.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct WebView: UIViewRepresentable {
    @ObservedObject var model: WebViewModel

    func makeUIView(context: Context) -> WKWebView {
        model.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

#Preview {
    EmulatorView()
        .environmentObject(AppearanceManager())
}
