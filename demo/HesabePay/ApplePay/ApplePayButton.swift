import PassKit
import SwiftUI

/// The Apple Pay button in a native frame. The button itself is WebKit's, on the hosted
/// page; everything around it is native: a stand-in while the session is created and the
/// page loads, a dimmed press, a "Processing" state while Hesabe charges, a retry.
///
/// Recreated (`.id`) by the caller for a new amount or environment.
@MainActor
struct ApplePayButton: View {
    let client: HesabeClient
    let amount: Decimal
    /// Hesabe's Apple Pay payment type: 11 KNET debit, 13 KNET international.
    let paymentType: Int
    let onOutcome: (PaymentOutcome) -> Void

    private enum Phase: Equatable { case loading, ready, processing, failed(String) }

    @State private var attempt: PaymentAttempt?
    @State private var pageURL: URL?
    @State private var tries = 0
    @State private var phase = Phase.loading

    private let shape = PayButtonStyle.shape

    var body: some View {
        Group {
            if case .failed(let message) = phase {
                // The same footprint as the button: a retry that says what went wrong.
                Button { tries += 1 } label: {
                    Label("Try again · \(message)", systemImage: "arrow.clockwise")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(PayButtonStyle(tint: .secondary))
            } else {
                button
            }
        }
        .task(id: tries) { await start() }
    }

    private var button: some View {
        ZStack {
            // Under the web view until it has drawn, so the slot never shows a hole.
            NativeApplePayButton()
                .opacity(phase == .loading ? 0.5 : 0)

            if let attempt, let pageURL {
                // Stays mounted while processing: the payment is a navigation inside it.
                ApplePayWebButton(
                    pageURL: pageURL, returnURL: attempt.returnURL, failureURL: attempt.failureURL,
                    cancelURL: Config.returnBase.appending(path: "cancelled")
                ) { handle($0, in: attempt) }
                .id(attempt.id)
                .opacity(phase == .ready ? 1 : 0)
                .allowsHitTesting(phase == .ready)
            }

            if phase == .processing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Processing")
                        .font(.body.weight(.medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.fill.secondary)
            }
        }
        .frame(height: PayButtonStyle.height)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.2), value: phase)
    }

    // MARK: Attempt

    private func start() async {
        phase = .loading
        attempt = nil
        pageURL = nil
        do {
            let next = try await PaymentAttempt.start(client: client, method: "Apple Pay", amount: amount) {
                $0.embedded = true
                // An embedded session (type 0) is what the Apple Pay script takes; the
                // Apple Pay type goes to processPayment on the page.
            }
            guard !Task.isCancelled, let session = next.session else { return }
            pageURL = try Self.pageURL(for: session, environment: client.environment, paymentType: paymentType)
            attempt = next
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
    }

    /// The static page with this attempt's settings in the fragment. Browsers never send
    /// the fragment to the server, so the page is the same file for every payment.
    /// The page is `Config.applePayPage`: set it to where you host `web/apple-pay.html`
    /// (the demo was run with https://derahkw.com/apple-pay.html).
    private static func pageURL(for session: HesabeClient.CheckoutSession,
                                environment: HesabeEnvironment, paymentType: Int) throws -> URL {
        let settings = try JSONSerialization.data(withJSONObject: [
            "requestData": session.requestData,
            "environment": environment.rawValue,
            "paymentType": paymentType,
            "cancelUrl": Config.returnBase.appending(path: "cancelled").absoluteString,
        ], options: .withoutEscapingSlashes)
        var page = URLComponents(url: Config.applePayPage, resolvingAgainstBaseURL: false)!
        page.percentEncodedFragment = String(decoding: settings, as: UTF8.self)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        return page.url!
    }

    private func handle(_ event: ApplePayButtonEvent, in attempt: PaymentAttempt) {
        switch event {
        case .ready, .cancelled:
            phase = .ready
        case .processing:
            phase = .processing
            let waiting = attempt.id
            Task {
                // Hesabe redirects within seconds. If it never does, ask Hesabe rather
                // than spin: by now the card may have been charged.
                try? await Task.sleep(for: .seconds(45))
                guard phase == .processing, self.attempt?.id == waiting else { return }
                await finish(attempt.outcome(hesabeFinished: false))
            }
        case .failed(let message):
            phase = .failed(message)
        case .lost(let message):
            phase = .processing
            Task {
                var outcome = await attempt.outcome(hesabeFinished: false)
                if outcome.state == .unconfirmed { outcome.message = message }
                await finish(outcome)
            }
        case .returned(let url):
            phase = .processing
            Task {
                await finish(attempt.outcome(hesabeFinished: true, redirect: attempt.redirectPayload(in: url)))
            }
        }
    }

    /// Reports once per attempt: the timeout and the return can both arrive.
    @MainActor
    private func finish(_ outcome: PaymentOutcome) {
        guard attempt?.id == outcome.reference else { return }
        attempt = nil
        onOutcome(outcome)
        tries += 1 // a session is single use; the next tap needs a new one
    }
}

/// PassKit's own button, used ONLY as the stand-in while the web button loads: the same
/// artwork WebKit draws, so the swap is invisible. It takes no taps; the payment belongs
/// to the page, whose domain Hesabe registered with Apple.
private struct NativeApplePayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> PKPaymentButton {
        // .buy matches the page's `-apple-pay-button-type: buy`.
        let button = PKPaymentButton(paymentButtonType: .buy, paymentButtonStyle: .automatic)
        button.cornerRadius = 0 // the caller clips both buttons to one shape
        button.isUserInteractionEnabled = false
        return button
    }

    func updateUIView(_ button: PKPaymentButton, context: Context) {}
}
