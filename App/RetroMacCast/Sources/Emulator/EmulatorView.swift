import SwiftUI
import WebKit

/// A real classic Mac, right in the app -- backed by Infinite Mac (infinitemac.org), a free,
/// open project that runs Basilisk II / SheepShaver / Mini vMac compiled to WebAssembly and
/// sources ROMs/system software itself. This just displays their hosted page in a WebView;
/// no emulator code ships in this app, which is what keeps this simple (no GPL exposure, no
/// asking the user for a ROM). Loads the full site (release picker and all) rather than a
/// fixed-size /embed instance -- letting the user pick their own machine/OS is the fun part.
struct EmulatorView: View {
    private static let infiniteMacURL = URL(string: "https://infinitemac.org")!

    var body: some View {
        NavigationStack {
            ZStack {
                Retro.beige.ignoresSafeArea()
                #if os(macOS)
                FinderWindowChrome(title: "Emulator", statusText: "Powered by Infinite Mac") {
                    WebView(url: Self.infiniteMacURL)
                        .frame(minHeight: 480, maxHeight: .infinity)
                }
                .frame(maxWidth: 820, maxHeight: .infinity)
                .padding(24)
                #else
                WebView(url: Self.infiniteMacURL)
                #endif
            }
            .navigationTitle("Emulator")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link("infinitemac.org", destination: Self.infiniteMacURL)
                        .font(.caption)
                }
            }
            #endif
        }
    }
}

#if os(macOS)
private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
private struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

#Preview {
    EmulatorView()
}
