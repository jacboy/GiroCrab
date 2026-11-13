#if os(macOS)
import AppKit
import SwiftUI
import GiroCrabCore

/// MoneyMoney database import as an assistant (HIG: a longer task in a sheet
/// goes step by step, Back / Continue at the bottom right):
///
///  1. Source – MoneyMoney's data folder (database plus statement PDFs) or a
///     single `MoneyMoney.sqlite` (backup), and the database password;
///  2. Accounts and data – which accounts, account type, target, what else;
///  3. Bank connections – one connection type per bank login (FinTS, the
///     bank's own API, Enable Banking), preset by priority;
///  4. Enable Banking – set up the user's application, only when needed;
///  then the import runs and the result shows the next step.
///
/// Everything is only read (never changed); the password is dropped from the
/// view state afterwards.
struct MoneyMoneyDatabaseImportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Tells the sheet that an import is running.
    @Binding var running: Bool
    /// Database or export file – switchable on the first step only.
    @Binding var source: MoneyMoneyImportSheet.Source

    enum Step: Hashable { case source, accounts, banks, enableBanking, importing, done }

    struct Choice: Equatable {
        var selected: Bool
        var kind: AccountKind
        /// nil = new account
        var target: Int64?
    }

    /// One table row.
    struct AccountRow: Identifiable {
        let a: MoneyMoneyDbAccount
        var id: Int64 { a.mmId }
    }

    @State private var step: Step = .source
    @State private var fileURL: URL?
    /// Folder with the statement PDFs when the database is a lone file (backup).
    @State private var statementsURL: URL?
    @State private var importStatements = true
    @State private var password = ""
    @State private var preview: MoneyMoneyDbPreview?
    @State private var choices: [Int64: Choice] = [:]
    /// Connection per MoneyMoney bank login: option key, "" = don't connect.
    @State private var bankChoice: [Int64: String] = [:]
    /// Rows selected in the account table (Space toggles their import).
    @State private var tableSelection = Set<Int64>()
    @State private var importCategories = true
    @State private var importNotes = true
    @State private var importGroups = true
    @State private var createConnections = true
    @State private var importPins = false
    /// Enable Banking credentials entered in the assistant.
    @State private var ebValues: [String: String] = [:]
    @State private var loading = false
    @State private var progress = ImportProgressState()
    /// Kept while the import runs: "Import abbrechen" tells the core through it.
    @State private var relay: ImportProgressRelay?
    @State private var cancelling = false
    @State private var error: String?
    @State private var result: MoneyMoneyDbImportResult?

    /// The content area keeps one size on every step, like an assistant.
    private let contentHeight: CGFloat = 470

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Group {
                switch step {
                case .source: sourceStep
                case .accounts: accountsStep
                case .banks: banksStep
                case .enableBanking: enableBankingStep
                case .importing: importingStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, minHeight: contentHeight, maxHeight: contentHeight, alignment: .top)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true) // wrap, never truncate
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            footer
        }
        .interactiveDismissDisabled(step == .importing)
        .onChange(of: step) { _, now in running = now == .importing }
        .onAppear {
            if let demo = model.demoDbPreview {
                fileURL = URL(fileURLWithPath: "/Users/max/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney")
                password = "demo-passwort"
                apply(demo)
                step = .accounts
            }
        }
        .onDisappear { password = "" }
    }

    // MARK: - Header and footer

    @ViewBuilder
    private var header: some View {
        if step == .done, let r = result {
            let ok = r.accountChecks.allSatisfy(\.ok)
            ImportAssistantHeader(title: stepTitle, subtitle: stepSubtitle,
                                  symbol: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                  tint: ok ? Theme.inflow : Theme.warning)
        } else {
            ImportAssistantHeader(title: stepTitle, subtitle: stepSubtitle)
        }
    }

    private var stepTitle: String {
        switch step {
        case .source: return String(localized: "Aus MoneyMoney importieren")
        case .accounts: return String(localized: "Konten")
        case .banks: return String(localized: "Übernahme")
        case .enableBanking: return String(localized: "Enable Banking einrichten")
        case .importing: return String(localized: "Import läuft")
        case .done: return String(localized: "Import abgeschlossen")
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .source:
            return String(localized: "Wählen Sie, woher die Daten kommen. MoneyMoney und seine Daten bleiben unverändert.")
        case .accounts:
            guard let p = preview else { return "" }
            return [String(localized: "\(p.accounts.count) Konten"),
                    String(localized: "\(p.totalBookings.formatted()) Buchungen"),
                    yearSpan(p)].compactMap { $0 }.joined(separator: " · ")
        case .banks:
            return String(localized: "Was GiroCrab außerdem übernimmt und wie es künftig Umsätze abruft.")
        case .enableBanking:
            return String(localized: "Für \(ebBankNames) braucht GiroCrab eine kostenlose Enable-Banking-Anwendung.")
        case .importing:
            return String(localized: "Bitte warten Sie, bis der Import fertig ist.")
        case .done:
            guard let r = result else { return "" }
            let accounts = r.accountsCreated + r.accountsMerged
            let line = String(localized: "\(r.bookingsNew.formatted()) Buchungen aus \(accounts) Konten übernommen.")
            let checks = r.accountChecks
            let problems = checks.filter { !$0.ok }.count
            if checks.isEmpty { return line }
            if problems > 0 {
                return line + " " + String(localized: "\(problems) von \(checks.count) Konten weichen von MoneyMoney ab.")
            }
            return line + " " + (checks.count == 1
                ? String(localized: "Das Konto stimmt mit MoneyMoney überein.")
                : String(localized: "Alle \(checks.count) Konten stimmen mit MoneyMoney überein."))
        }
    }

    /// The numbered steps this import goes through.
    private var visibleSteps: [Step] {
        var s: [Step] = [.source, .accounts, .banks]
        if needsEnableBankingSetup { s.append(.enableBanking) }
        return s
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch step {
            case .importing:
                Spacer()
                // closing would leave the import running unseen: cancel it instead
                Button(cancelling ? "Wird abgebrochen …" : "Import abbrechen") {
                    cancelling = true
                    relay?.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(cancelling)
            case .done:
                Spacer()
                Button("Fertig") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    // Esc / ⌘. close the finished import as well
                    .background(
                        Button("Schließen") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true))
            default:
                AssistantFooter(
                    cancel: { password = ""; dismiss() },
                    back: step != .source ? { back() } : nil,
                    nextTitle: isLastStep ? "Importieren" : "Fortfahren",
                    nextDisabled: !canContinue,
                    busy: loading,
                    next: { next() }
                ) {
                    if step == .enableBanking {
                        Button("Später einrichten") { runImport() }
                    }
                }
            }
        }
    }

    private var isLastStep: Bool { visibleSteps.last == step }

    private var canContinue: Bool {
        switch step {
        case .source: return fileURL != nil && !loading
        case .accounts: return choices.values.contains(where: \.selected)
        default: return true
        }
    }

    private func next() {
        error = nil
        switch step {
        case .source:
            loadPreview()
        case .enableBanking:
            for (k, v) in ebValues where !v.trimmingCharacters(in: .whitespaces).isEmpty {
                model.saveSetting(k, v)
            }
            runImport()
        default:
            if isLastStep {
                runImport()
            } else if let i = visibleSteps.firstIndex(of: step) {
                go(visibleSteps[i + 1])
            }
        }
    }

    private func back() {
        error = nil
        if let i = visibleSteps.firstIndex(of: step), i > 0 { go(visibleSteps[i - 1]) }
    }

    private func go(_ s: Step) {
        if s == .enableBanking { model.psd2LinkHints = plannedPsd2Links }
        step = s
    }

    // MARK: - 1. Source

    private var sourceStep: some View {
        Form {
            ImportSourceSection(source: $source)
            Section {
                ImportFileRow(title: "MoneyMoney-Daten", url: fileURL, name: fileURL?.lastPathComponent ?? "") { pickFile() }
                SecureField("Datenbank-Passwort", text: $password, prompt: Text("Erforderlich"))
            } header: {
                Text("Datenbank")
            } footer: {
                footerText("Wählen Sie den MoneyMoney-Ordner, damit auch die Kontoauszüge übernommen werden. Eine einzelne Datei (MoneyMoney.sqlite), etwa aus einem Backup, geht auch.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden) // flush with the sheet, like System Settings
        .scrollDisabled(true)
    }

    // MARK: - 2. Accounts and data

    private var accountsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let p = preview {
                HStack {
                    let selected = choices.values.filter(\.selected).count
                    Text("\(selected) von \(p.accounts.count) Konten ausgewählt")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button(selected == p.accounts.count ? "Alle abwählen" : "Alle auswählen") {
                        let all = selected != p.accounts.count
                        for id in choices.keys { choices[id]?.selected = all }
                    }
                    .controlSize(.small)
                }
                accountTable(p)
                    .frame(maxHeight: .infinity)
                    // Space switches the selected accounts on or off, like a checkbox
                    .onKeyPress(.space) {
                        guard !tableSelection.isEmpty else { return .ignored }
                        let on = !tableSelection.allSatisfy { choices[$0]?.selected ?? true }
                        for id in tableSelection { choices[id]?.selected = on }
                        return .handled
                    }
            }
        }
    }

    @ViewBuilder
    private func accountTable(_ p: MoneyMoneyDbPreview) -> some View {
        let rows = p.accounts.map(AccountRow.init)
        // "Ziel" only when GiroCrab already has accounts to merge into
        if model.allAccounts.isEmpty {
            Table(rows, selection: $tableSelection) {
                TableColumn("") { r in selectCell(r.a) }.width(22)
                TableColumn("Konto") { r in nameCell(r.a) }
                TableColumn("Buchungen") { r in bookingsCell(r.a) }.width(80)
                TableColumn("Saldo") { r in balanceCell(r.a) }.width(110)
                TableColumn("Kontoart") { r in kindCell(r.a) }.width(150)
            }
        } else {
            Table(rows, selection: $tableSelection) {
                TableColumn("") { r in selectCell(r.a) }.width(22)
                TableColumn("Konto") { r in nameCell(r.a) }
                TableColumn("Buchungen") { r in bookingsCell(r.a) }.width(80)
                TableColumn("Saldo") { r in balanceCell(r.a) }.width(110)
                TableColumn("Kontoart") { r in kindCell(r.a) }.width(150)
                TableColumn("Ziel") { r in targetCell(r.a) }.width(170)
            }
        }
    }

    private func selectCell(_ a: MoneyMoneyDbAccount) -> some View {
        Toggle("„\(a.name)“ importieren", isOn: binding(a).selected).labelsHidden()
    }

    private func nameCell(_ a: MoneyMoneyDbAccount) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(a.name).lineLimit(1)
            Text(accountSubtitle(a)).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .opacity(binding(a).wrappedValue.selected ? 1 : 0.5)
    }

    private func bookingsCell(_ a: MoneyMoneyDbAccount) -> some View {
        Text(a.bookingCount.formatted())
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(bookingSummary(a))
    }

    private func balanceCell(_ a: MoneyMoneyDbAccount) -> some View {
        Text(Money.format(a.computedBalanceCents, currency: a.currency))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(a.balanceSource)
    }

    private func kindCell(_ a: MoneyMoneyDbAccount) -> some View {
        Picker("Kontoart", selection: binding(a).kind) {
            ForEach(AccountKind.importChoices, id: \.self) { k in Text(k.label).tag(k) }
        }
        .labelsHidden()
    }

    private func targetCell(_ a: MoneyMoneyDbAccount) -> some View {
        Picker("Ziel", selection: binding(a).target) {
            Text("Neues Konto").tag(Int64?.none)
            ForEach(model.allAccounts) { acc in
                Text(acc.id == a.existingAccountId ? String(localized: "\(acc.name) (gleiche IBAN)") : acc.name).tag(Int64?.some(acc.id))
            }
            if let id = a.existingAccountId, !model.allAccounts.contains(where: { $0.id == id }) {
                Text(a.existingAccountName ?? String(localized: "Vorhandenes Konto")).tag(Int64?.some(id))
            }
        }
        .labelsHidden()
    }

    /// "Daten" section of step 3: what is taken over besides the bookings.
    @ViewBuilder
    private func dataSection(_ p: MoneyMoneyDbPreview) -> some View {
        Section {
            Toggle("Kategorien und Regeln (\(p.categoryPaths.count))", isOn: $importCategories)
            Toggle("Notizen (\(p.notesCount))", isOn: $importNotes)
            let groupCount = Set(p.accounts.map(\.groupName).filter { !$0.isEmpty }).count
            if groupCount > 0 {
                Toggle("Kontogruppen (\(groupCount))", isOn: $importGroups)
            }
            if p.statementCount > 0 { statementOptions(p) }
        } header: {
            Text("Daten")
        } footer: {
            if p.replacesStarterCategories && importCategories {
                footerText("Die Kategorien ersetzen die GiroCrab-Startkategorien – Ihr Tresor enthält noch keine Buchungen.")
            }
        }
    }

    /// Statement PDFs: MoneyMoney's database only lists them, the files are
    /// in its `Statements` folder – or, for a backup, wherever the user saved them.
    @ViewBuilder
    private func statementOptions(_ p: MoneyMoneyDbPreview) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: Int64(p.statementsBytes), countStyle: .file)
        Toggle(isOn: $importStatements) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Kontoauszüge und Dokumente (\(p.statementsFound), \(size))")
                if p.statementsFound < p.statementCount {
                    Text(p.statementsDir == nil
                         ? String(localized: "\(p.statementCount) PDFs liegen nicht bei dieser Datenbank. Wählen Sie den Ordner, falls Sie sie gesichert haben.")
                         : String(localized: "\(p.statementsFound) von \(p.statementCount) PDFs gefunden, die übrigen werden ausgelassen."))
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
        .disabled(p.statementsFound == 0)
        if p.statementsFound < p.statementCount {
            LabeledContent("Ordner mit Kontoauszügen") {
                Button(statementsURL == nil ? "Auswählen …" : "Ändern …") { pickStatementsFolder() }
                    .disabled(loading)
            }
        }
    }

    // MARK: - 3. Bank connections

    private var banksStep: some View {
        Form {
            if let p = preview { dataSection(p) }
            Section {
                Toggle("Bankzugänge anlegen", isOn: $createConnections)
            } header: {
                Text("Bankzugänge")
            } footer: {
                footerText("Die Konten erscheinen unter ihrem Bankzugang. Der erste Abruf übernimmt sie, ohne Duplikate anzulegen.")
            }
            if let p = preview {
                Section {
                    ForEach(p.banks, id: \.mmId) { b in bankRow(b) }
                } footer: {
                    if createConnections, chosenEnableBanking, !enableBankingReady {
                        footerText("Enable Banking richten Sie im nächsten Schritt ein.")
                    }
                }
                .disabled(!createConnections)
                if createConnections, p.banks.contains(where: { $0.hasSavedPin && usesPin($0) }) {
                    Section {
                        Toggle("Gespeicherte PINs übernehmen", isOn: $importPins)
                    } footer: {
                        footerText("Die PINs aus MoneyMoney kommen verschlüsselt in den GiroCrab-Tresor. Ohne diese Option werden sie nicht gelesen.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden) // flush with the sheet, like System Settings
    }

    /// Section footer of a grouped form, aligned with the section (leading).
    private func footerText(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(Theme.secondary)
            .leadingFooter()
    }

    private func bankRow(_ b: MoneyMoneyDbBank) -> some View {
        let options = connectionOptions(b)
        return LabeledContent {
            if options.count > 1 {
                Picker("Verbindung für \(b.name)", selection: bankBinding(b)) {
                    ForEach(options, id: \.key) { o in Text(label(o)).tag(o.key) }
                    Divider()
                    Text("Nicht verbinden").tag("")
                }
                .labelsHidden()
                .fixedSize()
            } else if let o = options.first {
                Text(label(o) + (b.existingConnectionId != nil ? " · " + String(localized: "vorhanden") : ""))
                    .foregroundStyle(Theme.secondary)
            } else {
                Text("Nicht verfügbar").foregroundStyle(Theme.tertiary)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(b.name.isEmpty ? (b.connector?.displayName ?? String(localized: "Bank")) : b.name)
                let detail = bankDetail(b)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    /// Login name, and the bank code only when it is a real one (MoneyMoney
    /// stores placeholders such as "Amazon-Kreditkarte" there).
    private func bankDetail(_ b: MoneyMoneyDbBank) -> String {
        let code = b.bankCode.filter(\.isNumber)
        let blz = code.count == 8 && code == b.bankCode.filter { !$0.isWhitespace } ? String(localized: "BLZ \(code)") : nil
        return [b.loginName.isEmpty ? nil : b.loginName, blz].compactMap { $0 }.joined(separator: " · ")
    }

    private func label(_ o: MoneyMoneyDbConnectionOption) -> String {
        switch o.via {
        case .finTs: return String(localized: "Online-Banking (FinTS)")
        case .ownApi: return String(localized: "Schnittstelle der Bank")
        case .enableBanking:
            // the Enable Banking name only when it differs from MoneyMoney's
            return String(localized: "Enable Banking")
        }
    }

    // MARK: - 4. Enable Banking

    private var enableBankingStep: some View {
        ScrollView {
            EnableBankingSetupSection(values: $ebValues)
                .padding(.trailing, 6)
        }
    }

    // MARK: - Import and result

    private var importingStep: some View {
        let p = progress.value
        return VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            ProgressView(value: p.fraction)
                .progressViewStyle(.linear)
                .frame(width: 380)
            VStack(spacing: 4) {
                Text(progressStatus(p)).font(.callout).lineLimit(1).truncationMode(.middle)
                if p.bookingsTotal > 0 || p.documentsTotal > 0 {
                    Text(progressCounts(p)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
            }
            Text(cancelling
                 ? "Der Import wird abgebrochen …"
                 : "„Import abbrechen“ verwirft alles – es wird dann nichts übernommen.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progressStatus(_ p: MoneyMoneyDbImportProgress) -> String {
        if p.accountIndex == 0 { return String(localized: "MoneyMoney-Datenbank wird gelesen …") }
        if p.accountIndex > p.accountCount { return String(localized: "Bankzugänge und Gruppen werden angelegt …") }
        return String(localized: "Konto \(p.accountIndex) von \(p.accountCount) · \(p.accountName)")
    }

    private func progressCounts(_ p: MoneyMoneyDbImportProgress) -> String {
        var s = String(localized: "\(p.bookingsDone.formatted()) von \(p.bookingsTotal.formatted()) Buchungen")
        if p.documentsTotal > 0 {
            s += " · " + String(localized: "\(p.documentsDone.formatted()) von \(p.documentsTotal.formatted()) Dokumenten")
        }
        return s
    }

    @ViewBuilder
    private var doneStep: some View {
        if let r = result {
            let problems = r.accountChecks.filter { !$0.ok }
            Form {
                // what still needs the user comes first
                if !r.psd2Connections.isEmpty { consentSection(r.psd2Connections) }
                if !problems.isEmpty { checkSection(r.accountChecks, problems: problems) }
                importedSection(r)
                skippedSection(r)
                if problems.isEmpty, !r.accountChecks.isEmpty { checkSection(r.accountChecks, problems: []) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    /// Enable Banking connections the import set up: the bank consent is next.
    private func consentSection(_ list: [MoneyMoneyDbPsd2Connection]) -> some View {
        Section {
            ForEach(list, id: \.connectionId) { c in
                LabeledContent {
                    Button("Freigeben …") { startConsent(c.connectionId) }
                } label: {
                    Text(c.bankName)
                    Text(c.accounts.map { a in
                        [a.name, a.iban.isEmpty ? (a.accountNumber.isEmpty ? nil : String(localized: "Konto \(a.accountNumber)")) : formatIBAN(a.iban)]
                            .compactMap { $0 }.joined(separator: " · ")
                    }.joined(separator: "\n"))
                    .monospacedDigit()
                    .textSelection(.enabled)
                }
            }
        } header: {
            Text("Bankfreigaben")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                footerText(enableBankingReady
                           ? "Konten, die noch nicht mit Ihrer Enable-Banking-Anwendung verknüpft sind, verknüpfen Sie auf enablebanking.com."
                           : "Die Enable-Banking-Anwendung wird bei der ersten Freigabe eingerichtet. Verknüpfen Sie dabei alle Konten dieser Banken auf einmal.")
                Link("Anwendungen auf enablebanking.com öffnen", destination: URL(string: "https://enablebanking.com/cp/applications")!)
                    .font(.caption)
            }
            .leadingFooter()
        }
    }

    /// Closes the import and starts the bank consent of that connection.
    private func startConsent(_ connectionID: Int64) {
        guard let conn = model.connections.first(where: { $0.id == connectionID }) else { return }
        dismiss()
        model.requestSync(conn)
    }

    /// The counts of what arrived in GiroCrab; zero rows are left out.
    private func importedSection(_ r: MoneyMoneyDbImportResult) -> some View {
        Section("Übernommen") {
            let accounts = r.accountsCreated + r.accountsMerged
            countRow("Konten", accounts,
                     detail: r.accountsMerged > 0 ? String(localized: "\(r.accountsMerged) bestehende ergänzt") : nil)
            countRow("Buchungen", r.bookingsNew,
                     detail: r.bookingsDuplicates > 0 ? String(localized: "\(r.bookingsDuplicates.formatted()) waren bereits vorhanden") : nil)
            countRow("Kategorien", r.categoriesCreated)
            countRow("Notizen", r.notesImported)
            countRow("Regeln", r.rulesCreated,
                     detail: r.rulesDisabled > 0 ? String(localized: "\(r.rulesDisabled) davon ausgeschaltet") : nil)
            countRow("Kontogruppen", r.groupsCreated)
            countRow("Kontoauszüge und Dokumente", r.documentsImported)
            countRow("Depotpositionen", r.holdingsImported)
            countRow("Bankzugänge", r.connectionsCreated,
                     detail: r.connectionsExisting > 0 ? String(localized: "\(r.connectionsExisting) bereits vorhanden") : nil)
            countRow("PINs im Tresor", r.pinsStored)
        }
    }

    @ViewBuilder
    private func countRow(_ title: LocalizedStringKey, _ n: UInt32, detail: String? = nil) -> some View {
        if n > 0 {
            LabeledContent {
                Text(n.formatted()).monospacedDigit()
            } label: {
                Text(title)
                if let detail { Text(detail) }
            }
        }
    }

    /// What the import left out, each with its reason.
    @ViewBuilder
    private func skippedSection(_ r: MoneyMoneyDbImportResult) -> some View {
        let documents = r.documentsMissing + r.documentsMismatched + r.documentsTooLarge
        if !r.banksSkippedNames.isEmpty || documents > 0 || r.pendingSkipped > 0 {
            Section {
                ForEach(Array(r.banksSkippedNames.enumerated()), id: \.offset) { _, name in
                    LabeledContent {
                        Text("Kein Abruf")
                    } label: {
                        Label { Text(name) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                if documents > 0 {
                    LabeledContent {
                        Text(documents.formatted()).monospacedDigit()
                    } label: {
                        Text("Dokumente ausgelassen")
                        Text("Nicht gefunden, beschädigt oder größer als 25 MB")
                    }
                }
                if r.pendingSkipped > 0 {
                    LabeledContent {
                        Text(r.pendingSkipped.formatted()).monospacedDigit()
                    } label: {
                        Text("Vorgemerkte Buchungen ausgelassen")
                        Text("Die Bank liefert sie gebucht erneut")
                    }
                }
            } header: {
                Text("Nicht übernommen")
            } footer: {
                if !r.banksSkippedNames.isEmpty {
                    footerText("Für diese Banken hat GiroCrab noch keinen Zugang. Ihre Konten und Buchungen sind übernommen, werden aber nicht automatisch aktualisiert.")
                }
            }
        }
    }

    /// Reconciliation with MoneyMoney: deviations open, otherwise folded away.
    private func checkSection(_ checks: [MoneyMoneyDbAccountCheck], problems: [MoneyMoneyDbAccountCheck]) -> some View {
        Section {
            if problems.isEmpty {
                DisclosureGroup(checks.count == 1
                                ? String(localized: "Das Konto stimmt überein")
                                : String(localized: "Alle \(checks.count) Konten stimmen überein")) {
                    checkTable(checks)
                }
            } else {
                checkTable(problems + checks.filter(\.ok))
            }
        } header: {
            Text("Abgleich mit MoneyMoney")
        } footer: {
            if !problems.isEmpty {
                footerText("Bitte prüfen Sie die markierten Konten. Ein erneuter Import ergänzt fehlende Buchungen, ohne Duplikate anzulegen.")
            }
        }
    }

    /// All rows at full height (no inner scrolling: the form scrolls as a whole).
    private func checkTable(_ checks: [MoneyMoneyDbAccountCheck]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Konto")
                Text("Buchungen").gridColumnAlignment(.trailing)
                Text("Saldo MoneyMoney").gridColumnAlignment(.trailing)
                Text("Saldo GiroCrab").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(Theme.secondary)
            ForEach(checks, id: \.mmId) { c in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .firstTextBaseline) {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name).lineLimit(1)
                            if let note = checkNote(c) {
                                Text(note).font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: c.ok ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.ok ? Theme.inflow : Theme.warning)
                            .accessibilityLabel(c.ok ? Text("Stimmt") : Text("Weicht ab"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(c.foundBookings + c.deletedBookings) / \(c.mmBookings)")
                        .foregroundStyle(c.foundBookings + c.deletedBookings == c.mmBookings ? Theme.text : Theme.warning)
                    Text(Money.format(c.mmBalanceCents, currency: c.currency))
                    Text(Money.format(c.girocrabBalanceCents, currency: c.currency))
                        .foregroundStyle(c.balanceFromBank || c.girocrabBalanceCents == c.mmBalanceCents ? Theme.text : Theme.warning)
                }
                .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }

    /// Short explanation under the account name, only where something is special.
    private func checkNote(_ c: MoneyMoneyDbAccountCheck) -> String? {
        var parts: [String] = []
        let missing = Int(c.mmBookings) - Int(c.foundBookings + c.deletedBookings)
        if missing > 0 { parts.append(String(localized: "\(missing) Buchungen fehlen")) }
        if c.deletedBookings > 0 { parts.append(String(localized: "\(c.deletedBookings) in GiroCrab gelöscht")) }
        if c.otherBookings > 0 { parts.append(String(localized: "\(c.otherBookings) weitere von der Bank")) }
        if c.balanceFromBank { parts.append(String(localized: "Saldo von der Bank")) }
        if !c.mmBalanceShown { parts.append(String(localized: "MoneyMoney-Saldo berechnet")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private func binding(_ a: MoneyMoneyDbAccount) -> Binding<Choice> {
        Binding(
            get: { choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId) },
            set: { choices[a.mmId] = $0 }
        )
    }

    private func accountSubtitle(_ a: MoneyMoneyDbAccount) -> String {
        var parts: [String] = []
        if !a.bankName.isEmpty { parts.append(a.bankName) }
        if !a.iban.isEmpty { parts.append(TransferSheetView.groupedIBAN(a.iban)) } else if !a.accountNumber.isEmpty { parts.append(String(localized: "Konto \(a.accountNumber)")) }
        if a.currency != "EUR" { parts.append(a.currency) }
        return parts.joined(separator: " · ")
    }

    private func bookingSummary(_ a: MoneyMoneyDbAccount) -> String {
        var parts: [String] = []
        if let f = a.firstDate, let l = a.lastDate { parts.append("\(DateText.medium(f)) – \(DateText.medium(l))") }
        if a.pendingCount > 0 { parts.append(String(localized: "\(a.pendingCount) vorgemerkt")) }
        if a.holdingCount > 0 { parts.append(String(localized: "\(a.holdingCount) Depotpositionen")) }
        if a.statementCount > 0 { parts.append(String(localized: "\(a.statementCount) Dokumente")) }
        if !a.groupName.isEmpty { parts.append(String(localized: "Gruppe „\(a.groupName)“")) }
        return parts.joined(separator: " · ")
    }

    private func yearSpan(_ p: MoneyMoneyDbPreview) -> String? {
        let span = [p.dateRangeStart, p.dateRangeEnd].compactMap { $0.map { String($0.prefix(4)) } }
        guard span.count == 2 else { return nil }
        return span[0] == span[1] ? span[0] : "\(span[0])–\(span[1])"
    }

    /// The bank's connection options. Once Enable Banking's live list is
    /// loaded (the user's application is set up), it decides: Enable Banking
    /// is offered only for banks listed there, with their exact name – the
    /// built-in catalogue is best effort (e.g. Advanzia isn't offered).
    private func connectionOptions(_ b: MoneyMoneyDbBank) -> [MoneyMoneyDbConnectionOption] {
        let live = model.livePsd2Banks
        guard !live.isEmpty else { return b.connectionOptions }
        var list = b.connectionOptions.filter { $0.via != .enableBanking }
        let catalogue = b.connectionOptions.first { $0.via == .enableBanking }?.psd2Bank
        let hit = catalogue.flatMap { c in
            live.first { $0.country == c.country && $0.aspsp.caseInsensitiveCompare(c.aspsp) == .orderedSame }
        } ?? matchPsd2BankByName(bankName: b.name, candidates: live)
        if let x = hit {
            list.append(MoneyMoneyDbConnectionOption(via: .enableBanking, connector: .enableBanking,
                                                     key: "enablebanking:\(x.country):\(x.aspsp)", psd2Bank: x))
        }
        return list
    }

    private func bankBinding(_ b: MoneyMoneyDbBank) -> Binding<String> {
        Binding(
            get: { bankChoice[b.mmId] ?? connectionOptions(b).first?.key ?? "" },
            set: { bankChoice[b.mmId] = $0 }
        )
    }

    /// The connection chosen for a bank (nil = none).
    private func chosenOption(_ b: MoneyMoneyDbBank) -> MoneyMoneyDbConnectionOption? {
        let key = bankChoice[b.mmId] ?? connectionOptions(b).first?.key ?? ""
        return connectionOptions(b).first { $0.key == key }
    }

    private func usesPin(_ b: MoneyMoneyDbBank) -> Bool {
        guard let o = chosenOption(b) else { return false }
        return o.via != .enableBanking
    }

    private var chosenEnableBanking: Bool {
        preview?.banks.contains { chosenOption($0)?.via == .enableBanking } ?? false
    }

    /// The user's own Enable Banking application is set up.
    private var enableBankingReady: Bool {
        model.settingEntry("enablebanking.application_id")?.hasValue == true
            && model.settingEntry("enablebanking.private_key_pem")?.hasValue == true
    }

    private var needsEnableBankingSetup: Bool {
        createConnections && chosenEnableBanking && !enableBankingReady
    }

    private var ebBankNames: String {
        (preview?.banks ?? []).filter { chosenOption($0)?.via == .enableBanking }
            .map(\.name).formatted(.list(type: .and))
    }

    /// The Enable Banking banks of this import with their selected accounts –
    /// shown in the setup so they can be linked while activating the application.
    private var plannedPsd2Links: [MoneyMoneyDbPsd2Connection] {
        guard let p = preview else { return [] }
        return p.banks.filter { chosenOption($0)?.via == .enableBanking }.map { b in
            MoneyMoneyDbPsd2Connection(
                connectionId: -b.mmId, bankName: b.name, created: true,
                accounts: p.accounts
                    .filter { $0.mmBankId == b.mmId && (choices[$0.mmId]?.selected ?? true) }
                    .map { MoneyMoneyDbPsd2Account(name: $0.name, iban: $0.iban, accountNumber: $0.accountNumber) })
        }
    }

    private func apply(_ p: MoneyMoneyDbPreview) {
        preview = p
        model.loadLivePsd2Banks()
        var c: [Int64: Choice] = [:]
        for a in p.accounts {
            c[a.mmId] = choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId)
        }
        choices = c
    }

    // MARK: - Actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // the folder brings the statement PDFs along; a single file is a backup
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "MoneyMoney-Ordner auswählen (mit Kontoauszügen) – oder eine einzelne Datenbank, z. B. ein Backup (MoneyMoney.sqlite)")
        panel.prompt = String(localized: "Auswählen")
        panel.treatsFilePackagesAsDirectories = true
        // opens inside MoneyMoney's folder: "Auswählen" right away takes the folder
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney")
        if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            statementsURL = nil
            preview = nil
            choices = [:]
            bankChoice = [:]
            error = nil
        }
    }

    /// Folder with separately saved statement PDFs (for a backup database).
    private func pickStatementsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Ordner mit den gesicherten Kontoauszügen (PDF) auswählen – Unterordner werden mit durchsucht")
        panel.prompt = String(localized: "Auswählen")
        if panel.runModal() == .OK, let url = panel.url {
            statementsURL = url
            loadPreview(stay: true)
        }
    }

    /// Reads the database; `stay` = keep the current step (statements folder changed).
    private func loadPreview(stay: Bool = false) {
        guard let vault = model.vault, let url = fileURL else { return }
        let statements = statementsURL
        let pw = password
        loading = true; error = nil
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyDbPreview, Error> in
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let ok2 = statements?.startAccessingSecurityScopedResource() ?? false
                defer { if ok2 { statements?.stopAccessingSecurityScopedResource() } }
                return Result { try vault.previewMoneymoneyDatabase(path: url.path, password: pw, statementsDir: statements?.path) }
            }.value
            loading = false
            switch result {
            case .success(let p):
                apply(p)
                if !stay { go(.accounts) }
            case .failure(let e):
                if case CoreError.Authentication(let m) = e { error = m } else { error = describe(e) }
            }
        }
    }

    private func runImport() {
        guard let vault = model.vault, let url = fileURL, let preview else { return }
        error = nil
        if model.demoDbPreview != nil {
            // demo: nothing to read – show what the summary looks like
            result = Self.demoResult(preview, statements: importStatements, psd2: plannedPsd2Links)
            password = ""
            step = .done
            return
        }
        let options = MoneyMoneyDbImportOptions(
            accounts: preview.accounts.map { a in
                let c = choices[a.mmId] ?? Choice(selected: true, kind: a.suggestedKind, target: a.existingAccountId)
                return MoneyMoneyDbAccountChoice(mmId: a.mmId, import: c.selected, kind: c.kind, targetAccountId: c.target)
            },
            importCategories: importCategories,
            importNotes: importNotes,
            createConnections: createConnections,
            importPins: createConnections && importPins,
            importGroups: importGroups,
            importStatements: importStatements && preview.statementsFound > 0,
            statementsDir: statementsURL?.path,
            bankChoices: preview.banks.map { MoneyMoneyDbBankChoice(mmBankId: $0.mmId, connection: chosenOption($0)) })
        let statements = statementsURL
        let pw = password
        progress.value = MoneyMoneyDbImportProgress(fraction: 0, accountIndex: 0, accountCount: 0, accountName: "", bookingsDone: 0, bookingsTotal: 0, documentsDone: 0, documentsTotal: 0)
        let observer = ImportProgressRelay(state: progress)
        relay = observer
        cancelling = false
        let from = step
        step = .importing
        Task {
            let result = await Task.detached { () -> Result<MoneyMoneyDbImportResult, Error> in
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let ok2 = statements?.startAccessingSecurityScopedResource() ?? false
                defer { if ok2 { statements?.stopAccessingSecurityScopedResource() } }
                return Result { try vault.importMoneymoneyDatabaseWithProgress(path: url.path, password: pw, options: options, observer: observer) }
            }.value
            relay = nil
            // after a cancel or an error the assistant goes back, ready for another try
            let wasCancelled = cancelling
            cancelling = false
            switch result {
            case .success(let r):
                password = ""
                self.result = r
                model.finishMoneyMoneyDbImport(r)
                step = .done
            case .failure where wasCancelled:
                step = from
                error = String(localized: "Import abgebrochen – es wurde nichts übernommen.")
            case .failure(let e):
                step = from
                if case CoreError.Authentication(let m) = e { error = m } else { error = describe(e) }
            }
        }
    }

    /// What the result looks like, for the demo (nothing is read or stored).
    private static func demoResult(_ p: MoneyMoneyDbPreview, statements: Bool, psd2: [MoneyMoneyDbPsd2Connection]) -> MoneyMoneyDbImportResult {
        MoneyMoneyDbImportResult(
            accountsCreated: UInt32(p.accounts.count), accountsMerged: 0, groupsCreated: 2, bookingsNew: p.totalBookings,
            bookingsDuplicates: 0, bookingsEnriched: 0, pendingSkipped: p.pendingBookings, notesImported: p.notesCount,
            categoriesCreated: UInt32(p.categoryPaths.count), connectionsCreated: 4, connectionsExisting: 0, pinsStored: 0,
            banksSkippedUnsupported: 1, banksSkippedNames: ["Musterbank"], documentsImported: statements ? p.statementsFound : 0, documentsExisting: 0,
            documentsMissing: 0, documentsMismatched: 0, documentsTooLarge: 0, documentsUnlisted: 0, holdingsImported: 3,
            rulesCreated: 0, rulesDisabled: 0,
            accountChecks: p.accounts.map { a in
                MoneyMoneyDbAccountCheck(mmId: a.mmId, accountId: 0, name: a.name, currency: a.currency, mmBookings: a.bookingCount,
                                         foundBookings: a.bookingCount, deletedBookings: 0, otherBookings: 0,
                                         mmBalanceCents: a.computedBalanceCents, mmBalanceShown: true,
                                         girocrabBalanceCents: a.computedBalanceCents, balanceFromBank: false, ok: true)
            },
            psd2Connections: psd2)
    }
}

/// The running import's progress, for the view (main actor only).
@MainActor @Observable
final class ImportProgressState {
    var value = MoneyMoneyDbImportProgress(fraction: 0, accountIndex: 0, accountCount: 0, accountName: "", bookingsDone: 0, bookingsTotal: 0, documentsDone: 0, documentsTotal: 0)
}

/// Receives the core's progress on the importing thread, passes it on to the
/// view (at most ~20 times a second) and tells the core when to cancel.
final class ImportProgressRelay: MoneyMoneyImportObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastSent = Date.distantPast
    private var lastAccount: UInt32 = .max
    private let state: ImportProgressState

    init(state: ImportProgressState) { self.state = state }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func progress(progress: MoneyMoneyDbImportProgress) -> Bool {
        lock.lock()
        let now = Date()
        let send = progress.accountIndex != lastAccount || progress.fraction >= 1 || now.timeIntervalSince(lastSent) > 0.05
        if send { lastSent = now; lastAccount = progress.accountIndex }
        let go = !cancelled
        lock.unlock()
        if send {
            let state = state
            Task { @MainActor in state.value = progress }
        }
        return go
    }
}

extension AccountKind {
    static let importChoices: [AccountKind] = [.checking, .savings, .creditCard, .paymentService, .brokerage, .cash, .loan]

    var label: String {
        switch self {
        case .checking: return String(localized: "Girokonto")
        case .savings: return String(localized: "Tagesgeld / Sparen")
        case .creditCard: return String(localized: "Kreditkarte")
        case .paymentService: return String(localized: "Zahlungsdienst")
        case .brokerage: return String(localized: "Depot")
        case .cash: return String(localized: "Bargeld")
        case .loan: return String(localized: "Darlehen")
        }
    }
}

extension AppModel {
    func finishMoneyMoneyDbImport(_ r: MoneyMoneyDbImportResult) {
        reloadAll()
        if !r.psd2Connections.isEmpty { psd2LinkHints = r.psd2Connections }
        toast = String(localized: "MoneyMoney: \(r.bookingsNew) Buchungen in \(r.accountsCreated + r.accountsMerged) Konten importiert")
            + (r.bookingsDuplicates > 0 ? String(localized: ", \(r.bookingsDuplicates) bereits vorhanden") : "")
    }
}

extension AppModel {
    /// Invented MoneyMoney database (public example IBANs, fictional names) for
    /// `--demo-sheet moneymoney-db` screenshots.
    static func demoMoneyMoneyDbPreview(existingGiro: Account?) -> MoneyMoneyDbPreview {
        func acc(_ id: Int64, _ name: String, _ bank: String, _ code: String, iban: String = "", number: String = "", currency: String = "EUR",
                 kind: AccountKind, portfolio: Bool = false, existing: Account? = nil, count: UInt32, pending: UInt32 = 0,
                 from: String?, to: String?, balance: Int64, group: String = "Privat", bankId: Int64? = nil) -> MoneyMoneyDbAccount {
            MoneyMoneyDbAccount(mmId: id, name: name, iban: iban, accountNumber: number, currency: currency, bankCode: code, bankName: bank,
                                owner: "Max Mustermann", groupName: group, mmBankId: bankId, isPortfolio: portfolio, suggestedKind: kind,
                                existingAccountId: existing?.id, existingAccountName: existing?.name, bookingCount: count, pendingCount: pending, holdingCount: portfolio ? 3 : 0,
                                notesCount: 0, firstDate: from, lastDate: to, statementCount: kind == .checking ? 48 : 0, computedBalanceCents: balance,
                                balanceSource: "Anfangssaldo laut MoneyMoney-Saldenverlauf + Umsätze")
        }
        let accounts = [
            acc(1, "Girokonto", "comdirect", "20041111", iban: "DE89370400440532013000", kind: .checking, existing: existingGiro,
                count: 4812, pending: 3, from: "2009-04-01", to: "2026-11-09", balance: 3_245_18, bankId: 1),
            acc(2, "Visa-Karte", "comdirect", "20041111", number: "4871 •••• 1234", kind: .creditCard, count: 1204, pending: 2,
                from: "2011-02-14", to: "2026-11-08", balance: -412_90, bankId: 1),
            acc(3, "Tagesgeld", "1822direkt", "50050201", iban: "DE02120300000000202051", kind: .savings, count: 96,
                from: "2014-06-30", to: "2026-10-31", balance: 12_500_00, group: "Sparen", bankId: 2),
            acc(4, "Depot", "comdirect", "20041111", number: "123456789", kind: .brokerage, portfolio: true, count: 0,
                from: nil, to: nil, balance: 0, group: "Sparen", bankId: 1),
            acc(5, "PayPal", "PayPal", "", number: "max@example.com", kind: .paymentService, count: 640,
                from: "2013-08-02", to: "2026-11-05", balance: 23_45, bankId: 3),
            acc(6, "Reisekasse USD", "Musterbank", "12345678", number: "1000200", currency: "USD", kind: .checking, count: 38,
                from: "2019-07-10", to: "2025-09-22", balance: 310_75, group: "", bankId: 4),
            acc(7, "C24 Smartkonto", "C24 Bank", "50024024", iban: "DE02500105170137075030", kind: .checking, count: 57,
                from: "2024-03-01", to: "2026-11-07", balance: 1_840_12, bankId: 5),
        ]
        func direct(_ via: MoneyMoneyDbConnectionVia, _ kind: ConnectorKind, _ key: String) -> MoneyMoneyDbConnectionOption {
            MoneyMoneyDbConnectionOption(via: via, connector: kind, key: key, psd2Bank: nil)
        }
        let banks = [
            MoneyMoneyDbBank(mmId: 1, bankCode: "20041111", name: "comdirect", loginName: "12345678", customerId: "12345678",
                             connector: .comdirect, hasSavedPin: true, existingConnectionId: nil, accountCount: 3,
                             connectionOptions: [direct(.ownApi, .comdirect, "comdirect")]),
            MoneyMoneyDbBank(mmId: 2, bankCode: "50050201", name: "1822direkt", loginName: "max.mustermann", customerId: "",
                             connector: .direkt1822, hasSavedPin: true, existingConnectionId: nil, accountCount: 1,
                             connectionOptions: [direct(.finTs, .direkt1822, "direkt1822")]),
            MoneyMoneyDbBank(mmId: 3, bankCode: "", name: "PayPal", loginName: "max@example.com", customerId: "",
                             connector: .payPal, hasSavedPin: false, existingConnectionId: nil, accountCount: 1,
                             connectionOptions: [direct(.ownApi, .payPal, "paypal")]),
            MoneyMoneyDbBank(mmId: 4, bankCode: "12345678", name: "Musterbank", loginName: "mustermann", customerId: "",
                             connector: nil, hasSavedPin: false, existingConnectionId: nil, accountCount: 1, connectionOptions: []),
            // no own connector, but reachable through Enable Banking (PSD2)
            MoneyMoneyDbBank(mmId: 5, bankCode: "50024024", name: "C24 Bank", loginName: "max.mustermann", customerId: "",
                             connector: nil, hasSavedPin: false, existingConnectionId: nil, accountCount: 1,
                             connectionOptions: psd2Catalog().filter { $0.aspsp == "C24" }.map {
                                 MoneyMoneyDbConnectionOption(via: .enableBanking, connector: .enableBanking,
                                                              key: "enablebanking:\($0.country):\($0.aspsp)", psd2Bank: $0)
                             }),
        ]
        let categories = ["Gehalt", "Haushalt › Lebensmittel", "Haushalt › Drogerie", "Wohnen › Miete", "Wohnen › Nebenkosten › Strom",
                          "Mobilität › Tanken", "Mobilität › ÖPNV", "Freizeit › Restaurants", "Freizeit › Sport", "Versicherungen",
                          "Steuern", "Reisen", "Abos", "Gesundheit", "Geschenke", "Sparen"]
        return MoneyMoneyDbPreview(accounts: accounts, banks: banks, categoryPaths: categories,
                                   totalBookings: accounts.reduce(0) { $0 + $1.bookingCount },
                                   pendingBookings: 5, notesCount: 312, splitParts: 14,
                                   dateRangeStart: "2009-04-01", dateRangeEnd: "2026-11-09", replacesStarterCategories: true,
                                   databasePath: "MoneyMoney.sqlite",
                                   statementCount: accounts.reduce(0) { $0 + $1.statementCount }, statementsDir: "Statements",
                                   statementsFound: accounts.reduce(0) { $0 + $1.statementCount }, statementsBytes: 38_400_000)
    }
}

#endif
