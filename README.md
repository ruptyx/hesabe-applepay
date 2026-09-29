# Apple Pay in SwiftUI with Hesabe

Hesabe validates Apple Pay merchants against a domain it registered with Apple, so the
payment has to start from a page on that domain. The app shows that page in a
borderless `WKWebView` that contains only the Apple Pay button. Everything else stays
native, and the sheet the customer sees is the real system Apple Pay sheet.

The backend examples use [hesabe-node](https://github.com/ruptyx/hesabe-node).

## Step 1. Enable Apple Pay on your Hesabe account

Email support@hesabe.com and ask them to enable Apple Pay for your merchant account.

## Step 2. Register your domain

Email itsupport@hesabe.com with the domain that will serve the button page. Hesabe
sends back a domain association file. Serve it as plain text at:

```
https://yourshop.com/.well-known/apple-developer-merchantid-domain-association.txt
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
import { Hesabe, HesabeError, isSuccessful } from "hesabe";

const app = express();
const hesabe = new Hesabe();
const BASE = "https://yourshop.com/pay/apple-pay";
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
    webhookUrl: "https://yourshop.com/hesabe/webhook",
    embedded: true,
  });

  // session.data is base64 JSON; the Apple Pay SDK wants only its inner `data`.
  const { data: requestData } = JSON.parse(Buffer.from(session.data, "base64").toString());

  res.set("Cache-Control", "no-store").type("html").send(applePayPage({
    requestData,
    paymentType: APPLE_PAY_TYPE,
    environment: process.env.HESABE_ENVIRONMENT,
    cancelUrl: `${BASE}/cancelled`,
  }));
});
```

- Protect this route like any other order endpoint, for example with a short-lived
  signed token in the URL. Anyone with the URL can create a session for the order.
- If your site sends a `Content-Security-Policy`, allow `https://unpkg.com` and
  `https://api.hesabe.com`.

## Step 5. Add the result route

The page navigates here after the sheet closes. The route looks up the reference in
the path, so it never trusts anything the device carried back.

```ts
app.get("/pay/apple-pay/done/:reference", async (req, res) => {
  let transaction = null;
  try {
    transaction = await hesabe.transactions.retrieveByOrderReference(req.params.reference);
  } catch (error) {
    // 404: no payment reached the gateway (cancelled, or rejected before charging)
    if (!(error instanceof HesabeError) || error.statusCode !== 404) throw error;
  }

  const paid = transaction !== null && isSuccessful(transaction);
  if (paid) await fulfil(req.params.reference); // idempotent: the webhook may get there first
  res.set("Cache-Control", "no-store").json({ paid, reference: req.params.reference, transaction });
});
```

- Don't use `verifyRedirect` here. The Apple Pay redirect has no `paymentToken`, so it
  throws even when the payment succeeded.
- Also handle the webhook from the hesabe-node README as a backup.

## Step 6. Add the button view

A `WKWebView` that loads the button page and stops the navigation to the done or
cancelled URL.

```swift
import SwiftUI
import WebKit

let applePayBase = "https://yourshop.com/pay/apple-pay"

struct ApplePayButton: UIViewRepresentable {
    let orderID: String
    /// The done URL to confirm with your backend, or nil when the customer cancelled.
    var onFinish: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

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
        webView.load(URLRequest(url: URL(string: "\(applePayBase)/button/\(orderID)")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onFinish: (URL?) -> Void
        init(onFinish: @escaping (URL?) -> Void) { self.onFinish = onFinish }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.targetFrame?.isMainFrame != false,
                  let url = action.request.url else { return decisionHandler(.allow) }

            if url.absoluteString.hasPrefix("\(applePayBase)/done/") {
                decisionHandler(.cancel)
                onFinish(url)
            } else if url.absoluteString.hasPrefix("\(applePayBase)/cancelled") {
                decisionHandler(.cancel)
                onFinish(nil)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
```

## Step 7. Use it in your checkout

```swift
struct ApplePayResult: Decodable {
    let paid: Bool
    let reference: String
}

struct CheckoutView: View {
    let orderID: String
    @State private var attempt = 0
    @State private var status: String?

    var body: some View {
        VStack(spacing: 16) {
            // … your native order summary …

            ApplePayButton(orderID: orderID) { doneURL in
                attempt += 1 // new identity = new web view = new Hesabe session
                guard let doneURL else { return }
                Task { status = await confirm(doneURL) }
            }
            .id(attempt)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let status { Text(status) }
        }
        .padding()
    }

    func confirm(_ url: URL) async -> String {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let result = try? JSONDecoder().decode(ApplePayResult.self, from: data)
        else { return "Couldn't confirm the payment" }
        return result.paid ? "Paid" : "Payment didn't go through"
    }
}
```

- Always show the result from the done route. The Apple Pay sheet says "Done" even
  when the payment is declined.
- Each Hesabe session is single use, so the view gets a new `id` after every attempt.
- Hide the button for orders below the Apple Pay minimum. Hesabe sets it per method
  (KNET debit rejected 0.100 KWD and accepted 0.250 KWD).

## Step 8. Test on a real iPhone

Apple Pay needs a real device with a card in Wallet.

- In Debug builds, inspect the page from a Mac: Safari → Develop → your iPhone.
- If the sheet shows "Payment Not Completed" without asking the customer to confirm,
  the domain registration from Step 2 is missing. Ask Hesabe to verify it again.
- The sheet shows your merchant code ("Pay 842217") until Hesabe sets a display name.
