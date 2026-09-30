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
