import PassKit
import SwiftUI

struct CheckoutView: View {
    let total = "\(hesabeAmount(checkoutAmount)) KWD"

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
                        ApplePayButton(orderID: checkoutOrderID, amount: checkoutAmount) { outcome = $0 }
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
