import SwiftUI
import GiroCrabCore

/// "Bank hinzufügen" as an assistant with the same frame as the MoneyMoney
/// import (header, fixed content area, Abbrechen / Zurück / Fortfahren):
/// 1. Bank – search by name, BLZ or IBAN; results grouped by how they connect,
/// 2. Zugang – the way to connect (when the bank offers several) and the login,
/// 3. Einrichten – only when GiroCrab still needs something once (FinTS product
///    ID, Enable Banking application).
/// "Hinzufügen" closes the assistant; the first sync (PIN, TAN, bank consent)
/// then runs in its usual sheet – no sheet on top of a sheet.
struct AddBankSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step { case bank, access, setup }

    @State private var step: Step = .bank
    @State private var query = ""
    @State private var selected: BankSearchResult?
    @State private var selectedID: String?
    /// Ways to reach the selected bank (FinTS, own API, Enable Banking).
    @State private var ways: [BankSearchResult] = []
    @State private var setupValues: [String: String] = [:]
    @State private var submit = AddBankSubmit()
    /// Shown while the search is empty (computed once, the directory is large).
    @State private var popular: [BankSearchResult] = []
    @FocusState private var searchFocused: Bool

    /// Well-known banks offered before typing. Sparkassen and Volksbanken are
    /// hundreds of banks – they are found by name, place or BLZ instead.
    private static let popularNames = ["ING", "DKB", "comdirect", "Postbank", "Consorsbank", "N26", "C24", "Revolut", "bunq", "Trade Republic", "Scalable Capital", "PayPal"]
    private static let manualFinTs = BankSearchResult(id: "fints:custom", name: "", mode: .finTs, country: "DE", blz: "", url: "", connector: nil, aspsp: "", tested: "")

    private var results: [BankSearchResult] {
        searchBanks(query: query, livePsd2: model.livePsd2Banks, perGroupLimit: 12)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The rows the list shows right now, in display order.
    private var candidates: [BankSearchResult] {
        guard searching else { return popular }
        let all = results
        return [BankAccessMode.finTs, .ownApi, .psd2].flatMap { m in all.filter { $0.mode == m } }
    }

    /// Best entry per well-known bank: FinTS before the bank's own API before PSD2.
    private func loadPopular() {
        let live = model.livePsd2Banks
        let order: [BankAccessMode] = [.finTs, .ownApi, .psd2]
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        popular = Self.popularNames.compactMap { name in
            let k = key(name)
            return searchBanks(query: name, livePsd2: live, perGroupLimit: 3)
                .filter { key($0.name).hasPrefix(k) }
                .min { order.firstIndex(of: $0.mode)! < order.firstIndex(of: $1.mode)! }
        }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack { content }
        #else
        content
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ImportAssistantHeader(title: title, subtitle: subtitle, symbol: "building.columns")
            Group {
                switch step {
                case .bank: bankStep
                case .access: accessStep
                case .setup: setupStep
                }
            }
            #if os(macOS)
            .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470, alignment: .top)
            #endif
            AssistantFooter(
                cancel: { dismiss() },
                back: step == .bank ? nil : { back() },
                nextTitle: isLastStep ? "Hinzufügen" : "Fortfahren",
                nextDisabled: !canContinue,
                next: { next() }
            )
        }
        .padding(20)
        .macFrame(width: 860)
        .onAppear {
            model.loadLivePsd2Banks()
            loadPopular()
            if let spec = model.demoAddBank { applyDemo(spec) }
        }
        .onChange(of: model.livePsd2Banks.count) { _, _ in loadPopular() }
    }

    // MARK: - Header

    private var title: String {
        switch step {
        case .bank: return String(localized: "Bank hinzufügen")
        case .access:
            guard let s = selected else { return "" }
            return s.id == Self.manualFinTs.id ? String(localized: "Andere FinTS-Bank") : s.name
        case .setup: return String(localized: "Einrichten")
        }
    }

    private var subtitle: String {
        switch step {
        case .bank:
            return String(localized: "Suchen Sie Ihre Bank nach Name, Bankleitzahl oder IBAN.")
        case .access:
            return String(localized: "Wie GiroCrab die Umsätze abruft. PIN und TAN fragt GiroCrab erst beim ersten Abruf ab.")
        case .setup:
            return String(localized: "Diese Angaben braucht GiroCrab einmalig, danach gelten sie für alle Banken dieser Art.")
        }
    }

    /// `--demo-sheet add-bank:…` (screenshots): "search:<text>" shows hits with
    /// the first one selected, "bank:<name>" opens its Zugang step, ":setup"
    /// on top the Einrichten step.
    private func applyDemo(_ spec: String) {
        model.demoAddBank = nil
        let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        query = parts[1]
        if parts[0] == "search" {
            // after the search field's own reset of the selection
            DispatchQueue.main.async { selectedID = candidates.first?.id }
            return
        }
        selectedID = candidates.first?.id
        choose(selectedID)
        guard parts[0] == "bank", selected != nil else { return }
        next()
        if parts.count > 2, parts[2] == "setup", !missingSettings.isEmpty { step = .setup }
    }

    // MARK: - Navigation

    /// Settings this way to connect still needs (none for the demo bank).
    private var missingSettings: [String] {
        guard let s = selected else { return [] }
        let kind = s.connector ?? (s.mode == .finTs ? .finTsGeneric : .enableBanking)
        guard let d = bankCatalog().first(where: { $0.kind == kind }) else { return [] }
        return d.requiredSettings.filter { key in !(model.settingEntry(key)?.hasValue ?? false) }
    }

    private var isLastStep: Bool {
        step == .setup || (step == .access && missingSettings.isEmpty)
    }

    private var canContinue: Bool {
        switch step {
        case .bank: return selected != nil
        case .access: return submit.canSubmit
        case .setup:
            return !missingSettings.contains { (setupValues[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    private func next() {
        guard canContinue else { return }
        switch step {
        case .bank:
            guard let s = selected else { return }
            ways = s.id == Self.manualFinTs.id ? [s]
                : Self.ways(to: s, in: searchBanks(query: s.name, livePsd2: model.livePsd2Banks, perGroupLimit: 12))
            step = .access
        case .access:
            if missingSettings.isEmpty { submit.action() } else { step = .setup }
        case .setup:
            for (k, v) in setupValues where !v.trimmingCharacters(in: .whitespaces).isEmpty {
                model.saveSetting(k, v)
            }
            submit.action()
        }
    }

    private func back() {
        switch step {
        case .bank: break
        case .access: step = .bank
        case .setup: step = .access
        }
    }

    /// The selected result plus the same bank in the other groups, in GiroCrab's
    /// order of preference: FinTS, the bank's own API, Enable Banking.
    static func ways(to r: BankSearchResult, in all: [BankSearchResult]) -> [BankSearchResult] {
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let k = key(r.name)
        guard k.count >= 3 else { return [r] }
        var out = [r]
        for m in [BankAccessMode.finTs, .ownApi, .psd2] where m != r.mode {
            if let other = all.first(where: {
                $0.mode == m && { let o = key($0.name); return o.count >= 3 && (o.hasPrefix(k) || k.hasPrefix(o)) }($0)
            }) {
                out.append(other)
            }
        }
        let order: [BankAccessMode] = [.finTs, .ownApi, .psd2]
        return out.sorted { order.firstIndex(of: $0.mode)! < order.firstIndex(of: $1.mode)! }
    }

    // MARK: - 1. Bank

    /// A native single-selection list: the chosen bank is highlighted like
    /// any selected row (HIG: checkmarks mean "toggle several"). A click
    /// selects, double-click or "Fortfahren" continues; no custom key handling.
    private var bankStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            searchField
            #endif
            List(selection: $selectedID) {
                if !searching {
                    Section {
                        ForEach(popular, id: \.id) { r in bankRow(r) }
                    } header: {
                        Text("Beliebte Banken")
                    } footer: {
                        Text("Jede Sparkasse und Volksbank ist eine eigene Bank. Suchen Sie sie über ihren Namen (meist mit Ort), die Bankleitzahl oder Ihre IBAN.")
                            .font(.caption).foregroundStyle(.secondary)
                            .leadingFooter()
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                } else {
                    resultSections
                }
                Section {
                    row(symbol: "square.and.pencil", title: String(localized: "Andere FinTS-Bank"),
                        detail: String(localized: "Bankleitzahl und FinTS-Adresse selbst eingeben"))
                        .tag(Self.manualFinTs.id)
                } header: {
                    Text("Nicht gefunden?")
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Bank, BLZ oder IBAN suchen …"))
            .onChange(of: query) { _, _ in selectedID = nil }
            #endif
            .contextMenu(forSelectionType: String.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                guard let id = ids.first else { return }
                selectedID = id
                choose(id)
                next()
            })
            .onChange(of: selectedID) { _, id in choose(id) }
            HStack(spacing: 18) {
                Button("Demo-Bank ausprobieren") {
                    model.addDemoBank()
                    dismiss()
                }
                .help(String(localized: "Ohne echte Bank: Kennung „demo“, PIN 12345, beliebige TAN"))
                #if os(macOS)
                Button("Von MoneyMoney umsteigen …") {
                    dismiss()
                    model.showMoneyMoneyImport = true
                }
                #endif
            }
            #if os(macOS)
            .buttonStyle(.link)
            #else
            .buttonStyle(.borderless)
            #endif
            .font(.callout)
        }
    }

    #if os(macOS)
    /// A SwiftUI field (magnifier, clear button) rather than an embedded
    /// NSSearchField, which swallowed Esc: here Esc closes the sheet as usual.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Bank, BLZ oder IBAN suchen …", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Suche löschen"))
                .accessibilityLabel(Text("Suche löschen"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selectedID = nil }
    }
    #endif

    private func choose(_ id: String?) {
        guard let id else { selected = nil; return }
        selected = id == Self.manualFinTs.id ? Self.manualFinTs : candidates.first { $0.id == id }
    }

    @ViewBuilder private var resultSections: some View {
        let all = results
        ForEach([BankAccessMode.finTs, .ownApi, .psd2], id: \.self) { mode in
            let rows = all.filter { $0.mode == mode }
            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.id) { r in bankRow(r) }
                } header: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.groupTitle(mode))
                        Text(Self.groupHint(mode)).font(.caption).fontWeight(.regular).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func bankRow(_ r: BankSearchResult) -> some View {
        row(symbol: Self.symbol(r), title: r.name, detail: Self.detailLine(r),
            accessibility: [r.name, Self.accessibleDetail(r)].compactMap { $0 }.joined(separator: ", "))
            .tag(r.id)
    }

    /// One bank row. Hierarchical styles, so the text stays readable on the
    /// selection highlight.
    private func row(symbol: String, title: String, detail: String?, accessibility: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility ?? [title, detail].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: - 2. Access

    @ViewBuilder private var accessStep: some View {
        if let s = selected {
            Form {
                if ways.count > 1 {
                    Section {
                        Picker("Verbindung", selection: Binding(
                            get: { s.id },
                            set: { id in if let w = ways.first(where: { $0.id == id }) { selected = w } }
                        )) {
                            ForEach(ways, id: \.id) { w in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.groupTitle(w.mode))
                                    Text(Self.groupHint(w.mode)).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                .padding(.vertical, 2)
                                .tag(w.id)
                            }
                        }
                        #if os(macOS)
                        .pickerStyle(.radioGroup)
                        #else
                        .pickerStyle(.inline)
                        #endif
                        .labelsHidden()
                    } header: {
                        Text("Verbindung")
                    } footer: {
                        Text("GiroCrab empfiehlt FinTS: direkt zur Bank, ohne Anmeldung bei Dritten.")
                            .font(.caption).foregroundStyle(Theme.secondary)
                            .leadingFooter()
                    }
                }
                // every form brings its own sections (Zugang, Anmeldung, Erweitert …)
                Group {
                    if s.mode == .finTs {
                        FinTsAddForm(prefill: s.id == Self.manualFinTs.id ? nil : s, onAdded: { dismiss() }, submit: submit)
                    } else if let k = s.connector {
                        KindAddForm(kind: k, onAdded: { dismiss() }, submit: submit)
                    } else {
                        Psd2AddForm(bank: s, onAdded: { dismiss() }, submit: submit)
                    }
                }
                .id(s.id) // a new form reports its own readiness
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - 3. Setup

    private var setupStep: some View {
        Form {
            let keys = missingSettings
            if keys.contains(where: { BankSetupSheet.enableBankingKeys.contains($0) }) {
                EnableBankingSetupSection(values: $setupValues)
            }
            let other = keys.filter { !BankSetupSheet.enableBankingKeys.contains($0) }
            if !other.isEmpty {
                let help = setupHelp(other)
                Section {
                    ForEach(other, id: \.self) { key in settingField(key) }
                    // a real row in accent colour, so it reads as a link (System Settings style)
                    if let help {
                        Link(destination: help.url) {
                            Label(help.title, systemImage: "arrow.up.forward.square")
                        }
                    }
                } footer: {
                    if let help {
                        Text(help.note)
                            .font(.caption).foregroundStyle(Theme.secondary)
                            .leadingFooter()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Where the one-time setup values come from: link and a short note.
    private func setupHelp(_ keys: [String]) -> (title: LocalizedStringKey, url: URL, note: LocalizedStringKey)? {
        if keys.contains("fints.product_id") {
            return ("Produktregistrierung öffnen",
                    URL(string: "https://www.fints.org/de/hersteller/produktregistrierung")!,
                    "FinTS-Programme brauchen eine kostenlose Produktregistrierung bei der Deutschen Kreditwirtschaft. Sie dauert meist einige Tage.")
        }
        if let k = selected?.connector, let link = KindAddForm.credentialsLink(k) {
            return (link.title, link.url,
                    "Die Zugangsdaten erstellen Sie einmalig bei Ihrer Bank. GiroCrab speichert sie verschlüsselt im Tresor.")
        }
        return nil
    }

    @ViewBuilder private func settingField(_ key: String) -> some View {
        let entry = model.settingEntry(key)
        let label = entry?.label ?? settingLabels[key] ?? key
        let binding = Binding(get: { setupValues[key] ?? "" }, set: { setupValues[key] = $0 })
        if entry?.isSecret ?? key.contains("secret") {
            SecureField(label, text: binding, prompt: Text("Erforderlich"))
        } else {
            TextField(label, text: binding, prompt: Text("Erforderlich"))
                .autocorrectionDisabled()
        }
    }

    // MARK: - Labels

    static func groupTitle(_ m: BankAccessMode) -> LocalizedStringKey {
        switch m {
        case .finTs: return "Direkt (FinTS 3.0 / HBCI)"
        case .ownApi: return "Direkt (Eigene API)"
        case .psd2: return "PSD2 (via Enable Banking)"
        }
    }

    static func groupHint(_ m: BankAccessMode) -> LocalizedStringKey {
        switch m {
        case .finTs: return "Keine Registrierung bei Dritten nötig"
        case .ownApi: return "Direkter Zugang über die API der Bank"
        case .psd2: return "Benötigt eine kostenlose eigene Enable-Banking-Anwendung"
        }
    }

    static func symbol(_ r: BankSearchResult) -> String {
        if let k = r.connector, let d = bankCatalog().first(where: { $0.kind == k }) { return d.sfSymbol }
        return r.mode == .psd2 ? "building.columns.circle" : "building.columns"
    }

    static func detailLine(_ r: BankSearchResult) -> String? {
        switch r.mode {
        case .finTs: return String(localized: "BLZ \(r.blz)")
        case .psd2: return r.country.isEmpty ? nil : (Locale.current.localizedString(forRegionCode: r.country) ?? r.country)
        case .ownApi: return nil
        }
    }

    /// What VoiceOver reads after the name: how the bank is reached, and where.
    static func accessibleDetail(_ r: BankSearchResult) -> String {
        let way: String
        switch r.mode {
        case .finTs: way = String(localized: "über FinTS")
        case .ownApi: way = String(localized: "über die eigene Schnittstelle der Bank")
        case .psd2: way = String(localized: "über Enable Banking")
        }
        return [way, detailLine(r)].compactMap { $0 }.joined(separator: ", ")
    }
}
