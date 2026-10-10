import SwiftUI
import WebKit

/// Shows claude.ai's own sign-in page and hands back the `sessionKey` cookie once it appears.
/// Uses a throwaway cookie store, so every account signs in from a clean slate.
struct ClaudeLoginView: UIViewRepresentable {
    let onSessionKey: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSessionKey: self.onSessionKey) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Present as Safari: some identity providers refuse pages that look like an embedded web view.
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        webView.uiDelegate = context.coordinator
        configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKUIDelegate {
        private let onSessionKey: (String) -> Void
        private var delivered = false

        init(onSessionKey: @escaping (String) -> Void) { self.onSessionKey = onSessionKey }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            cookieStore.getAllCookies { cookies in
                guard !self.delivered,
                      let cookie = cookies.first(where: {
                          $0.name == "sessionKey" && $0.domain.hasSuffix("claude.ai") && !$0.value.isEmpty
                      })
                else { return }
                self.delivered = true
                self.onSessionKey(cookie.value)
            }
        }

        /// Sign-in pop-ups (target=_blank / window.open) load in the same view instead of being dropped.
        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures) -> WKWebView?
        {
            webView.load(navigationAction.request)
            return nil
        }
    }
}
