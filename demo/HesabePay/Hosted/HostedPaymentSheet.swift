import SwiftUI
@preconcurrency import WebKit

/// KNET and card payments happen on pages the app can't replace: KNET's own PIN page,
/// the bank's 3-D Secure page. This sheet shows Hesabe's hosted flow for one attempt in a
/// full-height web view with a native bar, and ends the moment Hesabe redirects back.
@MainActor
struct HostedPaymentSheet: View {
    let attempt: PaymentAttempt
    let title: String
    let onOutcome: (PaymentOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var isFinishing = false
    @State private var isConfirmingCancel = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let url = attempt.session?.webviewURL ?? attempt.session?.paymentURL {
                    HostedWebView(url: url, returnURL: attempt.returnURL, failureURL: attempt.failureURL,
                                  progress: $progress, onEvent: handle)
                }
                if isFinishing {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Confirming with Hesabe…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if progress < 1, !isFinishing {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isConfirmingCancel = true }
                        .disabled(isFinishing)
                }
            }
            .confirmationDialog("Leave the payment?", isPresented: $isConfirmingCancel, titleVisibility: .visible) {
                Button("Leave", role: .destructive) { cancel() }
                Button("Stay", role: .cancel) {}
            } message: {
                Text("If you already confirmed on the bank's page, the app will check with Hesabe.")
            }
        }
        .interactiveDismissDisabled()
    }

    private func handle(_ event: HostedWebView.Event) {
        switch event {
        case .returned(let url):
            finish { await attempt.outcome(hesabeFinished: true, redirect: attempt.redirectPayload(in: url)) }
        case .failed(let message):
            finish {
                var outcome = await attempt.outcome(hesabeFinished: false)
                if outcome.state == .unconfirmed { outcome.message = message }
                return outcome
            }
        }
    }

    /// Leaving mid-flow: the customer may have confirmed on KNET's page already, so ask
    /// Hesabe once before calling it cancelled.
    private func cancel() {
        finish {
            let transaction = try? await attempt.client.transaction(orderReference: attempt.reference)
            if transaction != nil { return await attempt.outcome(hesabeFinished: false) }
            return PaymentOutcome(state: .cancelled, method: attempt.method, amount: attempt.amount, reference: attempt.reference)
        }
    }

    private func finish(_ resolve: @escaping () async -> PaymentOutcome) {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            let outcome = await resolve()
            onOutcome(outcome)
            dismiss()
        }
    }
}

/// A full web view for Hesabe's hosted pages. It reports only the end: the redirect to
/// the response or failure URL (stopped before it loads), or a load failure.
struct HostedWebView: UIViewRepresentable {
    enum Event {
        case returned(URL)
        case failed(String)
    }

    let url: URL
    let returnURL: URL
    let failureURL: URL
    @Binding var progress: Double
    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.observe(webView)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.view = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.observation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var view: HostedWebView
        var observation: NSKeyValueObservation?
        private var isDone = false

        init(view: HostedWebView) { self.view = view }

        func observe(_ webView: WKWebView) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor in self?.view.progress = value }
            }
        }

        private func finish(_ event: Event) {
            guard !isDone else { return }
            isDone = true
            view.onEvent(event)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            guard action.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }

            let text = url.absoluteString
            if text.hasPrefix(view.returnURL.absoluteString) || text.hasPrefix(view.failureURL.absoluteString) {
                finish(.returned(url))
                return decisionHandler(.cancel)
            }
            // A popup (target=_blank) has no target frame; load it here instead.
            if action.targetFrame == nil {
                webView.load(action.request)
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                finish(.failed("The payment page answered \(http.statusCode)."))
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finish(.failed("The payment page stopped."))
        }

        private func fail(_ error: Error) {
            let error = error as NSError
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }
            finish(.failed(error.localizedDescription))
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame?.isMainFrame != true { webView.load(action.request) }
            return nil
        }
    }
}
