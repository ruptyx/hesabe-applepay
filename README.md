# Apple Pay in SwiftUI with Hesabe

The app talks to Hesabe directly: it creates the payment session, and afterwards asks
Hesabe whether the payment went through. There is no backend. The only thing you host
is one static HTML file, on the domain Hesabe registered with Apple.

That file draws the Apple Pay button. The app shows it in a borderless `WKWebView` that
is only as big as the button. Everything else on the screen is native, and the sheet the
customer sees is the real system Apple Pay sheet.

[`demo/`](demo) is a complete Xcode project with the app code from Steps 5 to 10. Only
the keys and URLs in `Config.swift` are placeholders.

## Why the button page can't live in the app

Hesabe validates Apple Pay merchants against a domain it registered with Apple, so the
button has to be on a page from that domain. WebKit also refuses to start Apple Pay on a
page that wasn't fetched over HTTPS with a real certificate. That rules out
`loadHTMLString`, `loadFileURL` and `loadSimulatedRequest`: WebKit rejects all three with
"Trying to start an Apple Pay session from an insecure document."

So the page is hosted, but it holds no logic and no secrets. It is the same file for every
payment. The app passes each payment's details in the URL fragment, which the browser
never sends to the server.

## Step 1. Enable Apple Pay on your Hesabe account

Email support@hesabe.com and ask them to enable Apple Pay for your merchant account.

## Step 2. Register your domain

Email itsupport@hesabe.com with the domain that will serve the button page. Hesabe
sends back a domain association file. Serve it as plain text at:

```
https://example.com/.well-known/apple-developer-merchantid-domain-association.txt
```

Tell Hesabe only after the file is live. Apple checks it when Hesabe presses verify,
and a verification that ran before the file was reachable fails without telling you.

## Step 3. Find your Apple Pay payment type

Each merchant has its own set. Ask Hesabe, or look it up: in a Debug build, print the
`requestData` that `ApplePayAttempt.start` gets back (Step 7) and open

```
https://sandbox.hesabe.com/api/checkout-details?data=<requestData>
```

(`api.hesabe.com` for production). The ids are under `response.applePay`.

| Type | Apple Pay method |
|---|---|
| `9` | MPGS |
| `10` | CyberSource |
| `11` | KNET debit (Kuwait-issued debit cards) |
| `12` | KNET credit |
| `13` | KNET international (other cards) |
| `14` | American Express |

One button starts one type. If you have both 11 and 13, pick one or show two buttons.

## Step 4. Host the button page

Put [`web/apple-pay.html`](web/apple-pay.html) anywhere on the domain from Step 2, next to
the association file. Any static host works: nothing runs on the server.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Hesabe's direct-apple-pay SDK, pinned. The integrity hash stops a changed file from running. -->
<script src="https://unpkg.com/@hesabe-pay/direct-apple-pay@1.0.15/cdn/hesabe-apple-pay.min.js"
        integrity="sha256-s8DYK/KIQxUy3+l9HOL1gnyxewm2v8C0bLHEqAaXMug="
        crossorigin="anonymous"></script>
<style>
  html, body { margin: 0; height: 100%; background: transparent; }
  button {
    display: block; width: 100%; height: 100%; border: 0;
    -webkit-appearance: -apple-pay-button;
    -apple-pay-button-type: buy;
    -apple-pay-button-style: black;
  }
  button[hidden] { display: none; }
  @media (prefers-color-scheme: dark) { button { -apple-pay-button-style: white; } }
</style>
</head>
<body>
<button id="pay" aria-label="Buy with Apple Pay" hidden></button>
<script>
  // The app puts this attempt's settings in the fragment. Browsers never send the
  // fragment to the server, so this file is the same for every payment.
  const config = JSON.parse(decodeURIComponent(location.hash.slice(1)));
  const button = document.getElementById("pay");
  if (window.ApplePaySession && ApplePaySession.canMakePayments()) button.hidden = false;

  const applePay = new HesabeApplePay({
    requestData: config.requestData,
    env: config.environment,
    // No paymentAttemptedCallback: after the sheet, the SDK sends the page to Hesabe,
    // which redirects to the session's responseUrl.
    paymentCancelledCallback: () => { location.href = config.cancelUrl; },
  });
  applePay.init();

  // processPayment must run inside the tap itself; Apple Pay needs a user gesture.
  button.onclick = () => applePay.processPayment(config.paymentType);
</script>
</body>
</html>
```

- The page loads Hesabe's `direct-apple-pay` SDK from unpkg, pinned to 1.0.15 and checked
  against an integrity hash.
- If your site sends a `Content-Security-Policy`, allow `https://unpkg.com`,
  `https://applepay.cdn-apple.com` and your Hesabe host (`https://api.hesabe.com` or
  `https://sandbox.hesabe.com`).

## Step 5. Add your Hesabe keys

Put your merchant account, the page URL and the payment type in one place:

```swift
import Foundation

// Replace these placeholders with your own values.

/// Your Hesabe merchant account. These are Hesabe's public sandbox test credentials.
/// Anything compiled into the app can be read out of it, so treat these keys as public.
let hesabe = HesabeClient(
    environment: .sandbox,
    merchantCode: "842217",
    accessCode: "c333729b-d060-4b74-a49d-7686a8353481",
    secretKey: "PkW64zMe5NVdrlPVNnjo2Jy9nOb7v1Xg",
    ivKey: "5NVdrlPVNnjo2Jy9"
)

/// Where you host `web/apple-pay.html` (Step 4), on the domain Hesabe registered with Apple.
let applePayPage = URL(string: "https://example.com/apple-pay.html")!

/// Your Apple Pay payment type (Step 3).
let applePayType = 11

/// The order the demo checkout pays for, at or above the Apple Pay minimum.
let checkoutOrderID = "ORDER-1001"
let checkoutAmount = Decimal(string: "1.000")!
```

Without a backend, the app holds the keys and decides the amount. Before you ship, know
what that means:

- Anyone can extract the keys from the app. With them they can create sessions for any
  amount, look up your transactions, and decrypt anything Hesabe encrypts for you.
- The amount comes from the app, so a modified app can charge less. Check what was paid
  before you fulfil an order.
- There is no webhook. A payment that is still processing when the app stops asking is
  only confirmed when something asks Hesabe again.

## Step 6. Talk to Hesabe from the app

A small client for the two calls the app makes: create a checkout session, and look a
payment up by its order reference. Hesabe encrypts every payload with AES-256-CBC under
your secret key, padded to 32 bytes instead of AES's 16, and hex encoded.
CommonCrypto does the AES; the client does the padding.

```swift
import CommonCrypto
import Foundation

/// Calls Hesabe's payment gateway directly from the app, with the merchant's own keys.
struct HesabeClient {
    enum Environment: String {
        case sandbox, production

        var gateway: URL {
            switch self {
            case .sandbox: URL(string: "https://sandbox.hesabe.com")!
            case .production: URL(string: "https://api.hesabe.com")!
            }
        }
    }

    let environment: Environment
    let merchantCode: String
    let accessCode: String
    let secretKey: String
    let ivKey: String

    /// Creates a single-use checkout session and returns the `requestData` that Hesabe's
    /// Apple Pay script takes. Nothing is charged until the customer pays.
    func createCheckout(amount: Decimal, orderReference: String, returnURL: URL) async throws -> String {
        let (_, envelope) = try await send("POST", "checkout", payload: [
            "merchantCode": merchantCode,
            "amount": hesabeAmount(amount),
            "currency": "KWD",
            "paymentType": 0,
            "orderReferenceNumber": orderReference,
            "responseUrl": returnURL.absoluteString,
            "failureUrl": returnURL.absoluteString,
            "embeddedPayment": true,
            "version": "3.0",
            // Hesabe's Apple Pay guide requires the domain the button page is on.
            "variable5": returnURL.host() ?? "",
        ])

        guard envelope["status"] as? Bool == true,
              let response = envelope["response"] as? [String: Any],
              let data = response["data"] as? String
        else { throw HesabeError.rejected(envelope["message"] as? String ?? "No checkout session") }

        // An embedded session is base64 JSON. The Apple Pay script wants only its inner `data`.
        if let decoded = Data(base64Encoded: data),
           let session = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
           let requestData = session["data"] as? String {
            return requestData
        }
        return data
    }

    /// Looks a payment up by the order reference its session was created with.
    /// `nil` means no payment for it has reached Hesabe.
    func transaction(orderReference: String) async throws -> HesabeTransaction? {
        let (status, envelope) = try await send(
            "GET", "api/transaction/\(orderReference)",
            query: [URLQueryItem(name: "isOrderReference", value: "1")]
        )
        if status == 404 { return nil }
        guard envelope["status"] as? Bool != false,
              let record = (envelope["response"] ?? envelope["data"]) as? [String: Any]
        else { throw HesabeError.rejected(envelope["message"] as? String ?? "HTTP \(status)") }
        return HesabeTransaction(record)
    }

    // MARK: - Transport

    /// Every request carries the access code, and every payload goes out AES-encrypted as `data`.
    private func send(_ method: String,
                      _ path: String,
                      query: [URLQueryItem] = [],
                      payload: [String: Any]? = nil) async throws -> (status: Int, envelope: [String: Any]) {
        var url = environment.gateway.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accessCode, forHTTPHeaderField: "accessCode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            let plaintext = try JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["data": try cipher.encrypt(plaintext)])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try envelope(from: body, status: status))
    }

    /// Hesabe answers in hex ciphertext on success, and in plain JSON for errors.
    private func envelope(from body: Data, status: Int) throws -> [String: Any] {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if isHex(text) { return try decryptObject(text, status: status) }

        let json = try? JSONSerialization.jsonObject(with: body, options: .fragmentsAllowed)
        if let hex = json as? String, isHex(hex) { return try decryptObject(hex, status: status) }
        if let object = json as? [String: Any] {
            if let hex = object["response"] as? String, isHex(hex) { return try decryptObject(hex, status: status) }
            return object
        }
        throw HesabeError.unreadableResponse(status)
    }

    private func decryptObject(_ hex: String, status: Int) throws -> [String: Any] {
        let plaintext = try cipher.decrypt(hex)
        guard let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            throw HesabeError.unreadableResponse(status)
        }
        return object
    }

    private var cipher: HesabeCipher { HesabeCipher(secretKey: secretKey, ivKey: ivKey) }
}

/// A payment as Hesabe reports it.
struct HesabeTransaction {
    enum Status { case paid, failed, pending }

    let status: Status
    let amount: Decimal?

    init(_ record: [String: Any]) {
        amount = (record["amount"]).flatMap { Decimal(string: "\($0)", locale: Locale(identifier: "en_US_POSIX")) }

        // Prefer the numeric status. 1 is paid, 6 is paid through a multivendor split, 0 is failed.
        if let code = record["payment_status"].flatMap({ Int("\($0)") }) {
            status = [1, 6].contains(code) ? .paid : code == 0 ? .failed : .pending
            return
        }
        let texts = ["status", "result_code", "resultCode"].compactMap {
            (record[$0] as? String)?.trimmingCharacters(in: .whitespaces).uppercased()
        }
        if texts.contains(where: { ["SUCCESSFUL", "SUCCESS", "CAPTURED", "PAID"].contains($0) }) {
            status = .paid
        } else if texts.contains("FAILED") {
            status = .failed
        } else {
            status = .pending
        }
    }
}

enum HesabeError: LocalizedError {
    case invalidKeys
    case rejected(String)
    case unreadableResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKeys: "The Hesabe secret key must be 32 bytes and the IV key 16 bytes."
        case .rejected(let message): "Hesabe refused the request: \(message)"
        case .unreadableResponse(let status): "Hesabe sent a response the app couldn't read (HTTP \(status))."
        }
    }
}

/// Hesabe rejects amounts that aren't fixed to three decimal places.
func hesabeAmount(_ amount: Decimal) -> String {
    var value = amount
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 3, .plain)

    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 3
    formatter.maximumFractionDigits = 3
    return formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)"
}

/// AES-256-CBC with Hesabe's padding: to a 32-byte block, not AES's 16, hex encoded.
private struct HesabeCipher {
    let secretKey: String
    let ivKey: String

    func encrypt(_ plaintext: Data) throws -> String {
        let padLength = 32 - plaintext.count % 32
        let padded = plaintext + Data(repeating: UInt8(padLength), count: padLength)
        return try crypt(padded, CCOperation(kCCEncrypt)).map { String(format: "%02x", $0) }.joined()
    }

    func decrypt(_ hex: String) throws -> Data {
        var ciphertext = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw HesabeError.unreadableResponse(0) }
            ciphertext.append(byte)
            index = next
        }
        let padded = try crypt(ciphertext, CCOperation(kCCDecrypt))

        // Every pad byte holds the pad length. Some Hesabe responses are zero-padded instead.
        if let last = padded.last, (1...32).contains(last), Int(last) <= padded.count,
           padded.suffix(Int(last)).allSatisfy({ $0 == last }) {
            return padded.dropLast(Int(last))
        }
        var end = padded.endIndex
        while end > padded.startIndex, padded[end - 1] == 0 { end -= 1 }
        return padded[padded.startIndex..<end]
    }

    private func crypt(_ input: Data, _ operation: CCOperation) throws -> Data {
        let key = Data(secretKey.utf8)
        let iv = Data(ivKey.utf8)
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { throw HesabeError.invalidKeys }

        let capacity = input.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        // No options: Hesabe's padding is applied and stripped above, not by CommonCrypto.
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), 0,
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count,
                                out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw HesabeError.unreadableResponse(0) }
        return output.prefix(written)
    }
}

private func isHex(_ text: String) -> Bool {
    !text.isEmpty && text.count.isMultiple(of: 2) && text.allSatisfy(\.isHexDigit)
}
```

- A session for the Apple Pay SDK is an embedded one (`embeddedPayment`, version 3.0).
  Its `data` is base64 JSON, and the SDK wants only the `data` inside it.
- Don't confirm the payment from the redirect. Apple Pay's redirect has no
  `paymentToken`, so look the payment up by order reference instead.

## Step 7. Start an attempt

Each attempt creates a new session with its own order reference, then builds the page URL
with the session in the fragment. When the attempt ends, it asks Hesabe how it went.

```swift
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
```

- `returnURL` and `cancelURL` are on your domain but don't exist. The web view stops both
  navigations before they load.
- A payment that is still settling reports pending. The attempt asks again every 3
  seconds for about 30 seconds. Hesabe allows 30 lookups a minute.

## Step 8. Add the web view

A `WKWebView` that loads the attempt's page and reports what happens in it: the button is
ready, Hesabe is charging, the attempt ended, the customer cancelled, or the page failed to
load. It learns this from navigations and responses only, because running script in the
page disables Apple Pay.

```swift
import SwiftUI
import WebKit

/// What the button page did. The app learns this from navigations and responses only:
/// running script in the page would disable Apple Pay.
enum ApplePayEvent {
    /// The button page loaded and the button is showing.
    case ready
    /// The customer approved the sheet and the page left for Hesabe to charge.
    case processing
    /// The attempt ended. Ask Hesabe how it went. `hesabeFinished` is false when the
    /// page failed mid-payment instead of coming back from Hesabe.
    case finished(hesabeFinished: Bool)
    /// The customer closed the sheet without paying.
    case cancelled
    /// The button page didn't load. Nothing was charged.
    case failed
}

/// A web view that shows only the button page and reports what happens in it.
struct ApplePayWebView: UIViewRepresentable {
    let attempt: ApplePayAttempt
    var onEvent: (ApplePayEvent) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(attempt: attempt, onEvent: onEvent) }

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
        webView.load(URLRequest(url: attempt.pageURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onEvent: (ApplePayEvent) -> Void
        private let attempt: ApplePayAttempt
        private var shown = false    // the button page finished loading
        private var charging = false // the page left for Hesabe after the sheet
        private var ended = false

        init(attempt: ApplePayAttempt, onEvent: @escaping (ApplePayEvent) -> Void) {
            self.attempt = attempt
            self.onEvent = onEvent
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame != false,
                  let url = action.request.url else { return decisionHandler(.allow) }

            if url.absoluteString.hasPrefix(attempt.returnURL.absoluteString) {
                end(.finished(hesabeFinished: true))
                decisionHandler(.cancel)
            } else if url.absoluteString.hasPrefix(attempt.cancelURL.absoluteString) {
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

            // After the sheet, the card may have been charged even though Hesabe's
            // redirect never arrived, so ask Hesabe about the attempt.
            end(charging ? .finished(hesabeFinished: false) : .failed)
        }

        private func end(_ event: ApplePayEvent) {
            guard !ended else { return }
            ended = true
            onEvent(event)
        }
    }
}
```

## Step 9. Wrap it in a native button view

After the sheet, the page goes to Hesabe before it redirects. The view hides the web view
from then on and shows a native "Confirming payment…" state, so Hesabe's pages never
appear in the button's frame. It shows a spinner while the session is created and the page
loads, and a retry button if either fails.

```swift
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
```

- Always show the result from Hesabe's lookup. The Apple Pay sheet says "Done" even when
  the payment is declined.
- Each Hesabe session is single use, so the view starts a new attempt after every one the
  customer can retry.

## Step 10. Use it in your checkout

```swift
import PassKit
import SwiftUI

struct CheckoutView: View {
    let total = "\(hesabeAmount(checkoutAmount)) KWD"

    @State private var outcome: PaymentOutcome?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Test item", value: total)
                    LabeledContent("Total", value: total)
                        .fontWeight(.semibold)
                }

                Section {
                    if !PKPaymentAuthorizationController.canMakePayments() {
                        Text("Apple Pay isn't available on this device.")
                    } else if outcome?.canRetry ?? true {
                        ApplePayButton(orderID: checkoutOrderID, amount: checkoutAmount) { outcome = $0 }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } footer: {
                    if let outcome { Text(outcome.message) }
                }
            }
            .navigationTitle("Checkout")
        }
    }
}

#Preview {
    CheckoutView()
}
```

Hide the button for orders below the Apple Pay minimum. Hesabe sets it per method (KNET
debit rejected 0.100 KWD and accepted 0.250 KWD).

## Step 11. Run it

1. Open `demo/ApplePayDemo.xcodeproj` in Xcode 16 or later.
2. Replace the placeholders in `Config.swift` with your Hesabe keys, the URL of your button
   page, and your payment type.
3. Open `CheckoutView.swift` to see the checkout in the Xcode preview. The preview creates
   a real Hesabe session each time it refreshes.
4. To pay, choose your team under Signing & Capabilities and run it on an iPhone with a
   card in Wallet. Payments don't complete in the preview or the simulator.

If something goes wrong:

- In Debug builds, inspect the page from a Mac: Safari → Develop → your iPhone.
- If the button never appears, open the page's console there. A 400 from
  `checkout-details` means the session was created with different keys or environment
  than the page is using.
- If the sheet shows "Payment Not Completed" without asking the customer to confirm,
  the domain registration from Step 2 is missing. Ask Hesabe to verify it again.
- The sheet shows your merchant code ("Pay 842217") until Hesabe sets a display name.
