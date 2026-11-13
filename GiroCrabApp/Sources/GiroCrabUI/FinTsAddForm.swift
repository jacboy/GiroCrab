import SwiftUI
import GiroCrabCore

/// FinTS login form of the "Bank hinzufügen" assistant; for "Andere FinTS-Bank"
/// with preset picker and manual BLZ / FinTS URL.
/// Any FinTS 3.0 PIN/TAN bank works: pick a preset, search for it, or type an
/// 8-digit BLZ (or paste a German IBAN) – name and FinTS URL are then filled in
/// from the built-in bank directory. The URL stays editable for custom banks.
struct FinTsAddForm: View {
    @Environment(AppModel.self) private var model
    /// Bank chosen in the search picker (pre-fills BLZ, name and URL).
    var prefill: BankSearchResult? = nil
    var onAdded: () -> Void = {}
    /// Inside the "Bank hinzufügen" assistant: no own button (see `AddBankSubmit`).
    var submit: AddBankSubmit? = nil

    @State private var presets = fintsPresets()
    @State private var presetID = "custom"
    @State private var blz = ""
    @State private var url = ""
    @State private var bankName = ""
    @State private var login = ""
    @State private var tanMedium = ""
    /// Bank found in the directory for the current BLZ.
    @State private var found: FinTsBankInfo?
    /// The URL we filled in ourselves; typing anything else marks it as user-edited.
    @State private var autoURL = ""
    @State private var urlEdited = false

    private var preset: FinTsPreset? { presets.first { $0.id == presetID } }
    private var blzValid: Bool { blz.count == 8 && blz.allSatisfy(\.isASCII) && blz.allSatisfy(\.isNumber) }
    private var urlValid: Bool { url.hasPrefix("https://") && url.count > 9 && !url.contains(where: \.isWhitespace) }
    /// Banks that use BestSign / need a TAN medium name and (Postbank) the Postbank ID.
    private var bankName_lc: String { (found?.name ?? bankName).lowercased() }
    private var isPostbank: Bool { bankName_lc.contains("postbank") }
    private var needsMediumHint: Bool {
        isPostbank || bankName_lc.contains("deutsche bank") || bankName_lc.contains("norisbank")
    }
    private var canAdd: Bool { blzValid && urlValid && !login.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Opened by the user, or because the address was changed.
    @State private var showAdvanced = false

    /// The bank came from the search: BLZ and address are fixed by the directory.
    private var known: Bool { prefill != nil && found != nil }

    /// Sections of their own (the assistant does not wrap this form):
    /// known bank – "Bank" (read-only), "Anmeldung", collapsible "Erweitert";
    /// "Andere FinTS-Bank" – "Bank" with BLZ and address to fill in, "Anmeldung".
    var body: some View {
        Section {
            if known {
                LabeledContent("Bankleitzahl", value: blz)
                LabeledContent("Verfahren", value: String(localized: "FinTS 3.0 mit PIN und TAN"))
            } else {
                if presets.count > 1 {
                    Picker("Vorlage", selection: $presetID) {
                        ForEach(presets, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: presetID) { _, _ in
                        guard let p = preset else { return }
                        bankName = p.id == "custom" ? "" : p.name
                        urlEdited = false
                        autoURL = p.url
                        url = p.url
                        blz = p.blz
                        lookup()
                    }
                }
                TextField("Bankleitzahl", text: $blz, prompt: Text("8 Ziffern oder IBAN"))
                    .autocorrectionDisabled()
                    .onChange(of: blz) { _, _ in
                        // a pasted German IBAN becomes its BLZ (characters 5–12)
                        if let b = blzFromBankInput(input: blz), b != blz { blz = b; return }
                        lookup()
                    }
                if let f = found { LabeledContent("Bank", value: f.name) }
                urlField
            }
        } header: {
            Text("Bank")
        } footer: {
            if !known { bankFooter }
        }
        .onAppear { apply(prefill) }
        .onChange(of: prefill?.id) { _, _ in apply(prefill) }
        .onChange(of: canAdd, initial: true) { _, ok in submit?.update(ok, commit) }

        Section {
            if model.demoActive || blz == "99999999" { DemoHintBanner(style: .credentials) { login = "demo" } }
            TextField("Anmeldename", text: $login, prompt: Text(isPostbank ? "Postbank ID" : "z. B. VR-NetKey oder Kontonummer"))
                .autocorrectionDisabled()
            TextField("TAN-Medium", text: $tanMedium, prompt: Text("Optional"))
                .autocorrectionDisabled()
            if submit == nil {
                Button("Bank hinzufügen") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        } header: {
            Text("Anmeldung")
        } footer: {
            AddFormFooter(lines: [
                isPostbank ? String(localized: "Postbank: Als Anmeldename die Postbank ID verwenden, nicht die Kontonummer.") : "",
                needsMediumHint
                    ? String(localized: "Fordert die Bank ein TAN-Medium (Fehler 9210), tragen Sie den Gerätenamen aus der BestSign- oder App-Verwaltung ein, z. B. SO:Gerätename.")
                    : String(localized: "Das TAN-Medium brauchen Sie nur, wenn die Bank danach fragt."),
            ])
        }

        if known {
            Section(isExpanded: $showAdvanced) {
                LabeledContent {
                    urlField.labelsHidden()
                } label: {
                    Text("FinTS-Adresse")
                    Text("Aus dem Bankverzeichnis der Deutschen Kreditwirtschaft. Nur ändern, wenn Ihre Bank eine andere angibt.")
                }
            } header: {
                Text("Erweitert")
            }
        }
    }

    /// "Andere FinTS-Bank": what is wrong, or where the address comes from.
    @ViewBuilder private var bankFooter: some View {
        Group {
            if (!blz.isEmpty && !blzValid) || (!url.isEmpty && !urlValid) {
                Label("Bankleitzahl: genau 8 Ziffern · FinTS-Adresse: beginnt mit https://", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if blzValid, found == nil {
                Text("Diese Bankleitzahl steht nicht im Verzeichnis. Tragen Sie die FinTS-Adresse Ihrer Bank selbst ein.")
                    .foregroundStyle(.secondary)
            } else if let n = preset?.note, !n.isEmpty {
                Text(n).foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .leadingFooter()
    }

    private var urlField: some View {
        TextField("FinTS-Adresse", text: $url, prompt: Text("https://…"))
            .autocorrectionDisabled()
            .onChange(of: url) { _, new in
                if new != autoURL { urlEdited = true; showAdvanced = true }
            }
    }

    private func commit() {
        let name = bankName.trimmingCharacters(in: .whitespaces)
        model.addFinTsConnection(name: name.isEmpty ? "FinTS-Bank \(blz)" : name, blz: blz, url: url, login: login, tanMedium: tanMedium)
        login = ""
        tanMedium = ""
        onAdded()
    }

    private func apply(_ r: BankSearchResult?) {
        guard let r, r.mode == .finTs else { return }
        presetID = "custom"
        bankName = r.name
        autoURL = r.url
        urlEdited = false
        url = r.url
        blz = r.blz
        lookup()
    }

    /// Fills in name and URL from the directory once a full BLZ is typed.
    private func lookup() {
        guard blzValid, let info = lookupFintsBankByBlz(blz: blz) else {
            // BLZ no longer matches: drop what we filled in ourselves
            if found != nil {
                found = nil
                if !urlEdited, url == autoURL { url = ""; autoURL = "" }
            }
            return
        }
        found = info
        if bankName.isEmpty || preset?.name == bankName || presetID == "custom" { bankName = info.name }
        if !urlEdited || url.isEmpty {
            autoURL = info.url
            url = info.url
            urlEdited = false
        }
    }
}
