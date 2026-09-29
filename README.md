# Apple Pay in SwiftUI with Hesabe

Hesabe validates Apple Pay merchants against a domain it registered with Apple, so the
payment has to start from a page on that domain. The app shows that page in a
borderless `WKWebView` that contains only the Apple Pay button. Everything else stays
native, and the sheet the customer sees is the real system Apple Pay sheet.

The backend examples use [hesabe-node](https://github.com/ruptyx/hesabe-node).
[`demo/`](demo) is a complete Xcode project with the app code from Steps 6 to 8; only
the backend URL and order ID are placeholders.

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

Each merchant has its own set. The checkout-details endpoint lists them:

```ts
const session = await hesabe.checkout.create({ embedded: true, amount: 1, /* … */ });
const { data } = JSON.parse(Buffer.from(session.data, "base64").toString());
const details = await fetch(`https://api.hesabe.com/api/checkout-details?data=${data}`)
  .then((r) => r.json());

details.response.applePay.map((method) => method.id); // e.g. [11, 13]
```

| Type | Apple Pay method |
|---|---|
| `9` | MPGS |
| `10` | CyberSource |
| `11` | KNET debit (Kuwait-issued debit cards) |
| `12` | KNET credit |
| `13` | KNET international (other cards) |
| `14` | American Express |

One button starts one type. If you have both 11 and 13, pick one or show two buttons.

## Step 4. Serve the button page

This HTML page loads Hesabe's `direct-apple-pay` browser SDK and draws WebKit's
built-in Apple Pay button. Pin the SDK version.

```js
const APPLE_PAY_SDK =
  "https://unpkg.com/@hesabe-pay/direct-apple-pay@1.0.15/cdn/hesabe-apple-pay.min.js";

/** HTML with nothing but a system Apple Pay button, sized by the web view around it. */
function applePayPage({ requestData, paymentType, environment, cancelUrl }) {
  const config = JSON.stringify({ requestData, environment, paymentType, cancelUrl })
    .replace(/</g, "\\u003c");
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<script src="${APPLE_PAY_SDK}"></script>
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
  const config = ${config};
  const button = document.getElementById("pay");
  if (window.ApplePaySession && ApplePaySession.canMakePayments()) button.hidden = false;

  const applePay = new HesabeApplePay({
    requestData: config.requestData,
    env: config.environment,
    // No paymentAttemptedCallback: after the sheet, the SDK redirects to responseUrl.
    paymentCancelledCallback: () => { location.href = config.cancelUrl; },
  });
  applePay.init();

  // processPayment must run inside the tap itself; Apple Pay needs a user gesture.
  button.onclick = () => applePay.processPayment(config.paymentType);
</script>
</body>
</html>`;
}
```

Serve it from a route that creates a new Hesabe session for each attempt:

```ts
import express from "express";
import { Hesabe, HesabeError, isSuccessful, type TransactionRecord } from "hesabe";

const app = express();
const hesabe = new Hesabe();
const BASE = "https://example.com/pay/apple-pay";
const APPLE_PAY_TYPE = 11; // from Step 3

app.get("/pay/apple-pay/button/:orderId", async (req, res) => {
  const order = await loadOrder(req.params.orderId); // amount from your database, never the app
  const reference = `${order.id}-${Date.now()}`;      // one per attempt
  await recordAttempt(order.id, reference);

  const session = await hesabe.checkout.create({
    amount: order.total,
    orderReferenceNumber: reference,
    responseUrl: `${BASE}/done/${reference}`,
    failureUrl: `${BASE}/done/${reference}`,
    webhookUrl: "https://example.com/hesabe/webhook",
    embedded: true,
  });

  // session.data is base64 JSON; the Apple Pay SDK wants only its inner `data`.
  const { data: requestData } = JSON.parse(Buffer.from(session.data, "base64").toString());

  res.set({
    "Cache-Control": "no-store",
    // The app asks the done route with this if Hesabe's redirect never arrives.
    "X-Payment-Reference": reference,
  });
  res.type("html").send(applePayPage({
    requestData,
    paymentType: APPLE_PAY_TYPE,
    environment: hesabe.environment, // the same environment the session was created in
    cancelUrl: `${BASE}/cancelled`,
  }));
});
```

- The `X-Payment-Reference` header lets the app find the attempt if Hesabe's redirect
  never arrives (Step 6).
- Protect this route like any other order endpoint, for example with a short-lived
  signed token in the URL. Anyone with the URL can create a session for the order.
- If your site sends a `Content-Security-Policy`, allow `https://unpkg.com` and
  `https://api.hesabe.com`.

## Step 5. Add the result route

After the sheet, Hesabe redirects the page here. The app stops that navigation and
asks this route itself. It looks up the reference in the path, so it never trusts
anything the device carried back.

```ts
app.get("/pay/apple-pay/done/:reference", async (req, res) => {
  const { reference } = req.params;
  let transaction: TransactionRecord | null = null;
  try {
    transaction = await hesabe.transactions.retrieveByOrderReference(reference);
  } catch (error) {
    // 404: no payment reached the gateway (cancelled, or rejected before charging)
    if (!(error instanceof HesabeError) || error.statusCode !== 404) throw error;
  }

  const status = paymentStatus(transaction);
  if (status === "paid") await fulfil(reference); // idempotent: the webhook may get there first
  res.set("Cache-Control", "no-store").json({ status, reference });
});

/** "paid", "failed", or "pending" while Hesabe is still settling it. */
function paymentStatus(transaction: TransactionRecord | null) {
  if (transaction === null) return "failed";
  if (isSuccessful(transaction)) return "paid";
  if (transaction.status.trim().toUpperCase() === "FAILED") return "failed";
  return "pending";
}
```

- A payment that is still settling answers `pending`. The app asks again for about 30
  seconds, then leaves it to your webhook (see the hesabe-node README).
- Don't use `verifyRedirect` here. The Apple Pay redirect has no `paymentToken`, so it
  throws even when the payment succeeded.

## Step 6. Add the web view

A `WKWebView` that loads the button page and reports what happens in it: the button
is ready, Hesabe is charging, the attempt ended, the customer cancelled, or the page
failed to load. It learns this from navigations and responses only, because running
script in the page disables Apple Pay.

Put your backend's details in one place:

```swift
import Foundation

// Replace these placeholders with your own values.

/// Your backend's Apple Pay routes (Steps 4 and 5), on the domain Hesabe registered with Apple.
let applePayBase = URL(string: "https://example.com/pay/apple-pay")!

/// An order your backend knows, at or above the Apple Pay minimum.
let checkoutOrderID = "ORDER-1001"
```

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
```

## Step 7. Wrap it in a native button view

After the sheet, the page goes to `api.hesabe.com` before it redirects. The view hides
the web view from then on and shows a native "Confirming payment…" state, so Hesabe's
pages never appear in the button's frame. It shows a spinner while the page loads, and
a retry button if the page fails.

```swift
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
```

- Always show the result from the done route. The Apple Pay sheet says "Done" even
  when the payment is declined.
- Each Hesabe session is single use, so the view loads a new web view after every
  attempt the customer can retry.

## Step 8. Use it in your checkout

```swift
import PassKit
import SwiftUI

struct CheckoutView: View {
    /// Display only: the backend charges the order's own total.
    let total = "1.000 KWD"

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
                        ApplePayButton(orderID: checkoutOrderID) { outcome = $0 }
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

## Step 9. Run it

1. Open `demo/ApplePayDemo.xcodeproj` in Xcode 16 or later.
2. Replace the placeholders in `Config.swift` with your backend's Apple Pay URL and an
   order it knows.
3. Open `CheckoutView.swift` to see the checkout in the Xcode preview. The preview loads
   your real button page, so each refresh creates a new Hesabe checkout session.
4. To pay, choose your team under Signing & Capabilities and run it on an iPhone with a
   card in Wallet. Payments don't complete in the preview or the simulator.

If something goes wrong:

- In Debug builds, inspect the page from a Mac: Safari → Develop → your iPhone.
- If the sheet shows "Payment Not Completed" without asking the customer to confirm,
  the domain registration from Step 2 is missing. Ask Hesabe to verify it again.
- The sheet shows your merchant code ("Pay 842217") until Hesabe sets a display name.
