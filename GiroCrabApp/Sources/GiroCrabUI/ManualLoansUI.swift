import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

// Manual loans (GitHub #36): a loan without an account at the bank, e.g. a car
// loan paid from the Girokonto. The core keeps a Stand (balance at the end of a
// date), an optional interest rate and a search rule; bookings are linked by
// the rule or by hand.

/// Loan data the views read; refreshed with the accounts.
@Observable final class ManualLoanStore {
    var loans: [ManualLoan] = []
    var linkByBooking: [Int64: LoanLink] = [:]
    /// The loan sheet on screen.
    var editor: LoanEditorRequest?
}

struct LoanEditorRequest: Identifiable {
    enum Mode { case create, edit, anchor }
    let id = UUID()
    let mode: Mode
    var accountId: Int64?
    /// Prefill for "Neues Darlehen aus Buchung …".
    var draft: LoanSetup?
}

extension AppModel {
    func reloadLoans() {
        guard let vault else { return }
        do {
            loanStore.loans = try vault.listManualLoans()
            loanStore.linkByBooking = Dictionary(try vault.listLoanLinks().map { ($0.transactionId, $0) }, uniquingKeysWith: { a, _ in a })
        } catch {
            errorMessage = describe(error)
        }
    }

    func manualLoan(_ accountId: Int64) -> ManualLoan? {
        loanStore.loans.first { $0.accountId == accountId }
    }

    /// Manual loans that bookings can be assigned to (not archived).
    var assignableLoans: [ManualLoan] {
        loanStore.loans.filter { account(for: $0.accountId).map { !$0.isArchived } ?? false }
    }

    func loanLink(for booking: Booking) -> LoanLink? {
        loanStore.linkByBooking[booking.id]
    }

    var windowUndoManager: UndoManager? {
        #if os(macOS)
        // The main window's manager, also when saving from one of its sheets
        // (a sheet's own undo stack would vanish with the sheet).
        let w = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        return (w?.sheetParent ?? w)?.undoManager
        #else
        nil
        #endif
    }

    /// Links (or with `nil` unlinks) a booking; undoable via Bearbeiten › Widerrufen.
    func assignLoan(_ loanId: Int64?, to booking: Booking) {
        guard let vault else { return }
        let previous = loanLink(for: booking)?.loanAccountId
        guard previous != loanId else { return }
        do {
            try vault.setBookingLoan(transactionId: booking.id, loanAccountId: loanId)
        } catch {
            errorMessage = describe(error)
            return
        }
        if let um = windowUndoManager {
            um.registerUndo(withTarget: self) { m in m.assignLoan(previous, to: booking) }
            um.setActionName(String(localized: "Darlehenszuordnung"))
        }
        let name = booking.merchant.name.isEmpty ? booking.counterparty : booking.merchant.name
        if let loanId, let loan = manualLoan(loanId) {
            toast = String(localized: "„\(name)“ dem Darlehen „\(loan.setup.name)“ zugeordnet")
        } else {
            toast = String(localized: "Zuordnung von „\(name)“ aufgehoben")
        }
        reloadAccounts(); reloadBookings()
    }

    /// Creates or changes a manual loan; returns the account id.
    @discardableResult
    func saveLoan(_ setup: LoanSetup, accountId: Int64?) throws -> Int64 {
        guard let vault else { throw CoreError.Database(message: "vault locked") }
        let id: Int64
        if let accountId {
            let old = manualLoan(accountId)?.setup
            try vault.updateManualLoan(accountId: accountId, setup: setup)
            id = accountId
            if let old, let um = windowUndoManager {
                um.registerUndo(withTarget: self) { m in _ = try? m.saveLoan(old, accountId: accountId) }
                um.setActionName(String(localized: "Darlehen ändern"))
            }
        } else {
            id = try vault.createManualLoan(setup: setup)
            if let um = windowUndoManager {
                um.registerUndo(withTarget: self) { m in m.removeCreatedLoan(id, setup: setup) }
                um.setActionName(String(localized: "Darlehen anlegen"))
            }
        }
        reloadAccounts(); reloadBookings(); reloadHistory()
        return id
    }

    /// Undo of "Neues Darlehen": removes the loan again (redo creates it anew).
    private func removeCreatedLoan(_ id: Int64, setup: LoanSetup) {
        guard let vault else { return }
        do {
            try vault.setAccountArchived(accountId: id, archived: true)
            try vault.deleteAccount(accountId: id)
        } catch {
            errorMessage = describe(error)
            return
        }
        if sidebarSelection == .account(id) { sidebarSelection = .allAccounts }
        if let um = windowUndoManager {
            um.registerUndo(withTarget: self) { m in
                if let new = try? m.saveLoan(setup, accountId: nil) { m.sidebarSelection = .account(new) }
            }
            um.setActionName(String(localized: "Darlehen anlegen"))
        }
        reloadAccounts(); reloadBookings(); reloadHistory()
    }

    func openLoanEditor(_ mode: LoanEditorRequest.Mode, accountId: Int64? = nil, draft: LoanSetup? = nil) {
        loanStore.editor = LoanEditorRequest(mode: mode, accountId: accountId, draft: draft)
    }

    /// "Neues Darlehen aus Buchung …": name and rule taken from the counterparty.
    func openLoanEditor(from booking: Booking) {
        let name = booking.counterparty.isEmpty ? booking.merchant.name : booking.counterparty
        let quoted = name.replacingOccurrences(of: "\"", with: "")
        let dayBefore = DateText.date(booking.bookingDate).flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) }
        openLoanEditor(.create, draft: LoanSetup(
            name: name, originalCents: nil,
            anchorDate: dayBefore.map(DateText.iso) ?? DateText.iso(Date()),
            anchorBalanceCents: 0, interestRatePpm: nil,
            matchExpr: quoted.isEmpty ? "" : "name:\"\(quoted)\""))
    }
}

// MARK: - Percent input

enum PercentText {
    /// "4,99" / "4.99" / "4,99 %" -> 49_900 (millionths); nil for anything else.
    static func ppm(_ input: String) -> Int64? {
        let t = input.filter { !($0 == "%" || $0.isWhitespace) }.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let d = Decimal(string: t, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: d * 10_000).rounding(accordingToBehavior: nil).int64Value
    }

    /// 49_900 -> "4,99" in the user's locale.
    static func format(_ ppm: Int64) -> String {
        let f = NumberFormatter()
        f.locale = .autoupdatingCurrent
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 3
        return f.string(from: (Decimal(ppm) / 10_000) as NSDecimalNumber) ?? "\(ppm)"
    }
}

// MARK: - Sheets

extension View {
    /// The loan editor / "Stand neu setzen" sheet, driven by `model.loanStore.editor`.
    func manualLoanSheets(_ model: AppModel) -> some View {
        modifier(ManualLoanSheets(model: model))
    }
}

private struct ManualLoanSheets: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        @Bindable var store = model.loanStore
        content
            .sheet(item: $store.editor) { req in
                LoanEditorSheet(request: req).environment(model)
            }
            .task {
                // screenshots: --demo-sheet loan | loan-edit | loan-anchor
                guard let sheet = model.options.demoSheet, sheet.hasPrefix("loan") else { return }
                try? await Task.sleep(for: .milliseconds(300))
                let car = model.loanStore.loans.first
                switch sheet {
                case "loan-edit": model.openLoanEditor(.edit, accountId: car?.accountId)
                case "loan-anchor": model.openLoanEditor(.anchor, accountId: car?.accountId)
                default: model.openLoanEditor(.create)
                }
            }
    }
}

/// Create / edit a manual loan, or set a new Stand, with a live preview.
struct LoanEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: LoanEditorRequest

    @State private var name = ""
    @State private var originalText = ""
    @State private var anchorDate = Date()
    @State private var balanceText = ""
    @State private var rateText = ""
    @State private var rule = ""
    @State private var preview: LoanPreview?
    /// Rule the shown preview was computed for (stale while typing).
    @State private var previewRule = ""
    @State private var previewError: String?
    @State private var saveError: String?
    @State private var loaded = false
    /// Validation hints appear once something was typed or saving was tried.
    @State private var touched = false
    /// Field contents right after `load`, to tell an edit from the prefill.
    @State private var initialKey = ""
    @FocusState private var focus: Field?
    private enum Field { case name, balance }

    private var existing: ManualLoan? { request.accountId.flatMap(model.manualLoan) }
    private var isAnchor: Bool { request.mode == .anchor }

    private var title: LocalizedStringKey {
        switch request.mode {
        case .create: "Neues Darlehen"
        case .edit: "Darlehen bearbeiten"
        case .anchor: "Stand neu setzen"
        }
    }

    // MARK: validation

    private var balanceCents: Int64? { Money.parseCents(balanceText).map { abs($0) } }
    private var originalCents: Int64?? {
        let t = originalText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        guard let c = Money.parseCents(t), c > 0 else { return nil }
        return .some(abs(c))
    }
    private var rate: Int64?? {
        let t = rateText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .some(nil) }
        guard let p = PercentText.ppm(t), (0...300_000).contains(p) else { return nil }
        return .some(p)
    }

    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Bitte einen Namen angeben.") }
        if balanceCents == nil { return String(localized: "Bitte die Restschuld am Stichtag angeben.") }
        if originalCents == nil { return String(localized: "Der ursprüngliche Kreditbetrag ist keine gültige Zahl.") }
        if rate == nil { return String(localized: "Der Sollzins muss zwischen 0 und 30 % liegen.") }
        return previewError
    }

    private var setup: LoanSetup? {
        guard let balanceCents, let originalCents, let rate else { return nil }
        return LoanSetup(
            name: name.trimmingCharacters(in: .whitespaces),
            originalCents: originalCents,
            anchorDate: DateText.iso(anchorDate),
            anchorBalanceCents: balanceCents,
            interestRatePpm: rate,
            matchExpr: rule.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if request.mode == .create {
                    Text("Für Kredite ohne eigenes Konto bei der Bank, z. B. einen Autokredit, den Sie vom Girokonto abbezahlen.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            form
            Divider()
            HStack {
                statusLine
                Spacer()
                cancelButton
                saveButton
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: isAnchor ? 520 : 660)
        .onAppear(perform: load)
        .task(id: previewKey) { await refreshPreview() }
        #else
        NavigationStack {
            form
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { cancelButton }
                    ToolbarItem(placement: .confirmationAction) { saveButton }
                }
                .safeAreaInset(edge: .bottom) {
                    statusLine.padding(.horizontal).padding(.vertical, 8)
                }
        }
        .onAppear(perform: load)
        .task(id: previewKey) { await refreshPreview() }
        #endif
    }

    private var form: some View {
        Form {
            if !isAnchor {
                Section {
                    TextField("Name", text: $name, prompt: Text("z. B. Autokredit"))
                        .focused($focus, equals: .name)
                    TextField("Ursprünglicher Kreditbetrag", text: $originalText, prompt: Text("optional"))
                }
            }
            Section {
                DatePicker("Stichtag", selection: $anchorDate, in: ...Date(), displayedComponents: .date)
                TextField("Restschuld am Stichtag", text: $balanceText, prompt: Text("z. B. \(Money.plain(8_400_00))"))
                    .focused($focus, equals: .balance)
            } header: {
                Text("Stand")
            } footer: {
                FormFooter("Die Restschuld am Ende des Stichtags, z. B. aus dem Jahreskontoauszug. Raten ab dem Folgetag werden abgezogen. Fehlt etwas oder stimmt etwas nicht, setzen Sie einfach einen neuen Stand.")
            }
            if !isAnchor {
                Section {
                    TextField("Sollzins p. a. in %", text: $rateText, prompt: Text("z. B. 4,99"))
                } header: {
                    Text("Zinsen")
                } footer: {
                    FormFooter("Mit Sollzins zählt von jeder Rate nur der Tilgungsanteil (Zinsen taggenau). Ohne Sollzins senkt die ganze Rate die Restschuld.")
                }
                Section {
                    TextField("Suchregel", text: $rule, prompt: Text("z. B. Autobank"))
                    matchList
                } header: {
                    Text("Raten automatisch zuordnen")
                } footer: {
                    FormFooter("Gleiche Schreibweise wie bei Regeln: Wörter, „Phrasen“, name:, purpose:, AND, OR, NOT. Einzelne Buchungen ordnen Sie im Kontextmenü zu oder heben die Zuordnung dort auf.")
                }
            }
            Section("Vorschau") { previewRows }
        }
        .formStyle(.grouped)
    }

    /// Why saving is not possible (only after the first edit) or why it failed.
    @ViewBuilder
    private var statusLine: some View {
        if let msg = saveError ?? (touched ? problem : nil) {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Theme.warning)
                .lineLimit(2)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var cancelButton: some View {
        Button("Abbrechen", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
    }

    private var saveButton: some View {
        Button(request.mode == .create ? "Anlegen" : "Speichern", action: save)
            .keyboardShortcut(.defaultAction)
            .disabled(problem != nil)
    }

    @ViewBuilder
    private var matchList: some View {
        let current = rule.trimmingCharacters(in: .whitespaces)
        if !current.isEmpty, preview == nil || previewRule != current {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Suche passende Buchungen …").foregroundStyle(Theme.secondary)
            }
        } else if let p = preview, !current.isEmpty {
            if p.matches.isEmpty {
                Text("Keine passenden Buchungen.").foregroundStyle(Theme.secondary)
            } else {
                ForEach(p.matches, id: \.id) { b in
                    HStack {
                        Text(DateText.medium(b.bookingDate)).monospacedDigit().foregroundStyle(Theme.secondary)
                        Text(b.merchant.name.isEmpty ? b.counterparty : b.merchant.name).lineLimit(1)
                        Spacer()
                        Text(Money.format(b.amountCents)).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
                if p.matchCount > UInt32(p.matches.count) {
                    Text("und \(Int(p.matchCount) - p.matches.count) weitere").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var previewRows: some View {
        if let s = preview?.status {
            if isAnchor, let old = existing?.status {
                LabeledContent("Restschuld bisher", value: Money.format(-old.remainingCents))
            }
            LabeledContent("Restschuld", value: Money.format(-s.remainingCents))
                .font(.headline)
            LabeledContent("Stand vom", value: DateText.medium(s.asOfDate))
            LabeledContent("Raten seit Stichtag", value: "\(s.paymentCount) · \(Money.format(s.paidCents))")
            if s.interestCents > 0 {
                LabeledContent("davon Zinsen / Tilgung", value: "\(Money.format(s.interestCents)) / \(Money.format(s.principalCents))")
            }
            if s.beforeAnchorCount > 0 {
                LabeledContent("Ältere Buchungen (nicht gezählt)", value: "\(s.beforeAnchorCount)")
            }
            if let m = s.monthsLeft, m > 0 {
                LabeledContent("Voraussichtlich noch", value: String(localized: "\(Int(m)) Monatsraten"))
            }
        } else {
            Text("Vorschau erscheint, sobald Restschuld und Stichtag ausgefüllt sind.").foregroundStyle(Theme.secondary)
        }
    }

    private var previewKey: String {
        [name, originalText, DateText.iso(anchorDate), balanceText, rateText, rule].joined(separator: "\u{1F}")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        focus = isAnchor ? .balance : .name
        defer { if initialKey.isEmpty { initialKey = previewKey } }
        let s = existing?.setup ?? request.draft
        guard let s else { return }
        name = s.name
        originalText = s.originalCents.map(Money.plain) ?? ""
        anchorDate = DateText.date(s.anchorDate) ?? Date()
        if isAnchor, let st = existing?.status {
            // a new Stand starts from today's computed balance
            anchorDate = Date()
            balanceText = Money.plain(st.remainingCents)
        } else {
            balanceText = s.anchorBalanceCents > 0 || existing != nil ? Money.plain(s.anchorBalanceCents) : ""
        }
        rateText = s.interestRatePpm.map(PercentText.format) ?? ""
        rule = s.matchExpr
        initialKey = previewKey
    }

    private func refreshPreview() async {
        if loaded && previewKey != initialKey { touched = true }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled, let vault = model.vault else { return }
        guard var s = setup else { preview = nil; previewError = nil; return }
        if s.name.isEmpty { s.name = "-" }
        do {
            preview = try vault.previewManualLoan(accountId: request.accountId, setup: s, limit: 5)
            previewRule = s.matchExpr
            previewError = nil
        } catch {
            previewError = describe(error)
        }
        saveError = nil
    }

    private func save() {
        touched = true
        guard let s = setup, problem == nil else { return }
        do {
            let id = try model.saveLoan(s, accountId: request.mode == .create ? nil : request.accountId)
            if request.mode == .create { model.sidebarSelection = .account(id) }
            dismiss()
        } catch {
            saveError = describe(error)
        }
    }
}

/// Section footer, leading-aligned like the rest of the form.
struct FormFooter: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).leadingFooter()
    }
}

extension View {
    /// Footer of a grouped `Form` section, leading-aligned like System Settings.
    /// macOS lays a plain footer out trailing (next to the values); wrapped
    /// lines and multi-line stacks stay left-aligned too. Use on every
    /// `Section { } footer: { }` content.
    func leadingFooter() -> some View {
        multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Menus

/// "Darlehen zuordnen" submenu for a booking (context menu and Buchung menu).
struct LoanAssignMenu: View {
    let model: AppModel
    let booking: Booking?
    /// Context menus leave out what doesn't apply; the menu bar disables it instead.
    var hidesWhenUnavailable = false

    var body: some View {
        let loans = model.assignableLoans
        if let b = booking, b.accountKind != .loan {
            Menu("Darlehen zuordnen") {
                if !loans.isEmpty {
                    Picker("Darlehen", selection: Binding(
                        get: { model.loanLink(for: b)?.loanAccountId },
                        set: { model.assignLoan($0, to: b) }
                    )) {
                        Text("Keinem Darlehen").tag(Int64?.none)
                        ForEach(loans, id: \.accountId) { l in
                            Text(l.setup.name).tag(Int64?.some(l.accountId))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                }
                Button("Neues Darlehen aus dieser Buchung …") { model.openLoanEditor(from: b) }
            }
        } else if !hidesWhenUnavailable {
            Menu("Darlehen zuordnen") {}.disabled(true)
        }
    }
}

/// Account context menu entries of a manual loan.
struct ManualLoanAccountMenu: View {
    let model: AppModel
    let account: Account

    var body: some View {
        if account.kind == .loan, model.manualLoan(account.id) != nil, !account.isArchived {
            Button("Darlehen bearbeiten …", systemImage: "pencil") { model.openLoanEditor(.edit, accountId: account.id) }
            Button("Stand neu setzen …", systemImage: "calendar.badge.clock") { model.openLoanEditor(.anchor, accountId: account.id) }
            Divider()
        }
    }
}

// MARK: - Loan card details

/// Stand, payments and interest of a manual loan (below the repayment bar).
struct ManualLoanDetails: View {
    @Environment(AppModel.self) private var model
    let loan: ManualLoan

    var body: some View {
        let s = loan.status
        VStack(alignment: .leading, spacing: 6) {
            Text("Stand \(DateText.medium(loan.setup.anchorDate)): \(Money.format(loan.setup.anchorBalanceCents))")
                .font(.caption)
            Text(paymentsLine(s))
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            if let rate = loan.setup.interestRatePpm {
                Text("Sollzins \(PercentText.format(rate)) % · Zinsen seit Stichtag \(Money.format(s.interestCents))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            if let m = s.monthsLeft, m > 0 {
                Text("Voraussichtlich noch \(Int(m)) Monatsraten")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            HStack {
                Button("Stand neu setzen …") { model.openLoanEditor(.anchor, accountId: loan.accountId) }
                Button("Bearbeiten …") { model.openLoanEditor(.edit, accountId: loan.accountId) }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .accessibilityElement(children: .contain)
    }

    private func paymentsLine(_ s: LoanStatus) -> String {
        if s.paymentCount == 0 {
            return loan.setup.matchExpr.isEmpty
                ? String(localized: "Noch keine Raten zugeordnet")
                : String(localized: "Noch keine Raten seit dem Stichtag")
        }
        return String(localized: "\(Int(s.paymentCount)) Raten seit Stichtag · \(Money.format(s.paidCents))")
    }
}
