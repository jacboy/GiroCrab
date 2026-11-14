import SwiftUI
import GiroCrabCore
#if os(macOS)
import AppKit
#endif

/// "Neue Überweisung": SEPA credit transfer via FinTS (HKCCS). After the
/// confirmation card the model starts the session; the bank's TAN request is
/// shown by the existing `TwoFactorSheet`.
struct TransferSheetView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.textScale) private var textScale
    @State private var confirming = false
    @State private var suggestions: [KnownRecipient] = []
    @FocusState private var nameFocused: Bool
    @State private var dropTargeted = false
    @State private var importNote: String?

    private let maxPurpose = 140

    private var account: Account? {
        model.transferFormAccounts.first { $0.id == model.transferDraft.accountID }
    }
    /// The account can send from GiroCrab (FinTS / bunq); otherwise the form
    /// ends with a GiroCode for the bank's app.
    private var canSend: Bool { model.canSendTransfer(from: account?.id) }
    private var giroCodePayload: String? {
        guard let cents else { return nil }
        let d = model.transferDraft
        return GiroCode.payload(name: d.name, iban: d.iban, bic: bicText, amountCents: cents, purpose: d.purpose)
    }
    private var ibanValid: Bool { validateIban(iban: model.transferDraft.iban) }
    private var bicText: String { model.transferDraft.bic.trimmingCharacters(in: .whitespaces) }
    private var bicValid: Bool { bicText.isEmpty || Self.looksLikeBIC(bicText) }
    private var cents: Int64? {
        guard let c = try? parseAmountToCents(text: model.transferDraft.amountText), c > 0 else { return nil }
        return c
    }
    private var isBunq: Bool { account?.connector == .bunq }
    private var sendsInstant: Bool {
        model.transferDraft.instant && account?.connector?.offersInstantChoice == true
    }
    private var isMagicDemoAccount: Bool {
        guard let id = account?.connectionId,
              let c = model.connections.first(where: { $0.id == id }) else { return false }
        return AppModel.isMagicDemoLogin(c.loginName)
    }
    private var pinStored: Bool {
        guard let id = account?.connectionId else { return false }
        return model.isDemo || (model.connectionStatus(id)?.hasPin ?? false)
    }
    private var canReview: Bool {
        account != nil
            && !model.transferDraft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && ibanValid && bicValid && cents != nil
            && model.transferDraft.purpose.count <= maxPurpose
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            if !confirming && model.canBatchTransfer {
                TransferKindPicker(batch: false).padding(.bottom, 10)
            }
            Divider()
            if confirming {
                confirmation
            } else {
                form(draft: $model.transferDraft)
            }
            if model.transferError != nil || model.transferInstantDeclined != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let e = model.transferError {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).appFont(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let reason = model.transferInstantDeclined {
                        instantDeclined(reason)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            buttons.padding(14)
        }
        .macFrame(width: 560, height: 700)
        .task { if model.options.demoSheet == "transfer-confirm" { confirming = true } } // screenshots
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Theme.accent.opacity(0.06)).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !confirming, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await importInvoice(url) }
            }
            return true
        }
        // ⌘V outside a text field (inside one, normal paste keeps working).
#if os(macOS)
        .onPasteCommand(of: [.plainText]) { _ in pasteFromClipboard() }
#endif
        .onChange(of: model.transferDraft.iban) { _, new in
            let f = Self.groupedIBAN(new)
            if f != new { model.transferDraft.iban = f }
        }
        .onChange(of: model.transferDraft.purpose) { _, new in
            if new.count > maxPurpose { model.transferDraft.purpose = String(new.prefix(maxPurpose)) }
        }
        .onChange(of: model.transferDraft.name) { _, new in
            suggestions = nameFocused ? model.suggestRecipients(new) : []
        }
        .onChange(of: nameFocused) { _, f in
            suggestions = f ? model.suggestRecipients(model.transferDraft.name) : []
        }
    }

    private var title: LocalizedStringKey {
        confirming ? (canSend ? "Überweisung prüfen" : "GiroCode scannen") : "Neue Überweisung"
    }

    /// Title left, the two helpers (templates, paste) as small actions right.
    private var header: some View {
        HStack(spacing: 12) {
            Text(title).appFont(.title2, weight: .semibold)
            Spacer()
            if !confirming {
                TransferTemplatesMenu()
                Button { pasteFromClipboard() } label: { Label("Einfügen", systemImage: "doc.on.clipboard") }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Erkennt IBAN, Betrag, Empfänger und Zweck (⇧⌘V; ⌘V außerhalb von Textfeldern). Rechnung (PDF, ZUGFeRD, GiroCode) hierher ziehen.")
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // MARK: form

    private func form(draft: Binding<TransferDraft>) -> some View {
        Form {
            Section {
                Picker("Von Konto", selection: draft.accountID) {
                    ForEach(model.transferFormAccounts) { a in
                        Text("\(a.name) · \(formatIBAN(a.iban))").tag(Optional(a.id))
                    }
                }
            } footer: {
                if account != nil && !canSend { noDirectTransferNote }
            }

            Section {
                TextField("Name", text: draft.name, prompt: Text("Name des Empfängers"))
                    .multilineTextAlignment(.trailing)
                    .focused($nameFocused)
                if !suggestions.isEmpty { suggestionRow }
                LabeledContent("IBAN") {
                    HStack(spacing: 8) {
                        TextField("IBAN", text: draft.iban, prompt: Text("DE00 0000 0000 0000 0000 00"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, design: .monospaced)
                            .autocorrectionDisabled()
                        if !draft.wrappedValue.iban.isEmpty {
                            Image(systemName: ibanValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(ibanValid ? Color.green : Color.red)
                                .help(ibanValid ? "Prüfsumme korrekt" : "IBAN ungültig (Prüfsumme/Länge)")
                        }
                    }
                }
                LabeledContent("BIC (optional)") {
                    HStack(spacing: 8) {
                        TextField("BIC", text: draft.bic, prompt: Text("z. B. GENODEF1KS2"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, design: .monospaced)
                            .autocorrectionDisabled()
                        if !bicText.isEmpty {
                            Image(systemName: bicValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(bicValid ? Color.green : Color.red)
                        }
                    }
                }
            } header: {
                Text("Empfänger").appSectionHeader()
            } footer: {
                Text(importNote ?? String(localized: "Oder Rechnung hierher ziehen"))
            }

            Section {
                LabeledContent("Betrag") {
                    HStack(spacing: 6) {
                        TextField("Betrag", text: draft.amountText, prompt: Text(Money.plain(0)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .appFont(.body, monospacedDigit: true)
                        Text("€").foregroundStyle(Theme.secondary)
                    }
                }
                TextField("Verwendungszweck", text: draft.purpose, prompt: Text("Verwendungszweck"), axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Zahlung").appSectionHeader()
            } footer: {
                HStack {
                    if !draft.wrappedValue.amountText.isEmpty && cents == nil {
                        Text("Betrag > 0 eingeben").foregroundStyle(.red)
                    }
                    Spacer()
                    Text("\(draft.wrappedValue.purpose.count)/\(maxPurpose)")
                        .monospacedDigit()
                        .foregroundStyle(draft.wrappedValue.purpose.count >= maxPurpose ? Color.red : Theme.tertiary)
                }
            }

            if canSend && account?.connector?.offersInstantChoice == true {
                Section {
                    // Mutually exclusive choices: one radio group (HIG), not
                    // two checkboxes where one disables the other.
                    Picker("Art", selection: executionMode(draft)) {
                        Text("Normale Überweisung").tag(ExecutionMode.regular)
                        Text("Terminüberweisung").tag(ExecutionMode.scheduled)
                        Text("Echtzeitüberweisung (SEPA Instant)").tag(ExecutionMode.instant)
                    }
                    #if os(macOS)
                    .pickerStyle(.radioGroup)
                    #else
                    .pickerStyle(.menu)
                    #endif
                    .labelsHidden()
                    if draft.wrappedValue.executionMode == .scheduled {
                        DatePicker("Ausführungsdatum", selection: draft.executionDate,
                                   in: (Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())...,
                                   displayedComponents: .date)
                    }
                } header: {
                    Text("Ausführung").appSectionHeader()
                } footer: {
                    if draft.wrappedValue.executionMode == .instant { instantNote }
                }
            }

            if canSend && (model.isDemo || isMagicDemoAccount) {
                Section {
                    DemoHintBanner(style: .pinAndTan, buttonTitle: "PIN 12345 einfügen") { draft.pin.wrappedValue = "12345" }
                }
            }
            if canSend && !pinStored {
                Section {
                    SecureField(isBunq ? "bunq-API-Schlüssel" : "Banking-PIN", text: draft.pin,
                                prompt: Text(isBunq ? "wird nicht gespeichert" : "wird nicht gespeichert"))
                        .multilineTextAlignment(.trailing)
                } footer: {
                    Text(isBunq ? "Der API-Schlüssel wird nicht gespeichert." : "Die PIN wird nicht gespeichert.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var suggestionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.iban) { r in
                    Button {
                        model.transferDraft.name = r.name
                        model.transferDraft.iban = r.iban
                        suggestions = []
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.name).appFont(.callout).lineLimit(1)
                            Text(formatIBAN(r.iban)).appFont(.caption2, design: .monospaced).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.selection))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Why this account ends in a GiroCode instead of a direct transfer.
    @ViewBuilder private var noDirectTransferNote: some View {
        if model.bankingGate(forAccount: account?.id) != nil {
            // Security lock: no direct transfer, the GiroCode needs no bank contact.
            Label("Die Sicherheitssperre verhindert direkte Überweisungen von diesem Konto. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.", systemImage: "exclamationmark.shield")
        } else if account?.connector == .comdirect {
            // The comdirect REST API has no payment endpoint; FinTS has.
            Label("Die comdirect-Schnittstelle (REST) kann keine Überweisungen ausführen. Verbinden Sie das Konto zusätzlich per FinTS, um direkt zu überweisen. Sonst erhalten Sie am Ende einen GiroCode zum Scannen in der comdirect-App.", systemImage: "qrcode")
        } else {
            Label("Von diesem Konto kann GiroCrab nicht direkt überweisen. Am Ende erhalten Sie einen GiroCode zum Scannen in der App Ihrer Bank.", systemImage: "qrcode")
        }
    }

    @ViewBuilder private var instantNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Kommt in Sekunden an und ist nicht rückholbar. Bietet die Bank sie nicht an, wird nichts gesendet; Sie können sie dann als normale Überweisung senden.")
            if let c = cents, c >= 10_000_000 {
                Label("Viele Banken begrenzen Echtzeitüberweisungen (oft auf 100.000 € oder ein eigenes Limit). Die Bank kann den Auftrag dann ablehnen.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func executionMode(_ draft: Binding<TransferDraft>) -> Binding<ExecutionMode> {
        Binding(get: { draft.wrappedValue.executionMode }, set: { draft.wrappedValue.executionMode = $0 })
    }

    // MARK: confirmation

    @ViewBuilder private var confirmation: some View {
        if canSend { sendConfirmation } else { giroCodeView }
    }

    /// Read-only account (e.g. C24): the transfer as EPC QR code.
    private var giroCodeView: some View {
        let d = model.transferDraft
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let payload = giroCodePayload, let cg = GiroCode.image(for: payload) {
                        Image(decorative: cg, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .accessibilityLabel(Text("GiroCode"))
                    } else {
                        Image(systemName: "qrcode").resizable().foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Money.format(-(cents ?? 0)).replacingOccurrences(of: "-", with: ""))
                        .appFont(.largeTitle, weight: .semibold, monospacedDigit: true)
                    summaryRow("An", d.name)
                    summaryRow("IBAN", d.iban)
                    if !bicText.isEmpty { summaryRow("BIC", bicText.uppercased()) }
                    summaryRow("Zweck", d.purpose.isEmpty ? "–" : d.purpose)
                    summaryRow("Von", account.map { "\($0.name) · \(formatIBAN($0.iban))" } ?? "–")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            Label("In der App Ihrer Bank „Fotoüberweisung“ bzw. „QR-Code scannen“ wählen, den Code scannen und dort mit TAN freigeben. GiroCrab sendet nichts.", systemImage: "camera.viewfinder")
                .appFont(.callout).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Read-only review in the same grouped style as the form: the amount first,
    /// then recipient, payment and execution, each as label + value.
    private var sendConfirmation: some View {
        let d = model.transferDraft
        return Form {
            Section {
                Text(Money.format(-(cents ?? 0)).replacingOccurrences(of: "-", with: ""))
                    .appFont(.largeTitle, weight: .semibold, monospacedDigit: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            Section {
                reviewRow("Name", d.name)
                reviewRow("IBAN", d.iban, monospaced: true)
                if !bicText.isEmpty { reviewRow("BIC", bicText.uppercased(), monospaced: true) }
            } header: {
                Text("Empfänger").appSectionHeader()
            }
            Section {
                reviewRow("Verwendungszweck", d.purpose.isEmpty ? "–" : d.purpose)
                reviewRow("Von Konto", account.map { "\($0.name) · \(formatIBAN($0.iban))" } ?? "–")
                reviewRow("Ausführung", sendsInstant
                    ? String(localized: "Sofort (Echtzeitüberweisung)")
                    : d.executionDateISO.map { String(format: String(localized: "Am %@ (Terminüberweisung)"), $0) }
                        ?? String(localized: "Heute (SEPA-Überweisung)"))
            } header: {
                Text("Zahlung").appSectionHeader()
            } footer: {
                Label("Bitte Empfänger und IBAN genau prüfen. Eine freigegebene Überweisung lässt sich meist nicht mehr zurückholen.", systemImage: "exclamationmark.shield")
            }
        }
        .formStyle(.grouped)
    }

    private func reviewRow(_ label: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .appFont(.body, design: monospaced ? .monospaced : .default)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func summaryRow(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Theme.secondary).frame(width: 90 * textScale, alignment: .leading)
            Text(v).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Instant was not possible and nothing was sent: offer a regular
    /// transfer, which needs its own approval.
    private func instantDeclined(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Echtzeitüberweisung nicht ausgeführt", systemImage: "bolt.slash.fill")
                .appFont(.callout, weight: .bold)
            Text(String(format: String(localized: "Es wurde kein Geld gesendet. Grund der Bank: %@"), reason))
                .appFont(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Als normale Überweisung senden") { model.sendAsRegularTransfer() }
                .disabled(model.transferBusy)
            Text("Kommt in der Regel am nächsten Bankarbeitstag an. Sie geben sie erneut frei.")
                .appFont(.caption).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: buttons

    private var buttons: some View {
        HStack {
            if confirming && !canSend {
                Button("Zurück") { confirming = false }
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if confirming {
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Zurück") { confirming = false }
                Button(isBunq ? "In der bunq-App freigeben" : "Jetzt mit TAN freigeben") { model.startTransfer() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.transferBusy)
            } else {
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(canSend ? "Weiter" : "GiroCode erstellen") { model.transferError = nil; confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canReview || (canSend && !pinStored && model.transferDraft.pin.isEmpty)
                              || (!canSend && giroCodePayload == nil))
            }
        }
    }

    // MARK: Sm@rtPaste / invoice drop

    private func pasteFromClipboard() {
        #if os(macOS)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        #else
        let text = UIPasteboard.general.string ?? ""
        #endif
        report(PaymentParser.parseText(text))
    }

    private func importInvoice(_ url: URL) async {
        importNote = String(localized: "Lese Rechnung …")
        report(await PaymentParser.parseFile(url) ?? ParsedPayment())
    }

    private func report(_ p: ParsedPayment) {
        guard !p.isEmpty else { importNote = String(localized: "Nichts Erkennbares gefunden"); return }
        p.apply(to: &model.transferDraft)
        importNote = String(localized: "Felder ausgefüllt – bitte prüfen")
    }

    // MARK: helpers

    /// Upper-case, only A–Z/0–9, groups of four.
    static func groupedIBAN(_ raw: String) -> String {
        let clean = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return stride(from: 0, to: clean.count, by: 4).map { i -> String in
            let s = clean.index(clean.startIndex, offsetBy: i)
            let e = clean.index(s, offsetBy: min(4, clean.count - i))
            return String(clean[s..<e])
        }.joined(separator: " ")
    }

    static func looksLikeBIC(_ s: String) -> Bool {
        let u = Array(s.uppercased())
        guard u.count == 8 || u.count == 11 else { return false }
        return u[..<6].allSatisfy { $0.isASCII && $0.isLetter } && u[6...].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
