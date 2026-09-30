import Foundation

/// How a payment ended, as the app shows it. Always what Hesabe's lookup said, never
/// what a redirect or a sheet claimed.
struct PaymentOutcome: Identifiable {
    enum State: Equatable {
        case paid
        /// Declined or rejected. Nothing was charged.
        case failed
        /// Hesabe is still settling it.
        case pending
        /// The app couldn't find out. The card may have been charged.
        case unconfirmed
        case cancelled
    }

    let id = UUID()
    var state: State
    var method: String
    var amount: Decimal
    var reference: String
    var transaction: HesabeTransaction?
    var message: String?
    /// Payloads as they came, for reading the shapes: title and pretty JSON.
    var raw: [(title: String, body: String)] = []

    var title: String {
        switch state {
        case .paid: "Paid"
        case .failed: "Not paid"
        case .pending: "Processing"
        case .unconfirmed: "Could not confirm"
        case .cancelled: "Cancelled"
        }
    }

    var detail: String {
        if let message { return message }
        switch state {
        case .paid: return "Hesabe confirms the payment."
        case .failed: return "The payment didn't go through. Nothing was charged."
        case .pending: return "Hesabe is still settling it. Don't pay again until it completes."
        case .unconfirmed: return "Check the Hesabe dashboard before paying again."
        case .cancelled: return "Nothing was charged."
        }
    }
}

/// One try at paying an amount: its order reference, and the session Hesabe gave for it.
/// Hesabe sessions are single use, so every retry is a new attempt.
struct PaymentAttempt: Identifiable {
    let client: HesabeClient
    let method: String
    let amount: Decimal
    /// The order reference the session was created with. The app looks the payment up by it.
    let reference: String
    let session: HesabeClient.CheckoutSession?
    /// Hesabe sends the customer here after paying, or after failing. The app stops both
    /// navigations, so nothing exists at these URLs.
    let returnURL: URL
    let failureURL: URL

    var id: String { reference }

    static func newReference() -> String {
        "IOS-\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    static func returnURLs(for reference: String) -> (response: URL, failure: URL) {
        (Config.returnBase.appending(path: "done/\(reference)"),
         Config.returnBase.appending(path: "failed/\(reference)"))
    }

    /// Creates a Hesabe session for a hosted page (KNET, card) or for the Apple Pay script.
    static func start(client: HesabeClient, method: String, amount: Decimal,
                      configure: (inout HesabeClient.CheckoutParams) -> Void = { _ in }) async throws -> PaymentAttempt {
        let reference = newReference()
        let urls = returnURLs(for: reference)
        var params = HesabeClient.CheckoutParams(
            amount: amount, orderReference: reference, responseURL: urls.response, failureURL: urls.failure
        )
        configure(&params)
        let session = try await client.createCheckout(params)
        return PaymentAttempt(client: client, method: method, amount: amount, reference: reference,
                              session: session, returnURL: urls.response, failureURL: urls.failure)
    }

    /// The redirect's `data`, decrypted, or nil when the URL carries none it can read.
    func redirectPayload(in url: URL) -> [String: Any]? {
        guard let data = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "data" })?.value
        else { return nil }
        return try? client.parseRedirect(data)
    }

    /// Asks Hesabe how this attempt ended. A payment still settling reports pending, so
    /// it asks again for about 30 seconds. Hesabe allows 30 lookups a minute.
    ///
    /// - Parameter hesabeFinished: Hesabe redirected back, so a payment it doesn't know
    ///   about never reached it. Otherwise the page failed mid-payment, and the payment
    ///   may still appear.
    func outcome(hesabeFinished: Bool, redirect: [String: Any]? = nil) async -> PaymentOutcome {
        var outcome = PaymentOutcome(state: .unconfirmed, method: method, amount: amount, reference: reference)
        if let redirect { outcome.raw.append(("Redirect payload", prettyJSON(redirect))) }

        var sawPending = false
        var lastError: String?
        for poll in 0..<10 {
            if poll > 0 { try? await Task.sleep(for: .seconds(3)) }

            let transaction: HesabeTransaction?
            do {
                transaction = try await client.transaction(orderReference: reference)
            } catch {
                lastError = error.localizedDescription
                continue
            }

            guard let transaction else {
                // Cancelled, or rejected before charging (for example, below the minimum).
                if hesabeFinished {
                    outcome.state = .failed
                    outcome.message = "Hesabe has no transaction for this reference: it was rejected before charging."
                    return outcome
                }
                continue
            }
            outcome.transaction = transaction
            outcome.raw.append(("Transaction lookup", prettyJSON(transaction.fields)))
            switch transaction.status {
            case .paid:
                if transaction.amount == amount {
                    outcome.state = .paid
                } else {
                    // Paid, but not this amount: don't treat it as this order's payment.
                    outcome.state = .unconfirmed
                    outcome.message = "Hesabe reports \(transaction.amount.map(hesabeAmount) ?? "no amount"), not the \(hesabeAmount(amount)) asked for."
                }
                return outcome
            case .failed:
                outcome.state = .failed
                return outcome
            case .pending:
                sawPending = true
            }
        }
        outcome.state = sawPending ? .pending : .unconfirmed
        if !sawPending, let lastError { outcome.message = lastError }
        return outcome
    }
}
