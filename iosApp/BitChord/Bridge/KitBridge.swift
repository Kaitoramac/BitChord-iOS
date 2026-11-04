import Foundation
import WebKit
import os
import BitChordKit

/// `KeyValueStore` for the Kotlin side: visitor data and InnerTubeX's cipher-config cache.
final class UserDefaultsStore: NSObject, KeyValueStore {
    private let defaults: UserDefaults
    private let prefix = "kit."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func getString(key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    func putString(key: String, value: String?) {
        if let value { defaults.set(value, forKey: prefix + key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}

/// Sends the Kotlin side's diagnostics to the unified log (Console.app, subsystem `com.music.bitchord`).
final class OSLogKitLogger: NSObject, KitLogger {
    private let logger = Logger(subsystem: "com.music.bitchord", category: "kit")

    func log(level: String, tag: String, message: String) {
        switch level {
        case "error": logger.error("\(tag, privacy: .public): \(message, privacy: .public)")
        case "warning": logger.warning("\(tag, privacy: .public): \(message, privacy: .public)")
        case "info": logger.info("\(tag, privacy: .public): \(message, privacy: .public)")
        default: logger.debug("\(tag, privacy: .public): \(message, privacy: .public)")
        }
    }
}

/// The browser BotGuard runs in, for PO tokens: a hidden WKWebView whose page
/// is served as `https://www.youtube.com/`, like BitChord's Android WebView.
final class WebViewJavaScriptHost: NSObject, JavaScriptHost, WKNavigationDelegate {
    private var webView: WKWebView?
    private var pendingLoad: PageLoadCallback?

    func loadPage(html: String, baseUrl: String, callback: PageLoadCallback) {
        DispatchQueue.main.async {
            self.tearDown()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.suppressesIncrementalRendering = true
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            self.pendingLoad = callback
            webView.loadHTMLString(html, baseURL: URL(string: baseUrl))
        }
    }

    func evaluate(body: String, callback: ScriptCallback) {
        let completion: (String?, String?) -> Void = { callback.onScriptResult(result: $0, error: $1) }
        DispatchQueue.main.async {
            guard let webView = self.webView else {
                completion(nil, "BotGuard page is not loaded")
                return
            }
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let string = value as? String {
                        completion(string, nil)
                    } else if value is NSNull {
                        completion(nil, "Script returned no value")
                    } else {
                        completion(String(describing: value), nil)
                    }
                case .failure(let error):
                    let info = (error as NSError).userInfo
                    let detail = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                    completion(nil, detail)
                }
            }
        }
    }

    func reset() {
        DispatchQueue.main.async { self.tearDown() }
    }

    private func tearDown() {
        pendingLoad?.onPageLoaded(error: "Page replaced before it finished loading")
        pendingLoad = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingLoad?.onPageLoaded(error: nil)
        pendingLoad = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pendingLoad?.onPageLoaded(error: error.localizedDescription)
        pendingLoad = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pendingLoad?.onPageLoaded(error: error.localizedDescription)
        pendingLoad = nil
    }
}
