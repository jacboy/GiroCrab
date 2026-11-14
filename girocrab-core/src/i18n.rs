//! Localisation of user-facing core texts (German source, English translation).
//!
//! German is the source language and the default. Every user-facing string is
//! written in German at its call site and routed through [`tr`] (static text)
//! or [`trf`] (text with `{0}`, `{1}` … placeholders). The English text is
//! looked up in [`english`]; a missing entry falls back to German, and a unit
//! test makes sure every `tr`/`trf` literal in the crate has an entry.
//!
//! The Swift app calls [`set_language`] once at start-up with
//! `Locale.preferredLanguages.first`. Tests never touch the process-wide
//! language: they use [`tr_in`] or `with_language` (a thread-local override
//! that only exists in test builds, so no async path can depend on the
//! thread it runs on), so tests asserting German messages stay deterministic
//! while `cargo test` runs them in parallel threads.
//!
//! Built-in account group and starter category names are stored in German in
//! the vault (the code finds groups by name and classifies bookings by the
//! top-level category name). They are translated only on the way out via
//! [`display_name`] / [`display_path`], so user-renamed entries stay as written.

#[cfg(test)]
use std::cell::Cell;
use std::fmt::Display;
use std::sync::atomic::{AtomicU8, Ordering};

/// UI language of the core texts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang {
    De,
    En,
}

impl Lang {
    fn to_u8(self) -> u8 {
        match self {
            Lang::De => 0,
            Lang::En => 1,
        }
    }
    fn from_u8(v: u8) -> Lang {
        if v == 1 {
            Lang::En
        } else {
            Lang::De
        }
    }
}

static LANGUAGE: AtomicU8 = AtomicU8::new(0);

#[cfg(test)]
thread_local! {
    static OVERRIDE: Cell<Option<Lang>> = const { Cell::new(None) };
}

/// Maps a BCP-47 tag ("en-US", "de-DE", "en") to a supported language:
/// any `en*` tag is English, everything else German.
pub fn parse_language(code: &str) -> Lang {
    let code = code.trim().to_ascii_lowercase();
    let primary = code.split(['-', '_']).next().unwrap_or("");
    if primary == "en" {
        Lang::En
    } else {
        Lang::De
    }
}

/// Sets the process-wide language of all core texts (BCP-47 tag, e.g.
/// "en-US" or "de-DE"). Any `en*` tag selects English, everything else German.
#[uniffi::export]
pub fn set_language(code: String) {
    LANGUAGE.store(parse_language(&code).to_u8(), Ordering::Relaxed);
}

/// The language in effect (process-wide; tests may override it per thread).
pub fn current() -> Lang {
    #[cfg(test)]
    if let Some(lang) = OVERRIDE.with(|o| o.get()) {
        return lang;
    }
    Lang::from_u8(LANGUAGE.load(Ordering::Relaxed))
}

/// Runs `f` with `lang` as the language of the current thread only
/// (for tests; the process-wide setting is left untouched).
#[cfg(test)]
pub fn with_language<R>(lang: Lang, f: impl FnOnce() -> R) -> R {
    struct Reset(Option<Lang>);
    impl Drop for Reset {
        fn drop(&mut self) {
            OVERRIDE.with(|o| o.set(self.0));
        }
    }
    let _reset = Reset(OVERRIDE.with(|o| o.replace(Some(lang))));
    f()
}

/// Translates a static German text into the current language.
pub fn tr(de: &'static str) -> &'static str {
    tr_in(current(), de)
}

/// Translates a static German text into `lang` (pure; used by tests).
pub fn tr_in(lang: Lang, de: &'static str) -> &'static str {
    match lang {
        Lang::De => de,
        Lang::En => english(de).unwrap_or(de),
    }
}

/// Translates a German template and fills its `{0}`, `{1}` … placeholders.
pub fn trf(de: &'static str, args: &[&dyn Display]) -> String {
    trf_in(current(), de, args)
}

/// [`trf`] for an explicit language.
pub fn trf_in(lang: Lang, de: &'static str, args: &[&dyn Display]) -> String {
    fill(tr_in(lang, de), args)
}

fn fill(template: &str, args: &[&dyn Display]) -> String {
    let mut out = String::with_capacity(template.len() + 16);
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let idx = after
            .find('}')
            .and_then(|end| after[..end].parse::<usize>().ok().map(|i| (i, end)));
        match idx {
            Some((i, end)) if i < args.len() => {
                out.push_str(&args[i].to_string());
                rest = &after[end + 1..];
            }
            _ => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Display name of a stored account group or category name: built-in German
/// defaults are translated, anything else (user names) is returned as is.
pub fn display_name(stored: &str) -> String {
    display_name_in(current(), stored)
}

pub fn display_name_in(lang: Lang, stored: &str) -> String {
    match lang {
        Lang::De => stored.to_string(),
        Lang::En => default_name_en(stored).unwrap_or(stored).to_string(),
    }
}

/// [`display_name`] for every segment of a "Parent › Child" category path.
pub fn display_path(path: &str) -> String {
    display_path_in(current(), path)
}

pub fn display_path_in(lang: Lang, path: &str) -> String {
    match lang {
        Lang::De => path.to_string(),
        Lang::En => path
            .split(" › ")
            .map(|p| display_name_in(lang, p))
            .collect::<Vec<_>>()
            .join(" › "),
    }
}

/// English names of the built-in account groups (`connectors::group_for`) and
/// the starter categories (`demo.rs`). Keys are the German names stored in
/// the vault.
fn default_name_en(de: &str) -> Option<&'static str> {
    Some(match de {
        // Account groups (sidebar sections).
        "Giro & Tagesgeld" => "Checking & savings",
        "Kreditkarten" => "Credit cards",
        "Depots & ETFs" => "Portfolios & ETFs",
        "Darlehen & Kredite" => "Loans",
        "Importierte Konten" => "Imported accounts",
        // Starter categories.
        "Einnahmen" => "Income",
        "Gehalt" => "Salary",
        "Zinsen & Dividenden" => "Interest & dividends",
        "Erstattungen" => "Refunds",
        "Sonstige Einnahmen" => "Other income",
        "Wohnen & Energie" => "Housing & utilities",
        "Miete" => "Rent",
        "Energie" => "Energy",
        "Internet & Telefon" => "Internet & phone",
        "Haushalt" => "Household",
        "Lebensmittel" => "Food",
        "Supermarkt" => "Supermarket",
        "Bäcker & Metzger" => "Bakery & butcher",
        "Lebensmittelrettung" => "Food rescue",
        "Restaurants & Cafés" => "Restaurants & cafés",
        "Lieferdienste" => "Food delivery",
        "Mobilität" => "Transport",
        "ÖPNV & Bahn" => "Public transport & rail",
        "Tanken" => "Fuel",
        "Fahrrad" => "Bike",
        "Reisen" => "Travel",
        "Einkaufen" => "Shopping",
        "Online-Shopping" => "Online shopping",
        "Elektronik" => "Electronics",
        "Drogerie" => "Drugstore",
        "Freizeit" => "Leisure",
        "Streaming & Musik" => "Streaming & music",
        "Sport & Fitness" => "Sports & fitness",
        "Spiele" => "Games",
        "Versicherungen" => "Insurance",
        "Krankenversicherung" => "Health insurance",
        "Haftpflicht & Hausrat" => "Liability & home insurance",
        "Mitgliedschaften" => "Memberships",
        "Gebühren & Bargeld" => "Fees & cash",
        "Bankgebühren" => "Bank fees",
        "Bargeld" => "Cash",
        "Kredite & Darlehen" => "Loans & credit",
        "Darlehensraten" => "Loan payments",
        "Sparen & Investieren" => "Saving & investing",
        "ETF-Sparpläne" => "ETF savings plans",
        "Krypto" => "Crypto",
        "Aktien" => "Stocks",
        "Saveback & Round up" => "Saveback & round up",
        "Umbuchungen" => "Transfers",
        "Kreditkartenabrechnung" => "Credit card statement",
        "Tagesgeld" => "Savings account",
        "Eigene Konten" => "Own accounts",
        _ => return None,
    })
}

/// English text for a German source string; `None` = no translation.
fn english(de: &str) -> Option<&'static str> {
    Some(match de {
        "Zugangsbezeichnung" => "Connection label",
        "Der Saldo dieses Kontos kommt von der Bank. Ein Startsaldo gilt nur für Konten, deren Saldo GiroCrab aus den Umsätzen berechnet." => "This account's balance comes from the bank. An opening balance only applies to accounts whose balance GiroCrab computes from the bookings.",
        "Ungültiges Datum: {0}" => "Invalid date: {0}",
        "quirion: Unvollständige oder ungültige Portalantwort. Es wurden keine Daten übernommen." => "quirion: Incomplete or invalid portal response. No data was imported.",
        "Bitte bei quirion im Browserfenster anmelden und die Daten abrufen." => "Please sign in to quirion in the browser window and fetch your data.",
        "Bitte bei quirion im Browserfenster abrufen." => "Please fetch your data in the quirion browser window.",
        "quirion: Depotpositionen, Liquiditätskonto, Verrechnungskonto und gebuchte Umsätze. Anmeldung im Browserfenster. Interne Portal-API; Änderungen sind möglich." => "quirion: securities positions, liquidity account, clearing account and booked transactions. Sign in in the browser window. Internal portal API; subject to change.",
        "FNZ Bank / ebase / finvesto: Kontosalden, Fondspositionen, Konto- und Depotumsätze sowie PDF-Postkorb einschließlich Archiv. Anmeldung im Browserfenster mit FNZsecure-Freigabe. Die PIN wird nicht gespeichert." => "FNZ Bank / ebase / finvesto: account balances, fund positions, cash and depot transactions, and PDF mailbox including the archive. Sign in in the browser window and approve with FNZsecure. Your PIN is not stored.",
        "Bitte bei FNZ anmelden und in FNZsecure freigeben." => "Please sign in to FNZ and approve with FNZsecure.",
        "Bitte im FNZ-Browserfenster abrufen." => "Please fetch data in the FNZ browser window.",
        "FNZ: Unvollständige Konten-, Bestands- oder Umsatzdaten. Es wurden keine Daten übernommen." => "FNZ: Incomplete account, position or transaction data. No data has been imported.",
        "FNZ: Unvollständige Portalantwort. Bitte erneut anmelden." => "FNZ: Incomplete portal response. Please sign in again.",
        "FNZ: Ungültige Kontoübersicht." => "FNZ: Invalid account overview.",
        "FNZ: Keine Kontoübersicht erkannt. Bitte erneut anmelden." => "FNZ: No account overview found. Please sign in again.",
        "FNZ: Unvollständige Kontoübersicht." => "FNZ: Incomplete account overview.",
        "FNZ: Bestände sind ausgeblendet oder veraltet. Es wurden keine Salden aktualisiert." => "FNZ: Values are hidden or outdated. No balances have been updated.",
        "FNZ: Unbekannte Kontowährung." => "FNZ: Unknown account currency.",
        "FNZ: Ungültiger Saldo in der Kontoübersicht." => "FNZ: Invalid balance in the account overview.",
        "FNZ: Keine aktuellen Konten oder Depotwerte erkannt." => "FNZ: No current accounts or depot values found.",
        "Keine FNZ-Bankverbindung." => "Not an FNZ connection.",
        "FNZ: Ungültige Dokumentenliste." => "FNZ: Invalid document list.",
        "FNZ: Ungültige Dokumentdaten." => "FNZ: Invalid document metadata.",
        "FNZ: Der Download ist kein PDF." => "FNZ: The download is not a PDF.",
        "FNZ: Zum Dokument gehört ein unbekanntes Konto oder Depot. Bitte zuerst die Salden abrufen." => "FNZ: The document belongs to an unknown account or depot. Please fetch balances first.",
        // ------------------------------------------------------------ error.rs
        "Datenbankfehler: {0}" => "Database error: {0}",
        "Der Tresor konnte nicht entsperrt werden (falscher Schlüssel oder beschädigte Datei)" => {
            "The vault could not be unlocked (wrong key or damaged file)"
        }
        "Nicht gefunden: {0}" => "Not found: {0}",
        "Ungültige Eingabe: {0}" => "Invalid input: {0}",
        "Einstellung fehlt: {0}. Bitte in den Einstellungen eintragen." => {
            "Missing setting: {0}. Please enter it in Settings."
        }
        "Netzwerkfehler: {0}" => "Network error: {0}",
        "Die Bank hat die Anfrage abgelehnt: {0} {1}" => "The bank rejected the request: {0} {1}",
        "Anmeldung fehlgeschlagen: {0}" => "Sign-in failed: {0}",
        "Protokollfehler: {0}" => "Protocol error: {0}",
        "Browser-Anmeldung nötig: {0}" => "Browser sign-in required: {0}",
        "Dieser Abruf ist nicht mehr aktiv" => "This sync is no longer active",
        "Dieser Tresor wurde mit einer neueren GiroCrab-Version gespeichert. Bitte die App aktualisieren." => "This vault was saved by a newer version of GiroCrab. Please update the app.",
        // ------------------------------------------------------------ connectors (catalog, sessions, persist)
        "VR-NetKey oder Alias" => "VR-NetKey or alias",
        "Online-Banking-PIN" => "Online banking PIN",
        "Die BLZ muss aus genau 8 Ziffern bestehen." => "The bank code (BLZ) must be exactly 8 digits.",
        "Die FinTS-URL muss mit https:// beginnen." => "The FinTS URL must start with https://.",
        "FinTS-Bank" => "FinTS bank",
        "Anmeldename / VR-NetKey / Kontonummer" => "Login name / VR-NetKey / account number",
        "Beliebige FinTS-3.0-Bank (PIN/TAN). BLZ und FinTS-URL stehen im Bankzugang." => "Any FinTS 3.0 (PIN/TAN) bank. Bank code and FinTS URL are stored with the login.",
        "Freigabe in der SecureGo-plus-App (Decoupled, TAN-Prozess 4, HKTAN v7). Server: fints1.atruvia.de" => "Approve in the SecureGo plus app (decoupled, TAN process 4, HKTAN v7). Server: fints1.atruvia.de",
        "Anmeldename / Kontonummer" => "Login name / account number",
        "pushTAN-App (Decoupled) oder chipTAN. Server: banking-hs5.s-fints-pt-hs.de" => "pushTAN app (decoupled) or chipTAN. Server: banking-hs5.s-fints-pt-hs.de",
        "comdirect REST-API (OAuth2 + Session-TAN)" => "comdirect REST API (OAuth2 + session TAN)",
        "Zugangsnummer" => "Access number",
        "Session-TAN per photoTAN-Push, photoTAN-Grafik oder mobileTAN." => "Session TAN via photoTAN push, photoTAN image or mobileTAN.",
        "PayPal Transaction Search REST-API" => "PayPal Transaction Search REST API",
        "E-Mail (nur Anzeige)" => "Email (display only)",
        "(nicht nötig – nutzt Ihre REST-App)" => "(not needed – uses your REST app)",
        "OAuth2 Client Credentials; Historie in 31-Tage-Fenstern." => "OAuth2 client credentials; history in 31-day windows.",
        "WebSocket-API + 2FA" => "WebSocket API + 2FA",
        "Telefonnummer (+49…)" => "Phone number (+49…)",
        "4-stellige App-PIN" => "4-digit app PIN",
        "Web-Login mit 4-stelligem Code aus der App/SMS. Inoffizielle Schnittstelle – kann sich jederzeit ändern." => "Web login with a 4-digit code from the app or SMS. Unofficial interface – may change at any time.",
        "Direkt-Login (Web-Session) oder CSV/PDF-Kontoauszug" => "Direct login (web session) or CSV/PDF statement",
        "Direkt-Login (Web-Session)" => "Direct login (web session)",
        "Kontobezeichnung" => "Account name",
        "Bitte im Browser-Fenster bei Amazon anmelden." => "Please sign in to Amazon in the browser window.",
        "Keine Bestellungen erkannt." => "No orders recognised.",
        "Liest Ihre Bestellungen aus dem Amazon-Kundenkonto (amazon.de). Anmeldung im eingebetteten Browser inkl. Captcha/2FA – keine Zugangsdaten werden gespeichert." => "Reads your orders from your Amazon customer account (amazon.de). Sign in inside the embedded browser incl. captcha/2FA – no credentials are stored.",
        "Kartenbezeichnung" => "Card name",
        "(Anmeldung im Browser-Fenster)" => "(sign in via the browser window)",
        "Anmeldung im eingebetteten Browser (Benutzername, Passwort, 2FA wie gewohnt) – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“." => "Sign in via the built-in browser (user name, password, 2FA as usual) – no API keys needed. Optional: your own PSD2/Enable Banking API under “Advanced”.",
        "Herausgeber: Open Bank S.A. (Zinia). Anmeldung im eingebetteten Browser – keine API-Schlüssel nötig. Optional: eigene PSD2-/Enable-Banking-API unter „Erweitert“." => "Issuer: Open Bank S.A. (Zinia). Sign in via the built-in browser – no API keys needed. Optional: your own PSD2/Enable Banking API under “Advanced”.",
        "Für diese Bank werden Überweisungen nicht unterstützt." => "Transfers aren’t supported for this bank.",
        "Der Betrag muss größer als 0 sein." => "The amount must be greater than 0.",
        "Die Empfänger-IBAN ist ungültig." => "The recipient IBAN is invalid.",
        "Die BIC ist ungültig." => "The BIC is invalid.",
        "Der Empfängername fehlt." => "The recipient name is missing.",
        "Zahlung {0}: {1}" => "Payment {0}: {1}",
        "Sammelüberweisungen sind nur für FinTS-Konten möglich." => "Batch transfers are only possible for FinTS accounts.",
        "Sammelüberweisung ({0} Zahlungen)" => "Batch transfer ({0} payments)",
        "Für diese Bank werden Sammelüberweisungen nicht unterstützt." => "Batch transfers are not supported for this bank.",
        "Dieses Konto oder diese Bank erlaubt keine Sammelüberweisungen per FinTS (HKCCM). Bitte in der Banking-App überweisen." => "This account or bank does not allow batch transfers via FinTS (HKCCM). Please transfer in the banking app.",
        "Die Bank erlaubt höchstens {0} Zahlungen pro Sammelüberweisung." => "The bank allows at most {0} payments per batch transfer.",
        "Die Bank bucht Sammelüberweisungen nur als Sammelbuchung." => "The bank books batch transfers only as a single batch booking.",
        "In der Kopfzeile fehlt die Spalte „{0}“." => "The header line has no “{0}” column.",
        "Die Datei enthält keine Zahlungen." => "The file contains no payments.",
        "Zu wenige Spalten (erwartet: Name, IBAN, Betrag, Zweck)." => "Too few columns (expected: name, IBAN, amount, purpose).",
        "Der Name ist länger als 70 Zeichen." => "The name is longer than 70 characters.",
        "Der Betrag ist ungültig oder fehlt." => "The amount is invalid or missing.",
        "Der Verwendungszweck ist länger als 140 Zeichen." => "The purpose is longer than 140 characters.",
        "Die Sammelüberweisung enthält keine Zahlung." => "The batch transfer contains no payment.",
        "Die Summe der Sammelüberweisung ist zu groß." => "The total of the batch transfer is too large.",
        "Der Verwendungszweck darf höchstens 140 Zeichen lang sein." => "The payment reference can be at most 140 characters.",
        "Dieses Konto hat keine Bankverbindung." => "This account has no bank connection.",
        "Überweisungen sind nur für FinTS- und bunq-Konten möglich." => "Transfers are only possible for FinTS and bunq accounts.",
        "Das Konto hat keine IBAN." => "The account has no IBAN.",
        "Bankverbindung {0}" => "bank connection {0}",
        "Konto {0}" => "account {0}",
        // ------------------------------------------------------ user_groups.rs
        "Gruppe {0}" => "group {0}",
        "Ungültige Farbe: {0}" => "Invalid colour: {0}",
        "Kein Symbol angegeben" => "No symbol given",
        "Ohne Gruppe" => "Ungrouped",
        "Nur archivierte Konten können gelöscht werden. Bitte das Konto zuerst archivieren." => "Only archived accounts can be deleted. Please archive the account first.",
        "Eine Gruppe kann nicht in sich selbst oder eine ihrer Untergruppen verschoben werden" => "A group can’t be moved into itself or one of its own subgroups",
        "Alltag" => "Everyday",
        "Sparen & Vorsorge" => "Savings & retirement",
        "Haus" => "Home",
        "Der Gruppenname darf nicht leer sein" => "The group name must not be empty",
        "Es gibt schon eine Gruppe „{0}“" => "A group named “{0}” already exists",
        // ------------------------------------------------------------ connectors/fints
        "Bitte in der Banking-App freigeben" => "Approve in your banking app",
        "TAN eingeben" => "Enter TAN",
        "Dieses Konto oder diese Bank erlaubt keine Echtzeitüberweisungen per FinTS (HKIPZ). Bitte in der Banking-App überweisen." => "This account or bank doesn’t allow instant transfers via FinTS (HKIPZ). Please make the transfer in your banking app.",
        "Dieses Konto oder diese Bank erlaubt keine Terminüberweisungen per FinTS (HKCSE). Bitte in der Banking-App überweisen." => "This account or bank doesn’t allow scheduled transfers via FinTS (HKCSE). Please make the transfer in your banking app.",
        "Echtzeitüberweisungen können nicht terminiert werden." => "Instant transfers cannot be scheduled.",
        "Die Datei ist zu groß (maximal 50 MB)." => "The file is too large (50 MB maximum).",
        "Das Ausführungsdatum ist ungültig (JJJJ-MM-TT)." => "The execution date is invalid (YYYY-MM-DD).",
        "Das Ausführungsdatum muss in der Zukunft liegen." => "The execution date must be in the future.",
        "Echtzeit- und Terminüberweisungen sind nur für FinTS-Konten möglich." => "Instant and scheduled transfers are only possible for FinTS accounts.",
        "Dieses Konto oder diese Bank erlaubt keine SEPA-Überweisungen per FinTS (HKCCS). Bitte in der Banking-App überweisen." => "This account or bank doesn’t allow SEPA transfers via FinTS (HKCCS). Please make the transfer in your banking app.",
        "Für Überweisungen ist ein TAN-Verfahren nötig; es wurde keines gefunden. Bitte zuerst eine Synchronisation mit TAN-Verfahren durchführen." => "Transfers need a TAN method, but none was found. Please sync with a TAN method first.",
        "PIN ist leer" => "PIN is empty",
        "TAN-Verfahren {0}" => "TAN method {0}",
        "{0}: Freigabe ohne Auftragsreferenz" => "{0}: approval without task reference",
        "Die Bank verlangt für {0} eine TAN-Eingabe. Bitte ein Push-/App-Verfahren (z. B. SecureGo plus) verwenden oder „Tage beim ersten Abruf“ auf höchstens 90 setzen." => "The bank requires a TAN for {0}. Use a push/app method (e.g. SecureGo plus) or set “Days on first sync” to 90 or less.",
        "Kontenliste (HKSPA) – {0}" => "Account list (HKSPA) – {0}",
        "Kontoauszug {0}" => "Statement {0}",
        "Konto {0} bei der Bank{1}" => "account {0} at the bank{1}",
        "{0}: Saldo – {1}" => "{0}: balance – {1}",
        "{0}: Depotbestand (HKWPD) – {1}" => "{0}: holdings (HKWPD) – {1}",
        "{0}: Depotbestand (HKWPD) – Wert einzelner Positionen fehlt" => "{0}: holdings (HKWPD) – value of some positions missing",
        "{0}: Umsätze (HKCAZ/camt.052) – {1}" => "{0}: transactions (HKCAZ/camt.052) – {1}",
        "{0}: Umsätze (HKKAZ/MT940) – {1}" => "{0}: transactions (HKKAZ/MT940) – {1}",
        "Mit echtem Konto getestet: Verrechnungs-, Giro- und Tagesgeldkonto sowie Depotbestand; die Bank liefert per FinTS nur die Umsätze der letzten 90 Tage." => "Tested with a real account: settlement, current and savings accounts plus depot holdings; via FinTS the bank only provides the transactions of the last 90 days.",
        "{0}: Die Bank hat nur einen Teil des angeforderten Zeitraums geliefert (Rückmeldung 3997)." => "{0}: the bank delivered only part of the requested period (return code 3997).",
        // ------------------------------------------------------------ connectors/fints transfer codes
        "Die Nachricht enthält Fehler." => "The message contains errors.",
        "Die Bank hat die Nachricht nicht verarbeitet." => "The bank didn’t process the message.",
        "Ein Pflichtfeld der Überweisung fehlt oder ist ungültig." => "A required field of the transfer is missing or invalid.",
        "Der Auftrag wurde abgelehnt (Daten ungültig oder nicht erlaubt)." => "The order was rejected (invalid or not permitted data).",
        "Der Auftrag ist ungültig; bitte IBAN, Betrag und Name prüfen." => "The order is invalid; please check IBAN, amount and name.",
        "Der Betrag überschreitet das Limit des Kontos." => "The amount exceeds the account limit.",
        "Das Konto lässt diese Überweisung nicht zu." => "The account doesn’t allow this transfer.",
        "Das Konto ist für Überweisungen gesperrt." => "The account is blocked for transfers.",
        "PIN oder Zugangsdaten wurden abgelehnt." => "PIN or login details were rejected.",
        "Die TAN ist ungültig oder abgelaufen." => "The TAN is invalid or has expired.",
        "Die Freigabe wurde abgelehnt oder ist abgelaufen." => "The approval was rejected or has expired.",
        "Starke Kundenauthentifizierung ist erforderlich, wurde aber nicht abgeschlossen." => "Strong customer authentication is required but wasn’t completed.",
        "{0} Die Bank hat die Überweisung abgelehnt: {1}{2}" => "{0} The bank rejected the transfer: {1}{2}",
        "{0} {1} Bank: {2}{3}" => "{0} {1} Bank: {2}{3}",
        // ------------------------------------------------------------ connectors/comdirect.rs
        "In der comdirect photoTAN-App freigeben" => "Approve in the comdirect photoTAN app",
        "Öffnen Sie die photoTAN-App und geben Sie die Session-TAN frei." => "Open the photoTAN app and approve the session TAN.",
        "photoTAN-Grafik scannen" => "Scan the photoTAN image",
        "mobileTAN eingeben" => "Enter mobileTAN",
        "Scannen Sie die Grafik mit der photoTAN-App und geben Sie die TAN ein." => "Scan the image with the photoTAN app and enter the TAN.",
        "Eine TAN wurde an {0} gesendet." => "A TAN was sent to {0}.",
        "Ihr Telefon" => "your phone",
        "Vorgemerkt" => "Pending",
        // ------------------------------------------------------------ connectors/scalable.rs
        "OAuth-Geräteanmeldung + GraphQL-API der offiziellen CLI" => "OAuth device login + GraphQL API of the official CLI",
        "(nicht nötig – Anmeldung im Browser)" => "(not needed – sign in in the browser)",
        "Vorher auf scalable.capital unter Profil → Sicherheit → „Agentic Investing“ den CLI-Zugriff einschalten. Die Anmeldung läuft im Browser und muss alle 7 Tage erneuert werden. Nur Lesezugriff." => "First enable CLI access on scalable.capital under Profile → Security → “Agentic Investing”. You sign in in the browser; the login has to be renewed every 7 days. Read-only.",
        "Keine Scalable-Sitzung – bitte anmelden." => "No Scalable session – please sign in.",
        "Scalable-Sitzung abgelaufen ({0}) – bitte erneut anmelden." => "Scalable session expired ({0}) – please sign in again.",
        "Scalable Capital: Ratenlimit erreicht – bitte später erneut abrufen." => "Scalable Capital: rate limit reached – please try again later.",
        "Scalable Capital: Anmeldung konnte nicht gestartet werden ({0}: {1})." => "Scalable Capital: could not start the login ({0}: {1}).",
        "Bei Scalable Capital im Browser anmelden" => "Sign in to Scalable Capital in the browser",
        "Öffnen Sie {0} und bestätigen Sie dort den Code {1}. Danach wartet GiroCrab automatisch auf die Freigabe." => "Open {0} and confirm the code {1} there. GiroCrab then waits for the approval automatically.",
        "Browser-Anmeldung" => "Browser login",
        "Die Browser-Anmeldung ist abgelaufen – bitte erneut starten." => "The browser login expired – please start again.",
        "Die Anmeldung wurde im Browser abgelehnt." => "The login was declined in the browser.",
        "Anmeldung in der Scalable-App freigeben" => "Approve the login in the Scalable app",
        "Scalable Capital hat eine Freigabe-Anfrage an Ihr verknüpftes Gerät gesendet. Bitte dort bestätigen." => "Scalable Capital sent an approval request to your linked device. Please confirm it there.",
        "2FA in der Scalable-App" => "2FA in the Scalable app",
        "Einzahlung" => "Deposit",
        "Auszahlung" => "Withdrawal",
        "Ausschüttung" => "Distribution",
        "Kauf" => "Buy",
        "Verkauf" => "Sell",
        "Gebühr" => "Fee",
        "Steuer" => "Tax",
        "Steuererstattung" => "Tax refund",
        "Tausch" => "Swap",
        "Bonus" => "Bonus",
        "Wiederanlage" => "Reinvestment",
        "Währungstausch" => "Currency switch",
        "Die Freigabe wurde in der Scalable-App abgelehnt." => "The approval was declined in the Scalable app.",
        "Die Freigabe in der Scalable-App ist abgelaufen – bitte erneut anmelden." => "The approval in the Scalable app expired – please sign in again.",
        // ------------------------------------------------------------ connectors/trade_republic.rs
        " – AWS-WAF-Schutz von Trade Republic. Bitte „Im Browser-Fenster anmelden“ verwenden." => " – Trade Republic’s AWS WAF protection. Please use “Sign in with browser”.",
        " – CLIENT_VERSION_OUTDATED: Trade Republic verlangt einen neueren Client. Bitte „Im Browser-Fenster anmelden“ verwenden." => " – CLIENT_VERSION_OUTDATED: Trade Republic requires a newer client. Please use “Sign in with browser”.",
        " – PIN, Code oder Sitzung ungültig." => " – invalid PIN, code or session.",
        " – zu viele Versuche, bitte etwas warten." => " – too many attempts, please wait a moment.",
        "App-Code (oder SMS)" => "App code (or SMS)",
        "Trade Republic schützt die Anmeldung mit AWS WAF. Bitte im Browser-Fenster anmelden – die Sitzung wird danach gespeichert und wiederverwendet." => "Trade Republic protects its login with AWS WAF. Please sign in using the browser window – the session is then saved and reused.",
        "Bitte die 4-stellige Trade-Republic-PIN eingeben (oder „Im Browser-Fenster anmelden“)." => "Please enter your 4-digit Trade Republic PIN (or use “Sign in with browser”).",
        "Die Trade-Republic-Sitzung ist abgelaufen. Bitte die 4-stellige PIN eingeben (oder „Im Browser-Fenster anmelden“)." => "Your Trade Republic session has expired. Please enter your 4-digit PIN (or use “Sign in with browser”).",
        "Die Trade-Republic-Sitzung ist abgelaufen. Bitte im Browser-Fenster neu anmelden – die neue Sitzung wird danach gespeichert." => "Your Trade Republic session has expired. Please sign in again using the browser window – the new session is then saved.",
        "Login (keine processId)" => "login (no processId)",
        "Geben Sie den 4-stelligen Code ein, der in der Trade-Republic-App angezeigt wird. Keine Push-Nachricht erhalten? „Code per SMS“ wählen." => "Enter the 4-digit code shown in the Trade Republic app. No push notification? Choose “Code via SMS”.",
        "Trade Republic benötigt den 4-stelligen Code" => "Trade Republic needs the 4-digit code",
        "SMS-Anforderung" => "SMS request",
        "Der Code wurde per SMS gesendet. Bitte die 4 Ziffern eingeben." => "The code was sent by SMS. Please enter the 4 digits.",
        "Der Code muss aus 4 Ziffern bestehen." => "The code must be 4 digits.",
        "2FA-Bestätigung" => "2FA confirmation",
        "Trade Republic {0}{1} Antwort: {2}" => "Trade Republic {0}{1} Response: {2}",
        "Telefonnummer fehlt oder ist ungültig („{0}“). Bitte z. B. +4915112345678 eintragen." => "Phone number missing or invalid (“{0}”). Please enter e.g. +4915112345678.",
        "AWS WAF hat den Login abgelehnt (HTTP {0}). Bitte im Browser-Fenster anmelden." => "AWS WAF rejected the login (HTTP {0}). Please sign in using the browser window.",
        "Trade Republic hat keine Sitzung (tr_session) gesetzt. HTTP {0}, Antwort: {1}" => "Trade Republic didn’t set a session (tr_session). HTTP {0}, response: {1}",
        "Trade-Republic-Sitzung abgelaufen ({0}). Bitte im Browser-Fenster neu anmelden." => "Trade Republic session expired ({0}). Please sign in again using the browser window.",
        "WebSocket-Verbindung abgelehnt: {0}" => "WebSocket connection refused: {0}",
        "Trade Republic hat „connect 31“ nicht bestätigt (Zeitüberschreitung)." => "Trade Republic didn’t confirm “connect 31” (timeout).",
        "WebSocket wurde vor „connected“ geschlossen – Sitzung abgelaufen?" => "WebSocket closed before “connected” – session expired?",
        "Unerwartete Antwort auf connect: {0}" => "Unexpected response to connect: {0}",
        "Trade Republic hat auf „{0}“ nicht geantwortet." => "Trade Republic didn’t respond to “{0}”.",
        "WebSocket während „{0}“ geschlossen." => "WebSocket closed during “{0}”.",
        "Fehler-Frame: {0}" => "Error frame: {0}",
        // ------------------------------------------------------------ connectors/enable_banking.rs
        "Zustimmung beim Kartenherausgeber erteilen" => "Grant consent at the card issuer",
        "Zustimmung bei der Bank erteilen" => "Grant consent at your bank",
        "Mit echtem Konto getestet: Girokonto, Gemeinschaftskonto und Tagesgeld-Pocket (auch ohne eigene IBAN); Abruf ohne TAN, Zustimmung 180 Tage." => "Tested with a real account: current account, joint account and savings Pocket (also without its own IBAN); syncs without a TAN, consent 180 days.",
        "Das ist eine Sandbox-Anwendung. Für echte Konten auf enablebanking.com eine Anwendung mit „Production“ registrieren." => "This is a sandbox application. For real accounts, register an application with “Production” on enablebanking.com.",
        "Die Anwendung ist noch nicht aktiv. Auf enablebanking.com bei der Anwendung „Activate by linking accounts“ wählen und alle gewünschten Konten verknüpfen." => "The application isn’t active yet. On enablebanking.com, choose “Activate by linking accounts” for the application and link every account you want.",
        "Die Redirect-URL „{0}“ ist in der Anwendung nicht eingetragen. Bitte auf enablebanking.com unter „Allowed redirect URLs“ ergänzen." => "The redirect URL “{0}” isn’t registered in the application. Please add it on enablebanking.com under “Allowed redirect URLs”.",
        "Enable Banking kennt diese Kombination aus Application-ID und Schlüssel nicht. Bitte die .pem-Datei der Anwendung wählen." => "Enable Banking doesn’t recognise this combination of application ID and key. Please choose the application’s .pem file.",
        "Automatischer PSD2-Abruf (Stunden)" => "Automatic PSD2 sync (hours)",
        "Solange GiroCrab läuft, werden PSD2-Bankzugänge (Enable Banking) alle N Stunden ohne TAN abgerufen, solange die Zustimmung gilt. Banken erlauben meist nur 4 Abrufe pro Tag. 0 = aus." => "While GiroCrab is running, PSD2 bank connections (Enable Banking) are synced every N hours without a TAN as long as the consent is valid. Banks usually allow only 4 syncs per day. 0 = off.",
        "PSD2-Zustimmung abgelaufen oder widerrufen – bitte die Verbindung neu verbinden" => "PSD2 consent expired or revoked – please reconnect",
        "Abruflimit der Bank für heute erreicht – bitte später erneut synchronisieren" => "The bank’s daily access limit is reached – please sync again later",
        "Seite öffnen, anmelden und Zugriff erlauben. Danach die Adresse einfügen, auf die der Browser weitergeleitet wurde." => "Open the page, sign in and allow access. Then paste the address the browser was redirected to.",
        "PSD2-Weiterleitung" => "PSD2 redirect",
        "Bitte die Weiterleitungsadresse einfügen" => "Please paste the redirect address",
        "Status stimmt nicht überein – bitte die Zustimmung neu starten" => "State mismatch – please start the consent again",
        "Kein „code“ in der eingefügten Adresse" => "No “code” in the pasted address",
        "Bitte die Adresse einfügen, auf die Sie weitergeleitet wurden" => "Paste the address you were redirected to",
        "ASPSP „{0}“: {1}" => "ASPSP “{0}”: {1}",
        // ------------------------------------------------------------ connectors/demo.rs
        "Demo: Eine Push-Nachricht wurde „gesendet“. Die Freigabe wird nach wenigen Sekunden simuliert." => "Demo: a push notification was “sent”. Approval is simulated after a few seconds.",
        "Demo: beliebigen 4-stelligen Code eingeben." => "Demo: enter any 4-digit code.",
        "App-Code (Demo)" => "App code (demo)",
        "Demo: beliebigen 6-stelligen Code eingeben." => "Demo: enter any 6-digit code.",
        "SMS-TAN (Demo)" => "SMS TAN (demo)",
        // ------------------------------------------------------------ connectors/easybank.rs (catalog)
        "Online-Banking-API (Direkt-Login)" => "Online banking API (direct login)",
        "Benutzername" => "User name",
        "Benutzername und Passwort erforderlich" => "User name and password required",
        "Passwort" => "Password",
        "easybank (ehemals Barclays Deutschland): Kreditkarten und Umsätze der letzten zwei Jahre. Beim ersten Abruf fragt easybank eine SMS-TAN ab, danach erkennt die Bank GiroCrab wieder. Interne Portal-API; Änderungen sind möglich." => "easybank (formerly Barclays Germany): credit cards and transactions of the last two years. On the first sync easybank asks for an SMS TAN; afterwards it recognises GiroCrab. Internal portal API; subject to change.",
        "easybank: Die Anfrage wurde abgelehnt." => "easybank: The request was rejected.",
        "easybank verlangt ein Captcha. Bitte einmal auf banking.easybank.de anmelden und den Abruf danach wiederholen." => "easybank requires a captcha. Please sign in once at banking.easybank.de and then retry.",
        "ohne JSON-Antwort (Sitzung abgelaufen oder Portal geändert)" => "without a JSON response (session expired or portal changed)",
        "Bitte die SMS-TAN eingeben, die easybank an Ihre Mobilnummer gesendet hat." => "Please enter the SMS TAN easybank sent to your mobile number.",
        "Bitte die SMS-TAN eingeben, die easybank an die Mobilnummer mit der Endung {0} gesendet hat." => "Please enter the SMS TAN easybank sent to the mobile number ending in {0}.",
        "easybank verlangt einen zusätzlichen Schritt (z. B. neue AGB oder Passwortwechsel). Bitte einmal auf banking.easybank.de anmelden und den Abruf danach wiederholen." => "easybank requires an additional step (e.g. new terms or a password change). Please sign in once at banking.easybank.de and then retry.",
        "easybank: Anmeldeseite nicht erkannt (Portal geändert?)." => "easybank: login page not recognised (portal changed?).",
        "Bitte die SMS-TAN eingeben." => "Please enter the SMS TAN.",
        "easybank: Die SMS-TAN wurde nicht akzeptiert." => "easybank: The SMS TAN was not accepted.",
        "Der Kontoauszug konnte nicht geladen werden." => "The statement could not be downloaded.",
        "easybank: Der Kontoauszug ist kein PDF." => "easybank: The statement is not a PDF.",
        "easybank: Unvollständige oder ungültige Portalantwort. Es wurden keine Daten übernommen." => "easybank: Incomplete or invalid portal response. No data was imported.",
        "Demo: Es wird keine echte Seite geöffnet. Beliebigen Text einfügen (z. B. https://localhost/cb?code=demo)." => "Demo: no real page is opened. Paste any text (e.g. https://localhost/cb?code=demo).",
        "PSD2-Weiterleitung (Demo)" => "PSD2 redirect (demo)",
        "Demo: Der Code muss 4 Ziffern haben" => "Demo: the code must be 4 digits",
        "Überweisung in der Banking-App freigeben" => "Approve the transfer in your banking app",
        "Demo: {0} an {1} wird nach wenigen Sekunden „freigegeben“." => "Demo: {0} to {1} will be “approved” in a few seconds.",
        // ------------------------------------------------------------ importers/portal_import.rs
        "Keine Umsätze erkannt." => "No transactions found.",
        // ------------------------------------------------------------ importers/moneymoney_import.rs
        "Keine MoneyMoney-Kopfzeile (Datum/Buchungstag und Betrag) gefunden." => "No MoneyMoney header row (date/booking date and amount) found.",
        // ------------------------------------------------------------ importers/moneymoney_db.rs
"Import abgebrochen – es wurde nichts übernommen." => "Import cancelled – nothing was imported.",
                "Falsches Passwort oder keine MoneyMoney-Datenbank." => "Wrong password or not a MoneyMoney database.",
        "MoneyMoney verschlüsselt diese Datenbank mit einem eigenen Schlüssel, weil dort kein Datenbank-Passwort festgelegt ist. Legen Sie in der App MoneyMoney (nicht in GiroCrab) unter MoneyMoney › Einstellungen › Sicherheit eines fest, beenden Sie MoneyMoney und geben Sie es dann im Feld „Datenbank-Passwort“ dieses Dialogs ein." => "MoneyMoney encrypts this database with a key of its own because no database password is set there. Set one in the MoneyMoney app (not in GiroCrab) under MoneyMoney › Settings › Security, quit MoneyMoney and then enter it in this dialog's “Database password” field.",
        "MoneyMoney-Datenbank" => "MoneyMoney database",
        "MoneyMoney ist noch geöffnet und sperrt die Datenbank. Beenden Sie MoneyMoney vollständig und versuchen Sie es erneut." => "MoneyMoney is still open and locks the database. Quit MoneyMoney completely and try again.",
        "Anfangssaldo laut MoneyMoney-Saldenverlauf ({0}) + Umsätze" => {
            "Opening balance from MoneyMoney balance history ({0}) + transactions"
        }
        "Saldo laut MoneyMoney" => "Balance as shown in MoneyMoney",
        "Saldo laut MoneyMoney ({0})" => "Balance as shown in MoneyMoney ({0})",
        "Anfangssaldo des Kontos + Umsätze" => "Account opening balance + transactions",
        "Summe der Umsätze" => "Sum of transactions",
        "Antwort der Bank zu groß (über {0} MB) – abgebrochen." => {
            "Bank response too large (over {0} MB) – aborted."
        }
        // ------------------------------------------------------------ connections.rs
        "Bankzugang {0}" => "bank connection {0}",
        "Keine Sitzungs-Cookies übergeben" => "No session cookies were passed",
        // ------------------------------------------------------------ loans.rs (#36)
        "Bitte einen Namen für das Darlehen angeben." => "Please enter a name for the loan.",
        "Der Name ist zu lang (höchstens {0} Zeichen)." => "The name is too long (at most {0} characters).",
        "Ungültiges Stichtagsdatum." => "Invalid balance date.",
        "Der Stichtag darf nicht in der Zukunft liegen." => "The balance date can't be in the future.",
        "Die Restschuld darf nicht negativ sein." => "The outstanding balance can't be negative.",
        "Der Kreditbetrag muss größer als 0 sein." => "The loan amount must be greater than 0.",
        "Der Zinssatz muss zwischen 0 und 30 % liegen." => "The interest rate must be between 0 and 30 %.",
        "Darlehen {0}" => "loan {0}",
        "Buchungen eines Darlehenskontos lassen sich keinem anderen Darlehen zuordnen." => "Transactions of a loan account can't be assigned to another loan.",
        // ------------------------------------------------------------ assets.rs (#87)
        "Sachwerte" => "Tangible assets",
        "Sachwerte-Konto {0}" => "tangible assets account {0}",
        "Sachwert {0}" => "asset {0}",
        "Ein Verkauf muss nach dem Kaufdatum liegen." => "A sale must be after the purchase date.",
        "Die Anzahl ist größer als der Bestand an diesem Tag." => "That is more than the quantity held on that day.",
        "Bitte einen Namen angeben." => "Please enter a name.",
        "Das Datum darf nicht in der Zukunft liegen." => "The date can't be in the future.",
        "Das Datum liegt vor dem Kaufdatum." => "The date is before the purchase date.",
        "Die Anzahl muss größer als 0 sein." => "The quantity must be greater than 0.",
        "Die Anzahl darf nicht negativ sein." => "The quantity can't be negative.",
        "Der Kaufpreis darf nicht negativ sein." => "The purchase price can't be negative.",
        "Bitte den Wert zum Kaufdatum angeben." => "Please enter the value on the purchase date.",
        "Unbekannte Kursquelle: {0}" => "Unknown price source: {0}",
        "Das Gewicht muss größer als 0 sein." => "The weight must be greater than 0.",
        "Der Feingehalt muss zwischen 0 und 1000 ‰ liegen." => "The fineness must be between 0 and 1000 ‰.",
        "Der Kauf selbst kann nicht entfernt werden." => "The purchase itself can't be removed.",
        "Der Wert darf nicht negativ sein." => "The value can't be negative.",
        "Dieser Sachwert wird über den Kurs bewertet." => "This asset is valued by its market price.",
        "Der Wert zum Kaufdatum kann nicht entfernt werden." => "The value on the purchase date can't be removed.",
        "Der Kurs muss größer als 0 sein." => "The price must be greater than 0.",
        "Kurs-API antwortet mit HTTP {0}" => "The price API answered with HTTP {0}",
        "Unerwartete Antwort der Kurs-API: {0}" => "Unexpected answer from the price API: {0}",
        "Vor dem neuen Kaufdatum liegen noch Bestands- oder Wertänderungen. Bitte diese zuerst entfernen." => "There are still quantity or value changes before the new purchase date. Please remove them first.",
        "Der Sachwert hat eingetragene Werte. Bitte diese zuerst entfernen, bevor er über den Kurs bewertet wird." => "The asset has entered values. Please remove them first before it is valued by its market price.",
        // ------------------------------------------------------------ documents.rs
        "Leere Datei" => "Empty file",
        "Beleg {0}" => "receipt {0}",
        "Buchung {0}" => "transaction {0}",
        "Beleg bereits vorhanden" => "Receipt already exists",
        "Dokument bereits vorhanden" => "Document already exists",
        "Für diese Bank können keine Kontoauszüge abgerufen werden." => "Statements cannot be fetched for this bank.",
        "Diese Bank bietet keine elektronischen Kontoauszüge per FinTS an." => "This bank does not offer electronic statements via FinTS.",
        "Export fehlgeschlagen: {0}" => "Export failed: {0}",
        "GiroCrab-Belege" => "GiroCrab Receipts",
        "ohne-Datum" => "no-date",
        // ------------------------------------------------------------ money.rs
        "Kein Betrag angegeben" => "No amount entered",
        "Kein gültiger Betrag: „{0}“" => "Not a valid amount: “{0}”",
        "Zu viele Nachkommastellen in „{0}“" => "Too many decimal places in “{0}”",
        "Betrag zu groß: „{0}“" => "Amount too large: “{0}”",
        // ------------------------------------------------------------ vault.rs
        "Ungültiger Monat." => "Invalid month.",
        "Das Budget muss größer als 0 sein." => "The budget must be greater than 0.",
        "Kategorie {0}" => "Category {0}",
        "Eine Splitbuchung braucht mindestens zwei Teilbeträge ungleich 0." => {
            "A split booking needs at least two non-zero parts."
        }
        "Die Teilbeträge sind zu groß." => "The split amounts are too large.",
        "Die Teilbeträge ({0} ¢) ergeben nicht den Buchungsbetrag ({1} ¢)." => {
            "The parts ({0} ¢) do not add up to the booking amount ({1} ¢)."
        }
        "Vorlage {0}" => "Template {0}",
        "Name, Empfänger und IBAN der Vorlage dürfen nicht leer sein." => {
            "Template name, recipient and IBAN must not be empty."
        }
        "Der Vorlagenbetrag muss größer als 0 sein." => {
            "The template amount must be greater than 0."
        }
        "Der Kategoriename ist leer." => "The category name is empty.",
        "Eine Kategorie kann nicht in sich selbst verschoben werden." => "A category can’t be moved into itself.",
        "Das Suchmuster ist leer." => "The pattern is empty.",
        "Das Suchmuster ist zu lang." => "The pattern is too long.",
        "Der Suchausdruck ist leer." => "The search expression is empty.",
        "Das Feld „{0}“ wird nicht unterstützt." => "The field “{0}” isn't supported.",
        "{0} (nur für bestimmte Konten)" => "{0} (specific accounts only)",
        "Der Suchausdruck ist unvollständig." => "The search expression is incomplete.",
        "Unerwartete schließende Klammer." => "Unexpected closing parenthesis.",
        "Klammer nicht geschlossen." => "Parenthesis not closed.",
        "Der Suchausdruck ist zu lang (höchstens {0} Zeichen)." => "The search expression is too long (at most {0} characters).",
        "Der Suchausdruck ist zu tief verschachtelt." => "The search expression is nested too deeply.",
        "Anführungszeichen nicht geschlossen." => "Quotation mark not closed.",
        "Regulärer Ausdruck nicht mit / geschlossen." => "Regular expression not closed with /.",
        "Ungültiger regulärer Ausdruck: {0}" => "Invalid regular expression: {0}",
        "Ungültiger Betrag „{0}“" => "Invalid amount “{0}”",
        "Unbekanntes Feld „{0}“" => "Unknown field “{0}”",
        "Nach „{0}:“ fehlt ein Suchbegriff." => "A search term is missing after “{0}:”.",
        "Der Ausdruck endet nach „{0}“." => "The expression ends after “{0}”.",
        "„AND“ steht ohne Begriff davor." => "“AND” has no term before it.",
        "„OR“ steht ohne Begriff davor." => "“OR” has no term before it.",
        "Eigene FinTS-Produktregistrierung" => "Own FinTS product registration",
        "Nur nötig, wenn Sie Ihre eigene Registrierung statt der von GiroCrab verwenden. Kostenlos bei der Deutschen Kreditwirtschaft zu beantragen." => "Only needed if you use your own registration instead of GiroCrab's. Free to apply for at Die Deutsche Kreditwirtschaft.",
        "FinTS-Produktversion" => "FinTS product version",
        "Versionsangabe, die mit HKVVB gesendet wird." => "Version string sent with HKVVB.",
        "Server Volksbank Kassel Göttingen (BLZ 52090000)" => "Server Volksbank Kassel Göttingen (bank code 52090000)",
        "FinTS-PIN/TAN-Adresse laut öffentlicher DK-Institutsliste." => "FinTS PIN/TAN address from the public DK institute list.",
        "Server 1822direkt (BLZ 50050201)" => "Server 1822direkt (bank code 50050201)",
        // ------------------------------------------------------------ SEPA Instant
        "Demo: Wenn Sie die Überweisung trotzdem freigeben, kann das Geld auf einem Konto landen, das nicht dem gewünschten Empfänger gehört." => {
            "Demo: If you approve the transfer anyway, the money may end up in an account that does not belong to the intended recipient."
        }
        "Die Empfängerbank hat kein Ergebnis geliefert." => "The recipient's bank did not return a result.",
        "Demo: Die Empfängerbank ist für Echtzeitüberweisungen gerade nicht erreichbar." => {
            "Demo: The recipient's bank is currently not reachable for instant transfers."
        }
        "Demo: 9800 Dialog abgebrochen." => "Demo: 9800 dialog aborted.",
        "Demo: Verbindung zur Bank unterbrochen." => "Demo: Connection to the bank lost.",
        "Die Bank bietet per FinTS keine Echtzeitüberweisung (HKIPZ) an." => {
            "The bank does not offer instant transfers (HKIPZ) via FinTS."
        }
        "Für dieses Konto ist die Echtzeitüberweisung per FinTS nicht freigeschaltet." => {
            "Instant transfers via FinTS are not enabled for this account."
        }
        "Die Bank erwartet für Echtzeitüberweisungen ein Datenformat, das GiroCrab nicht unterstützt." => {
            "The bank expects a data format for instant transfers that GiroCrab does not support."
        }
        "comdirect Client-ID" => "comdirect client ID",
        "Aus dem comdirect-Entwicklerportal (Persönlicher Bereich › Verwaltung › Entwicklerzugang)." => "From the comdirect developer portal (Persönlicher Bereich › Verwaltung › Entwicklerzugang).",
        "comdirect Client-Secret" => "comdirect client secret",
        "Wird beim Freischalten des API-Zugangs einmalig angezeigt." => "Shown once when API access is activated.",
        "comdirect REST-API" => "comdirect REST API",
        "PayPal Client-ID" => "PayPal client ID",
        "REST-App auf developer.paypal.com mit aktivierter „Transaction Search“ anlegen." => "Create a REST app on developer.paypal.com with “Transaction Search” enabled.",
        "Secret derselben REST-App." => "Secret of the same REST app.",
        "PayPal-Umgebung" => "PayPal environment",
        "live oder sandbox" => "live or sandbox",
        "Enable Banking Application-ID" => "Enable Banking application ID",
        "Bank oder Ländercode ungültig." => "Invalid bank or country code.",
        "Bank per PSD2 (Enable Banking)" => "Bank via PSD2 (Enable Banking)",
        "PSD2 über Enable Banking (eigene Anwendung)" => "PSD2 via Enable Banking (your own application)",
        "Bezeichnung (z. B. Kontoname)" => "Label (e.g. account name)",
        "(Zustimmung im Browser)" => "(consent in the browser)",
        "Banken wie N26, Revolut oder C24 per PSD2. Benötigt eine kostenlose eigene Anwendung auf enablebanking.com (Application-ID, privater Schlüssel, Redirect-URL). Die Zustimmung erteilen Sie im Browser Ihrer Bank." => "Banks such as N26, Revolut or C24 via PSD2. Needs a free application of your own on enablebanking.com (application ID, private key, redirect URL). You give consent in your bank's browser page.",
        "Anwendung auf enablebanking.com registrieren (wird als JWT-„kid“ verwendet)." => "Register an application on enablebanking.com (used as the JWT “kid”).",
        "RSA-Schlüssel der Anwendung; signiert das RS256-JWT." => "The application’s RSA key; signs the RS256 JWT.",
        "Redirect-URL" => "Redirect URL",
        "Muss in Ihrer Enable-Banking-Anwendung freigegeben sein." => "Must be allowed in your Enable Banking application.",
        "ASPSP-Name American Express" => "ASPSP name American Express",
        "Exakter Name aus GET /aspsps." => "Exact name from GET /aspsps.",
        "Die Freigabe wurde bei der Bank abgelehnt ({0})." => "The consent was declined at the bank ({0}).",
        "Die Bank hat die Freigabe mit einem Fehler auf ihrer Seite beendet ({0}). Das liegt nicht an Ihren Angaben – bitte später erneut versuchen, gegebenenfalls mit weniger ausgewählten Konten." => "The bank ended the consent with an error on its side ({0}). It isn't caused by your input – please try again later, if needed with fewer accounts selected.",
        "Die Freigabe ist fehlgeschlagen ({0})." => "The consent failed ({0}).",
        "„{0}“ ist über Enable Banking ({1}) nicht verfügbar. Für diese Bank gibt es in GiroCrab derzeit keinen Abruf." => "“{0}” isn't available through Enable Banking ({1}). GiroCrab can't fetch this bank at the moment.",
        "Die Bank hat die Freigabe erteilt, Enable Banking liefert aber keine Konten. Bei einer Anwendung im eingeschränkten Modus müssen die Konten zuerst auf enablebanking.com mit der Anwendung verknüpft werden („Linked accounts“). Danach die Freigabe erneut starten." => "The bank granted access, but Enable Banking returns no accounts. With an application in restricted mode, the accounts must first be linked to the application on enablebanking.com (“Linked accounts”). Then start the consent again.",
        "Land American Express" => "Country American Express",
        "American Express per Enable Banking abrufen" => "Sync American Express via Enable Banking",
        "Amazon Visa per Enable Banking abrufen" => "Sync Amazon Visa via Enable Banking",
        "1 = PSD2-API statt Web-Login (eigene Enable-Banking-Anwendung nötig). Leer oder 0 = Web-Login." => "1 = PSD2 API instead of the web login (needs your own Enable Banking application). Empty or 0 = web login.",
        "Zweistelliger Ländercode." => "Two-letter country code.",
        "ASPSP-Name Amazon Visa" => "ASPSP name Amazon Visa",
        "Herausgeber in Deutschland: Open Bank S.A. (Marke Zinia). Je nach Listung „Open Bank“ oder „Zinia“ eintragen." => "Issuer in Germany: Open Bank S.A. (brand Zinia). Enter “Open Bank” or “Zinia”, depending on the listing.",
        "Land Amazon Visa" => "Country Amazon Visa",
        "Händler-Logos online laden" => "Load merchant logos online",
        "Händler-Logos laden" => "Load merchant logos",
        "Aus" => "Off",
        "Anbieter für Händler-Logos: off, duckduckgo oder google. Logos werden verschlüsselt zwischengespeichert; übertragen wird nur die Händler-Domain (z. B. lidl.de). Standard: off." => "Merchant logo provider: off, duckduckgo or google. Logos are cached encrypted; only the merchant domain (e.g. lidl.de) is sent. Default: off.",
        "Händler-Logos" => "Merchant logos",
        "Tage beim ersten Abruf" => "Days on first sync",
        "Ältere Umsätze werden nur einmal abgefragt." => "Older transactions are only fetched once.",
        "Allgemein" => "General",
        // ------------------------------------------------------------ vault.rs settings (same in both languages)
        "PayPal Secret" => "PayPal secret",
        "Enable Banking Private Key (PEM)" => "Enable Banking private key (PEM)",
        "FinTS 3.0" => "FinTS 3.0",
        "PayPal" => "PayPal",
        "Enable Banking (PSD2)" => "Enable Banking (PSD2)",
        // ------------------------------------------------------------ merchants.rs (payment method labels, asset classes)
        "Saveback" => "Saveback",
        "Round up" => "Round up",
        "Sparplan" => "Savings plan",
        "Zinsen" => "Interest",
        "Dauerauftrag" => "Standing order",
        "Lastschrift" => "Direct debit",
        "Kartenzahlung" => "Card payment",
        "Entgelt" => "Fee",
        "Kreditkarte" => "Credit card",
        "Gutschrift" => "Credit",
        "Bestellung" => "Order",
        "Erstattung" => "Refund",
        "Überweisung" => "Transfer",
        "Buchung" => "Transaction",
        "Ordner nicht gefunden: {0}" => "Folder not found: {0}",
        "Ohne Konto" => "No account",
        "Bitte mindestens ein Datum angeben (z. B. 15.03.)." => "Please enter at least one date (e.g. 15.03.).",
        "Buchung ohne Gegenpartei kann nicht als wiederkehrend markiert werden." => "A transaction without a counterparty can't be marked as recurring.",
        "ETF" => "ETF",
        "Aktie" => "Stock",
        "Gehalt" => "Salary",
        "Bargeld" => "Cash",
        "Krypto" => "Crypto",
        // ------------------------------------------------------------ bunq
        "bunq Public API (eigener API-Schlüssel)" => "bunq public API (your own API key)",
        "API-Schlüssel" => "API key",
        "API-Schlüssel in der bunq-App unter Profil → Einstellungen → Entwickler → API-Schlüssel erstellen und „Alle IP-Adressen erlauben“ aktivieren. Keine PSD2-Registrierung nötig." => {
            "Create an API key in the bunq app under Profile → Settings → Developers → API keys and enable “Allow all IP addresses”. No PSD2 registration needed."
        }
        "bunq hat den API-Schlüssel oder diese IP-Adresse abgelehnt. Erstellen Sie in der bunq-App einen API-Schlüssel mit „Alle IP-Adressen erlauben“ und tragen Sie ihn neu ein." => {
            "bunq rejected the API key or this IP address. Create an API key with “Allow all IP addresses” in the bunq app and enter it again."
        }
        "Die Antwort von bunq ist nicht korrekt signiert." => "The response from bunq is not correctly signed.",
        "Bitte den bunq-API-Schlüssel eingeben." => "Please enter your bunq API key.",
        "Sparen" => "Savings",
        "Rückbuchung" => "Reversal",
        "Abhebung" => "Withdrawal",
        "Kontoauszug {0} – {1}" => "Statement {0} – {1}",
        "vorgemerkt" => "pending",
        "Originalbetrag {0}" => "Original amount {0}",
        "Überweisung in der bunq-App freigeben" => "Approve the transfer in the bunq app",
        "Freigabe in der bunq-App" => "Approval in the bunq app",
        "bunq hat die Überweisung abgelehnt oder sie wurde abgebrochen." => "bunq rejected the transfer or it was cancelled.",
        "Die Überweisung wurde in der bunq-App bereits freigegeben." => "The transfer was already approved in the bunq app.",
        "bunq zeigt die Überweisung noch als offen." => "bunq still shows the transfer as open.",
        "bunq hat die Stornierung angenommen, der Status ist noch nicht bestätigt." => "bunq accepted the cancellation, but the status is not confirmed yet.",
        "Die Überweisung wurde bereits ausgeführt." => "The transfer has already been executed.",
        "bunq meldet den Status „{0}“." => "bunq reports the status \"{0}\".",
        "Das Quellkonto wurde bei bunq nicht gefunden." => "The source account was not found at bunq.",
        "{0} an {1}: Bitte öffnen Sie die bunq-App und bestätigen Sie die Zahlung." => "{0} to {1}: please open the bunq app and confirm the payment.",
        "Flex-Token" => "Flex token",
        "Flex-Query-ID" => "Flex query ID",
        "Flex Web Service (Token + Flex Query)" => "Flex Web Service (token + Flex Query)",
        "Im IBKR Client Portal unter Performance & Reports → Flex Queries eine Activity Flex Query (XML) mit Kontoinformationen, Offenen Positionen, Cash-Transaktionen und Trades anlegen und unter Flex Web Service Configuration ein Token erzeugen. Nur Lesezugriff." => "In the IBKR Client Portal under Performance & Reports → Flex Queries, create an Activity Flex Query (XML) with account information, open positions, cash transactions and trades, and create a token under Flex Web Service Configuration. Read-only.",
        "Bitte Flex-Token und Flex-Query-ID eingeben." => "Please enter the Flex token and Flex query ID.",
        "Interactive Brokers: unerwartete Antwort (HTTP {0})." => "Interactive Brokers: unexpected response (HTTP {0}).",
        "Interactive Brokers: Antwort ohne Referenzcode." => "Interactive Brokers: response without reference code.",
        "Interactive Brokers: unerwartete Abruf-Adresse." => "Interactive Brokers: unexpected download address.",
        "Interactive Brokers erstellt den Bericht noch. Bitte in einer Minute erneut synchronisieren." => "Interactive Brokers is still generating the report. Please sync again in a minute.",
        "Interactive Brokers: kein Bericht erhalten." => "Interactive Brokers: no report received.",
        "Interactive Brokers lehnt das Flex-Token ab ({0}): {1}" => "Interactive Brokers rejects the Flex token ({0}): {1}",
        "Interactive Brokers: Flex-Query-ID ungültig ({0}): {1}" => "Interactive Brokers: invalid Flex query ID ({0}): {1}",
        "Interactive Brokers meldet {0}: {1}" => "Interactive Brokers reports {0}: {1}",
        "Interactive Brokers: Bericht ist keine Flex-Query-Antwort." => "Interactive Brokers: report is not a Flex Query response.",
        "Interactive Brokers: Der Bericht enthält kein FlexStatement. Bitte in der Flex Query Konten, Offene Positionen und Cash-Transaktionen aktivieren." => "Interactive Brokers: the report contains no FlexStatement. Please enable accounts, open positions and cash transactions in the Flex Query.",
        "bunq" => "bunq",
        "bunq-Umgebung" => "bunq environment",
        "production oder sandbox (Test-API von bunq)." => "production or sandbox (bunq's test API).",
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_german() {
        // The process-wide default is German; tests never change it.
        assert_eq!(Lang::from_u8(LANGUAGE.load(Ordering::Relaxed)), Lang::De);
        assert_eq!(
            tr("Dieser Abruf ist nicht mehr aktiv"),
            "Dieser Abruf ist nicht mehr aktiv"
        );
    }

    #[test]
    fn parses_language_tags() {
        assert_eq!(parse_language("en-US"), Lang::En);
        assert_eq!(parse_language("en"), Lang::En);
        assert_eq!(parse_language("EN_gb"), Lang::En);
        assert_eq!(parse_language("de-DE"), Lang::De);
        assert_eq!(parse_language("fr-FR"), Lang::De);
        assert_eq!(parse_language(""), Lang::De);
        assert_eq!(parse_language("eng"), Lang::De);
    }

    #[test]
    fn thread_override_is_scoped() {
        with_language(Lang::En, || {
            assert_eq!(current(), Lang::En);
            assert_eq!(
                tr("Dieser Abruf ist nicht mehr aktiv"),
                "This sync is no longer active"
            );
        });
        assert_eq!(current(), Lang::De);
    }

    #[test]
    fn templates_fill_placeholders() {
        assert_eq!(
            trf_in(
                Lang::En,
                "Die Bank hat die Anfrage abgelehnt: {0} {1}",
                &[&"9050", &"x"]
            ),
            "The bank rejected the request: 9050 x"
        );
        assert_eq!(
            trf_in(Lang::De, "Netzwerkfehler: {0}", &[&"timeout"]),
            "Netzwerkfehler: timeout"
        );
        // Unknown or out-of-range placeholders and stray braces are kept.
        assert_eq!(fill("a {1} {x} {", &[&1]), "a {1} {x} {");
    }

    #[test]
    fn unknown_text_falls_back_to_german() {
        assert_eq!(tr_in(Lang::En, "Gibt es nicht"), "Gibt es nicht");
    }

    #[test]
    fn default_names_translate() {
        assert_eq!(
            display_name_in(Lang::En, "Giro & Tagesgeld"),
            "Checking & savings"
        );
        assert_eq!(display_name_in(Lang::En, "Lebensmittel"), "Food");
        assert_eq!(
            display_name_in(Lang::En, "Meine Kategorie"),
            "Meine Kategorie"
        );
        assert_eq!(display_name_in(Lang::De, "Kreditkarten"), "Kreditkarten");
        assert_eq!(
            display_path_in(Lang::En, "Lebensmittel › Supermarkt"),
            "Food › Supermarket"
        );
        assert_eq!(
            display_path_in(Lang::En, "Lebensmittel › Wochenmarkt"),
            "Food › Wochenmarkt"
        );
    }

    #[test]
    fn sample_messages_in_english() {
        assert_eq!(tr_in(Lang::En, "TAN eingeben"), "Enter TAN");
        assert_eq!(
            tr_in(Lang::En, "Der Betrag muss größer als 0 sein."),
            "The amount must be greater than 0."
        );
        assert_eq!(
            trf_in(Lang::En, "Eine TAN wurde an {0} gesendet.", &[&"+49 151 …"]),
            "A TAN was sent to +49 151 …."
        );
        assert_eq!(
            trf_in(Lang::De, "Eine TAN wurde an {0} gesendet.", &[&"+49 151 …"]),
            "Eine TAN wurde an +49 151 … gesendet."
        );
        let e = crate::error::CoreError::Bank {
            code: "9050".into(),
            message: "x".into(),
        };
        assert_eq!(
            with_language(Lang::En, || e.to_string()),
            "The bank rejected the request: 9050 x"
        );
        assert_eq!(e.to_string(), "Die Bank hat die Anfrage abgelehnt: 9050 x");
        assert_eq!(
            with_language(Lang::En, || crate::merchants::payment_method(
                "KARTENZAHLUNG",
                "",
                crate::models::AccountKind::Checking,
                -5_00
            )),
            "Card payment"
        );
    }

    #[test]
    fn settings_catalogue_is_translated() {
        for (key, label, help, group, ..) in crate::vault::KNOWN_SETTINGS {
            for de in [label, help, group] {
                assert!(english(de).is_some(), "{key}: no English for {de}");
            }
        }
    }

    /// Every `tr("…")` / `trf("…", …)` literal in the crate needs an English
    /// entry, otherwise English users would silently see German.
    #[test]
    fn every_source_string_has_an_english_translation() {
        let re = regex::Regex::new(r#"\btrf?\(\s*"((?:[^"\\]|\\.)*)""#).unwrap();
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut files = vec![root.clone()];
        let mut missing = Vec::new();
        let mut count = 0;
        while let Some(p) = files.pop() {
            if p.is_dir() {
                for e in std::fs::read_dir(&p).unwrap() {
                    files.push(e.unwrap().path());
                }
                continue;
            }
            if p.extension().and_then(|e| e.to_str()) != Some("rs") || p.ends_with("i18n.rs") {
                continue;
            }
            let src = std::fs::read_to_string(&p).unwrap();
            for c in re.captures_iter(&src) {
                let de = c[1]
                    .replace("\\\"", "\"")
                    .replace("\\n", "\n")
                    .replace("\\\\", "\\");
                count += 1;
                if english(&de).is_none() {
                    missing.push(format!("{}: {de}", p.display()));
                }
            }
        }
        assert!(count > 10, "scanner found only {count} strings");
        assert!(
            missing.is_empty(),
            "missing English:\n{}",
            missing.join("\n")
        );
    }
}
