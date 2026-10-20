import SwiftUI
import WebKit

// Holds the live WebView so a dynetremote:// deep link can reach the page after Dropbox auth.
enum AuthInbox {
    static weak var webView: WKWebView?
    static var pendingCode: String?   // code that arrived before the WebView was ready

    static func deliver(_ code: String) {
        let safe = code.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        guard let wv = webView else { pendingCode = code; return }
        wv.evaluateJavaScript("window.__dbxDeepCode && window.__dbxDeepCode('\(safe)')", completionHandler: nil)
    }

    // Accepts dynetremote://auth?code=XXXX (or ...#code=XXXX) and hands the code to the page.
    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "dynetremote" else { return }
        var code: String?
        if let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value {
            code = c
        } else if let frag = url.fragment {
            code = URLComponents(string: "?\(frag)")?.queryItems?.first(where: { $0.name == "code" })?.value
        }
        if let code = code, !code.isEmpty { deliver(code) }
    }
}

@main
struct DyNetRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            WebHost().ignoresSafeArea()
                .onOpenURL { url in AuthInbox.handle(url) }
        }
    }
}

struct WebHost: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true

        let ucc = WKUserContentController()
        // Tell the page it runs inside the native host, and hand it the saved settings before any script runs.
        let boot = "window.__DYNET_NATIVE='wk';window.__DYNET_TCP=true;window.__KV=\(Bridge.kvJSON());"
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "dynet")
        cfg.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        context.coordinator.webView = wv
        AuthInbox.webView = wv

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        // If a deep-link code arrived before the page was ready, deliver it once loaded.
        if let code = AuthInbox.pendingCode {
            AuthInbox.pendingCode = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AuthInbox.deliver(code) }
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
