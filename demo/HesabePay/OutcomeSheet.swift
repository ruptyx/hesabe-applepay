import SwiftUI

/// The result of one payment: what Hesabe's lookup said, and the payloads as they came.
struct OutcomeSheet: View {
    let outcome: PaymentOutcome

    @Environment(\.dismiss) private var dismiss

    private var symbol: (name: String, color: Color) {
        switch outcome.state {
        case .paid: ("checkmark.circle.fill", .green)
        case .failed, .cancelled: ("xmark.circle.fill", .red)
        case .pending: ("clock.fill", .orange)
        case .unconfirmed: ("questionmark.circle.fill", .orange)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: symbol.name)
                            .font(.system(size: 52))
                            .foregroundStyle(symbol.color)
                        Text(outcome.title)
                            .font(.title2.weight(.semibold))
                        Text("\(hesabeAmount(outcome.transaction?.amount ?? outcome.amount)) KWD · \(outcome.method)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(outcome.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section {
                    row("Reference", outcome.reference)
                    if let transaction = outcome.transaction {
                        row("Status", transaction.statusText)
                        row("Method", transaction.paymentType)
                        row("Payment ID", transaction.paymentID)
                        row("Card", transaction.customerCard)
                        row("Time", transaction.date)
                    }
                }

                ForEach(outcome.raw, id: \.title) { section in
                    Section {
                        DisclosureGroup(section.title) {
                            Text(section.body)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        Button("Copy") { UIPasteboard.general.string = section.body }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
