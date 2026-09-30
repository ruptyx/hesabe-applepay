# Apple Pay and KNET in SwiftUI with Hesabe, no backend

The app talks to Hesabe directly with the merchant's keys. It creates the payment
session, shows the payment, and asks Hesabe whether the money moved. Nothing runs on a
server. The only hosted thing is one static HTML file that draws the Apple Pay button.

Everything on screen is native SwiftUI except that button, which is WebKit's, shown in a
web view the size of the button. KNET opens KNET's own page in a sheet with a native bar.

[`demo/`](demo) is the complete Xcode project. [`web/apple-pay.html`](web/apple-pay.html)
is the page to host.

## What you need before starting

1. Apple Pay enabled on your Hesabe merchant account. Email support@hesabe.com.
2. A domain registered with Apple through Hesabe. Email itsupport@hesabe.com with the
   domain that will serve the button page. Hesabe sends back a domain association file.
   Serve it as plain text at
   `https://your-domain.com/.well-known/apple-developer-merchantid-domain-association.txt`,
   and only then tell Hesabe to verify. A verification that runs before the file is live
   fails silently.
3. Your Apple Pay payment type. `11` is KNET debit, `13` is KNET international. Ask Hesabe
   which ones your account has.
4. Your keys from Merchant Panel, Profile, Merchant Keys: merchant code, access code,
   secret key (32 characters), IV key (16 characters).

## Step 1. Host the HTML file

Copy [`web/apple-pay.html`](web/apple-pay.html) to the domain from the list above, next
to the association file. Any static host works. Note the URL, for example
`https://your-domain.com/apple-pay.html`.

### What the file does

It is the same file for every payment and holds no keys.

- It loads Hesabe's `direct-apple-pay` script from unpkg, pinned to version 1.0.15 and
  checked against an integrity hash, so a changed file never runs.
- It draws one button with WebKit's `-webkit-appearance: -apple-pay-button`, filling the
  page on a transparent background. The app sizes and clips it.
- It reads the payment's settings from the URL fragment (the part after `#`). Browsers
  never send the fragment to a server. The app puts a JSON object there:

  ```json
  { "requestData": "...", "environment": "production", "paymentType": 11,
    "cancelUrl": "https://your-domain.com/pay/cancelled" }
  ```

- On tap it calls `processPayment(paymentType)`, inside the tap, which Apple Pay requires.
- After the sheet, Hesabe's script sends the page to Hesabe, which redirects to the
  session's response URL. If the customer closes the sheet, the page goes to `cancelUrl`.
  The app stops both navigations before they load, so neither URL has to exist.

Why it can't live inside the app: Hesabe validates the Apple Pay merchant against the
registered domain, and WebKit refuses to start Apple Pay from `loadHTMLString`,
`loadFileURL` or `loadSimulatedRequest`.

If your site sends a `Content-Security-Policy`, allow `https://unpkg.com`,
`https://applepay.cdn-apple.com` and `https://api.hesabe.com`.

## Step 2. Put in your keys

Open `demo/HesabePay/Secrets.swift` and replace the placeholders:

```swift
enum Secrets {
    static let production = HesabeCredentials(
        merchantCode: "YOUR_MERCHANT_CODE",
        accessCode: "YOUR_ACCESS_CODE",
        secretKey: "YOUR_32_CHARACTER_SECRET_KEY____",
        ivKey: "YOUR_16_CHAR_IV_"
    )
}
```

Anyone can extract keys from an app. With them they can create sessions for any amount,
read your transactions and decrypt what Hesabe encrypts for you. Know that before
shipping, and never commit real keys.

## Step 3. Put in your URLs

Open `demo/HesabePay/Config.swift`:

```swift
/// Where you host web/apple-pay.html, on the registered domain.
static let applePayPage = URL(string: "https://example.com/apple-pay.html")!

/// Hesabe redirects here afterwards. The app stops the navigation, so nothing has to exist here.
static let returnBase = URL(string: "https://example.com/pay/")!
```

Use the exact host you registered. If you registered the apex, don't use `www`.
`Config.client` is the production client; change `.production` to `.sandbox` to use
Hesabe's sandbox with sandbox keys.

Then set the Apple Pay type in `CheckoutView.swift` if yours is not `11` or `13`.

## Step 4. Run it

1. Open `demo/HesabePay.xcodeproj` in Xcode 16 or later.
2. Under Signing & Capabilities pick your team. No Apple Pay capability is needed: the
   payment belongs to the page, not the app.
3. Run on an iPhone with a card in Wallet. Apple Pay doesn't complete in the simulator.

Every payment is a real charge. Hesabe's minimum is 0.200 KWD.

## How the app works

`demo/HesabePay/` in the order a payment goes through it:

| File | Role |
|---|---|
| `Cart.swift` | A prefilled demo order. The total is the amount charged. |
| `CheckoutView.swift` | The screen: order, a choice between Apple Pay and KNET, and one pay button that swaps with the choice. |
| `Hesabe/HesabeClient.swift` | Calls Hesabe: AES-256-CBC with Hesabe's 32-byte padding, checkout creation, transaction lookup, redirect decryption. |
| `Hesabe/PaymentAttempt.swift` | One session per try, with its order reference and return URLs. Asks Hesabe how it ended, retrying for 30 seconds while pending. |
| `ApplePay/ApplePayButton.swift` | Creates the session, builds the page URL with the fragment, and wraps the web button in native states: a `PKPaymentButton` stand-in while loading, "Processing" while Hesabe charges, a retry on failure. |
| `ApplePay/ApplePayWebButton.swift` | The `WKWebView` that is only the button. Transparent, no scrolling, no script injection. Reports what happens from the page's navigations. |
| `Hosted/HostedPaymentSheet.swift` | KNET: Hesabe's hosted page in a full sheet with a native title and Cancel. Ends when Hesabe redirects back. |
| `OutcomeSheet.swift` | The result, with the decrypted redirect and the lookup payload shown as they came. |

Things that matter:

- Never add a `WKUserScript` or call `evaluateJavaScript` on the button's web view.
  Either one turns Apple Pay off for the page. Every event is read from navigations.
- The Apple Pay sheet says "Done" even when the payment is declined. Always show the
  result of the lookup, never the sheet's.
- The Apple Pay redirect has no `paymentToken`, so the app looks the payment up by the
  order reference it created the session with.
- Sessions are single use. After every result the app creates a new one.
- An embedded session's `data` is base64 JSON. The Apple Pay script wants the `data`
  inside it. `HesabeClient.CheckoutSession.requestData` does that.

## If something goes wrong

- Inspect the page from a Mac in Debug builds: Safari, Develop, your iPhone.
- The button never appears: open the page's console. A 400 from `checkout-details`
  means the session was made with different keys or environment than the page uses.
- The sheet shows "Payment Not Completed" without asking to confirm: the domain is not
  registered, or was verified before the association file was live.
- The sheet shows your merchant code as the name until Hesabe sets a display name.
