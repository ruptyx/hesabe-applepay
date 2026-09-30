import Foundation

/// Your Hesabe production keys: Merchant Panel → Profile → Merchant Keys.
/// Anything compiled into an app can be read out of it, so treat these as public
/// once the app ships. Never commit real keys to a public repository.
enum Secrets {
    static let production = HesabeCredentials(
        merchantCode: "YOUR_MERCHANT_CODE",
        accessCode: "YOUR_ACCESS_CODE",
        secretKey: "YOUR_32_CHARACTER_SECRET_KEY____",
        ivKey: "YOUR_16_CHAR_IV_"
    )
}
