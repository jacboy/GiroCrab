import SwiftUI
import GiroCrabCore

/// „Geplant“ (GitHub #240): everything already ordered at the bank but not
/// booked yet, across accounts. Only real orders – never guesses from the
/// booking history (those stay in the recurring-payments view).
struct PlannedPaymentsView: View {
    @Environment(AppModel.self) private var model

    private struct Month: Identifiable {
        let id: String // YYYY-MM
        let items: [PlannedPayment]
    }

    private var months: [Month] {
        Dictionary(grouping: model.plannedPayments) { String($0.date.prefix(7)) }
            .map { Month(id: $0.key, items: $0.value) }
            .sorted { $0.id < $1.id }
    }

    private struct ReloadKey: Equatable {
        let account: Int64?
        let horizon: PlannedHorizon
        let version: Int
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Geplant").appFont(.title2, weight: .semibold)
                Text("Zahlungen, die bei der Bank bereits beauftragt, aber noch nicht gebucht sind.")
                    .appFont(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Picker("Konto", selection: $model.plannedAccountFilter) {
                    Text("Alle Konten").tag(Int64?.none)
                    Divider()
                    ForEach(model.allAccounts) { a in
                        Label(a.name, systemImage: a.sfSymbol).tag(Int64?.some(a.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .sensitive(model.plannedAccountFilter == nil ? [] : .personal) // the selected account's name
                .frame(minWidth: 150, maxWidth: 240)
                Picker("Zeitraum", selection: $model.plannedHorizon) {
                    ForEach(PlannedHorizon.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 140)
                Spacer(minLength: 0)
            }
            totals
            if model.plannedPayments.isEmpty {
                ContentUnavailableView(
                    "Keine geplanten Zahlungen",
                    systemImage: "calendar.badge.clock",
                    description: Text("Terminüberweisungen, die du in GiroCrab beauftragst, erscheinen hier bis zur Ausführung."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(months) { month in
                        Section {
                            ForEach(month.items, id: \.id) { row($0) }
                        } header: {
                            Text(DateText.date(month.id + "-01")?.formatted(.dateTime.month(.wide).year()) ?? month.id).appSectionHeader()
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .task(id: ReloadKey(account: model.plannedAccountFilter, horizon: model.plannedHorizon, version: model.plannedVersion)) {
            await model.reloadPlanned()
        }
    }

    private var totals: some View {
        HStack(spacing: 24) {
            totalCell("Abgehend", model.plannedTotals.outgoingCents)
            totalCell("Eingehend", model.plannedTotals.incomingCents)
            Spacer(minLength: 0)
        }
        .card(padding: 12)
    }

    private func totalCell(_ label: LocalizedStringKey, _ cents: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).appFont(.caption).foregroundStyle(Theme.secondary)
            Text(Money.format(cents)).appFont(.title3, weight: .semibold, monospacedDigit: true)
                .fixedSize().sensitive()
        }
    }

    private func row(_ p: PlannedPayment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.counterparty).fontWeight(.medium).lineLimit(1).sensitive()
                Text(p.purpose.isEmpty ? p.accountName : "\(p.purpose) · \(p.accountName)")
                    .appFont(.caption).foregroundStyle(Theme.secondary).lineLimit(1).sensitive()
                Text("Terminüberweisung").appFont(.caption2).foregroundStyle(Theme.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(p.amountCents))
                    .appFont(.body, weight: .medium, monospacedDigit: true)
                    .foregroundStyle(p.amountCents < 0 ? Theme.negative : Theme.invest)
                    .fixedSize().sensitive()
                Text(DateText.medium(p.date)).appFont(.caption, monospacedDigit: true).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
