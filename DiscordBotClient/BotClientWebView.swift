import SwiftUI
import WebKit
import UIKit
import Combine

@MainActor
final class BotWebController: ObservableObject {
    @Published var isLoading = true
    @Published var currentTitle = "Discord Bot Client"
    weak var webView: WKWebView?

    enum PendingTokenOp {
        case none
        case set(String)
        case clear
    }

    var pendingTokenOp: PendingTokenOp = .none

    func loadTarget(mode: ConnectionMode, localBaseURL: URL?, customServerURL: String) {
        guard let webView = webView else { return }
        let targetURL: URL?
        switch mode {
        case .standalone:
            targetURL = localBaseURL?.appendingPathComponent("app")
        case .customServer:
            var trimmed = customServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
                trimmed = "https://" + trimmed
            }
            targetURL = URL(string: trimmed)
        }
        guard let url = targetURL else { return }

        rebuildUserScripts(for: mode, webView: webView)
        webView.load(URLRequest(url: url))
    }

    func switchBotToken(_ token: String, mode: ConnectionMode, localBaseURL: URL?, customServerURL: String) {
        let clean = KeychainBotStore.normalizeToken(token)
        pendingTokenOp = .set(clean)
        loadTarget(mode: mode, localBaseURL: localBaseURL, customServerURL: customServerURL)
    }

    func logoutBot(mode: ConnectionMode, localBaseURL: URL?, customServerURL: String) {
        pendingTokenOp = .clear
        guard let webView = webView else { return }
        let targetURL: URL?
        switch mode {
        case .standalone:
            targetURL = localBaseURL?.appendingPathComponent("login")
        case .customServer:
            var trimmed = customServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
                trimmed = "https://" + trimmed
            }
            targetURL = URL(string: trimmed)?.appendingPathComponent("login")
        }
        guard let url = targetURL else { return }
        rebuildUserScripts(for: mode, webView: webView)
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView?.reload()
    }

    func clearWebCache(completion: @escaping () -> Void) {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            LocalBotProxyServer.shared.clearCache()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func rebuildUserScripts(for mode: ConnectionMode, webView: WKWebView) {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()

        // 1. Apply pending token operation BEFORE Discord web.js runs `delete window.localStorage`
        switch pendingTokenOp {
        case .set(let token):
            let encoded = (try? JSONEncoder().encode(token)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let js = """
            (function(){
              try { window.localStorage.setItem('token', \(encoded)); } catch(e) {}
            })();
            """
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            pendingTokenOp = .none
        case .clear:
            let js = """
            (function(){
              try { window.localStorage.removeItem('token'); } catch(e) {}
            })();
            """
            ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            pendingTokenOp = .none
        case .none:
            break
        }

        // 2. When connected to an external Custom Server URL, inject our patched dbc-web-bridge.js + dbc-mobile.css!
        if mode == .customServer {
            if let bridgeURL = Bundle.main.resourceURL?.appendingPathComponent("Resources/dbc-assets/dbc-web-bridge.js"),
               let bridgeJS = try? String(contentsOf: bridgeURL, encoding: .utf8) {
                ucc.addUserScript(WKUserScript(source: bridgeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            if let cssURL = Bundle.main.resourceURL?.appendingPathComponent("Resources/dbc-assets/dbc-mobile.css"),
               let cssText = try? String(contentsOf: cssURL, encoding: .utf8) {
                let encodedCSS = (try? JSONEncoder().encode(cssText)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                let injectCSS = """
                (function(){
                  var applyCss = function(){
                    var existing = document.getElementById('dbc-native-mobile-css');
                    if (existing) { existing.textContent = \(encodedCSS); return; }
                    var st = document.createElement('style');
                    st.id = 'dbc-native-mobile-css';
                    st.textContent = \(encodedCSS);
                    (document.head || document.documentElement).appendChild(st);
                  };
                  if (document.head || document.documentElement) applyCss();
                  document.addEventListener('DOMContentLoaded', applyCss);
                })();
                """
                ucc.addUserScript(WKUserScript(source: injectCSS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
    }
}

struct BotClientWebView: UIViewRepresentable {
    @ObservedObject var controller: BotWebController
    let mode: ConnectionMode
    let localBaseURL: URL?
    let customServerURL: String

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 0.067, green: 0.071, blue: 0.078, alpha: 1.0)
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        controller.webView = webView
        context.coordinator.hasLoadedInitial = true
        controller.loadTarget(mode: mode, localBaseURL: localBaseURL, customServerURL: customServerURL)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if !context.coordinator.hasLoadedInitial && (mode == .customServer || localBaseURL != nil) {
            context.coordinator.hasLoadedInitial = true
            controller.loadTarget(mode: mode, localBaseURL: localBaseURL, customServerURL: customServerURL)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let controller: BotWebController
        var hasLoadedInitial = false

        init(controller: BotWebController) {
            self.controller = controller
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                controller.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                controller.isLoading = false
                if let title = webView.title, !title.isEmpty {
                    controller.currentTitle = title
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                controller.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                controller.isLoading = false
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                let host = url.host ?? ""
                if host == "127.0.0.1" || host == "localhost" || host == webView.url?.host {
                    webView.load(navigationAction.request)
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = UIAlertController(title: "BotClient", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
            presentAlert(alert)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = UIAlertController(title: "BotClient", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Đồng ý", style: .default) { _ in completionHandler(true) })
            presentAlert(alert)
        }

        private func presentAlert(_ alert: UIAlertController) {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController ?? scene.windows.first?.rootViewController else {
                return
            }
            var top = root
            while let next = top.presentedViewController {
                top = next
            }
            top.present(alert, animated: true)
        }
    }
}
