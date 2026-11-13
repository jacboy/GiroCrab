import SwiftUI
import GiroCrabCore

/// Keyword / regex auto-categorisation rules with live preview.
struct RuleEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let initialDraft: Rule?

    @State private var selection: Int64?
    @State private var draft: Rule?
    /// Rule waiting for the delete confirmation. The dialog lives here, not in
    /// RuleForm: RuleForm's binding is force-unwrapped from `draft`, so a dialog
    /// attached to it would still update after `draft` became nil (crash).
    @State private var ruleToDelete: Rule?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(model.rules) { rule in
                    HStack {
                        Image(systemName: rule.enabled ? "wand.and.stars" : "pause.circle")
                            .foregroundStyle(rule.enabled ? Color.readable(hex: color(of: rule)) : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name).lineLimit(1)
                            Text("→ " + categoryName(rule.categoryId)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text("\(rule.matchCount)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    .tag(rule.id)
                }
            }
            .navigationTitle("Regeln")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { newRule() } label: { Label("Neue Regel", systemImage: "plus") }
                }
            }
        } detail: {
            if let current = draft {
                // Not Binding($draft): its force-unwrap crashes when the form
                // updates once more after `draft` became nil (e.g. while the
                // delete confirmation closes). Fall back to the last value.
                RuleForm(rule: Binding(get: { draft ?? current }, set: { draft = $0 }),
                         onSave: save, onDelete: { ruleToDelete = $0 })
            } else {
                ContentUnavailableView("Keine Regel ausgewählt", systemImage: "wand.and.stars", description: Text("Regeln ordnen neue Buchungen automatisch Kategorien zu. Die erste passende Regel (nach Priorität) gewinnt; manuelle Zuordnungen werden nie überschrieben."))
            }
        }
        .macFrame(minWidth: 860, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Fertig") { dismiss() }
            }
            ToolbarItem(placement: .automatic) {
                Button { model.applyAllRules() } label: { Label("Alle Regeln anwenden", systemImage: "play.fill") }
            }
        }
        .confirmationDialog("Regel löschen?",
                            isPresented: Binding(get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }),
                            titleVisibility: .visible, presenting: ruleToDelete) { rule in
            Button("Löschen", role: .destructive) { delete(rule) }
            Button("Abbrechen", role: .cancel) {}
        } message: { _ in
            Text("Buchungen, die diese Regel kategorisiert hat, sind danach wieder ohne Kategorie. Das lässt sich nicht widerrufen.")
        }
        .onAppear {
            if let d = initialDraft {
                draft = d
                selection = d.id == 0 ? nil : d.id
            }
            model.ruleDraft = nil
        }
        .onChange(of: selection) { _, new in
            if let new, let r = model.rules.first(where: { $0.id == new }) { draft = r }
        }
    }

    private func color(of rule: Rule) -> String {
        model.categories.first { $0.id == rule.categoryId }?.colorHex ?? "#8E8E93"
    }

    private func categoryName(_ id: Int64) -> String {
        model.categories.first { $0.id == id }?.path ?? "?"
    }

    private func newRule() {
        selection = nil
        draft = model.newRuleDraft()
    }

    private func save(_ rule: Rule) {
        if let id = model.saveRule(rule) {
            selection = id
            draft = model.rules.first { $0.id == id }
        }
    }

    private func delete(_ rule: Rule) {
        model.deleteRule(rule.id)
        selection = nil
        draft = nil
    }
}

struct RuleForm: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: Rule
    let onSave: (Rule) -> Void
    /// Asks to delete (RuleEditorView confirms first).
    let onDelete: (Rule) -> Void

    @State private var minText = ""
    @State private var maxText = ""
    @State private var direction = 0 // 0 any, 1 expenses, 2 income

    var body: some View {
        let preview = model.preview(rule)
        VStack(spacing: 0) {
            Form {
                Section("Regel") {
                    TextField("Name", text: $rule.name)
                    Picker("Kategorie", selection: $rule.categoryId) {
                        ForEach(model.categories) { c in
                            Text(String(repeating: "    ", count: Int(c.depth)) + c.name).tag(c.id)
                        }
                    }
                    Toggle("Aktiv", isOn: $rule.enabled)
                    Stepper("Priorität \(rule.priority)", value: $rule.priority, in: 0...10_000, step: 10)
                }
                Section("Treffer") {
                    // A search expression names its fields itself and ignores case.
                    if rule.matchKind != .expression {
                        Picker("Suchen in", selection: $rule.field) {
                            Text("Name, Verwendungszweck und Buchungstext").tag(RuleField.any)
                            Text("Name").tag(RuleField.counterparty)
                            Text("Verwendungszweck").tag(RuleField.purpose)
                            Text("Buchungstext").tag(RuleField.bookingText)
                            Text("IBAN").tag(RuleField.counterpartyIban)
                        }
                    }
                    Picker("Art", selection: $rule.matchKind) {
                        Text("Stichwörter").tag(MatchKind.keyword)
                        Text("Regulärer Ausdruck").tag(MatchKind.regex)
                        Text("Suchausdruck").tag(MatchKind.expression)
                    }
                    .pickerStyle(.segmented)
                    if rule.matchKind != .expression {
                        Toggle("Groß-/Kleinschreibung beachten", isOn: $rule.caseSensitive)
                    }
                }
                // The pattern gets its own full-width, multi-line field so long
                // patterns wrap instead of scrolling sideways; the example is
                // the footer, apart from the input (#179). A vertical
                // TextField, not a TextEditor: no smart-quote substitution.
                Section {
                    TextField("Muster", text: $rule.pattern, prompt: Text(placeholder), axis: .vertical)
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3...10)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Muster")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Beispiel: \(Text(verbatim: placeholder).font(.caption.monospaced()))")
                            .textSelection(.enabled)
                        if rule.matchKind == .expression {
                            Text("Mit AND, OR, NOT, Klammern, „Wortgruppen“, * und ?, /Regex/, Feldern wie name: oder purpose: und Beträgen wie amount<0.")
                        } else if rule.matchKind == .keyword {
                            #if os(macOS)
                            Text("Stichwörter mit | trennen oder eines pro Zeile (neue Zeile mit ⌥↩).")
                            #else
                            Text("Stichwörter mit | trennen oder eines pro Zeile.")
                            #endif
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .leadingFooter()
                }
                Section("Betrag") {
                    Picker("Richtung", selection: $direction) {
                        Text("Alle").tag(0)
                        Text("Nur Ausgaben").tag(1)
                        Text("Nur Einnahmen").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Picker("Konto", selection: $rule.accountId) {
                        Text("Alle Konten").tag(Int64?.none)
                        ForEach(model.allAccounts) { a in
                            Text("\(a.bankName) – \(a.name)").tag(Int64?.some(a.id))
                        }
                    }
                }
                Section {
                    if let err = preview.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else {
                        Text("\(preview.matches.count >= 200 ? "200+" : String(preview.matches.count)) passende Buchungen")
                            .font(.headline)
                        ForEach(preview.matches.prefix(40)) { b in
                            HStack {
                                Text(DateText.medium(b.bookingDate)).foregroundStyle(.secondary).monospacedDigit()
                                Text(b.counterparty).lineLimit(1)
                                Spacer()
                                if b.categorySource == .manual {
                                    Image(systemName: "hand.raised.fill").foregroundStyle(.secondary).help("Manuell zugeordnet – die Regel ändert das nicht")
                                }
                                Text(Money.format(b.amountCents)).monospacedDigit().foregroundStyle(Money.ink(b.amountCents))
                            }
                            .font(.callout)
                        }
                    }
                } header: {
                    Text("Live-Vorschau")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if rule.id != 0 {
                    Button("Regel löschen …", role: .destructive) { onDelete(rule) }
                }
                Spacer()
                Button("Speichern & anwenden") { onSave(rule) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(rule.pattern.trimmingCharacters(in: .whitespaces).isEmpty || preview.error != nil)
            }
            .padding(12)
        }
        .onAppear(perform: syncDirection)
        .onChange(of: rule.id) { _, _ in syncDirection() }
        .onChange(of: direction) { _, d in
            switch d {
            case 1: rule.minAmountCents = nil; rule.maxAmountCents = 0
            case 2: rule.minAmountCents = 1; rule.maxAmountCents = nil
            default: rule.minAmountCents = nil; rule.maxAmountCents = nil
            }
        }
    }

    private var placeholder: String {
        switch rule.matchKind {
        case .keyword: "REWE | EDEKA | ALDI"
        case .regex: #"^DB\s+(Fernverkehr|Vertrieb)"#
        case .expression: #"name:REWE OR purpose:"Bahn AG""#
        }
    }

    private func syncDirection() {
        if rule.maxAmountCents == 0 { direction = 1 } else if rule.minAmountCents == 1 { direction = 2 } else { direction = 0 }
    }
}
