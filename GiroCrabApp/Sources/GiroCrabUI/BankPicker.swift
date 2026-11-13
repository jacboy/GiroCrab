import SwiftUI
import GiroCrabCore

/// Link between an embedded add form and the assistant's footer: whether the
/// form is complete, and what "Hinzufügen" does.
@Observable final class AddBankSubmit {
    var canSubmit = false
    @ObservationIgnored var action: () -> Void = {}

    func update(_ ok: Bool, _ action: @escaping () -> Void) {
        self.action = action
        if canSubmit != ok { canSubmit = ok }
    }
}

/// Add form for a bank with a dedicated connector (bunq, comdirect, Trade
/// Republic, PayPal, American Express, Amazon Visa).
struct KindAddForm: View {
    @Environment(AppModel.self) private var model
    let kind: ConnectorKind
    var onAdded: () -> Void = {}
    /// Inside the "Bank hinzufügen" assistant: no own button; readiness and the
    /// add action go to the assistant's footer.
    var submit: AddBankSubmit? = nil
    @State private var login = ""

    private var canAdd: Bool { !(loginRequired && login.trimmingCharacters(in: .whitespaces).isEmpty) }

    private func commit() {
        model.addConnection(kind, login: kind == .tradeRepublic ? normalizePhoneNumber(input: login) : login)
        login = ""
        onAdded()
    }

    /// Banks that need the login to sign in. For the others (Amazon, Amex,
    /// PayPal, bunq …) the field is only an optional display name.
    private var loginRequired: Bool {
        [.comdirect, .tradeRepublic, .volksbankKasselGoettingen, .direkt1822, .finTsGeneric].contains(kind)
    }

    /// Page where the bank hands out the API credentials GiroCrab asks for.
    static func credentialsLink(_ kind: ConnectorKind) -> (title: LocalizedStringKey, url: URL)? {
        switch kind {
        case .comdirect:
            return ("API-Zugangsdaten bei comdirect erstellen", URL(string: "https://kunde.comdirect.de/itx/oauth/privatkunden")!)
        default:
            return nil
        }
    }

    /// One section: login and the fixed facts as rows, every explanation once
    /// in the footer (HIG: notes belong under the section, not between rows).
    var body: some View {
        if let d = bankCatalog().first(where: { $0.kind == kind }) {
            Section {
                if model.demoActive { DemoHintBanner(style: .credentials) { login = "demo" } }
                TextField(d.loginLabel, text: $login, prompt: loginRequired ? nil : Text("Optional"))
                    .autocorrectionDisabled()
                    .onChange(of: canAdd, initial: true) { _, ok in submit?.update(ok, commit) }
                LabeledContent("Verfahren", value: d.protocol)
                if !d.bankCode.isEmpty { LabeledContent("Bankleitzahl", value: d.bankCode) }
                if submit == nil {
                    Button("Bank hinzufügen") { commit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAdd)
                }
            } header: {
                Text("Zugang")
            } footer: {
                let missing = d.requiredSettings.filter { key in !(model.settings.first { $0.key == key }?.hasValue ?? false) }
                AddFormFooter(lines: [d.note] + (missing.isEmpty || submit != nil ? [] :
                    [String(localized: "Wird nach dem Hinzufügen abgefragt: \(missing.map { settingLabels[$0] ?? $0 }.joined(separator: ", "))")]),
                              // in the assistant the link sits under the credential fields ("Einrichten")
                              link: submit == nil ? Self.credentialsLink(kind) : nil)
            }
        }
    }
}

/// Footer of an add form: the notes, then the hint that an existing login is
/// updated rather than added twice.
struct AddFormFooter: View {
    let lines: [String]
    /// Where the user gets what the form asks for (e.g. API credentials).
    var link: (title: LocalizedStringKey, url: URL)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, l in Text(l) }
            if let link {
                // tint, not the footer's grey: it has to read as a link
                Link(link.title, destination: link.url).foregroundStyle(.tint)
            }
            Text("Gibt es den Zugang schon (gleiche Bank, gleiche Kennung), wird er aktualisiert statt doppelt angelegt.")
        }
        .font(.caption).foregroundStyle(.secondary)
        .leadingFooter()
    }
}

/// Add form for a bank reached through Enable Banking: the bank is fixed by the
/// search result; the Enable Banking credentials are asked for right after adding.
struct Psd2AddForm: View {
    @Environment(AppModel.self) private var model
    let bank: BankSearchResult
    var onAdded: () -> Void = {}
    var submit: AddBankSubmit? = nil
    @State private var label = ""

    private func commit() {
        model.addEnableBankingConnection(aspsp: bank.aspsp, country: bank.country, name: bank.name, label: label)
        label = ""
        onAdded()
    }

    private var missing: [String] {
        (bankCatalog().first { $0.kind == .enableBanking }?.requiredSettings ?? [])
            .filter { key in !(model.settings.first { $0.key == key }?.hasValue ?? false) }
    }

    var body: some View {
        Section {
            LabeledContent("Land", value: Locale.current.localizedString(forRegionCode: bank.country) ?? bank.country)
            LabeledContent("Verfahren", value: String(localized: "PSD2 über Enable Banking"))
            if model.demoActive { DemoHintBanner(style: .credentials) { label = "demo" } }
            TextField("Bezeichnung", text: $label, prompt: Text("Optional"))
                .autocorrectionDisabled()
                .onAppear { submit?.update(true, commit) }
            if submit == nil {
                Button("Bank hinzufügen") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Zugang")
        } footer: {
            AddFormFooter(lines: [
                bank.tested,
                String(localized: "Sie melden sich in einem GiroCrab-Fenster direkt bei Ihrer Bank an. Dafür brauchen Sie eine kostenlose eigene Anwendung auf enablebanking.com – die Einrichtung führt Sie Schritt für Schritt hindurch."),
            ] + (missing.isEmpty || submit != nil ? [] :
                [String(localized: "Wird nach dem Hinzufügen abgefragt: \(missing.map { settingLabels[$0] ?? $0 }.joined(separator: ", "))")]))
        }
    }
}
