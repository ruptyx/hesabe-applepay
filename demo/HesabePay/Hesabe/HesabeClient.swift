import CommonCrypto
import Foundation

/// A Hesabe merchant account. Anything compiled into an app can be read out of it,
/// so keys in the app are keys anyone can use: they create sessions for any amount,
/// read transactions.
struct HesabeCredentials: Equatable {
    var merchantCode: String
    var accessCode: String
    /// AES-256 key, exactly 32 characters as Hesabe issues it.
    var secretKey: String
    /// AES IV, exactly 16 characters.
    var ivKey: String

    var isComplete: Bool {
        !merchantCode.isEmpty && !accessCode.isEmpty && secretKey.utf8.count == 32 && ivKey.utf8.count == 16
    }
}

enum HesabeEnvironment: String, CaseIterable, Identifiable {
    case sandbox, production

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var gateway: URL {
        switch self {
        case .sandbox: URL(string: "https://sandbox.hesabe.com")!
        case .production: URL(string: "https://api.hesabe.com")!
        }
    }
}

/// Hesabe's payment types, as `paymentType` on a checkout.
enum HesabePaymentType {
    static let hostedCheckout = 0
    static let knet = 1
    static let knetDebitApplePay = 11
    static let knetInternationalApplePay = 13
}

/// Calls Hesabe's gateway directly from the app, with the merchant's own keys.
/// The wire format is the one hesabe-node speaks: every payload AES-encrypted as
/// `data`, every answer a hex ciphertext (or plain JSON for errors).
struct HesabeClient {
    let environment: HesabeEnvironment
    let credentials: HesabeCredentials

    struct CheckoutParams {
        var amount: Decimal
        var orderReference: String
        var responseURL: URL
        var failureURL: URL
        var paymentType = HesabePaymentType.hostedCheckout
        /// The embedded/direct SDKs take a session instead of a redirect.
        var embedded = false
        /// Hesabe returns a `webviewUrl` made for in-app web views.
        var mobileChannel = false
        var name: String?
        var email: String?
        var mobileNumber: String?
    }

    struct CheckoutSession {
        /// Hesabe's transaction handle; the enquiry API accepts it.
        let token: String
        /// The one-shot session blob: `paymentURL` carries it, the embedded SDKs take it.
        let data: String
        /// Where a browser goes to pay on Hesabe's hosted page.
        let paymentURL: URL
        /// Present when `mobileChannel` was asked for.
        let webviewURL: URL?

        /// An embedded session is base64 JSON; Hesabe's Apple Pay script wants only the
        /// `data` inside it.
        var requestData: String {
            if let decoded = Data(base64Encoded: data),
               let session = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
               let inner = session["data"] as? String {
                return inner
            }
            return data
        }
    }

    // MARK: - Checkout

    /// Creates a single-use checkout session. Nothing is charged until the customer pays.
    func createCheckout(_ params: CheckoutParams) async throws -> CheckoutSession {
        var payload: [String: Any] = [
            "merchantCode": credentials.merchantCode,
            "amount": hesabeAmount(params.amount),
            "currency": "KWD",
            "paymentType": params.paymentType,
            "orderReferenceNumber": params.orderReference,
            "responseUrl": params.responseURL.absoluteString,
            "failureUrl": params.failureURL.absoluteString,
        ]
        let needsVersion3 = params.embedded || params.mobileChannel
        payload["version"] = needsVersion3 ? "3.0" : "2.0"
        if params.embedded {
            payload["embeddedPayment"] = true
            // Hesabe's Apple Pay guide requires the domain the button page is on.
            payload["variable5"] = params.responseURL.host() ?? ""
        }
        if params.mobileChannel { payload["channel"] = "mobile" }
        if let name = params.name { payload["name"] = name }
        if let email = params.email { payload["email"] = email }
        if let mobile = params.mobileNumber { payload["mobile_number"] = mobile }

        let (status, envelope) = try await send("POST", "checkout", payload: payload)
        guard envelope["status"] as? Bool == true,
              let response = envelope["response"] as? [String: Any],
              let data = response["data"] as? String, !data.isEmpty
        else { throw HesabeError.rejected(message(in: envelope) ?? "No checkout session", status: status) }

        var paymentURL = URLComponents(url: environment.gateway.appending(path: "payment"), resolvingAgainstBaseURL: false)!
        paymentURL.queryItems = [URLQueryItem(name: "data", value: data)]
        return CheckoutSession(
            token: envelope["token"] as? String ?? "",
            data: data,
            paymentURL: paymentURL.url!,
            webviewURL: (envelope["webviewUrl"] as? String).flatMap(URL.init(string:))
        )
    }

    // MARK: - Transactions

    /// Looks a payment up by the order reference its session was created with.
    /// `nil` means no payment for it has reached Hesabe.
    func transaction(orderReference: String) async throws -> HesabeTransaction? {
        try await lookup("api/transaction/\(orderReference)", query: [URLQueryItem(name: "isOrderReference", value: "1")])
    }

    /// Looks a payment up by the payment token Hesabe issued for it.
    func transaction(token: String) async throws -> HesabeTransaction? {
        try await lookup("api/transaction/\(token)")
    }

    private func lookup(_ path: String, query: [URLQueryItem] = []) async throws -> HesabeTransaction? {
        let (status, envelope) = try await send("GET", path, query: query)
        if status == 404 { return nil }
        if let record = record(in: envelope), envelope["status"] as? Bool != false {
            return HesabeTransaction(record)
        }
        let text = message(in: envelope) ?? "HTTP \(status)"
        // Hesabe answers an unknown reference with a "not found" message, and 404 only sometimes.
        if text.range(of: "not found", options: .caseInsensitive) != nil { return nil }
        throw HesabeError.rejected(text, status: status)
    }

    /// Decrypts the `data` Hesabe appends when it redirects back to the response or
    /// failure URL. Decrypting proves key possession, not integrity: confirm with a lookup.
    func parseRedirect(_ data: String) throws -> [String: Any] {
        try decryptObject(data, status: 200)
    }

    // MARK: - Transport

    /// Every request carries the access code, and every payload goes out AES-encrypted
    /// as `data`: in the body for POST/DELETE, in the query for GET.
    private func send(_ method: String,
                      _ path: String,
                      query: [URLQueryItem] = [],
                      payload: [String: Any]? = nil) async throws -> (status: Int, envelope: [String: Any]) {
        var url = environment.gateway.appending(path: path)
        var items = query
        if method == "GET", let payload {
            items.insert(URLQueryItem(name: "data", value: try encrypt(payload)), at: 0)
        }
        if !items.isEmpty { url.append(queryItems: items) }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue(credentials.accessCode, forHTTPHeaderField: "accessCode")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("hesabe-swift/0.1", forHTTPHeaderField: "User-Agent")
        if method != "GET", let payload {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["data": try encrypt(payload)])
        }

        let (body, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, try envelope(from: body, status: status))
    }

    /// Hesabe never redirects API calls; following one would re-send the access code
    /// to wherever it points.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func encrypt(_ payload: [String: Any]) throws -> String {
        let plaintext = try JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes)
        return try cipher.encrypt(plaintext)
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

    /// The transaction fields, wherever this endpoint put them.
    private func record(in envelope: [String: Any]) -> [String: Any]? {
        if let response = envelope["response"] as? [String: Any] {
            if let data = response["data"] as? [String: Any], data["status"] != nil || data["amount"] != nil { return data }
            return response
        }
        return envelope["data"] as? [String: Any]
    }

    private func message(in envelope: [String: Any]) -> String? {
        if let message = envelope["message"] as? String, !message.isEmpty { return message }
        if let errors = envelope["data"] as? [String: Any] {
            let lines = errors.compactMap { key, value -> String? in
                guard let messages = value as? [String] else { return nil }
                return "\(key): \(messages.joined(separator: " "))"
            }
            if !lines.isEmpty { return lines.sorted().joined(separator: "\n") }
        }
        return nil
    }

    private var cipher: HesabeCipher { HesabeCipher(secretKey: credentials.secretKey, ivKey: credentials.ivKey) }
}

/// A payment as Hesabe's enquiry API reports it.
struct HesabeTransaction {
    enum Status: String { case paid, failed, pending }

    let status: Status
    let amount: Decimal?
    let fields: [String: Any]

    init(_ record: [String: Any]) {
        fields = record
        amount = record["amount"].flatMap { Decimal(string: "\($0)", locale: Locale(identifier: "en_US_POSIX")) }

        // Prefer the numeric status. 1 is paid, 6 is paid through a multivendor split, 0 is failed.
        if let code = record["payment_status"].flatMap({ Int("\($0)") }) {
            status = [1, 6].contains(code) ? .paid : code == 0 ? .failed : .pending
            return
        }
        let texts = ["status", "result_code", "resultCode"].compactMap {
            (record[$0] as? String)?.trimmingCharacters(in: .whitespaces).uppercased()
        }
        if texts.contains(where: { ["SUCCESSFUL", "SUCCESS", "CAPTURED", "PAID", "APPROVED", "ACCEPT"].contains($0) }) {
            status = .paid
        } else if texts.contains(where: { ["FAILED", "FAILURE", "DECLINED", "CANCELLED", "CANCELED", "NOT CAPTURED", "REJECTED", "ERROR"].contains($0) }) {
            status = .failed
        } else {
            status = .pending
        }
    }

    var statusText: String? { fields["status"] as? String ?? fields["result_code"] as? String }
    var paymentID: String? { fields["PaymentID"].map { "\($0)" } ?? fields["paymentId"].map { "\($0)" } }
    var token: String? { fields["token"] as? String ?? fields["paymentToken"] as? String }
    var reference: String? { fields["reference_number"] as? String ?? fields["orderReferenceNumber"] as? String }
    var paymentType: String? { fields["payment_type"] as? String }
    var date: String? { fields["datetime"] as? String ?? fields["paidOn"] as? String }
    var customerCard: String? { fields["customerCard"] as? String }
}

enum HesabeError: LocalizedError {
    case invalidKeys
    case rejected(String, status: Int)
    case unreadableResponse(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKeys: "The Hesabe secret key must be 32 bytes and the IV key 16 bytes."
        case .rejected(let message, _): "Hesabe refused the request: \(message)"
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

/// Pretty-printed JSON, for showing a payload as it came.
func prettyJSON(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return "\(object)" }
    return String(decoding: data, as: UTF8.self)
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
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16)
            else { throw HesabeError.unreadableResponse(0) }
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
        guard input.count.isMultiple(of: kCCBlockSizeAES128) else { throw HesabeError.unreadableResponse(0) }

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
