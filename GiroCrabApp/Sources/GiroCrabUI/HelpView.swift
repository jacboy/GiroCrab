import SwiftUI

/// Eine Hilfe-Seite. Texte liegen zweisprachig im Code (Deutsch/Englisch),
/// damit die Suche den ganzen Inhalt durchsuchen kann; Markdown im Fließtext.
struct HelpTopic: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: [String: String]
    let body: [String: String]
    /// Zusätzliche Suchbegriffe (beide Sprachen).
    let keywords: [String]

    func title(_ lang: String) -> String { title[lang] ?? title["de"] ?? id }
    func body(_ lang: String) -> String { body[lang] ?? body["de"] ?? "" }

    /// Alle Suchbegriffe müssen vorkommen (Groß-/Kleinschreibung und Diakritika egal).
    func matches(_ query: String, language: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if terms.isEmpty { return true }
        let haystack = ([title(language), body(language)] + keywords)
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return terms.allSatisfy {
            haystack.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
        }
    }
}

enum HelpLinks {
    static let website = URL(string: "https://girocrab.de")!
    static let issues = URL(string: "https://github.com/GiroCrab/GiroCrab/issues")!
    static let discussions = URL(string: "https://github.com/GiroCrab/GiroCrab/discussions")!
}

enum HelpCatalog {
    static func filter(_ topics: [HelpTopic], query: String, language: String) -> [HelpTopic] {
        topics.filter { $0.matches(query, language: language) }
    }

    /// Tastaturkürzel (macOS), geprüft gegen die Menüs in `RootView`.
    static let shortcuts: [(keys: String, de: String, en: String)] = [
        ("⌘R", "Alle Konten abrufen", "Sync all accounts"),
        ("⌘F", "Suchen", "Search"),
        ("⌘K", "Befehlspalette", "Command palette"),
        ("⌘,", "Einstellungen", "Settings"),
        ("⌘?", "GiroCrab-Hilfe", "GiroCrab Help"),
        ("⌃⌘L", "Tresor sperren", "Lock vault"),
        ("⌘N", "Neue Überweisung", "New transfer"),
        ("⇧⌘N", "Neue Kontogruppe", "New account group"),
        ("⌥⌘K", "Regeln", "Rules"),
        ("C", "Kategorie wählen (in der Buchungsliste)", "Quick category (in the booking list)"),
        ("R", "Regel aus Buchung erstellen (in der Buchungsliste)", "Create rule from booking (in the booking list)"),
        ("⌃⌘C / ⌃⌘R", "Kategorisieren / Regel erstellen (Menü Buchung)", "Categorize / create rule (Booking menu)"),
        ("⇧⌘U", "Als geprüft markieren", "Mark as reviewed"),
        ("⌘Y", "Beleg in Quick Look", "Show receipt in Quick Look"),
        ("⌃⌘↓ / ⌃⌘↑", "Nächste / vorherige Buchung", "Next / previous booking"),
        ("⌘1 … ⌘9", "Buchungsbereich wechseln", "Switch booking scope"),
        ("⌘P", "Drucken", "Print"),
    ]

    static let topics: [HelpTopic] = [
        HelpTopic(
            id: "start", icon: "flag.checkered",
            title: ["de": "Erste Schritte & MoneyMoney-Import", "en": "Getting started & MoneyMoney import"],
            body: [
                "de": """
                Beim ersten Start legt GiroCrab einen **lokalen, verschlüsselten Tresor** an. Danach gibt es zwei Wege, Buchungen zu laden: Bank direkt verbinden (siehe „Banken verbinden“) oder bestehende Daten importieren.

                **MoneyMoney-Import:** *Ablage › Aus MoneyMoney importieren …* liest die MoneyMoney-Datenbank (Konten, Buchungen, Kategorien) oder eine CSV-Datei. Der Import kann gefahrlos wiederholt werden, bereits vorhandene Buchungen werden nicht doppelt angelegt.

                **Startsaldo & Kalibrieren:** Konten ohne Banksaldo (z. B. CSV-Import oder Kreditkarten-Portale) kennen nur die importierten Umsätze. Damit der Kontostand stimmt, trägst du bei „Startsaldo & Kalibrieren“ den echten Saldo zu einem Stichtag ein. GiroCrab rechnet den Anfangssaldo daraus zurück und hält den Verlauf danach konsistent.
                """,
                "en": """
                On first launch GiroCrab creates a **local, encrypted vault**. You then have two ways to load bookings: connect a bank directly (see "Connecting banks") or import existing data.

                **MoneyMoney import:** *File › Import from MoneyMoney …* reads the MoneyMoney database (accounts, bookings, categories) or a CSV file. Importing is safe to repeat; bookings that already exist are not duplicated.

                **Opening balance & calibrate:** Accounts without a bank balance (e.g. CSV imports or card portals) only know the imported transactions. To get the right balance, enter the real balance for a date under "Opening balance & calibrate". GiroCrab derives the starting balance from it and keeps the history consistent afterwards.
                """],
            keywords: ["import", "csv", "moneymoney", "startsaldo", "opening balance", "kalibrieren", "calibrate"]),
        HelpTopic(
            id: "fints", icon: "building.columns",
            title: ["de": "Banken verbinden: FinTS / HBCI", "en": "Connecting banks: FinTS / HBCI"],
            body: [
                "de": """
                FinTS fragt deine Bank direkt ab, ohne Zwischenserver. Gehe auf *Ablage › Bank hinzufügen …* und wähle FinTS.

                - **Registrierung:** GiroCrab nutzt standardmäßig seine **eingebaute FinTS-Registrierung**. Wenn du lieber eine eigene Produkt-ID der Deutschen Kreditwirtschaft verwendest, trage sie unter *Einstellungen › FinTS & API-Schlüssel › FinTS-Registrierung* ein.
                - **Anmeldung:** Viele Banken verlangen die **Anmelde-/Legitimations-ID** (VR-NetKey, Benutzerkennung) statt der Kontonummer. Wenn die Anmeldung scheitert, probiere diese Kennung.
                - **PIN:** Die Online-Banking-PIN ist oft nur 5-stellig. Sie wird im Schlüsselbund bzw. im verschlüsselten Tresor gespeichert, nicht im Klartext.
                - **TAN:** Das TAN-Verfahren (pushTAN, chipTAN, …) wählst du beim Hinzufügen; der TAN-Dialog erscheint beim Abruf.
                """,
                "en": """
                FinTS queries your bank directly, without an intermediary server. Go to *File › Add bank …* and choose FinTS.

                - **Registration:** GiroCrab uses its **built-in FinTS registration** by default. If you prefer your own product ID from the German banking industry (DK), enter it under *Settings › FinTS & API keys › FinTS registration*.
                - **Login:** Many banks require the **login / legitimation ID** (VR-NetKey, user ID) instead of the account number. If sign-in fails, try that ID.
                - **PIN:** The online-banking PIN is often only 5 digits. It is stored in the keychain / encrypted vault, never in plain text.
                - **TAN:** You pick the TAN method (pushTAN, chipTAN, …) when adding the bank; the TAN dialog appears during sync.
                """],
            keywords: ["hbci", "fints", "pin", "tan", "produkt-id", "registrierung", "registration", "anmeldename", "login"]),
        HelpTopic(
            id: "enable-banking", icon: "network",
            title: ["de": "Banken verbinden: Enable Banking (PSD2 – C24, N26 …)", "en": "Connecting banks: Enable Banking (PSD2 – C24, N26 …)"],
            body: [
                "de": """
                Für Banken ohne FinTS (z. B. C24, N26) nutzt GiroCrab PSD2 über **Enable Banking**. Du brauchst dafür eine kostenlose, **persönliche App** bei Enable Banking:

                1. Auf **enablebanking.com** registrieren und im Control Panel eine neue Anwendung anlegen (Umgebung „Production“, Zugriff auf eigene Konten).
                2. Als **Privacy-Policy-URL** und **Terms-of-Service-URL** jeweils `https://girocrab.de` eintragen.
                3. Beim Erstellen wird ein privater Schlüssel als **.pem-Datei** erzeugt. Diese Datei in GiroCrab unter *Bank hinzufügen › Enable Banking* hochladen, dazu die Application-ID eintragen.
                4. Bank auswählen und im Browser freigeben. Danach die Konten in GiroCrab verknüpfen.
                5. **C24:** Beim Freigeben wird die Telefonnummer im internationalen Format verlangt, z. B. `+491701234567`.

                Die Freigabe ist zeitlich befristet (meist 90 Tage); GiroCrab erinnert dich an die Erneuerung.
                """,
                "en": """
                For banks without FinTS (e.g. C24, N26) GiroCrab uses PSD2 via **Enable Banking**. You need a free **personal app** at Enable Banking:

                1. Sign up at **enablebanking.com** and create a new application in the control panel (environment "Production", access to your own accounts).
                2. Enter `https://girocrab.de` as both the **Privacy policy URL** and **Terms of service URL**.
                3. Creating the app generates a private key as a **.pem file**. Upload it in GiroCrab under *Add bank › Enable Banking* and enter the application ID.
                4. Choose your bank and approve access in the browser. Then link the accounts in GiroCrab.
                5. **C24:** The approval asks for your phone number in international format, e.g. `+491701234567`.

                Consent is time-limited (usually 90 days); GiroCrab reminds you to renew it.
                """],
            keywords: ["psd2", "c24", "n26", "enable banking", "pem", "privacy", "tos", "telefon", "phone", "open banking"]),
        HelpTopic(
            id: "other-banks", icon: "creditcard",
            title: ["de": "comdirect, Trade Republic, Scalable Capital, Amex", "en": "comdirect, Trade Republic, Scalable Capital, Amex"],
            body: [
                "de": """
                - **comdirect:** Zugang über die comdirect-Schnittstelle; Zugangsdaten und die Freigabe per photoTAN/Push in der App bestätigen.
                - **Trade Republic:** Anmeldung mit Telefonnummer und PIN, danach ein Bestätigungscode. Es werden Depot und Verrechnungskonto abgefragt.
                - **Scalable Capital:** Anmeldung im Browserfenster von GiroCrab; Depot und Umsätze werden danach übernommen.
                - **Amex / Amazon Visa:** Über das Portal-Fenster anmelden oder Umsätze als CSV/PDF importieren.

                Alle Zugangsdaten bleiben lokal im verschlüsselten Tresor.
                """,
                "en": """
                - **comdirect:** Access via the comdirect interface; confirm credentials and the photoTAN/push approval in the app.
                - **Trade Republic:** Sign in with phone number and PIN, then a confirmation code. Portfolio and settlement account are fetched.
                - **Scalable Capital:** Sign in in GiroCrab's browser window; portfolio and transactions are imported afterwards.
                - **Amex / Amazon Visa:** Sign in via the portal window or import transactions as CSV/PDF.

                All credentials stay local in the encrypted vault.
                """],
            keywords: ["comdirect", "trade republic", "scalable", "amex", "american express", "amazon", "visa", "depot", "paypal"]),
        HelpTopic(
            id: "categories", icon: "tag",
            title: ["de": "Kategorien, Regeln & Suche", "en": "Categories, rules & search"],
            body: [
                "de": """
                **Kategorien** sind hierarchisch (Hauptkategorie › Unterkategorie). Neue legst du über *Ablage › Neue Hauptkategorie …* oder direkt im Kategorie-Dialog an. In der Buchungsliste öffnet **C** die schnelle Kategorieauswahl.

                **Regeln** (*Konten › Regeln …*, ⌥⌘K) ordnen Buchungen automatisch zu. Ein Ausdruck kombiniert Felder und Beträge:

                - `name:REWE` – Name des Gegenübers
                - `purpose:"Bahn AG"` – Verwendungszweck
                - `remote_account:DE89…` – IBAN/Konto des Gegenübers
                - `amount>100` oder `amount<0` – Betragsvergleich (auch `>=`, `<=`, `=`, `!=`)
                - Verknüpfen mit `AND`, `OR`, `NOT` und Klammern; `*` und `?` als Platzhalter, `/Regex/` für reguläre Ausdrücke

                Beispiel: `name:REWE OR purpose:"Bahn AG"`. Mit **R** in der Liste erzeugst du eine Regel direkt aus einer Buchung.

                **Splitbuchungen:** Eine Buchung lässt sich auf mehrere Kategorien aufteilen (z. B. Supermarkt-Einkauf in Lebensmittel und Haushalt). Die Summe der Teile muss dem Betrag entsprechen.

                **Interne Umbuchungen** zwischen eigenen Konten werden erkannt und zählen nicht als Einnahme oder Ausgabe.

                **Suche:** ⌘F fokussiert das Suchfeld; es versteht dieselben Ausdrücke wie die Regeln.
                """,
                "en": """
                **Categories** are hierarchical (main category › subcategory). Create new ones via *File › New main category …* or right in the category dialog. In the booking list, **C** opens the quick category picker.

                **Rules** (*Accounts › Rules …*, ⌥⌘K) assign bookings automatically. An expression combines fields and amounts:

                - `name:REWE` – counterparty name
                - `purpose:"Bahn AG"` – payment reference
                - `remote_account:DE89…` – counterparty IBAN/account
                - `amount>100` or `amount<0` – amount comparison (also `>=`, `<=`, `=`, `!=`)
                - Combine with `AND`, `OR`, `NOT` and parentheses; `*` and `?` as wildcards, `/regex/` for regular expressions

                Example: `name:REWE OR purpose:"Bahn AG"`. Press **R** in the list to create a rule straight from a booking.

                **Split bookings:** A booking can be divided across several categories (e.g. a supermarket trip into groceries and household). The parts must add up to the amount.

                **Internal transfers** between your own accounts are detected and do not count as income or expense.

                **Search:** ⌘F focuses the search field; it understands the same expressions as rules.
                """],
            keywords: ["regel", "rule", "kategorie", "category", "split", "umbuchung", "transfer", "suche", "search", "name:", "purpose:", "iban", "amount", "betrag", "regex"]),
        HelpTopic(
            id: "vault", icon: "lock.shield",
            title: ["de": "Tresor, Datenschutz & iCloud-Sync", "en": "Vault, privacy & iCloud sync"],
            body: [
                "de": """
                **100 % lokal:** Alle Daten liegen in einer verschlüsselten SQLite/SQLCipher-Datenbank auf deinem Gerät. GiroCrab hat keinen eigenen Server und sendet nichts an Dritte; Abfragen gehen nur direkt an deine Bank bzw. den gewählten Dienst.

                **Tresor sperren:** *Tresor sperren* im Menü (⌃⌘L) oder die Schaltfläche in der Symbolleiste. Beim Entsperren wird dein Schlüssel verlangt (Touch ID/Face ID oder Passwort). Auf iPhone/iPad sperrt die App automatisch beim Wechsel in den Hintergrund.

                **iCloud-Sync:** Unter *Einstellungen › Sicherheit › iCloud Sync* legt GiroCrab verschlüsselte Snapshots in iCloud Drive ab. Mac, iPhone und iPad führen die Snapshots zusammen (Merge), ohne dass Klartext in der Cloud liegt. Auf allen Geräten muss derselbe Tresorschlüssel hinterlegt sein.
                """,
                "en": """
                **100% local:** All data lives in an encrypted SQLite/SQLCipher database on your device. GiroCrab has no server of its own and sends nothing to third parties; requests go only to your bank or the service you chose.

                **Locking the vault:** *Lock vault* in the menu (⌃⌘L) or the toolbar button. Unlocking asks for your key (Touch ID/Face ID or password). On iPhone/iPad the app locks automatically when it goes to the background.

                **iCloud sync:** Under *Settings › Security › iCloud Sync* GiroCrab stores encrypted snapshots in iCloud Drive. Mac, iPhone and iPad merge the snapshots without any plain text in the cloud. All devices need the same vault key.
                """],
            keywords: ["sqlcipher", "verschlüsselung", "encryption", "icloud", "sync", "sperren", "lock", "datenschutz", "privacy", "touch id", "face id"]),
    ]
}

/// Durchsuchbare Hilfe & FAQ (macOS-Fenster und iOS-/Einstellungs-Sheet).
struct HelpView: View {
    @State private var query = ""
    private let language = LanguagePreference.runningLanguage

    private var topics: [HelpTopic] {
        HelpCatalog.filter(HelpCatalog.topics, query: query, language: language)
    }
    private var showShortcuts: Bool {
        #if os(macOS)
        let hay = (HelpCatalog.shortcuts.map { "\($0.keys) \($0.de) \($0.en)" } + ["Tastaturkürzel keyboard shortcuts"]).joined(separator: " ")
        return HelpTopic(id: "k", icon: "", title: [:], body: ["de": hay], keywords: []).matches(query, language: "de")
        #else
        false
        #endif
    }

    var body: some View {
        List {
            ForEach(topics) { topic in
                Section {
                    Text(markdown(topic.body(language)))
                        .textSelection(.enabled)
                        .padding(.vertical, 4)
                } header: {
                    Label(topic.title(language), systemImage: topic.icon)
                        .font(.headline)
                        .textCase(nil)
                }
            }
            if showShortcuts {
                Section {
                    ForEach(HelpCatalog.shortcuts, id: \.keys) { s in
                        LabeledContent {
                            Text(verbatim: s.keys).font(.body.monospaced())
                        } label: {
                            Text(verbatim: language == "en" ? s.en : s.de)
                        }
                    }
                } header: {
                    Label(language == "en" ? "Keyboard shortcuts (macOS)" : "Tastaturkürzel (macOS)",
                          systemImage: "keyboard")
                        .font(.headline).textCase(nil)
                }
            }
            if topics.isEmpty && !showShortcuts {
                ContentUnavailableView.search(text: query)
            }
            if query.isEmpty {
                Section("Support") {
                    Link(destination: HelpLinks.website) {
                        Label("Webseite & Dokumentation (girocrab.de)", systemImage: "globe")
                    }
                    Link(destination: HelpLinks.issues) {
                        Label("Fehler melden / Issue erstellen (GitHub)", systemImage: "ladybug")
                    }
                    Link(destination: HelpLinks.discussions) {
                        Label("Community & Diskussionen (GitHub)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "In der Hilfe suchen")
        .navigationTitle("Hilfe & FAQ")
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    private func markdown(_ s: String) -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }
}

/// Sheet-Hülle mit „Fertig“ für Einstellungen (iOS und macOS).
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fertig") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 560)
        #endif
    }
}
