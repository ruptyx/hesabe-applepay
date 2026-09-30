import PassKit
import SwiftUI

/// A checkout where everything is native except the Apple Pay button, and no backend
/// is involved: the app talks to Hesabe with the merchant's keys.
///
///   Apple Pay  the hosted button page in a button-sized web view (the sheet is the
///              system's), confirmed by a lookup
///   KNET       KNET's page, via Hesabe, in a sheet with a native bar, confirmed by a lookup
@MainActor
struct CheckoutView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case applePay = "Apple Pay"
        case knet = "KNET"

        var id: String { rawValue }
        var symbol: String { self == .applePay ? "apple.logo" : "creditcard" }
        var detail: String { self == .applePay ? "Cards in Wallet" : "Kuwaiti debit cards" }
    }

    @State private var cart = Cart.demo
    @State private var method = Method.applePay
    @State private var applePayType = HesabePaymentType.knetDebitApplePay

    @State private var hosted: HostedAttempt?
    @State private var outcome: PaymentOutcome?
    @State private var busy: String?
    @State private var failure: String?

    private let canUseApplePay = PKPaymentAuthorizationController.canMakePayments()

    private struct HostedAttempt: Identifiable {
        let attempt: PaymentAttempt
        let title: String
        var id: String { attempt.id }
    }

    private let client = Config.client
    private var amount: Decimal { cart.subtotal }

    var body: some View {
        NavigationStack {
            Form {
                orderSection
                methodSection
            }
            .navigationTitle("Checkout")
            .safeAreaInset(edge: .bottom) { payBar }
            .disabled(busy != nil)
            .overlay {
                if let busy {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(busy).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .sheet(item: $hosted) { hosted in
                HostedPaymentSheet(attempt: hosted.attempt, title: hosted.title) { finish($0) }
            }
            .sheet(item: $outcome) { outcome in
                OutcomeSheet(outcome: outcome)
                    .presentationDetents([.medium, .large])
            }
            .alert("Couldn't start", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK") {}
            } message: {
                Text(failure ?? "")
            }
        }
    }

    // MARK: Sections

    private var orderSection: some View {
        Section {
            ForEach($cart.items) { $item in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(hesabeAmount(item.price * Decimal(item.quantity)))
                        .monospacedDigit()
                        .foregroundStyle(item.quantity == 0 ? .tertiary : .secondary)
                    Stepper(value: $item.quantity, in: 0...9) {
                        Text("\(item.quantity)")
                            .monospacedDigit()
                            .frame(minWidth: 16)
                    }
                    .fixedSize()
                }
            }
            LabeledContent("Total") {
                Text("\(hesabeAmount(amount)) KWD")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        } header: {
            Text("Order · \(cart.count) items")
        } footer: {
            Text(cart.canPay
                 ? "Every payment is a real charge."
                 : "Hesabe's minimum is \(hesabeAmount(Cart.minimum)) KWD.")
        }
    }

    private var methodSection: some View {
        Section("Payment method") {
            ForEach(Method.allCases) { choice in
                Button {
                    method = choice
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: choice.symbol)
                            .font(.title3)
                            .frame(width: 28)
                            .foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.rawValue)
                                .foregroundStyle(.primary)
                            Text(choice.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: method == choice ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(method == choice ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                }
            }
            if method == .applePay {
                Picker("Card type", selection: $applePayType) {
                    Text("KNET debit").tag(HesabePaymentType.knetDebitApplePay)
                    Text("International").tag(HesabePaymentType.knetInternationalApplePay)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    // MARK: Pay bar

    /// One button, swapped with the method: WebKit's Apple Pay button, or a native KNET one.
    private var payBar: some View {
        Group {
            if !cart.canPay {
                note("Add something to the order to pay.")
            } else if method == .applePay, !canUseApplePay {
                note("Apple Pay is not available on this device.")
            } else if method == .applePay {
                ApplePayButton(client: client, amount: amount, paymentType: applePayType) { finish($0) }
                    .id("\(amount)-\(applePayType)")
            } else {
                Button {
                    startHosted(title: "KNET", method: "KNET") { $0.paymentType = HesabePaymentType.knet }
                } label: {
                    Label("Pay \(hesabeAmount(amount)) KWD with KNET", systemImage: "creditcard")
                }
                .buttonStyle(PayButtonStyle())
            }
        }
        // Every state is exactly the Apple Pay button's size, so nothing below moves.
        .frame(maxWidth: .infinity)
        .frame(height: PayButtonStyle.height)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .animation(.easeOut(duration: 0.2), value: method)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: Actions

    private func finish(_ outcome: PaymentOutcome) {
        UINotificationFeedbackGenerator().notificationOccurred(outcome.state == .paid ? .success : .error)
        self.outcome = outcome
    }

    private func startHosted(title: String, method: String,
                             configure: @escaping (inout HesabeClient.CheckoutParams) -> Void) {
        run("Starting \(title)…") {
            let attempt = try await PaymentAttempt.start(client: client, method: method, amount: amount, configure: configure)
            hosted = HostedAttempt(attempt: attempt, title: title)
        }
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) {
        busy = label
        Task {
            do { try await work() } catch { failure = error.localizedDescription }
            busy = nil
        }
    }
}

/// The native buttons in the pay bar: the Apple Pay button's height, radius and press dim.
struct PayButtonStyle: ButtonStyle {
    static let height = 50.0
    static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(tint, in: Self.shape)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: configuration.isPressed ? 0.05 : 0.25), value: configuration.isPressed)
    }
}

#Preview {
    CheckoutView()
}
