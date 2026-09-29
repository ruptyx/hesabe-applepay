import PassKit
import SwiftUI

struct CheckoutView: View {
    /// An order your backend knows, at or above the Apple Pay minimum.
    let orderID = "ORDER-1001"
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
                        ApplePayButton(orderID: orderID) { outcome = $0 }
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
