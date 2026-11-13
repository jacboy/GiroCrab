import SwiftUI
import GiroCrabCore

/// Shown above the stream while demo data is visible.
struct DemoBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let button = HStack(spacing: 14) {
            Button(model.hasOwnVault || AppModel.vaultMayHoldRealData ? "Zurück zum eigenen Tresor" : "Eigenes Konto anlegen") { model.showOwnVault() }
            if !model.hasOwnVault && !AppModel.vaultMayHoldRealData {
                Button("Sperrbildschirm testen") { model.previewLock() }
            }
        }
        .controlSize(.small)
        let content = HStack(alignment: .top, spacing: 12) {
            Image(systemName: "theatermasks.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Demo-Daten").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(model.hasOwnVault
                     ? "Ihr eigener Tresor ist noch leer. Hier sehen Sie erfundene Buchungen aller 7 Banken."
                     : "Erfundene Buchungen aller 7 Banken – keine echte Bank verbunden. Sobald echte Daten da sind, schützt Face ID bzw. Ihr Gerätecode den Tresor automatisch; hier können Sie den Sperrbildschirm testen.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            #if os(macOS)
            button
            #endif
        }
        VStack(alignment: .leading, spacing: 8) {
            content
            #if os(iOS)
            button
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.selection))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.18), lineWidth: 1))
    }
}

/// Always-visible hint for testers (Apple App Review): login `demo`, PIN `12345`, TAN `123456`.
/// `.credentials` = add-bank / PIN form, `.pinAndTan` = PIN, TAN and transfer dialogs.
struct DemoHintBanner: View {
    enum Style { case credentials, pinAndTan }
    let style: Style
    var buttonTitle: LocalizedStringKey? = nil
    let onFill: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(style == .credentials
                     ? "Test- & Demo-Zugang (ohne echtes Bankkonto): Kennung demo · PIN 12345"
                     : "Demo-Modus: PIN 12345 · TAN 123456")
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "play.circle.fill").foregroundStyle(Theme.accent)
            }
            Button(buttonTitle ?? (style == .credentials ? "Demo-Zugangsdaten ausfüllen" : "Demo-Werte einfügen"), action: onFill)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

/// Own vault without accounts: three steps + way back to the demo.
struct EmptyVaultCard: View {
    @Environment(AppModel.self) private var model
    @State private var showAddBank = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AnimatedCrabLogoView(size: 56, phase: .idle)
                Text("Willkommen bei GiroCrab").font(.title3.weight(.semibold))
            }
            Text("Ihr Tresor ist eingerichtet, enthält aber noch keine Konten. So geht es weiter:")
                .font(.callout).foregroundStyle(Theme.secondary)
            step(1, "Bank wählen und Anmeldenamen eingeben")
            step(2, "Fehlende Angaben ergänzen (z. B. FinTS-Produkt-ID, API-Schlüssel) – das Formular öffnet sich automatisch")
            step(3, "PIN eingeben und in der Banking-App freigeben")
            Button { showAddBank = true } label: {
                Label("Bank suchen und hinzufügen …", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            #if os(macOS)
            Button { model.openMoneyMoneyImport() } label: {
                Label("Aus MoneyMoney importieren …", systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            #else
            Button { model.openMoneyMoneyImport() } label: {
                Label("Von MoneyMoney wechseln", systemImage: "square.and.arrow.down.on.square")
            }
            #endif
            Divider()
            HStack {
                Text("Erst einmal ansehen?").font(.caption).foregroundStyle(Theme.secondary)
                Button("Demo-Daten & Demo-Banken laden (Kennung: demo / PIN: 12345)") { model.loadDemoData() }
                    .buttonStyle(.borderless)
            }
        }
        .card()
        .sheet(isPresented: $showAddBank) {
            AddBankSheet()
                .environment(model)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.selection))
            Text(text).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Fill in what a bank still needs (FinTS product ID, API keys …), then sync.
struct BankSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SetupRequest
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SymbolTile(symbol: request.connection.sfSymbol, tint: request.connection.connector.tint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(request.connection.displayName) einrichten").font(.headline)
                    Text("Diese Angaben fehlen noch, bevor Buchungen abgerufen werden können.")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                SyncBatchProgressLabel()
            }
            if request.keys.contains(where: { Self.enableBankingKeys.contains($0) }) {
                EnableBankingSetupSection(values: $values)
            }
            ForEach(request.keys.filter { !Self.enableBankingKeys.contains($0) }, id: \.self) { key in
                let entry = model.settingEntry(key)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry?.label ?? settingLabels[key] ?? key).font(.callout.weight(.medium))
                    if key.contains("private_key") {
                        TextEditor(text: binding(key))
                            .font(.caption.monospaced())
                            .frame(height: 80)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    } else if entry?.isSecret ?? key.contains("secret") {
                        SecureField(entry?.label ?? settingLabels[key] ?? key, text: binding(key))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(entry?.label ?? settingLabels[key] ?? key, text: binding(key), prompt: Text(entry?.value.isEmpty == false ? entry!.value : ""))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    if let help = entry?.help { Text(help).font(.caption).foregroundStyle(Theme.secondary) }
                    if key == "fints.product_id" {
                        Link("Kostenlose FinTS-Produktregistrierung (Deutsche Kreditwirtschaft) öffnen",
                             destination: URL(string: "https://www.fints.org/de/hersteller/produktregistrierung")!)
                            .font(.caption)
                        Text("Die Registrierung dauert meist einige Tage. Bis dahin können Sie GiroCrab mit den Demo-Daten ausprobieren.")
                            .font(.caption2).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            // "Alle abrufen": cancelling skips this login (see SyncPromptButtons)
            SyncPromptButtons(
                // no dismiss(): clearing the request closes this sheet, and in
                // "Alle abrufen" the next login may already have opened its own –
                // a dismiss() here would close that one and stall the batch.
                cancel: { model.cancelSetupRequest() },
                leading: nil
            ) {
                Button { model.completeSetup(request, values: values) } label: {
                    Text("Speichern & abrufen").frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // HIG: the default button stays off until every required field has a value.
                .disabled(request.keys.contains { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(24)
        .macFrame(width: 520)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    /// Shown together in `EnableBankingSetupSection` (guide, key file, check).
    static let enableBankingKeys: Set<String> = [
        "enablebanking.application_id", "enablebanking.private_key_pem", "enablebanking.redirect_url",
    ]
}
