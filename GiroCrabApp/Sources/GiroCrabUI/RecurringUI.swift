import SwiftUI
import GiroCrabCore

// Wiederkehrende Buchungen (GitHub #35): inspector card, menu, month overview sheet.

extension RecurrenceInterval {
    static let fixed: [RecurrenceInterval] = [.monthly, .quarterly, .halfYearly, .yearly]

    var label: String {
        switch self {
        case .monthly: return String(localized: "Monatlich")
        case .quarterly: return String(localized: "Vierteljährlich")
        case .halfYearly: return String(localized: "Halbjährlich")
        case .yearly: return String(localized: "Jährlich")
        case .custom: return String(localized: "Individuell")
        }
    }
}

/// "15.03., 15.08." in the user's order of day and month.
enum CustomDates {
    /// Parses "15.03.", "15.3", "03-15"; returns valid MM-DD and the tokens it could not read.
    static func parse(_ text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = [], invalid: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            let token = String(raw)
            let t = token.hasSuffix(".") ? String(token.dropLast()) : token
            var md: (Int, Int)?
            if t.contains("-") {
                let p = t.split(separator: "-")
                if p.count == 2, let m = Int(p[0]), let d = Int(p[1]) { md = (m, d) }
            } else {
                let p = t.split(separator: ".")
                if p.count == 2, let d = Int(p[0]), let m = Int(p[1]) { md = (m, d) }
            }
            // a leap year accepts 29.02.
            if let (m, d) = md,
               let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: m, day: d).date,
               Calendar(identifier: .gregorian).component(.day, from: date) == d {
                let key = String(format: "%02d-%02d", m, d)
                if !valid.contains(key) { valid.append(key) }
            } else {
                invalid.append(token)
            }
        }
        return (valid.sorted(), invalid)
    }

    /// "15. März" for "03-15".
    static func display(_ mmdd: String) -> String {
        let p = mmdd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2,
              let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: p[0], day: p[1]).date
        else { return mmdd }
        return date.formatted(.dateTime.day().month(.wide))
    }

    /// "15.03." for "03-15".
    static func short(_ mmdd: String) -> String {
        let p = mmdd.split(separator: "-")
        return p.count == 2 ? "\(p[1]).\(p[0])." : mmdd
    }
}

extension RecurringSeries {
    /// "Monatlich" or "Individuell (15.03., 15.08.)".
    var intervalText: String {
        guard interval == .custom, !customDates.isEmpty else { return interval.label }
        return "\(interval.label) (\(customDates.map(CustomDates.short).joined(separator: ", ")))"
    }
}

/// Interval choices for one booking – used in the inspector card and the "Buchung" menu.
/// The current interval carries a checkmark.
/// Menu-bar commands don't inherit the window's environment, so the model is passed in.
struct RecurringMenu: View {
    let model: AppModel
    let booking: Booking?

    var body: some View {
        Menu("Wiederkehrend") {
            RecurringMenuItems(model: model, booking: booking)
        }
    }
}

/// The entries of `RecurringMenu` (also used inside the inspector card's menu).
struct RecurringMenuItems: View {
    let model: AppModel
    let booking: Booking?

    var body: some View {
        let series = booking.flatMap { model.recurringSeries(for: $0) }
        ForEach(RecurrenceInterval.fixed, id: \.self) { i in
            Toggle(i.label, isOn: Binding(
                get: { series?.interval == i },
                set: { _ in if let b = booking { model.markRecurring(b, i) } }
            ))
        }
        Toggle("Individuell …", isOn: Binding(
            get: { series?.interval == .custom },
            set: { _ in model.customRecurringBooking = booking }
        ))
        Divider()
        if let s = series, s.source == .manual {
            Button("Automatisch erkennen") { model.resetRecurring(s) }
        }
        Button("Nicht wiederkehrend") { if let s = series { model.ignoreRecurring(s) } }
            .disabled(series == nil)
    }
}

/// Inspector card: is this booking part of a recurring series? Mark / change / hide.
struct RecurringCard: View {
    @Environment(AppModel.self) private var model
    let booking: Booking

    var body: some View {
        let series = model.recurringSeries(for: booking)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Wiederkehrend", systemImage: "repeat")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(series == nil ? Theme.text : Theme.accent)
                Spacer()
                Menu {
                    RecurringMenuItems(model: model, booking: booking)
                } label: {
                    Text(series == nil ? "Markieren" : "Ändern")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(series == nil ? "Als wiederkehrend markieren" : "Turnus ändern")
            }
            if let s = series {
                Text("\(s.intervalText) · nächste am \(DateText.medium(s.nextDue))")
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                Text(s.source == .manual
                     ? "Manuell markiert · ca. \(Money.format(s.amountCents))"
                     : "Automatisch erkannt aus \(s.occurrences) Buchungen · ca. \(Money.format(s.amountCents))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Nicht als wiederkehrend erkannt. Markieren Sie die Buchung, damit sie in den anstehenden Fixkosten erscheint.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Custom recurrence, e.g. "15.03., 15.08." (every year on these days).
struct CustomDatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initialDates: [String]
    let onSave: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let parsed = CustomDates.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            Text("Individueller Turnus").font(.headline)
            Text("Tage im Jahr, an denen die Buchung fällig ist, z. B. „15.03., 15.08.“.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("15.03., 15.08.", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save(parsed) }
            Group {
                if !parsed.invalid.isEmpty {
                    Label("Kein gültiges Datum: \(parsed.invalid.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.outflow)
                } else if !parsed.valid.isEmpty {
                    Label("Jedes Jahr am \(ListFormatter.localizedString(byJoining: parsed.valid.map(CustomDates.display)))", systemImage: "calendar")
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") { save(parsed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed.valid.isEmpty || !parsed.invalid.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear {
            text = initialDates.map(CustomDates.short).joined(separator: ", ")
            focused = true
        }
    }

    private func save(_ parsed: (valid: [String], invalid: [String])) {
        guard !parsed.valid.isEmpty, parsed.invalid.isEmpty else { return }
        onSave(parsed.valid)
        dismiss()
    }
}

/// "Fixkosten" sheet: what is booked / still due this month, all series, hidden ones.
struct RecurringSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Wiederkehrende Buchungen").font(.headline)
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            List {
                if let m = model.recurringMonth {
                    Section {
                        if m.items.isEmpty {
                            Text("Diesen Monat ist nichts fällig.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(m.items, id: \.self) { item in
                            monthRow(item)
                        }
                    } header: {
                        Text("Diesen Monat")
                    } footer: {
                        Text("Noch offen: \(Money.format(-m.openExpenseCents)) Ausgaben, \(Money.format(m.openIncomeCents)) Einnahmen · bereits gebucht: \(Money.format(-m.bookedExpenseCents))")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .leadingFooter()
                    }
                }
                Section {
                    if model.recurring.isEmpty {
                        Text("Noch keine wiederkehrenden Buchungen erkannt. Sie können eine Buchung in der Detailansicht als wiederkehrend markieren.")
                            .foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.recurring, id: \.seriesKey) { s in
                        seriesRow(s)
                    }
                } header: {
                    Text("Alle (\(model.recurring.count))")
                }
                if !model.recurringHidden.isEmpty {
                    Section {
                        ForEach(model.recurringHidden, id: \.seriesKey) { h in
                            hiddenRow(h)
                        }
                    } header: {
                        Text("Ausgeblendet (\(model.recurringHidden.count))")
                    }
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, idealHeight: 640)
        #if os(macOS)
        .onExitCommand { dismiss() }
        #endif
    }

    private func show(_ bookingID: Int64) {
        dismiss()
        model.revealBooking(bookingID)
    }

    private func monthRow(_ item: RecurringMonthItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.booked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(item.booked ? Theme.inflow : Theme.tertiary)
                .accessibilityLabel(item.booked ? "Gebucht" : "Offen")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.series.name).lineLimit(1)
                Text(item.booked ? "Gebucht am \(DateText.medium(item.dueDate))" : "Fällig am \(DateText.medium(item.dueDate))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(Money.format(item.amountCents))
                .monospacedDigit()
                .foregroundStyle(item.amountCents < 0 ? Theme.outflow : Theme.inflow)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { show(item.bookingId ?? item.series.lastBookingId) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Buchung anzeigen") { show(item.bookingId ?? item.series.lastBookingId) }
        .contextMenu {
            Button(item.booked ? "Buchung anzeigen" : "Letzte Buchung anzeigen") {
                show(item.bookingId ?? item.series.lastBookingId)
            }
            Divider()
            seriesActions(item.series)
        }
    }

    private func seriesRow(_ s: RecurringSeries) -> some View {
        HStack(spacing: 10) {
            Image(systemName: s.source == .manual ? "hand.point.up.left" : "sparkles")
                .foregroundStyle(Theme.tertiary)
                .help(s.source == .manual ? "Manuell markiert" : "Automatisch erkannt")
                .accessibilityLabel(s.source == .manual ? "Manuell markiert" : "Automatisch erkannt")
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).lineLimit(1)
                Text("\(s.intervalText) · nächste am \(DateText.medium(s.nextDue))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Text(Money.format(s.amountCents))
                .monospacedDigit()
                .foregroundStyle(s.amountCents < 0 ? Theme.outflow : Theme.inflow)
            Menu {
                seriesActions(s)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Aktionen")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { show(s.lastBookingId) }
        .contextMenu {
            Button("Letzte Buchung anzeigen") { show(s.lastBookingId) }
            Divider()
            seriesActions(s)
        }
    }

    @ViewBuilder
    private func seriesActions(_ s: RecurringSeries) -> some View {
        if s.source == .manual {
            Button("Automatisch erkennen") { model.resetRecurring(s) }
        }
        Button("Nicht wiederkehrend") { model.ignoreRecurring(s) }
    }

    private func hiddenRow(_ h: IgnoredRecurring) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(h.name).lineLimit(1).foregroundStyle(Theme.secondary)
                Text("Zuletzt am \(DateText.medium(h.lastDate))")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Text(Money.format(h.amountCents))
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
            Button("Einblenden") { model.resetRecurring(key: h.seriesKey) }
                .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Wieder einblenden") { model.resetRecurring(key: h.seriesKey) }
        }
    }
}
