import SwiftUI
import WebKit

/// What the button page did. The app learns this from navigations and responses only:
/// running script in the page would disable Apple Pay.
enum ApplePayEvent {
    /// The button page loaded and the button is showing.
    case ready
    /// The customer approved the sheet and the page left for Hesabe to charge.
    case processing
    /// The attempt ended. Ask this done URL how it went.
    case finished(URL)
    /// Hesabe may have charged the card, but the page failed before saying which attempt.
    case unconfirmed
    /// The customer closed the sheet without paying.
    case cancelled
    /// The button page didn't load. Nothing was charged.
    case failed
}

/// A web view that shows only the button page and reports what happens in it.
struct ApplePayWebView: UIViewRepresentable {
    let orderID: String
    var onEvent: (ApplePayEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEvent: onEvent) }

    func makeUIView(context: Context) -> WKWebView {
        // Never add a WKUserScript or call evaluateJavaScript on this web view:
        // either one disables Apple Pay for the page.
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        webView.load(URLRequest(url: applePayBase.appending(path: "button/\(orderID)")))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onEvent: (ApplePayEvent) -> Void
        private var reference: String? // this attempt's, from the button page's response
        private var shown = false       // the button page finished loading
        private var charging = false    // the page left for Hesabe after the sheet
        private var ended = false

        init(onEvent: @escaping (ApplePayEvent) -> Void) { self.onEvent = onEvent }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame != false,
                  let url = action.request.url else { return decisionHandler(.allow) }

            if url.absoluteString.hasPrefix(applePayBase.appending(path: "done/").absoluteString) {
                end(.finished(url))
                decisionHandler(.cancel)
            } else if url.absoluteString.hasPrefix(applePayBase.appending(path: "cancelled").absoluteString) {
                end(.cancelled)
                decisionHandler(.cancel)
            } else {
                // Anything after the button page is Hesabe charging the card. The view
                // hides the web view from here on, so Hesabe's pages never show in the slot.
                if shown && !charging {
                    charging = true
                    onEvent(.processing)
                }
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard response.isForMainFrame,
                  let http = response.response as? HTTPURLResponse else { return decisionHandler(.allow) }

            if !shown {
                reference = http.value(forHTTPHeaderField: "X-Payment-Reference")
            }
            if http.statusCode >= 400 {
                loadFailed()
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if !shown && !ended {
                shown = true
                onEvent(.ready)
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            loadFailed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadFailed(error)
        }

        private func loadFailed(_ error: Error? = nil) {
            // A newer navigation replacing this one also reports as a failure.
            if let error = error as? URLError, error.code == .cancelled { return }

            if !charging {
                end(.failed)
            } else if let reference {
                // The card may have been charged but Hesabe's redirect never arrived:
                // ask the done route directly.
                end(.finished(applePayBase.appending(path: "done/\(reference)")))
            } else {
                end(.unconfirmed)
            }
        }

        private func end(_ event: ApplePayEvent) {
            guard !ended else { return }
            ended = true
            onEvent(event)
        }
    }
}
