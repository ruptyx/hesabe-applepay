import SwiftUI

/// How one Apple Pay attempt ended, as the app shows it.
enum PaymentOutcome: Equatable {
    case paid
    /// Declined or rejected. Nothing was charged.
    case failed
    /// Hesabe is still settling it. Your webhook finishes the order.
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
        case .pending: "Your payment is still processing. We'll update your order when it completes."
        case .unconfirmed: "We couldn't confirm your payment. Check your order before paying again."
        case .cancelled: "Payment cancelled."
        }
    }
}

/// The Apple Pay button in a native frame: a spinner while the page loads, a retry button
/// if it doesn't, and a native "Confirming" state while Hesabe charges the card.
struct ApplePayButton: View {
    let orderID: String
    var onOutcome: (PaymentOutcome) -> Void

    private enum Phase { case loading, ready, charging, failed }

    @State private var attempt = 0
    @State private var phase = Phase.loading

    var body: some View {
        ZStack {
            ApplePayWebView(orderID: orderID, onEvent: handle)
                .id(attempt) // new web view = new Hesabe session; each one is single use
                // Keep the web view loading, but only ever show the button page.
                .opacity(phase == .ready ? 1 : 0)
                .allowsHitTesting(phase == .ready)

            switch phase {
            case .loading:
                ProgressView()
            case .charging:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Confirming payment…")
                }
            case .failed:
                Button("Couldn't load Apple Pay. Try again", action: reload)
            case .ready:
                EmptyView()
            }
        }
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func handle(_ event: ApplePayEvent) {
        switch event {
        case .ready:
            phase = .ready
        case .processing:
            phase = .charging
        case .failed:
            phase = .failed
        case .cancelled:
            onOutcome(.cancelled)
            reload()
        case .unconfirmed:
            onOutcome(.unconfirmed)
        case .finished(let doneURL):
            phase = .charging
            Task {
                let outcome = await confirmPayment(at: doneURL)
                onOutcome(outcome)
                if outcome.canRetry { reload() }
            }
        }
    }

    private func reload() {
        phase = .loading
        attempt += 1
    }
}

/// Asks the done route (Step 5) how the attempt ended. A payment still settling reports
/// "pending", so ask again for a while before handing it to the webhook.
func confirmPayment(at url: URL) async -> PaymentOutcome {
    struct Reply: Decodable { let status: String }

    var sawPending = false
    for attempt in 0..<10 {
        if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let reply = try? JSONDecoder().decode(Reply.self, from: data)
        else { continue }

        switch reply.status {
        case "paid": return .paid
        case "failed": return .failed
        default: sawPending = true
        }
    }
    return sawPending ? .pending : .unconfirmed
}
