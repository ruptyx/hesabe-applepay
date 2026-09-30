import Foundation

/// Everything the app needs to reach Hesabe. No backend: the app creates the sessions
/// and reads the results itself. The one thing hosted is the Apple Pay button page.
enum Config {
    /// The merchant, on production. The keys live in Secrets.swift, which git ignores.
    static let client = HesabeClient(environment: .production, credentials: Secrets.production)

    /// Where you host `web/apple-pay.html`, on the domain Hesabe registered with Apple.
    /// Use the exact host you registered: if that is the apex, don't use www.
    // static let applePayPage = URL(string: "https://derahkw.com/apple-pay.html")!
    static let applePayPage = URL(string: "https://example.com/apple-pay.html")!

    /// Hesabe redirects the hosted pages and the Apple Pay page here afterwards. The app
    /// stops those navigations before they load, so nothing has to exist at these paths.
    // static let returnBase = URL(string: "https://derahkw.com/pay/")!
    static let returnBase = URL(string: "https://example.com/pay/")!
}
