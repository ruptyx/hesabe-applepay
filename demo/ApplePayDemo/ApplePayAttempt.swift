import Foundation

/// One try at paying: a new Hesabe session, and the URLs the button page uses for it.
/// Hesabe sessions are single use, so every retry starts a new attempt.
struct ApplePayAttempt: Identifiable {
    /// The session's order reference. The app looks the payment up by it afterwards.
    let reference: String
    let amount: Decimal
    /// The button page, with this attempt's settings in its fragment.
    let pageURL: URL
    /// Hesabe sends the page here after the sheet. The app stops that navigation, so
    /// nothing has to exist at this URL.
    let returnURL: URL
    /// The page goes here when the customer closes the sheet. It doesn't have to exist either.
    let cancelURL: URL

    var id: String { reference }

    /// Creates the Hesabe session and the button page URL for it.
    static func start(orderID: String, amount: Decimal) async throws -> ApplePayAttempt {
        let reference = "\(orderID)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let returnURL = URL(string: "/apple-pay/done/\(reference)", relativeTo: applePayPage)!.absoluteURL
        let cancelURL = URL(string: "/apple-pay/cancelled", relativeTo: applePayPage)!.absoluteURL

        let requestData = try await hesabe.createCheckout(
            amount: amount,
            orderReference: reference,
            returnURL: returnURL
        )

        // The fragment stays on the device: browsers never send it to the server.
        let settings = try JSONSerialization.data(withJSONObject: [
            "requestData": requestData,
            "environment": hesabe.environment.rawValue,
            "paymentType": applePayType,
            "cancelUrl": cancelURL.absoluteString,
        ], options: .withoutEscapingSlashes)
        var page = URLComponents(url: applePayPage, resolvingAgainstBaseURL: false)!
        page.percentEncodedFragment = String(decoding: settings, as: UTF8.self)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)

        return ApplePayAttempt(
            reference: reference,
            amount: amount,
            pageURL: page.url!,
            returnURL: returnURL,
            cancelURL: cancelURL
        )
    }

    /// Asks Hesabe how this attempt ended. A payment still settling reports pending,
    /// so it asks again for about 30 seconds.
    ///
    /// - Parameter hesabeFinished: Hesabe redirected back, so a payment it doesn't know
    ///   about never reached it. Otherwise the page failed mid-payment, and the payment
    ///   may still appear.
    func outcome(hesabeFinished: Bool) async -> PaymentOutcome {
        var sawPending = false
        for poll in 0..<10 {
            if poll > 0 { try? await Task.sleep(for: .seconds(3)) }

            let transaction: HesabeTransaction?
            do {
                transaction = try await hesabe.transaction(orderReference: reference)
            } catch {
                continue
            }

            guard let transaction else {
                // Cancelled, or rejected before charging (for example, below the minimum).
                if hesabeFinished { return .failed }
                continue
            }
            switch transaction.status {
            case .paid:
                // Paid, but not this amount: don't treat it as this order's payment.
                return transaction.amount == amount ? .paid : .unconfirmed
            case .failed:
                return .failed
            case .pending:
                sawPending = true
            }
        }
        return sawPending ? .pending : .unconfirmed
    }
}
