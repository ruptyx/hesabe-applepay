# Apple Pay in native apps

Hesabe Apple Pay inside a React Native or SwiftUI app, using your own button and the
system Apple Pay sheet. Backend examples use the Hesabe SDKs:
[hesabe-node](https://github.com/ruptyx/hesabe-node) and
[hesabe-python](https://github.com/ruptyx/hesabe-python).

Hesabe does not document in-app Apple Pay through PassKit. Apple Pay goes through the
web: Hesabe validates the merchant against a domain it registered with Apple, so the
payment has to start from a page on that domain. The app shows that page as a
borderless WebView containing only the Apple Pay button. The sheet the customer sees
is the real system sheet either way.

```
App screen (native)                 Your backend                      Hesabe
───────────────────                 ────────────                      ──────
WebView ── GET /pay/apple-pay/button/ORDER-1001 ──▶ checkout.create ──▶ session
        ◀── page with a single Apple Pay button ────
tap ──────────────────── Apple Pay sheet ──────────────────────────▶ validate + charge
        ◀── navigates to /pay/apple-pay/done/ORDER-1001-… ◀──────── redirect
app stops that navigation ── GET …/done/… ─▶ transactions.retrieveByOrderReference
        ◀── { paid, reference, transaction } ──
```

## Demo app

[`demo/`](demo) is an Expo SDK 54 app with a native checkout screen and the Apple
Pay button from [React Native](#react-native). It runs in Expo Go. It needs a backend
serving the routes from [Backend](#backend) on your Hesabe-registered domain.

1. Set `BASE` in [`demo/components/ApplePayButton.tsx`](demo/components/ApplePayButton.tsx)
   to your backend's Apple Pay routes.
2. Set `ORDER` in [`demo/App.tsx`](demo/App.tsx) to an order your backend knows,
   at or above the Apple Pay minimum (see [Behavior worth knowing](#behavior-worth-knowing)).
3. Run it:

   ```bash
   cd demo
   npm install
   npx expo start
   ```

   Scan the QR code with an iPhone camera to open it in Expo Go. Use
   `npx expo start --tunnel` if the phone isn't on the same network. Apple Pay needs
   a real iPhone with a card in Wallet.

## Before you start

1. **Enable Apple Pay on your merchant account.** Email support@hesabe.com.
2. **Register your domain.** Email itsupport@hesabe.com with the domain that will serve
   the button page. Hesabe sends back a domain association file. Serve it as plain text at:

   ```
   https://yourshop.com/.well-known/apple-developer-merchantid-domain-association.txt
   ```

   Only tell Hesabe once the file is live. Apple checks the file when Hesabe presses
   verify, so a verification run before the file was reachable fails. Nothing tells you
   it failed.
3. **Find your Apple Pay payment types.** Each merchant has its own set. Hesabe's
   checkout-details endpoint lists them, and needs no access code:

   ```ts
   const session = await hesabe.checkout.create({ embedded: true, amount: 1, /* … */ });
   const { data } = JSON.parse(Buffer.from(session.data, "base64").toString());
   const details = await fetch(`https://api.hesabe.com/api/checkout-details?data=${data}`)
     .then((r) => r.json());

   details.response.applePay.map((method) => method.id); // e.g. [11, 13]
   ```

| Type | Apple Pay method | Notes |
|---|---|---|
| `9` | MPGS | |
| `10` | CyberSource | |
| `11` | KNET debit | Kuwait-issued debit cards; shown as "Apple Pay (KNET)" in Hesabe's checkout |
| `12` | KNET credit | |
| `13` | KNET international | Other cards; shown as "Apple Pay" in Hesabe's checkout |
| `14` | American Express | |

One button starts one type. With both 11 and 13 enabled, either choose the one your
customers use most, or show two buttons.

## Backend

Three things: a route that serves the button page, a route the app asks for the
result, and the webhook from the SDK README as a backup.

The button page loads Hesabe's `direct-apple-pay` browser SDK and draws WebKit's
built-in Apple Pay button. Pin the version; `@latest` can change a payment page
without warning.

```js
const APPLE_PAY_SDK =
  "https://unpkg.com/@hesabe-pay/direct-apple-pay@1.0.15/cdn/hesabe-apple-pay.min.js";

/** HTML with nothing but a system Apple Pay button, sized by the WebView around it. */
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

### Node

```ts
import express from "express";
import { Hesabe, HesabeError, isSuccessful } from "hesabe";

const hesabe = new Hesabe();
const BASE = "https://yourshop.com/pay/apple-pay";
const APPLE_PAY_TYPE = 11; // from checkout-details, see "Before you start"

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

### Python

```python
import base64
import json
import os
import time

from flask import jsonify
from hesabe import Hesabe, HesabeError, is_successful

hesabe = Hesabe()
BASE = "https://yourshop.com/pay/apple-pay"
APPLE_PAY_TYPE = 11


@app.get("/pay/apple-pay/button/<order_id>")
def apple_pay_button(order_id):
    order = load_order(order_id)
    reference = f"{order.id}-{int(time.time() * 1000)}"
    record_attempt(order.id, reference)

    session = hesabe.checkout.create(
        amount=order.total,
        order_reference_number=reference,
        response_url=f"{BASE}/done/{reference}",
        failure_url=f"{BASE}/done/{reference}",
        webhook_url="https://yourshop.com/hesabe/webhook",
        embedded=True,
    )

    wrapped = session["data"]
    request_data = json.loads(base64.b64decode(wrapped + "=" * (-len(wrapped) % 4)))["data"]

    html = apple_pay_page(
        request_data=request_data,
        payment_type=APPLE_PAY_TYPE,
        environment=os.environ["HESABE_ENVIRONMENT"],
        cancel_url=f"{BASE}/cancelled",
    )
    return html, {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store"}


@app.get("/pay/apple-pay/done/<reference>")
def apple_pay_done(reference):
    try:
        transaction = hesabe.transactions.retrieve_by_order_reference(reference)
    except HesabeError as exc:
        if exc.status_code != 404:
            raise
        transaction = None

    paid = transaction is not None and is_successful(transaction)
    if paid:
        fulfil(reference)
    return jsonify(paid=paid, reference=reference, transaction=transaction)
```

`apple_pay_page` is the same HTML template as above.

The done route confirms the payment by looking up the reference in the URL's path, so
it never trusts anything the customer's device carried back. Don't use
`verifyRedirect` here. The Apple Pay SDK's redirect payload has no `paymentToken`, so
`verifyRedirect` throws `Redirect payload has no payment token` even when the payment
succeeded.

**Protect the button route like any other order endpoint.** Anyone who has the URL can
create a checkout session for that order. A short-lived signed token in the path or
query works for both apps. React Native can also send headers on the first request.

If your site sends a `Content-Security-Policy` with `script-src` or `connect-src`,
allow `https://unpkg.com` (the SDK) and `https://api.hesabe.com` (the SDK calls it
for checkout details, merchant validation and the result).

## React Native

```bash
npx expo install react-native-webview
```

Works in Expo Go and in development builds; tested on Expo SDK 54 with
`react-native-webview` 13.15.0. A runnable version is in [`demo/`](demo).

```tsx
import { useState } from "react";
import { Platform, StyleSheet, View } from "react-native";
import { WebView } from "react-native-webview";

// Your backend's Apple Pay routes: see "Backend" in the README.
// Must be on the domain Hesabe registered with Apple for your merchant.
const BASE = "https://yourshop.com/pay/apple-pay";

export type ApplePayResult = { paid: boolean; cancelled?: boolean; reference?: string };

export function ApplePayButton({
  orderId,
  onResult,
}: {
  orderId: string;
  onResult: (result: ApplePayResult) => void;
}) {
  const [attempt, setAttempt] = useState(0); // new key = new WebView = new Hesabe session

  if (Platform.OS !== "ios") return null;

  function intercept(url: string) {
    if (url.startsWith(`${BASE}/done/`)) {
      fetch(url)
        .then((res) => res.json())
        .then(onResult)
        .catch(() => onResult({ paid: false }));
    } else if (url.startsWith(`${BASE}/cancelled`)) {
      onResult({ paid: false, cancelled: true });
    } else {
      return true;
    }
    setAttempt((n) => n + 1);
    return false;
  }

  return (
    <View style={styles.button}>
      <WebView
        key={attempt}
        source={{ uri: `${BASE}/button/${orderId}` }}
        // Apple Pay only works in a WKWebView with no injected scripts;
        // this also disables injectedJavaScript and postMessage.
        enableApplePay
        webviewDebuggingEnabled={__DEV__}
        scrollEnabled={false}
        style={styles.transparent}
        containerStyle={styles.transparent}
        onShouldStartLoadWithRequest={(req) => req.isTopFrame === false || intercept(req.url)}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  button: { height: 50, borderRadius: 8, overflow: "hidden" },
  transparent: { backgroundColor: "transparent" },
});
```

```tsx
<ApplePayButton
  orderId={order.id}
  onResult={(result) => {
    if (result.paid) navigation.replace("OrderConfirmed", { orderId: order.id });
    else if (!result.cancelled) showError("Payment didn't go through");
  }}
/>
```

`enableApplePay` is required. WebKit turns Apple Pay off for any page with injected
JavaScript, so this prop also disables `injectedJavaScript`, `injectJavaScript()`,
`injectedJavaScriptBeforeContentLoaded`, `sharedCookiesEnabled` and the HTML5 history
shim. The app therefore finds out what happened from the URLs the page navigates to,
not from `postMessage`. `onShouldStartLoadWithRequest` is native and keeps working.

`webviewDebuggingEnabled={__DEV__}` lets you read Hesabe's logs during development:
open Safari → Develop → your iPhone on a Mac.

## SwiftUI

The same rules apply: no scripts injected into the web view, and find out the result
from navigations. `react-native-webview` with `enableApplePay` is this exact
WKWebView setup.

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

## Behavior worth knowing

Probed on production (September 2026, merchant with Apple Pay types 11 and 13).
Hesabe's docs cover none of it.

- **The sheet always says "Done".** The SDK reports success to Apple Pay before
  Hesabe returns the result. The customer sees a checkmark even for a declined
  payment, so the app must show its own result from the done route.
- **`session.data` is a wrapper.** It is base64 JSON:
  `{ data, token, session_id, track_id, payment_types, amount }`. Hesabe's embedded
  checkout unwraps it itself, but `direct-apple-pay` needs the inner `data`. Passing
  the wrapper fails with `checkout-details` 400 `Failed to decrypt data parameter`.
- **Apple Pay has a minimum amount.** Apple Pay KNET (type 11) rejected 0.100 KWD with
  422 `Minimum amount error for chosen payment method, please try other payment
  method` and accepted 0.250 KWD. The exact figure is set per method on Hesabe's side
  and isn't published. Keep smaller orders off Apple Pay before you show the button.
- **A missing domain registration looks like a card problem.** The sheet opens, then
  shows "Payment Not Completed" without asking the customer to confirm. On a Mac,
  Safari's Web Inspector shows the cause: merchant validation returns a ~145-byte
  error body instead of a merchant session, and Wallet rejects it with `-25293`. Ask
  Hesabe to run the domain verification again.
- **The sheet shows your merchant code** ("Pay 842217") until Hesabe sets a display
  name for your account.
- **Tapping before `init()` finishes throws.** `init()` fetches the checkout details
  and doesn't return a promise. A tap in the first few hundred milliseconds throws
  `Token not available`; the next tap works.
- **Each session is single use.** After a payment or cancel, load a new page, which
  creates a new session. Both examples do this by changing the web view's `key` / `id`.
