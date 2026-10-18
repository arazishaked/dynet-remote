import SwiftUI
import WebKit

@main
struct DyNetRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            WebHost().ignoresSafeArea()
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

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
