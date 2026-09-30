import SwiftUI

/// How one Apple Pay attempt ended, as the app shows it.
enum PaymentOutcome: Equatable {
    case paid
    /// Declined or rejected. Nothing was charged.
    case failed
    /// Hesabe is still settling it.
    case pending
    /// The app couldn't find out. The card may have been charged.
    case unconfirmed
    case cancelled

    /// Whether the customer can safely pay again.
    var canRetry: Bool { self == .failed || self == .cancelled }

    var message: String {
        switch self {
        case .paid: "Paid. Thank you!"
        case .failed: "The payment didn't go through. You weren't charged."
        case .pending: "Your payment is still processing. Don't pay again until it completes."
        case .unconfirmed: "We couldn't confirm your payment. Check your order before paying again."
        case .cancelled: "Payment cancelled."
        }
    }
}

/// The Apple Pay button in a native frame: a spinner while the session is created and the
/// page loads, a retry button if either fails, and a native "Confirming" state while Hesabe
/// charges the card.
struct ApplePayButton: View {
    let orderID: String
    let amount: Decimal
    var onOutcome: (PaymentOutcome) -> Void

    private enum Phase { case loading, ready, charging, failed }

    @State private var attempt: ApplePayAttempt?
    @State private var tries = 0
    @State private var phase = Phase.loading

    var body: some View {
        ZStack {
            if let attempt {
                ApplePayWebView(attempt: attempt) { handle($0, in: attempt) }
                    .id(attempt.id) // a new web view for every attempt
                    // Keep the web view loading, but only ever show the button page.
                    .opacity(phase == .ready ? 1 : 0)
                    .allowsHitTesting(phase == .ready)
            }

            switch phase {
            case .loading:
                ProgressView()
            case .charging:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Confirming payment…")
                }
            case .failed:
                Button("Couldn't load Apple Pay. Try again", action: retry)
            case .ready:
                EmptyView()
            }
        }
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: tries) { await start() }
    }

    /// Creates a new Hesabe session. Each one is single use.
    private func start() async {
        phase = .loading
        attempt = nil
        do {
            let next = try await ApplePayAttempt.start(orderID: orderID, amount: amount)
            if !Task.isCancelled { attempt = next }
        } catch {
            if !Task.isCancelled { phase = .failed }
        }
    }

    private func handle(_ event: ApplePayEvent, in attempt: ApplePayAttempt) {
        switch event {
        case .ready:
            phase = .ready
        case .processing:
            phase = .charging
        case .failed:
            phase = .failed
        case .cancelled:
            onOutcome(.cancelled)
            retry()
        case .finished(let hesabeFinished):
            phase = .charging
            Task {
                let outcome = await attempt.outcome(hesabeFinished: hesabeFinished)
                onOutcome(outcome)
                if outcome.canRetry { retry() }
            }
        }
    }

    private func retry() {
        tries += 1
    }
}
