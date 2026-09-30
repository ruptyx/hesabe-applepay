import Foundation

/// A demo order. Prices are tiny on purpose: every payment is a real one.
struct CartItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let detail: String
    let price: Decimal
    var quantity: Int
}

struct Cart: Equatable {
    var items: [CartItem]

    static let demo = Cart(items: [
        CartItem(name: "Karak tea", detail: "Small, extra cardamom", price: 0.250, quantity: 1),
        CartItem(name: "Regag bread", detail: "Cheese and honey", price: 0.350, quantity: 1),
        CartItem(name: "Water", detail: "330 ml", price: 0.100, quantity: 2),
    ])

    var subtotal: Decimal {
        items.reduce(0) { $0 + $1.price * Decimal($1.quantity) }
    }

    var count: Int { items.reduce(0) { $0 + $1.quantity } }

    /// Hesabe's checkout validator floors the amount at 0.200 KWD.
    static let minimum = Decimal(string: "0.200")!

    var canPay: Bool { subtotal >= Self.minimum }
}
