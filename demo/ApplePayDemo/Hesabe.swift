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
