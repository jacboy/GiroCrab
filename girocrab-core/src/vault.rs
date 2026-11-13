//! The encrypted ledger ("vault"): one SQLCipher database file.
//!
//! Schema (clean-room design, see `SCHEMA` below):
//!   bank_connections  1─n accounts 1─n transactions n─1 categories (tree)
//!   rules             n─1 categories, optional n─1 accounts
//!   settings          key/value, secrets flagged, all inside the encrypted file
//!   account_groups    sidebar grouping by account kind (Giro, Credit cards, ...)
//!   user_groups       user-defined sidebar groups ("Privat", "Geschäft", ...), synced by uuid

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard};

use rusqlite::{params, params_from_iter, Connection, OptionalExtension, ToSql};
use zeroize::Zeroizing;

use crate::error::{CoreError, CoreResult};
use crate::i18n::{display_name, display_path, tr, trf};
use crate::merchants::{classify, clean_purpose, payment_method, FlowKind, MerchantResolver};
use crate::models::*;
use crate::money::parse_cents;
use crate::rules::{RuleInput, RuleSet};

/// Booking between two own accounts: counterparty IBAN is one of ours, or a
/// category segment marks it as transfer (MoneyMoney "Umbuchung", "Geldtransit" …).
fn is_own_transfer(t: &Booking, own_ibans: &std::collections::HashSet<String>) -> bool {
    let iban = crate::connectors::fints::sepa::normalize_iban(&t.counterparty_iban);
    (!iban.is_empty() && own_ibans.contains(&iban))
        || t.category_path.split(" › ").any(|s| {
            matches!(
                s.trim().to_lowercase().as_str(),
                "umbuchung" | "umbuchungen" | "geldtransit" | "transfer" | "transfers"
            )
        })
}

/// WHERE clause "booking `t` belongs to the categories `cat_match`" (e.g. `= ?3`,
/// `IS NULL`), split-aware like `planning::EFFECTIVE_SQL`: an unsplit booking by
/// its own category, a split booking only by the categories of its parts.
fn category_match_sql(cat_match: &str) -> String {
    format!(
        "((t.category_id {cat_match} AND NOT EXISTS (SELECT 1 FROM transaction_splits sp WHERE sp.transaction_id = t.id)) \
         OR EXISTS (SELECT 1 FROM transaction_splits sp WHERE sp.transaction_id = t.id AND sp.category_id {cat_match}))"
    )
}

/// Adds merchant, flow kind, payment method and clean purpose to a booking.
pub(crate) fn enrich(t: &mut Booking) {
    t.merchant = MerchantResolver::resolve(&t.counterparty, &t.purpose);
    t.merchant_name = t.merchant.name.clone();
    t.merchant_domain = Some(t.merchant.domain.clone()).filter(|d| !d.is_empty());
    t.merchant_svg_path = Some(t.merchant.svg_path.clone()).filter(|d| !d.is_empty());
    t.merchant_hex_color = t.merchant.color_hex.clone();
    let top = t
        .category_path
        .split(" › ")
        .next()
        .unwrap_or("")
        .to_string();
    t.flow = classify(
        t.amount_cents,
        &t.counterparty,
        &t.purpose,
        &t.booking_text,
        &t.merchant,
        &top,
        t.account_kind,
    );
    t.payment_method = payment_method(&t.booking_text, &t.purpose, t.account_kind, t.amount_cents);
    t.clean_purpose = clean_purpose(&t.purpose);
    t.recurrence_key = crate::recurring::series_key(t);
}

/// Securities positions of depot accounts (replaced on every sync).
pub(crate) const HOLDINGS_SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS holdings (
    id                   INTEGER PRIMARY KEY,
    account_id           INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    isin                 TEXT    NOT NULL DEFAULT '',
    wkn                  TEXT    NOT NULL DEFAULT '',
    name                 TEXT    NOT NULL DEFAULT '',
    quantity             REAL    NOT NULL DEFAULT 0,
    current_price_cents  INTEGER NOT NULL DEFAULT 0,
    purchase_price_cents INTEGER NOT NULL DEFAULT 0,
    value_cents          INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS holdings_account ON holdings(account_id);
";

/// Indexes for the queries every reload runs (idempotent, also for existing
/// vaults; measured on a vault with ~19 000 bookings):
/// - `tx_date_id`: the booking list is ordered by date, then id – with the
///   old `tx_date` (date only) SQLite sorted every result again.
/// - The sidebar counters ("ohne Kategorie", "neu") per account use
///   `tx_account_category` / `tx_account_checked`; they also cover
///   `deleted_ms` and are defined in `sync_merge::COVERING_INDEXES`.
/// - `tx_salary_marked`: the user-marked salary bookings, looked up on every
///   booking list, without scanning all bookings.
pub(crate) const PERF_INDEXES: &str = "
DROP INDEX IF EXISTS tx_date;
CREATE INDEX IF NOT EXISTS tx_date_id ON transactions(booking_date DESC, id DESC);
CREATE INDEX IF NOT EXISTS tx_salary_marked ON transactions(counterparty_iban) WHERE salary_flag = 1;
";

pub(crate) use crate::schema::SCHEMA_VERSION;

/// Base schema before #206 (`version == 0` branch of the probe-based setup):
/// no sync, group or salary columns. Tests build old vaults from it; new vaults
/// get `schema::BASELINE`.
#[cfg(test)]
pub(crate) const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS bank_connections (
    id              INTEGER PRIMARY KEY,
    connector       TEXT    NOT NULL,              -- ConnectorKind::as_str()
    display_name    TEXT    NOT NULL,
    login_name      TEXT    NOT NULL DEFAULT '',
    bank_code       TEXT    NOT NULL DEFAULT '',
    sf_symbol       TEXT    NOT NULL DEFAULT 'building.columns',
    state_json      TEXT    NOT NULL DEFAULT '{}',  -- connector state (FinTS system id, BPD, PSD2 session ...)
    last_sync_unix  INTEGER,
    created_unix    INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS account_groups (
    id          INTEGER PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    sf_symbol   TEXT    NOT NULL DEFAULT 'folder',
    sort_order  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS accounts (
    id              INTEGER PRIMARY KEY,
    connection_id   INTEGER REFERENCES bank_connections(id) ON DELETE SET NULL,
    group_id        INTEGER NOT NULL REFERENCES account_groups(id),
    external_ref    TEXT    NOT NULL DEFAULT '',   -- IBAN / bank account id / PSD2 uid
    name            TEXT    NOT NULL,
    bank_name       TEXT    NOT NULL DEFAULT '',
    owner           TEXT    NOT NULL DEFAULT '',
    iban            TEXT    NOT NULL DEFAULT '',
    account_number  TEXT    NOT NULL DEFAULT '',
    currency        TEXT    NOT NULL DEFAULT 'EUR',
    kind            TEXT    NOT NULL DEFAULT 'checking',
    balance_cents   INTEGER NOT NULL DEFAULT 0,    -- i64 cents
    balance_date    TEXT    NOT NULL DEFAULT '',
    sf_symbol       TEXT    NOT NULL DEFAULT 'building.columns',
    sort_order      INTEGER NOT NULL DEFAULT 0,
    initial_balance_cents INTEGER,                 -- original amount of a Darlehen (i64 cents)
    access_revoked  INTEGER NOT NULL DEFAULT 0,    -- bank / PSD2 consent no longer grants access
    UNIQUE (connection_id, external_ref)
);

CREATE TABLE IF NOT EXISTS categories (
    id            INTEGER PRIMARY KEY,
    parent_id     INTEGER REFERENCES categories(id) ON DELETE CASCADE,
    name          TEXT    NOT NULL,
    sf_symbol     TEXT    NOT NULL DEFAULT 'tag',
    color_hex     TEXT    NOT NULL DEFAULT '#8E8E93',
    budget_cents  INTEGER,                         -- optional monthly budget, i64 cents
    sort_order    INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX IF NOT EXISTS categories_unique_name ON categories(IFNULL(parent_id, 0), name);

CREATE TABLE IF NOT EXISTS rules (
    id                INTEGER PRIMARY KEY,
    name              TEXT    NOT NULL,
    category_id       INTEGER NOT NULL REFERENCES categories(id) ON DELETE CASCADE,
    field             TEXT    NOT NULL DEFAULT 'any',
    match_kind        TEXT    NOT NULL DEFAULT 'keyword',   -- keyword | regex | expression
    pattern           TEXT    NOT NULL,
    case_sensitive    INTEGER NOT NULL DEFAULT 0,
    min_amount_cents  INTEGER,
    max_amount_cents  INTEGER,
    account_id        INTEGER REFERENCES accounts(id) ON DELETE CASCADE,
    priority          INTEGER NOT NULL DEFAULT 100,
    enabled           INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS transactions (
    id                 INTEGER PRIMARY KEY,
    account_id         INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    external_id        TEXT    NOT NULL,           -- de-duplication key from the bank
    booking_date       TEXT    NOT NULL,           -- YYYY-MM-DD
    value_date         TEXT    NOT NULL DEFAULT '',
    amount_cents       INTEGER NOT NULL,           -- i64 cents, negative = debit
    currency           TEXT    NOT NULL DEFAULT 'EUR',
    counterparty       TEXT    NOT NULL DEFAULT '',
    counterparty_iban  TEXT    NOT NULL DEFAULT '',
    purpose            TEXT    NOT NULL DEFAULT '',
    booking_text       TEXT    NOT NULL DEFAULT '',
    category_id        INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    category_source    TEXT    NOT NULL DEFAULT 'none',   -- none | rule | manual
    rule_id            INTEGER REFERENCES rules(id) ON DELETE SET NULL,
    checked            INTEGER NOT NULL DEFAULT 0,
    imported_unix      INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    note               TEXT    NOT NULL DEFAULT '',        -- user note (MoneyMoney import / detail view)
    import_fp          TEXT    NOT NULL DEFAULT '',        -- MoneyMoney de-duplication fingerprint
    purpose_code       TEXT    NOT NULL DEFAULT '',        -- SEPA purpose code (SALA, PENS, …)
    gvc                TEXT    NOT NULL DEFAULT '',        -- German Geschäftsvorfallcode (153, …)
    salary_flag        INTEGER,                            -- NULL = auto, 1 = salary, 0 = not salary (user)
    UNIQUE (account_id, external_id)
);
CREATE INDEX IF NOT EXISTS tx_account_date ON transactions(account_id, booking_date DESC);
CREATE INDEX IF NOT EXISTS tx_category ON transactions(category_id);
CREATE INDEX IF NOT EXISTS tx_import_fp ON transactions(account_id, import_fp) WHERE import_fp != '';

CREATE TABLE IF NOT EXISTS merchant_logo_cache (
    domain        TEXT PRIMARY KEY,
    image_bytes   BLOB,                            -- PNG/ICO; NULL/empty = nothing found (negative cache)
    updated_at    INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    source        TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS settings (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    is_secret  INTEGER NOT NULL DEFAULT 0
);
"#;

/// Known settings shown in the Settings UI. Nothing is pre-filled. The FinTS
/// product ID here is the user's *own* one; GiroCrab's registration is compiled
/// in separately (see `connectors::fints::product_id`). API applications are
/// always the user's own.
/// (key, label, help, group, is_secret, default)
pub const KNOWN_SETTINGS: &[(&str, &str, &str, &str, bool, &str)] = &[
    ("fints.product_id", "Eigene FinTS-Produktregistrierung", "Nur nötig, wenn Sie Ihre eigene Registrierung statt der von GiroCrab verwenden. Kostenlos bei der Deutschen Kreditwirtschaft zu beantragen.", "FinTS 3.0", true, ""),
    ("fints.product_version", "FinTS-Produktversion", "Versionsangabe, die mit HKVVB gesendet wird.", "FinTS 3.0", false, "0.1"),
    ("fints.url.52090000", "Server Volksbank Kassel Göttingen (BLZ 52090000)", "FinTS-PIN/TAN-Adresse laut öffentlicher DK-Institutsliste.", "FinTS 3.0", false, "https://fints1.atruvia.de/cgi-bin/hbciservlet"),
    ("fints.url.50050201", "Server 1822direkt (BLZ 50050201)", "FinTS-PIN/TAN-Adresse laut öffentlicher DK-Institutsliste.", "FinTS 3.0", false, "https://banking-hs5.s-fints-pt-hs.de/fints30"),
    ("comdirect.client_id", "comdirect Client-ID", "Aus dem comdirect-Entwicklerportal (Persönlicher Bereich › Verwaltung › Entwicklerzugang).", "comdirect REST-API", false, ""),
    ("comdirect.client_secret", "comdirect Client-Secret", "Wird beim Freischalten des API-Zugangs einmalig angezeigt.", "comdirect REST-API", true, ""),
    ("paypal.client_id", "PayPal Client-ID", "REST-App auf developer.paypal.com mit aktivierter „Transaction Search“ anlegen.", "PayPal", false, ""),
    ("paypal.client_secret", "PayPal Secret", "Secret derselben REST-App.", "PayPal", true, ""),
    ("paypal.environment", "PayPal-Umgebung", "live oder sandbox", "PayPal", false, "live"),
    ("bunq.environment", "bunq-Umgebung", "production oder sandbox (Test-API von bunq).", "bunq", false, "production"),
    ("enablebanking.application_id", "Enable Banking Application-ID", "Anwendung auf enablebanking.com registrieren (wird als JWT-„kid“ verwendet).", "Enable Banking (PSD2)", false, ""),
    ("enablebanking.private_key_pem", "Enable Banking Private Key (PEM)", "RSA-Schlüssel der Anwendung; signiert das RS256-JWT.", "Enable Banking (PSD2)", true, ""),
    ("enablebanking.redirect_url", "Redirect-URL", "Muss in Ihrer Enable-Banking-Anwendung freigegeben sein.", "Enable Banking (PSD2)", false, "https://localhost/girocrab/callback"),
    ("enablebanking.aspsp.amex", "ASPSP-Name American Express", "Exakter Name aus GET /aspsps.", "Enable Banking (PSD2)", false, "American Express"),
    ("enablebanking.country.amex", "Land American Express", "Zweistelliger Ländercode.", "Enable Banking (PSD2)", false, "DE"),
    ("enablebanking.aspsp.amazonvisa", "ASPSP-Name Amazon Visa", "Herausgeber in Deutschland: Open Bank S.A. (Marke Zinia). Je nach Listung „Open Bank“ oder „Zinia“ eintragen.", "Enable Banking (PSD2)", false, "Open Bank"),
    ("enablebanking.country.amazonvisa", "Land Amazon Visa", "Zweistelliger Ländercode.", "Enable Banking (PSD2)", false, "DE"),
    // Opt-in per card: the Enable Banking credentials are shared with PSD2
    // banks (C24, N26 …), so having them must not switch the cards away from
    // the web login.
    ("enablebanking.use.amex", "American Express per Enable Banking abrufen", "1 = PSD2-API statt Web-Login (eigene Enable-Banking-Anwendung nötig). Leer oder 0 = Web-Login.", "Enable Banking (PSD2)", false, ""),
    ("enablebanking.use.amazonvisa", "Amazon Visa per Enable Banking abrufen", "1 = PSD2-API statt Web-Login (eigene Enable-Banking-Anwendung nötig). Leer oder 0 = Web-Login.", "Enable Banking (PSD2)", false, ""),
    ("merchants.online_logos", "Händler-Logos online laden", "Anbieter für Händler-Logos: off, duckduckgo oder google. Logos werden verschlüsselt zwischengespeichert; übertragen wird nur die Händler-Domain (z. B. lidl.de). Standard: off.", "Händler-Logos", false, "off"),
    ("sync.psd2_auto_hours", "Automatischer PSD2-Abruf (Stunden)", "Solange GiroCrab läuft, werden PSD2-Bankzugänge (Enable Banking) alle N Stunden ohne TAN abgerufen, solange die Zustimmung gilt. Banken erlauben meist nur 4 Abrufe pro Tag. 0 = aus.", "Allgemein", false, "6"),
    ("sync.days_back", "Tage beim ersten Abruf", "Ältere Umsätze werden nur einmal abgefragt.", "Allgemein", false, "90"),
];

#[derive(uniffi::Object)]
pub struct Vault {
    conn: Mutex<Connection>,
    path: String,
    /// The master key, kept for sync snapshots and peer merges so the app
    /// doesn't ask the keychain again. Wiped on drop.
    key: Mutex<Zeroizing<Vec<u8>>>,
}

impl Vault {
    pub(crate) fn db(&self) -> CoreResult<MutexGuard<'_, Connection>> {
        self.conn.lock().map_err(|_| CoreError::Database {
            message: "vault lock poisoned".into(),
        })
    }

    fn kept_key(&self) -> CoreResult<MutexGuard<'_, Zeroizing<Vec<u8>>>> {
        self.key.lock().map_err(|_| CoreError::Database {
            message: "vault key lock poisoned".into(),
        })
    }

    pub(crate) fn apply_key(conn: &Connection, key: &[u8]) -> CoreResult<()> {
        if key.len() < 16 {
            return Err(CoreError::InvalidInput {
                message: "master key must be at least 16 bytes".into(),
            });
        }
        // Raw key syntax: x'..hex..' -> no PBKDF2 on every open, key comes from Keychain.
        let pragma = Zeroizing::new(format!("PRAGMA key = \"x'{}'\";", hex::encode(key)));
        conn.execute_batch(&pragma)?;
        // Best effort: lock + wipe SQLCipher's in-memory key/page buffers.
        let _ = conn.query_row("PRAGMA cipher_log_level = NONE;", [], |_| Ok(()));
        let _ = conn.query_row("PRAGMA cipher_memory_security = ON;", [], |_| Ok(()));
        Ok(())
    }

    /// True if the file starts with the plaintext SQLite header.
    fn is_plaintext_sqlite(path: &str) -> bool {
        use std::io::Read;
        let mut buf = [0u8; 16];
        std::fs::File::open(path)
            .and_then(|mut f| f.read_exact(&mut buf))
            .map(|_| &buf == b"SQLite format 3\0")
            .unwrap_or(false)
    }

    fn migrate(conn: &mut Connection) -> CoreResult<()> {
        // Fails with NotADatabase if the key is wrong.
        conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })?;
        // A vault from a newer build stays untouched (not even the pragmas below).
        crate::schema::check_not_too_new(conn)?;
        // Connection settings first: neither pragma takes effect inside a transaction.
        conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
        // All pending steps in one transaction (SQLite DDL is transactional): an
        // aborted run leaves the old schema and `user_version`, never half of it.
        crate::schema::migrate(conn)
    }

    /// Fills `initial_balance_cents` from the largest historical absolute
    /// balance, reconstructed backwards from the current balance over the
    /// account's own bookings. Never overwrites an existing value.
    pub(crate) fn derive_initial_balance(conn: &Connection, account_id: i64) -> CoreResult<()> {
        let (balance, existing): (i64, Option<i64>) = conn.query_row(
            "SELECT balance_cents, initial_balance_cents FROM accounts WHERE id = ?1",
            [account_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        if existing.is_some() {
            return Ok(());
        }
        let mut stmt = conn.prepare("SELECT amount_cents FROM transactions WHERE account_id = ?1 AND deleted_ms IS NULL ORDER BY booking_date DESC, id DESC")?;
        let amounts: Vec<i64> = stmt
            .query_map([account_id], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        if amounts.is_empty() {
            return Ok(());
        }
        let mut running = balance;
        let mut max_abs = running.abs();
        for a in amounts {
            running -= a; // balance before this booking
            max_abs = max_abs.max(running.abs());
        }
        if max_abs > 0 {
            conn.execute(
                "UPDATE accounts SET initial_balance_cents = ?1 WHERE id = ?2",
                params![max_abs, account_id],
            )?;
        }
        Ok(())
    }

    pub(crate) fn rule_set(conn: &Connection) -> CoreResult<RuleSet> {
        // Disabled rules never match; skipping them also keeps a switched-off
        // rule with an invalid pattern (e.g. imported) from breaking the set.
        let mut rules = Self::load_rules(conn)?;
        rules.retain(|r| r.enabled);
        RuleSet::new(rules)
    }

    fn load_rules(conn: &Connection) -> CoreResult<Vec<Rule>> {
        let mut stmt = conn.prepare(
            "SELECT r.id, r.name, r.category_id, r.field, r.match_kind, r.pattern, r.case_sensitive,
                    r.min_amount_cents, r.max_amount_cents, r.account_id, r.priority, r.enabled,
                    (SELECT count(*) FROM transactions t WHERE t.rule_id = r.id AND t.deleted_ms IS NULL)
             FROM rules r WHERE r.deleted_ms IS NULL
               AND (r.account_id IS NULL OR EXISTS (SELECT 1 FROM accounts a WHERE a.id = r.account_id AND a.deleted_ms IS NULL))
             ORDER BY r.priority, r.id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(Rule {
                id: r.get(0)?,
                name: r.get(1)?,
                category_id: r.get(2)?,
                field: RuleField::from_str(&r.get::<_, String>(3)?),
                match_kind: match r.get::<_, String>(4)?.as_str() {
                    "regex" => MatchKind::Regex,
                    "expression" => MatchKind::Expression,
                    _ => MatchKind::Keyword,
                },
                pattern: r.get(5)?,
                case_sensitive: r.get::<_, i64>(6)? != 0,
                min_amount_cents: r.get(7)?,
                max_amount_cents: r.get(8)?,
                account_id: r.get(9)?,
                priority: r.get(10)?,
                enabled: r.get::<_, i64>(11)? != 0,
                match_count: r.get::<_, i64>(12)? as u32,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    /// Re-runs rules over transactions that are not manually categorised.
    /// Returns the number of transactions whose category changed.
    /// Bookings of archived accounts are left alone (GiroCrab/GiroCrab#43).
    pub(crate) fn apply_rules_inner(
        conn: &Connection,
        only_uncategorised: bool,
    ) -> CoreResult<u32> {
        let changed = Self::categorise_by_rules(conn, only_uncategorised, None)?;
        // manual loans (#36): link new bookings by expression, refresh balances
        crate::loans::apply_loan_rules(conn)?;
        // opening balances (#212): balance = opening + bookings since
        crate::opening_balance::refresh_all(conn)?;
        Ok(changed)
    }

    /// Runs the rules over the uncategorised bookings in `ids` (a merge lets
    /// rules refill the bookings whose category it cleared).
    pub(crate) fn apply_rules_to(conn: &Connection, ids: &HashSet<i64>) -> CoreResult<u32> {
        Self::categorise_by_rules(conn, true, Some(ids))
    }

    /// `only`: restricts the run to these bookings.
    fn categorise_by_rules(
        conn: &Connection,
        only_uncategorised: bool,
        only: Option<&HashSet<i64>>,
    ) -> CoreResult<u32> {
        let set = Self::rule_set(conn)?;
        let sql = if only_uncategorised {
            "SELECT t.id, t.account_id, t.amount_cents, t.counterparty, t.counterparty_iban, t.purpose, t.booking_text, t.category_id, t.rule_id,
                    t.note, t.currency, IFNULL(a.iban, '')
             FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id WHERE a.archived_unix IS NULL AND a.deleted_ms IS NULL AND t.deleted_ms IS NULL AND t.category_source = 'none'"
        } else {
            "SELECT t.id, t.account_id, t.amount_cents, t.counterparty, t.counterparty_iban, t.purpose, t.booking_text, t.category_id, t.rule_id,
                    t.note, t.currency, IFNULL(a.iban, '')
             FROM transactions t LEFT JOIN accounts a ON a.id = t.account_id WHERE a.archived_unix IS NULL AND a.deleted_ms IS NULL AND t.deleted_ms IS NULL AND t.category_source != 'manual'"
        };
        let mut stmt = conn.prepare(sql)?;
        // (note, currency, own account IBAN) ride along for search expressions
        #[allow(clippy::type_complexity)]
        let rows: Vec<(
            (
                i64,
                i64,
                i64,
                String,
                String,
                String,
                String,
                Option<i64>,
                Option<i64>,
            ),
            (String, String, String),
        )> = stmt
            .query_map([], |r| {
                Ok((
                    (
                        r.get(0)?,
                        r.get(1)?,
                        r.get(2)?,
                        r.get(3)?,
                        r.get(4)?,
                        r.get(5)?,
                        r.get(6)?,
                        r.get(7)?,
                        r.get(8)?,
                    ),
                    (r.get(9)?, r.get(10)?, r.get(11)?),
                ))
            })?
            .collect::<Result<_, _>>()?;
        let rows = rows
            .into_iter()
            .filter(|r| only.is_none_or(|ids| ids.contains(&r.0 .0)));
        let mut changed = 0u32;
        let mut upd_rule = conn.prepare("UPDATE transactions SET category_id = ?1, rule_id = ?2, category_source = 'rule' WHERE id = ?3")?;
        let mut upd_none = conn.prepare("UPDATE transactions SET category_id = NULL, rule_id = NULL, category_source = 'none' WHERE id = ?1")?;
        for (
            (id, account_id, amount, cp, iban, purpose, bt, cat, rule),
            (note, currency, own_iban),
        ) in rows
        {
            let input = RuleInput {
                account_id,
                amount_cents: amount,
                counterparty: &cp,
                counterparty_iban: &iban,
                purpose: &purpose,
                booking_text: &bt,
                note: &note,
                currency: &currency,
                account_iban: &own_iban,
            };
            match set.categorise(&input) {
                Some((rule_id, cat_id)) => {
                    if cat != Some(cat_id) || rule != Some(rule_id) {
                        upd_rule.execute(params![cat_id, rule_id, id])?;
                        changed += 1;
                    }
                }
                None => {
                    if rule.is_some() {
                        upd_none.execute(params![id])?;
                        changed += 1;
                    }
                }
            }
        }
        Ok(changed)
    }

    pub(crate) fn setting_inner(conn: &Connection, key: &str) -> CoreResult<Option<String>> {
        let stored: Option<String> = conn
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()?;
        let stored = stored.filter(|v| !v.is_empty());
        if stored.is_some() {
            return Ok(stored);
        }
        Ok(KNOWN_SETTINGS
            .iter()
            .find(|s| s.0 == key)
            .map(|s| s.5.to_string())
            .filter(|v| !v.is_empty()))
    }

    fn category_rows(
        conn: &Connection,
    ) -> CoreResult<Vec<(i64, Option<i64>, String, String, String, i32, Option<i64>)>> {
        let mut stmt = conn.prepare("SELECT id, parent_id, name, sf_symbol, color_hex, sort_order, budget_cents FROM categories WHERE deleted_ms IS NULL")?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn category_paths(
        conn: &Connection,
    ) -> CoreResult<HashMap<i64, (String, String, String, String)>> {
        // id -> (name, path, color, symbol)
        let rows = Self::category_rows(conn)?;
        let by_id: HashMap<i64, &(i64, Option<i64>, String, String, String, i32, Option<i64>)> =
            rows.iter().map(|r| (r.0, r)).collect();
        let mut out = HashMap::new();
        for r in &rows {
            let mut parts = vec![r.2.clone()];
            let mut cur = r.1;
            let mut guard = 0;
            while let Some(pid) = cur {
                guard += 1;
                if guard > 32 {
                    break;
                }
                if let Some(p) = by_id.get(&pid) {
                    parts.push(p.2.clone());
                    cur = p.1;
                } else {
                    break;
                }
            }
            parts.reverse();
            out.insert(
                r.0,
                (r.2.clone(), parts.join(" › "), r.4.clone(), r.3.clone()),
            );
        }
        Ok(out)
    }

    pub(crate) fn ensure_group(
        conn: &Connection,
        name: &str,
        symbol: &str,
        order: i32,
    ) -> CoreResult<i64> {
        if let Some(id) = conn
            .query_row(
                "SELECT id FROM account_groups WHERE name = ?1",
                [name],
                |r| r.get(0),
            )
            .optional()?
        {
            return Ok(id);
        }
        conn.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES (?1, ?2, ?3)",
            params![name, symbol, order],
        )?;
        Ok(conn.last_insert_rowid())
    }

    /// Adds a bank login or returns the existing one with the same provider and
    /// login (`(id, created)`).
    pub(crate) fn add_bank_connection_inner(
        conn: &Connection,
        connector: ConnectorKind,
        display_name: String,
        login_name: String,
    ) -> CoreResult<(i64, bool)> {
        Self::add_bank_connection_keyed(
            conn,
            connector,
            connector.as_str(),
            None,
            display_name,
            login_name,
        )
    }

    /// Like `add_bank_connection_inner`, with an explicit connector key
    /// (`fints:<blz>` for generic FinTS banks) and bank code.
    pub(crate) fn add_bank_connection_keyed(
        conn: &Connection,
        connector: ConnectorKind,
        key: &str,
        bank_code: Option<&str>,
        display_name: String,
        login_name: String,
    ) -> CoreResult<(i64, bool)> {
        let info = crate::connectors::descriptor(connector);
        let login_name = crate::connections::normalize_login(connector, &login_name);
        // Same provider + same login: update instead of creating a duplicate.
        // A live match wins over a deleted one; a deleted one is revived.
        let existing: Vec<(i64, String, bool)> = {
            let mut st = conn.prepare(
                // includes soft-deleted rows
                "SELECT id, login_name, deleted_ms IS NOT NULL FROM bank_connections
                 WHERE connector = ?1 ORDER BY deleted_ms IS NOT NULL, id",
            )?;
            let r = st
                .query_map([key], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            r
        };
        if let Some((id, _, deleted)) = existing.iter().find(|(_, l, _)| {
            !login_name.is_empty()
                && crate::connections::normalize_login(connector, l)
                    .eq_ignore_ascii_case(&login_name)
        }) {
            if !display_name.trim().is_empty() {
                conn.execute(
                    "UPDATE bank_connections SET display_name = ?1 WHERE id = ?2",
                    params![display_name.trim(), id],
                )?;
            }
            if *deleted {
                crate::sync_merge::revive_connection(conn, *id)?;
                return Ok((*id, true));
            }
            return Ok((*id, false));
        }
        conn.execute(
            "INSERT INTO bank_connections(connector, display_name, login_name, bank_code, sf_symbol, created_ms) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                key,
                if display_name.trim().is_empty() { info.name.clone() } else { display_name },
                login_name,
                bank_code.map(str::to_string).unwrap_or(info.bank_code),
                info.sf_symbol,
                crate::user_groups::now_ms()
            ],
        )?;
        Ok((conn.last_insert_rowid(), true))
    }

    pub fn path(&self) -> &str {
        &self.path
    }
}

impl Vault {
    // includes soft-deleted rows: the merge reads and matches every row of
    // both vaults, deleted ones too
    /// `legacy`: the other vault was written by a v7 build (no uuids).
    fn merge_attached(conn: &Connection, legacy: bool) -> CoreResult<MergeStats> {
        let mut st = MergeStats::default();
        let tx = conn.unchecked_transaction()?;

        // account groups (by name)
        let mut group_map: HashMap<i64, i64> = HashMap::new();
        {
            let rows: Vec<(i64, String, String, i64)> = tx
                .prepare("SELECT id, name, sf_symbol, sort_order FROM other.account_groups")?
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
                .collect::<Result<_, _>>()?;
            for (oid, name, sym, ord) in rows {
                tx.execute(
                    "INSERT OR IGNORE INTO account_groups(name, sf_symbol, sort_order) VALUES (?1,?2,?3)",
                    params![name, sym, ord],
                )?;
                let id: i64 = tx.query_row(
                    "SELECT id FROM account_groups WHERE name = ?1",
                    [&name],
                    |r| r.get(0),
                )?;
                group_map.insert(oid, id);
            }
        }

        // bank connections (by sync key) and accounts (by connection +
        // external_ref): newest creation or deletion wins, deletions cascade
        let conn_map = crate::sync_merge::merge_connections(&tx)?;
        let (acc_map, acc_inserted) =
            crate::sync_merge::merge_accounts(&tx, &conn_map, &group_map, &mut st)?;
        // user groups, account placements and names (newest edit wins)
        st.groups_updated = crate::user_groups::merge_attached(&tx, &acc_map, &acc_inserted)?;

        // categories and rules (newest edit wins, deletions stay deleted)
        let cat_map = crate::sync_merge::merge_categories(&tx, legacy, &mut st)?;
        let rule_map = crate::sync_merge::merge_rules(&tx, &cat_map, &acc_map, legacy, &mut st)?;
        // bookings only point at live categories and rules
        let cat_map = crate::sync_merge::live_targets(&tx, "categories", &cat_map)?;
        let rule_map = crate::sync_merge::live_targets(&tx, "rules", &rule_map)?;

        // bookings and splits (newest edit per field wins, deletions stay)
        crate::sync_merge::merge_bookings(&tx, &acc_map, &cat_map, &rule_map, &mut st)?;
        crate::loans::merge_attached(&tx, &acc_map)?;
        crate::opening_balance::merge_attached(&tx, &acc_map)?;
        tx.commit()?;
        Ok(st)
    }
}

/// Result of [`Vault::merge_other_vault`].
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct MergeStats {
    pub accounts_added: u32,
    pub categories_added: u32,
    pub rules_added: u32,
    pub bookings_added: u32,
    pub bookings_updated: u32,
    /// User groups and account placements taken over from the other vault.
    pub groups_updated: u32,
    /// Rows this merge changed in the vault (part of [`Vault::change_count`]),
    /// so the app can tell its own changes from merged ones.
    pub changes: u64,
}

#[uniffi::export]
impl Vault {
    /// Opens (or creates) the encrypted vault at `path` with the raw 32-byte
    /// master key. The key bytes are wiped from memory after use.
    #[uniffi::constructor]
    pub fn open(path: String, key: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let key = Zeroizing::new(key);
        // Default (SQLCipher 4 settings) first; if the key check fails, retry with
        // explicit compatibility modes for vaults written by older SQLCipher builds.
        // The cipher_compatibility pragma must be issued before the key.
        let mut tried: Vec<&str> = Vec::new();
        let mut opened: Option<Connection> = None;
        let mut first_err: Option<CoreError> = None;
        for compat in [None, Some(4u8), Some(3u8)] {
            let mut conn = Connection::open(&path)?;
            Self::apply_key(&conn, &key)?;
            if let Some(c) = compat {
                let _ = conn.query_row(&format!("PRAGMA cipher_compatibility = {c};"), [], |_| {
                    Ok(())
                });
            }
            match Self::migrate(&mut conn) {
                Ok(()) => {
                    if compat.is_some() {
                        tried.push("ok");
                        eprintln!("vault: opened with cipher_compatibility={compat:?}");
                    }
                    opened = Some(conn);
                    break;
                }
                Err(e) if matches!(e, CoreError::WrongKey) => {
                    tried.push(match compat {
                        None => "default",
                        Some(4) => "compat4",
                        _ => "compat3",
                    });
                    first_err.get_or_insert(e);
                }
                // Any other error is real (not a key/format mismatch): report as is.
                Err(e) => return Err(e),
            }
        }
        let Some(conn) = opened else {
            if Self::is_plaintext_sqlite(&path) {
                return Err(CoreError::InvalidInput {
                    message: "Die Tresordatei ist unverschlüsselt (Klartext-SQLite) und passt nicht zum Schlüssel. Sie wurde nicht verändert.".into(),
                });
            }
            let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            let wal = std::fs::metadata(format!("{path}-wal"))
                .map(|m| m.len())
                .unwrap_or(0);
            let name = std::path::Path::new(&path)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            crate::depot_debug::log(&format!(
                "vault open failed: HMAC check on page 1 failed for all modes tried: {} (file={name} size={size} wal_size={wal} key_len={})",
                tried.join(", "),
                key.len()
            ));
            return Err(first_err.unwrap_or(CoreError::WrongKey));
        };
        // categories/rules without a sync key (rows written outside the app's own
        // paths); used to happen as part of the per-open schema probes
        let _ = crate::sync_merge::fill_missing_uuids(&conn);
        // merge duplicate bank logins left by older versions (keeps bookings)
        let _ = crate::connections::deduplicate(&conn);
        // repair "MÃ¼ller" -> "Müller" stored by older versions
        let _ = crate::text::repair_stored_text(&conn);
        // one-time purge of favicons that don't belong to a known brand
        let _ = crate::insights::purge_untrusted_logos(&conn);
        Ok(Arc::new(Vault {
            conn: Mutex::new(conn),
            path,
            key: Mutex::new(key),
        }))
    }

    /// Changes the master key (SQLCipher `PRAGMA rekey`).
    pub fn rekey(&self, new_key: Vec<u8>) -> Result<(), CoreError> {
        let key = Zeroizing::new(new_key);
        if key.len() < 16 {
            return Err(CoreError::InvalidInput {
                message: "master key must be at least 16 bytes".into(),
            });
        }
        let pragma = Zeroizing::new(format!("PRAGMA rekey = \"x'{}'\";", hex::encode(&*key)));
        self.db()?.execute_batch(&pragma)?;
        *self.kept_key()? = key;
        Ok(())
    }

    /// Merges another device's sync snapshot using this vault's own key
    /// (see [`merge_other_vault`](Self::merge_other_vault)).
    pub fn merge_peer_snapshot(&self, other_path: String) -> Result<MergeStats, CoreError> {
        let key = self.kept_key()?.to_vec();
        self.merge_other_vault(other_path, key)
    }

    /// Writes a consistent, encrypted copy of this vault to `dest_path`
    /// (replacing it), for the sync folder. Runs under the connection lock,
    /// so concurrent writes never end up half in the copy.
    pub fn write_snapshot(&self, dest_path: String) -> Result<(), CoreError> {
        let raw_key = Zeroizing::new(format!("x'{}'", hex::encode(&**self.kept_key()?)));
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let p = format!("{dest_path}{suffix}");
            if std::path::Path::new(&p).exists() {
                std::fs::remove_file(&p).map_err(|e| CoreError::Database {
                    message: format!("{p}: {e}"),
                })?;
            }
        }
        let conn = self.db()?;
        conn.execute(
            "ATTACH DATABASE ?1 AS snap KEY ?2",
            params![dest_path, &*raw_key],
        )?;
        let res = conn
            .query_row("SELECT sqlcipher_export('snap')", [], |_| Ok(()))
            .and_then(|_| {
                conn.execute_batch(&format!("PRAGMA snap.user_version = {SCHEMA_VERSION}"))
            });
        let _ = conn.execute_batch("DETACH DATABASE snap");
        res?;
        Ok(())
    }

    /// Number of rows changed through this vault since it was opened; the
    /// app compares it to notice local changes worth syncing.
    pub fn change_count(&self) -> u64 {
        self.db().map(|c| c.total_changes()).unwrap_or(0)
    }

    /// Merges another vault file (e.g. a copy synced via iCloud) into this one.
    /// Categories and rules: newest edit wins, deletions stay deleted, same
    /// ones created on both sides are combined. Missing connections, accounts
    /// and bookings are added; existing bookings (matched by account +
    /// external id, else import fingerprint) take the newest edit per field
    /// (category, note, checked, text, splits) and stay deleted once deleted.
    pub fn merge_other_vault(
        &self,
        other_path: String,
        key: Vec<u8>,
    ) -> Result<MergeStats, CoreError> {
        let key = Zeroizing::new(key);
        if other_path == self.path {
            return Err(CoreError::InvalidInput {
                message: "cannot merge a vault into itself".into(),
            });
        }
        // Validate key and bring the other file up to the current schema;
        // a file from a v7 build has no uuids before that.
        let legacy = {
            let mut o = Connection::open(&other_path)?;
            Self::apply_key(&o, &key)?;
            let has_uuid: bool = o
                .query_row(
                    "SELECT count(*) > 0 FROM pragma_table_info('categories') WHERE name = 'uuid'",
                    [],
                    |r| r.get(0),
                )
                .unwrap_or(true);
            Self::migrate(&mut o)?;
            crate::sync_merge::fill_missing_uuids(&o)?;
            !has_uuid
        };
        let conn = self.db()?;
        let before = conn.total_changes();
        let raw_key = Zeroizing::new(format!("x'{}'", hex::encode(&*key)));
        conn.execute(
            "ATTACH DATABASE ?1 AS other KEY ?2",
            params![other_path, &*raw_key],
        )?;
        let res = Self::merge_attached(&conn, legacy).map(|mut st| {
            st.changes = conn.total_changes() - before;
            st
        });
        let detach_res = conn.execute_batch("DETACH DATABASE other");
        // Fold WAL frames into the main file so a plain file copy is complete.
        let _ = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
        let stats = res?;
        detach_res?;
        Ok(stats)
    }

    /// Flushes the WAL into the main vault file (`wal_checkpoint(TRUNCATE)`),
    /// so copying the file (e.g. to iCloud) never misses committed frames.
    pub fn checkpoint(&self) -> Result<(), CoreError> {
        let conn = self.db()?;
        conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
        Ok(())
    }

    pub fn file_path(&self) -> String {
        self.path.clone()
    }

    pub fn is_empty(&self) -> Result<bool, CoreError> {
        let db = self.db()?;
        let n: i64 = db.query_row(
            "SELECT (SELECT count(*) FROM accounts WHERE deleted_ms IS NULL)
                  + (SELECT count(*) FROM categories WHERE deleted_ms IS NULL)",
            [],
            |r| r.get(0),
        )?;
        Ok(n == 0)
    }

    // ---------------------------------------------------------------- bank connections

    pub fn list_bank_connections(&self) -> Result<Vec<BankConnection>, CoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare(
            "SELECT id, connector, display_name, login_name, bank_code, sf_symbol, last_sync_unix,
                    EXISTS (SELECT 1 FROM accounts a WHERE a.connection_id = bank_connections.id AND a.deleted_ms IS NULL)
                      AND NOT EXISTS (SELECT 1 FROM accounts a WHERE a.connection_id = bank_connections.id AND a.deleted_ms IS NULL AND a.archived_unix IS NULL)
             FROM bank_connections WHERE deleted_ms IS NULL ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| {
            let kind: String = r.get(1)?;
            Ok((
                kind,
                BankConnection {
                    id: r.get(0)?,
                    connector: ConnectorKind::VolksbankKasselGoettingen,
                    display_name: r.get(2)?,
                    login_name: r.get(3)?,
                    bank_code: r.get(4)?,
                    sf_symbol: r.get(5)?,
                    last_sync_unix: r.get(6)?,
                    all_accounts_archived: r.get(7)?,
                },
            ))
        })?;
        let mut out = vec![];
        for row in rows {
            let (kind, mut c) = row?;
            if let Some(k) = ConnectorKind::from_str(&kind) {
                c.connector = k;
                out.push(c);
            }
        }
        Ok(out)
    }

    /// Connector key of a bank login (`fints:<BLZ>`,
    /// `enablebanking:<country>:<bank>`, `comdirect`, …) – what the banking
    /// policy's connector IDs are matched against.
    pub fn connection_key(&self, connection_id: i64) -> Result<String, CoreError> {
        let db = self.db()?;
        db.query_row(
            "SELECT connector FROM bank_connections WHERE id = ?1",
            [connection_id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or_else(|| CoreError::NotFound {
            what: trf("Bankverbindung {0}", &[&connection_id]),
        })
    }

    /// Adds a bank login. Credentials (PIN/password) are *not* stored here;
    /// they are passed to `begin_sync` each time.
    pub fn add_bank_connection(
        &self,
        connector: ConnectorKind,
        display_name: String,
        login_name: String,
    ) -> Result<i64, CoreError> {
        if !crate::demo::is_magic_demo_login(&login_name) {
            crate::banking_gate::check_connector(connector.as_str())?;
        }
        let db = self.db()?;
        Ok(Self::add_bank_connection_inner(&db, connector, display_name, login_name)?.0)
    }

    /// Adds a login at any FinTS 3.0 PIN/TAN bank and stores the bank's URL
    /// (`fints.url.<blz>`). `blz` must be 8 digits, `url` an https URL.
    /// `tan_medium` is optional (stored as `fints.tan_medium.<connection id>`).
    pub fn add_fints_connection(
        &self,
        blz: String,
        url: String,
        display_name: String,
        login_name: String,
        tan_medium: String,
    ) -> Result<i64, CoreError> {
        let blz = blz.trim().to_string();
        let url = url.trim().to_string();
        if ConnectorKind::fints_blz(&ConnectorKind::fints_key(&blz)).is_none() {
            return Err(CoreError::InvalidInput {
                message: tr("Die BLZ muss aus genau 8 Ziffern bestehen.").into(),
            });
        }
        if !crate::connectors::fints_presets::is_valid_fints_url(&url) {
            return Err(CoreError::InvalidInput {
                message: tr("Die FinTS-URL muss mit https:// beginnen.").into(),
            });
        }
        let key = ConnectorKind::fints_key(&blz);
        if !crate::demo::is_magic_demo_login(&login_name) {
            crate::banking_gate::check_connector(&key)?;
        }
        let db = self.db()?;
        let (id, _) = Self::add_bank_connection_keyed(
            &db,
            ConnectorKind::FinTsGeneric,
            &key,
            Some(&blz),
            display_name,
            login_name,
        )?;
        db.execute(
            "INSERT INTO settings(key, value, is_secret) VALUES (?1, ?2, 0)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![format!("fints.url.{blz}"), url],
        )?;
        // Optional TAN medium name (HKTAN), e.g. Postbank BestSign "SO:Gerät".
        let tan_medium = tan_medium.trim();
        if !tan_medium.is_empty() {
            db.execute(
                "INSERT INTO settings(key, value, is_secret) VALUES (?1, ?2, 0)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![format!("fints.tan_medium.{id}"), tan_medium],
            )?;
        }
        Ok(id)
    }

    /// Adds a login at a bank reached through Enable Banking (PSD2). `aspsp`
    /// is the Enable Banking bank name, `country` its ISO alpha-2 code.
    /// `login_name` is only a label (defaults to the bank name).
    pub fn add_enable_banking_connection(
        &self,
        aspsp: String,
        country: String,
        display_name: String,
        login_name: String,
    ) -> Result<i64, CoreError> {
        let aspsp = aspsp.trim().to_string();
        let country = country.trim().to_uppercase();
        let key = ConnectorKind::enable_banking_key(&country, &aspsp);
        if aspsp.is_empty() || ConnectorKind::enable_banking_target(&key).is_none() {
            return Err(CoreError::InvalidInput {
                message: tr("Bank oder Ländercode ungültig.").into(),
            });
        }
        if !crate::demo::is_magic_demo_login(&login_name) {
            crate::banking_gate::check_connector(&key)?;
        }
        let login = if login_name.trim().is_empty() {
            aspsp.clone()
        } else {
            login_name
        };
        let display = if display_name.trim().is_empty() {
            aspsp.clone()
        } else {
            display_name
        };
        let db = self.db()?;
        let (id, _) = Self::add_bank_connection_keyed(
            &db,
            ConnectorKind::EnableBanking,
            &key,
            None,
            display,
            login,
        )?;
        Ok(id)
    }

    pub fn delete_bank_connection(&self, connection_id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        Self::purge_connection(&tx, connection_id)?;
        tx.commit()?;
        Ok(())
    }

    /// Deletes one account with its bookings, documents and holdings. When it was the last
    /// account of its connection, the connection and its stored secrets (PIN, session) go too.
    /// Only archived accounts can be deleted (`set_account_archived` first).
    pub fn delete_account(&self, account_id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let Some((conn, archived)) = tx
            .query_row(
                "SELECT connection_id, archived_unix IS NOT NULL FROM accounts WHERE id = ?1 AND deleted_ms IS NULL",
                [account_id],
                |r| Ok((r.get::<_, Option<i64>>(0)?, r.get::<_, bool>(1)?)),
            )
            .optional()?
        else {
            return Err(CoreError::NotFound {
                what: trf("Konto {0}", &[&account_id]),
            });
        };
        if !archived {
            return Err(CoreError::InvalidInput {
                message: tr("Nur archivierte Konten können gelöscht werden. Bitte das Konto zuerst archivieren.")
                    .to_string(),
            });
        }
        Self::delete_account_rows(&tx, account_id)?;
        // linked loan payments of this account are gone with it
        crate::loans::refresh_all(&tx)?;
        if let Some(c) = conn {
            let left: i64 = tx.query_row(
                "SELECT count(*) FROM accounts WHERE connection_id = ?1 AND deleted_ms IS NULL",
                [c],
                |r| r.get(0),
            )?;
            if left == 0 {
                Self::purge_connection(&tx, c)?;
            }
        }
        tx.commit()?;
        Ok(())
    }

    // ---------------------------------------------------------------- holdings

    pub fn list_holdings(&self, account_id: i64) -> Result<Vec<Holding>, CoreError> {
        let db = self.db()?;
        let mut q = db.prepare(
            "SELECT isin, wkn, name, quantity, current_price_cents, purchase_price_cents, value_cents
             FROM holdings h WHERE account_id = ?1
               AND EXISTS (SELECT 1 FROM accounts a WHERE a.id = h.account_id AND a.deleted_ms IS NULL)
             ORDER BY value_cents DESC, name",
        )?;
        let rows = q.query_map([account_id], |r| {
            Ok(Holding {
                isin: r.get(0)?,
                wkn: r.get(1)?,
                name: r.get(2)?,
                quantity: r.get(3)?,
                current_price_cents: r.get(4)?,
                purchase_price_cents: r.get(5)?,
                value_cents: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    }

    // ---------------------------------------------------------------- accounts

    pub fn list_accounts(&self) -> Result<Vec<Account>, CoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare(&format!(
            "SELECT a.id, a.connection_id, c.connector, a.group_id, a.name, a.bank_name, a.owner, a.iban, a.account_number,
                    a.currency, a.kind, a.balance_cents, a.balance_date, a.sf_symbol, a.sort_order,
                    (SELECT count(*) FROM transactions t WHERE t.account_id = a.id AND t.deleted_ms IS NULL),
                    -- uncategorised, split-aware like `category_match_sql(\"IS NULL\")`
                    (SELECT count(*) FROM transactions t WHERE t.account_id = a.id AND t.category_id IS NULL AND t.deleted_ms IS NULL
                        AND NOT EXISTS (SELECT 1 FROM transaction_splits sp WHERE sp.transaction_id = t.id))
                    + (SELECT count(DISTINCT sp.transaction_id) FROM transaction_splits sp
                        JOIN transactions t ON t.id = sp.transaction_id
                        WHERE t.account_id = a.id AND sp.category_id IS NULL AND t.deleted_ms IS NULL),
                    (SELECT count(*) FROM transactions t WHERE t.account_id = a.id AND t.checked = 0 AND t.deleted_ms IS NULL),
                    a.initial_balance_cents, g.uuid, IFNULL(g.include_in_total, 1) AND a.archived_unix IS NULL,
                    a.color_hex, IFNULL(c.connector, ''), IFNULL(c.bank_code, ''), IFNULL(c.login_name, ''), a.external_ref,
                    a.archived_unix, a.access_revoked,
                    o.opening_cents, IFNULL(o.opening_date, ''), {derived}
             FROM accounts a LEFT JOIN bank_connections c ON c.id = a.connection_id
             LEFT JOIN user_groups g ON g.uuid = a.user_group_uuid AND g.deleted_ms IS NULL
             LEFT JOIN opening_balances o ON o.account_id = a.id
             WHERE a.deleted_ms IS NULL
             ORDER BY a.sort_order, a.id",
            derived = crate::opening_balance::DERIVED_SQL
        ))?;
        let mut color_hashes: HashMap<i64, u64> = HashMap::new();
        let rows = stmt.query_map([], |r| {
            Ok(Account {
                id: r.get(0)?,
                connection_id: r.get(1)?,
                connector: r
                    .get::<_, Option<String>>(2)?
                    .and_then(|s| ConnectorKind::from_str(&s)),
                group_id: r.get(3)?,
                name: r.get(4)?,
                bank_name: r.get(5)?,
                owner: r.get(6)?,
                iban: r.get(7)?,
                account_number: r.get(8)?,
                currency: r.get(9)?,
                kind: AccountKind::from_str(&r.get::<_, String>(10)?),
                balance_cents: r.get(11)?,
                balance_date: r.get(12)?,
                sf_symbol: r.get(13)?,
                sort_order: r.get(14)?,
                transaction_count: r.get::<_, i64>(15)? as u32,
                uncategorized_count: r.get::<_, i64>(16)? as u32,
                new_count: r.get::<_, i64>(17)? as u32,
                initial_balance_cents: r
                    .get::<_, Option<i64>>(18)?
                    .map(i64::abs)
                    .filter(|c| *c > 0),
                user_group_uuid: r.get(19)?,
                in_total: r.get(20)?,
                // filled in below for accounts without a chosen colour
                color_hex: match r.get::<_, Option<String>>(21)? {
                    Some(c) => c,
                    None => {
                        color_hashes.insert(
                            r.get(0)?,
                            crate::user_groups::account_color_hash(
                                &r.get::<_, String>(22)?,
                                &r.get::<_, String>(23)?,
                                &r.get::<_, String>(24)?,
                                &r.get::<_, String>(25)?,
                            ),
                        );
                        String::new()
                    }
                },
                archived_unix: r.get(26)?,
                access_revoked: r.get::<_, i64>(27)? != 0,
                opening_balance_cents: r.get(28)?,
                opening_balance_date: r.get(29)?,
                balance_derived: r.get(30)?,
            })
        })?;
        let mut accounts = rows.collect::<Result<Vec<_>, _>>()?;
        // a subgroup of an excluded group is excluded too
        let excluded = crate::user_groups::excluded_from_total(&db)?;
        if !excluded.is_empty() {
            for a in accounts.iter_mut() {
                if a.user_group_uuid
                    .as_ref()
                    .is_some_and(|u| excluded.contains(u))
                {
                    a.in_total = false;
                }
            }
        }
        crate::user_groups::assign_default_colors(&mut accounts, &color_hashes);
        // Credit cards stored with balance 0: derive the open amount from bookings
        // (unless a Startsaldo drives the balance; bank-synced cards ignore one).
        for a in accounts.iter_mut().filter(|a| {
            a.kind == AccountKind::CreditCard
                && a.balance_cents == 0
                && a.transaction_count > 0
                && !(a.balance_derived && a.opening_balance_cents.is_some())
        }) {
            let mut st = db.prepare(
                "SELECT booking_date, amount_cents, counterparty || ' ' || purpose || ' ' || booking_text
                 FROM transactions WHERE account_id = ?1 AND deleted_ms IS NULL ORDER BY booking_date, id",
            )?;
            let tx_rows: Vec<(String, i64, String)> = st
                .query_map([a.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?;
            if let Some(open) = crate::connectors::open_card_balance(&tx_rows) {
                a.balance_cents = open;
            }
        }
        Ok(accounts)
    }

    /// Sidebar data: groups with their accounts and summed balances.
    pub fn list_account_groups(&self) -> Result<Vec<AccountGroup>, CoreError> {
        let accounts = self.list_accounts()?;
        let db = self.db()?;
        let mut stmt = db.prepare(
            "SELECT id, name, sf_symbol, sort_order FROM account_groups ORDER BY sort_order, id",
        )?;
        let groups = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, i32>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(groups
            .into_iter()
            .map(|(id, name, sym, order)| {
                let accs: Vec<Account> = accounts
                    .iter()
                    .filter(|a| a.group_id == id)
                    .cloned()
                    .collect();
                // archived accounts stay listed but don't count (GiroCrab/GiroCrab#208)
                let balance = accs
                    .iter()
                    .filter(|a| a.currency == "EUR" && a.archived_unix.is_none())
                    .map(|a| a.balance_cents)
                    .sum();
                AccountGroup {
                    id,
                    name: display_name(&name),
                    sf_symbol: sym,
                    sort_order: order,
                    balance_cents: balance,
                    accounts: accs,
                }
            })
            .filter(|g| !g.accounts.is_empty())
            .collect())
    }

    /// End-of-day balances for the last `days` days (oldest first), for the
    /// header chart. Empty `account_ids` = all EUR accounts. Computed backwards
    /// from the current balance, so it is exact in cents.
    pub fn balance_history(
        &self,
        account_ids: Vec<i64>,
        days: u32,
    ) -> Result<Vec<DailyBalance>, CoreError> {
        let accounts = self.list_accounts()?;
        let chosen: Vec<&Account> = accounts
            .iter()
            .filter(|a| {
                a.currency == "EUR"
                    && if account_ids.is_empty() {
                        a.in_total
                    } else {
                        account_ids.contains(&a.id)
                    }
            })
            .collect();
        let mut balance: i64 = chosen.iter().map(|a| a.balance_cents).sum();
        let ids: Vec<i64> = chosen.iter().map(|a| a.id).collect();
        let today = chrono::Local::now().date_naive();
        let start = today - chrono::Duration::days(days.max(1) as i64 - 1);
        let mut per_day: HashMap<String, i64> = HashMap::new();
        if !ids.is_empty() {
            let db = self.db()?;
            let list = (0..ids.len())
                .map(|n| format!("?{}", n + 2))
                .collect::<Vec<_>>()
                .join(",");
            let mut stmt = db.prepare(&format!(
                "SELECT booking_date, SUM(amount_cents) FROM transactions WHERE account_id IN ({list}) AND booking_date > ?1 AND deleted_ms IS NULL GROUP BY booking_date"
            ))?;
            let date = start.format("%Y-%m-%d").to_string();
            let args: Vec<rusqlite::types::Value> = std::iter::once(date.into())
                .chain(ids.iter().map(|&i| i.into()))
                .collect();
            let rows = stmt.query_map(rusqlite::params_from_iter(args), |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
            })?;
            for row in rows {
                let (d, s) = row?;
                per_day.insert(d, s);
            }
        }
        let mut out = Vec::with_capacity(days as usize);
        let mut day = today;
        while day >= start {
            let key = day.format("%Y-%m-%d").to_string();
            out.push(DailyBalance {
                date: key.clone(),
                balance_cents: balance,
            });
            balance -= per_day.get(&key).copied().unwrap_or(0);
            day -= chrono::Duration::days(1);
        }
        out.reverse();
        Ok(out)
    }

    pub fn rename_account(&self, account_id: i64, name: String) -> Result<(), CoreError> {
        let n = self.db()?.execute(
            "UPDATE accounts SET name = ?1, name_ms = ?3 WHERE id = ?2",
            params![name, account_id, crate::user_groups::now_ms()],
        )?;
        if n == 0 {
            return Err(CoreError::NotFound {
                what: trf("Konto {0}", &[&account_id]),
            });
        }
        Ok(())
    }

    /// Sets (or clears with `None`) the original loan amount of an account.
    pub fn set_account_initial_balance(
        &self,
        account_id: i64,
        cents: Option<i64>,
    ) -> Result<(), CoreError> {
        let cents = cents.map(|c| c.abs()).filter(|c| *c > 0);
        let n = self.db()?.execute(
            "UPDATE accounts SET initial_balance_cents = ?1 WHERE id = ?2",
            params![cents, account_id],
        )?;
        if n == 0 {
            return Err(CoreError::NotFound {
                what: trf("Konto {0}", &[&account_id]),
            });
        }
        Ok(())
    }

    // ---------------------------------------------------------------- categories

    /// All categories in tree order (depth-first, siblings by sort order) with
    /// totals for the optional period.
    pub fn list_categories(
        &self,
        date_from: Option<String>,
        date_to: Option<String>,
    ) -> Result<Vec<Category>, CoreError> {
        let db = self.db()?;
        let rows = Self::category_rows(&db)?;
        let mut totals: HashMap<Option<i64>, (i64, u32)> = HashMap::new();
        {
            let mut stmt = db.prepare(&format!(
                "SELECT category_id, SUM(amount_cents), COUNT(*) FROM {}
                 WHERE (?1 IS NULL OR booking_date >= ?1) AND (?2 IS NULL OR booking_date <= ?2)
                 GROUP BY category_id",
                crate::planning::EFFECTIVE_SQL
            ))?;
            let it = stmt.query_map(params![date_from, date_to], |r| {
                Ok((
                    r.get::<_, Option<i64>>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, i64>(2)? as u32,
                ))
            })?;
            for row in it {
                let (c, s, n) = row?;
                totals.insert(c, (s, n));
            }
        }
        let mut children: HashMap<
            Option<i64>,
            Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
        > = HashMap::new();
        for r in &rows {
            children.entry(r.1).or_default().push(r);
        }
        for list in children.values_mut() {
            list.sort_by(|a, b| {
                a.5.cmp(&b.5)
                    .then_with(|| a.2.to_lowercase().cmp(&b.2.to_lowercase()))
            });
        }
        fn subtotal(
            id: i64,
            children: &HashMap<
                Option<i64>,
                Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
            >,
            totals: &HashMap<Option<i64>, (i64, u32)>,
            depth: u32,
        ) -> (i64, u32) {
            let own = totals.get(&Some(id)).copied().unwrap_or((0, 0));
            if depth > 32 {
                return own;
            }
            let mut sum = own;
            if let Some(kids) = children.get(&Some(id)) {
                for k in kids {
                    let (s, n) = subtotal(k.0, children, totals, depth + 1);
                    sum.0 += s;
                    sum.1 += n;
                }
            }
            sum
        }
        let mut out = Vec::with_capacity(rows.len());
        fn walk(
            parent: Option<i64>,
            depth: u32,
            prefix: &str,
            children: &HashMap<
                Option<i64>,
                Vec<&(i64, Option<i64>, String, String, String, i32, Option<i64>)>,
            >,
            totals: &HashMap<Option<i64>, (i64, u32)>,
            out: &mut Vec<Category>,
        ) {
            if depth > 32 {
                return;
            }
            if let Some(kids) = children.get(&parent) {
                for k in kids {
                    let path = if prefix.is_empty() {
                        k.2.clone()
                    } else {
                        format!("{prefix} › {}", k.2)
                    };
                    let own = totals.get(&Some(k.0)).copied().unwrap_or((0, 0));
                    let (total, count) = subtotal(k.0, children, totals, 0);
                    out.push(Category {
                        id: k.0,
                        parent_id: k.1,
                        name: display_name(&k.2),
                        sf_symbol: k.3.clone(),
                        color_hex: k.4.clone(),
                        sort_order: k.5,
                        depth,
                        path: display_path(&path),
                        own_total_cents: own.0,
                        total_cents: total,
                        transaction_count: count,
                        budget_cents: k.6,
                    });
                    walk(Some(k.0), depth + 1, &path, children, totals, out);
                }
            }
        }
        walk(None, 0, "", &children, &totals, &mut out);
        Ok(out)
    }

    pub fn create_category(
        &self,
        name: String,
        parent_id: Option<i64>,
        sf_symbol: String,
        color_hex: String,
    ) -> Result<i64, CoreError> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Der Kategoriename ist leer.").into(),
            });
        }
        let db = self.db()?;
        let order: i32 = db.query_row(
            "SELECT IFNULL(MAX(sort_order), 0) + 1 FROM categories WHERE parent_id IS ?1",
            [parent_id],
            |r| r.get(0),
        )?;
        db.execute(
            "INSERT INTO categories(parent_id, name, sf_symbol, color_hex, sort_order,
                    name_ms, parent_ms, symbol_ms, color_ms, order_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?6, ?6, ?6)",
            params![
                parent_id,
                name,
                if sf_symbol.is_empty() {
                    "tag".to_string()
                } else {
                    sf_symbol
                },
                color_hex,
                order,
                crate::user_groups::now_ms()
            ],
        )?;
        let id = db.last_insert_rowid();
        crate::sync_merge::fill_missing_uuids(&db)?;
        Ok(id)
    }

    pub fn update_category(
        &self,
        id: i64,
        name: String,
        parent_id: Option<i64>,
        sf_symbol: String,
        color_hex: String,
    ) -> Result<(), CoreError> {
        let db = self.db()?;
        // Refuse moving a category below itself.
        if let Some(mut p) = parent_id {
            let mut guard = 0;
            loop {
                if p == id {
                    return Err(CoreError::InvalidInput {
                        message: tr("Eine Kategorie kann nicht in sich selbst verschoben werden.")
                            .into(),
                    });
                }
                guard += 1;
                match db
                    .query_row("SELECT parent_id FROM categories WHERE id = ?1", [p], |r| {
                        r.get::<_, Option<i64>>(0)
                    })
                    .optional()?
                {
                    Some(Some(next)) if guard < 32 => p = next,
                    _ => break,
                }
            }
        }
        // The UI shows built-in names translated; saving that unchanged
        // display name keeps the stored German default (and its logic).
        let stored: Option<(String, Option<i64>, String, String)> = db
            .query_row(
                "SELECT name, parent_id, sf_symbol, color_hex FROM categories WHERE id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        let name = match &stored {
            Some((stored, ..)) if *stored != name && display_name(stored) == name => stored.clone(),
            _ => name,
        };
        // only fields that really change get a stamp (newest edit wins per field)
        let now = crate::user_groups::now_ms();
        let (old_name, old_parent, old_symbol, old_color) = stored.unwrap_or_default();
        db.execute(
            "UPDATE categories SET name = ?1, parent_id = ?2, sf_symbol = ?3, color_hex = ?4,
                    name_ms = CASE WHEN ?6 THEN ?10 ELSE name_ms END,
                    parent_ms = CASE WHEN ?7 THEN ?10 ELSE parent_ms END,
                    symbol_ms = CASE WHEN ?8 THEN ?10 ELSE symbol_ms END,
                    color_ms = CASE WHEN ?9 THEN ?10 ELSE color_ms END
             WHERE id = ?5",
            params![
                name,
                parent_id,
                sf_symbol,
                color_hex,
                id,
                name != old_name,
                parent_id != old_parent,
                sf_symbol != old_symbol,
                color_hex != old_color,
                now
            ],
        )?;
        Ok(())
    }

    /// Deletes a category and its sub-categories (soft: the rows stay with a
    /// deletion stamp, so a sync does not bring them back); their rules go
    /// too and their transactions and splits become uncategorised. The
    /// uncategorising is derived, so it carries no `category_ms` stamp.
    pub fn delete_category(&self, id: i64) -> Result<(), CoreError> {
        let mut db = self.db()?;
        let tx = db.transaction()?;
        crate::sync_merge::soft_delete_categories(&tx, id)?;
        tx.commit()?;
        Ok(())
    }

    // ---------------------------------------------------------------- transactions

    pub fn list_transactions(&self, filter: BookingFilter) -> Result<BookingPage, CoreError> {
        let db = self.db()?;
        let paths = Self::category_paths(&db)?;
        let mut wh: Vec<String> = vec!["t.deleted_ms IS NULL AND a.deleted_ms IS NULL".into()];
        let mut args: Vec<Box<dyn ToSql>> = vec![];
        let mut cte = String::new();
        if !filter.account_ids.is_empty() {
            let ph: Vec<String> = filter
                .account_ids
                .iter()
                .map(|id| {
                    args.push(Box::new(*id));
                    format!("?{}", args.len())
                })
                .collect();
            let mut clause = format!("t.account_id IN ({})", ph.join(","));
            // Loan view: also surface bookings of other accounts (e.g. the Girokonto's
            // monthly "Zins / Tilgung" debits) that reference the loan's IBAN / account number.
            let loans: Vec<(i64, String, String)> = {
                let mut q = db
                    .prepare("SELECT id, iban, account_number FROM accounts WHERE kind = 'loan' AND deleted_ms IS NULL")?;
                let rows = q.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
                rows.collect::<Result<Vec<_>, _>>()?
            };
            let loan_ids: Vec<i64> = loans.iter().map(|l| l.0).collect();
            for (id, iban, number) in loans.iter().filter(|l| filter.account_ids.contains(&l.0)) {
                let digits: String = number.chars().filter(|c| c.is_ascii_digit()).collect();
                let trimmed = digits.trim_start_matches('0').to_string();
                let mut ors: Vec<String> = Vec::new();
                if iban.len() >= 15 {
                    args.push(Box::new(iban.clone()));
                    ors.push(format!("t.counterparty_iban = ?{0} OR REPLACE(t.purpose,' ','') LIKE '%' || ?{0} || '%'", args.len()));
                }
                if trimmed.len() >= 6 {
                    args.push(Box::new(trimmed.clone()));
                    let n = args.len();
                    ors.push(format!(
                        "t.counterparty_iban LIKE '%' || ?{n} OR t.purpose LIKE '%' || ?{n} || '%'"
                    ));
                }
                // Only exact references (IBAN / full loan number) – no keyword or short-suffix
                // heuristics: those pulled unrelated bookings of every account into a loan.
                if !ors.is_empty() {
                    let own: Vec<String> = loan_ids.iter().map(|i| i.to_string()).collect();
                    clause.push_str(&format!(
                        " OR (t.account_id NOT IN ({}) AND ({}))",
                        own.join(","),
                        ors.join(" OR ")
                    ));
                }
                let _ = id;
            }
            // manual loans (#36): bookings linked by hand or by the loan's expression
            clause.push_str(&format!(
                " OR t.id IN (SELECT transaction_id FROM loan_links WHERE source != 'excluded' AND loan_account_id IN ({}))",
                filter.account_ids.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",")
            ));
            wh.push(format!("({clause})"));
        }
        // Category filters follow `planning::EFFECTIVE_SQL`: a split booking belongs
        // to the categories of its parts (never to its own category), and only the
        // parts of the filtered category count in the KPI sums (`share_sql`).
        let cat_match: Option<String> = if filter.uncategorized_only {
            Some("IS NULL".into())
        } else if let Some(cat) = filter.category_id {
            args.push(Box::new(cat));
            let n = args.len();
            if filter.include_subcategories {
                cte = format!(
                    "WITH RECURSIVE sub(id) AS (SELECT ?{n} UNION ALL SELECT c.id FROM categories c JOIN sub ON c.parent_id = sub.id WHERE c.deleted_ms IS NULL) "
                );
                Some("IN (SELECT id FROM sub)".into())
            } else {
                Some(format!("= ?{n}"))
            }
        } else {
            None
        };
        let share_sql = match &cat_match {
            Some(m) => {
                wh.push(category_match_sql(m));
                format!(
                    "COALESCE((SELECT SUM(sp.amount_cents) FROM transaction_splits sp WHERE sp.transaction_id = t.id AND sp.category_id {m}), t.amount_cents)"
                )
            }
            None => "t.amount_cents".to_string(),
        };
        if let Some(from) = filter.date_from.as_ref().filter(|s| !s.is_empty()) {
            args.push(Box::new(from.clone()));
            wh.push(format!("t.booking_date >= ?{}", args.len()));
        }
        if let Some(to) = filter.date_to.as_ref().filter(|s| !s.is_empty()) {
            args.push(Box::new(to.clone()));
            wh.push(format!("t.booking_date <= ?{}", args.len()));
        }
        match filter.checked {
            None => {}
            Some(true) => wh.push("t.checked != 0".into()),
            Some(false) => wh.push("t.checked = 0".into()),
        }
        match filter.direction {
            BookingDirection::All => {}
            BookingDirection::Income => wh.push("t.amount_cents > 0".into()),
            BookingDirection::Expense => wh.push("t.amount_cents < 0".into()),
        }
        if let Some(q) = filter
            .search
            .as_ref()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
        {
            let mut ors = Vec::new();
            for term in q.split_whitespace() {
                let like = format!(
                    "%{}%",
                    term.replace('\\', "\\\\")
                        .replace('%', "\\%")
                        .replace('_', "\\_")
                );
                args.push(Box::new(like));
                let n = args.len();
                let mut alt = format!(
                    "(t.counterparty LIKE ?{n} ESCAPE '\\' OR t.purpose LIKE ?{n} ESCAPE '\\' OR t.booking_text LIKE ?{n} ESCAPE '\\' \
                     OR t.counterparty_iban LIKE ?{n} ESCAPE '\\' OR cat.name LIKE ?{n} ESCAPE '\\' OR a.name LIKE ?{n} ESCAPE '\\'"
                );
                if term.chars().any(|c| c.is_ascii_digit()) {
                    if let Ok(cents) = parse_cents(term) {
                        args.push(Box::new(cents.abs()));
                        alt.push_str(&format!(" OR ABS(t.amount_cents) = ?{}", args.len()));
                    }
                }
                alt.push(')');
                ors.push(alt);
            }
            wh.push(ors.join(" AND "));
        }
        let loan_links = crate::loans::link_map(&db)?;
        let where_sql = wh.join(" AND ");
        // a deleted category or rule reads as none (what the old SET NULL did)
        let from_sql = "FROM transactions t JOIN accounts a ON a.id = t.account_id
             LEFT JOIN categories cat ON cat.id = t.category_id AND cat.deleted_ms IS NULL
             LEFT JOIN rules r ON r.id = t.rule_id AND r.deleted_ms IS NULL";
        let sql = format!(
            "{cte}SELECT t.id, t.account_id, a.name, t.booking_date, t.value_date, t.amount_cents, t.currency, t.counterparty,
                    t.counterparty_iban, t.purpose, t.booking_text, cat.id, t.category_source, r.id, t.checked, a.kind,
                    (SELECT count(*) FROM booking_documents d WHERE d.booking_id = t.id), t.note,
                    t.purpose_code, t.gvc, t.salary_flag, {share_sql},
                    (t.external_id LIKE 'pending-%')
             {from_sql} WHERE {where_sql} ORDER BY t.booking_date DESC, t.id DESC"
        );
        let mut stmt = db.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args.iter().map(|b| b.as_ref())), |r| {
            let cat: Option<i64> = r.get(11)?;
            let src: String = r.get(12)?;
            let share: i64 = r.get(21)?;
            Ok((
                share,
                Booking {
                    id: r.get(0)?,
                    account_id: r.get(1)?,
                    account_name: r.get(2)?,
                    booking_date: r.get(3)?,
                    value_date: r.get(4)?,
                    amount_cents: r.get(5)?,
                    currency: r.get(6)?,
                    counterparty: r.get(7)?,
                    counterparty_iban: r.get(8)?,
                    purpose: r.get(9)?,
                    booking_text: r.get(10)?,
                    category_id: cat,
                    category_name: String::new(),
                    category_path: String::new(),
                    category_color_hex: String::new(),
                    category_symbol: String::new(),
                    category_source: match src.as_str() {
                        "rule" => CategorySource::Rule,
                        "manual" => CategorySource::Manual,
                        _ => CategorySource::None,
                    },
                    rule_id: r.get(13)?,
                    checked: r.get::<_, i64>(14)? != 0,
                    merchant: MerchantResolver::placeholder(),
                    merchant_name: String::new(),
                    merchant_domain: None,
                    merchant_svg_path: None,
                    merchant_hex_color: String::new(),
                    payment_method: String::new(),
                    flow: FlowKind::Consumption,
                    clean_purpose: String::new(),
                    account_kind: AccountKind::from_str(&r.get::<_, String>(15)?),
                    document_count: r.get::<_, i64>(16)? as u32,
                    note: r.get(17)?,
                    purpose_code: r.get(18)?,
                    gvc: r.get(19)?,
                    salary_flag: r.get::<_, Option<i64>>(20)?.map(|f| f != 0),
                    is_salary: false,
                    recurrence_key: String::new(),
                    is_pending: r.get::<_, i64>(22)? != 0,
                },
            ))
        })?;
        let mut txs = Vec::new();
        let salary_ibans = crate::salary::marked_salary_ibans(&db)?;
        let overrides = crate::insights::load_overrides(&db).unwrap_or_default();
        // Own IBANs: bookings to / from them are transfers (Issue #94).
        let own_ibans: std::collections::HashSet<String> = {
            let mut st =
                db.prepare("SELECT iban FROM accounts WHERE iban IS NOT NULL AND iban != '' AND deleted_ms IS NULL")?;
            let ibans = st
                .query_map([], |r| r.get::<_, String>(0))?
                .filter_map(Result::ok)
                .map(|i| crate::connectors::fints::sepa::normalize_iban(&i))
                .collect();
            ibans
        };
        let (mut income, mut expense, mut consumption, mut investment, mut perk) =
            (0i64, 0i64, 0i64, 0i64, 0i64);
        let mut flow = SelectionFlow::default();
        for row in rows {
            let (share, mut t) = row?;
            if let Some((name, path, color, sym)) = t.category_id.and_then(|c| paths.get(&c)) {
                t.category_name = name.clone();
                t.category_path = path.clone();
                t.category_color_hex = color.clone();
                t.category_symbol = sym.clone();
            }
            enrich(&mut t);
            t.is_salary = crate::salary::is_salary(&t, &salary_ibans);
            if is_own_transfer(&t, &own_ibans) {
                t.flow = FlowKind::Transfer;
            }
            // Localise after `enrich`: flow classification needs the stored names.
            t.category_name = display_name(&t.category_name);
            t.category_path = display_path(&t.category_path);
            if let Some(d) = overrides.get(&t.merchant.key) {
                t.merchant.domain = d.clone();
                t.merchant.domain_candidates = vec![d.clone()];
                t.merchant.domain_source = "override".into();
                t.merchant_domain = Some(d.clone());
            }
            if loan_links.contains_key(&t.id) {
                t.flow = FlowKind::Loan;
            }
            let keep = match filter.scope {
                BookingScope::All => true,
                BookingScope::Everyday => !matches!(t.flow, FlowKind::Investment | FlowKind::Perk),
                BookingScope::Investments => {
                    matches!(t.flow, FlowKind::Investment | FlowKind::Perk)
                }
            } && filter
                .merchant_key
                .as_ref()
                .map(|k| *k == t.merchant.key)
                .unwrap_or(true);
            if !keep {
                continue;
            }
            // One KPI definition (`kpi_side`) for the page sums and `SelectionFlow`;
            // transfers between own accounts are neutral (else counted on both sides).
            // `share` is the full amount, or with a category filter only the split
            // parts of that category.
            match kpi_side(t.flow, share) {
                KpiSide::Income => income += share,
                KpiSide::Expense => expense += share,
                KpiSide::Neutral => {}
            }
            match t.flow {
                FlowKind::Consumption => consumption += share,
                FlowKind::Investment => investment += share,
                FlowKind::Perk => perk += share,
                _ => {}
            }
            flow.add(t.flow, share);
            txs.push(t);
        }
        let total = txs.len() as u32;
        let limit = if filter.limit == 0 {
            usize::MAX
        } else {
            filter.limit as usize
        };
        let start = (filter.offset as usize).min(txs.len());
        let mut end = start.saturating_add(limit).min(txs.len());
        if filter.whole_days && end > start {
            // sorted by day: the rest of the page's last day follows directly
            while end < txs.len() && txs[end].booking_date == txs[end - 1].booking_date {
                end += 1;
            }
        }
        let txs: Vec<Booking> = txs.drain(start..end).collect();
        Ok(BookingPage {
            transactions: txs,
            total_count: total,
            income_cents: income,
            expense_cents: expense,
            consumption_cents: consumption,
            investment_cents: investment,
            perk_cents: perk,
            flow,
        })
    }

    /// Manual categorisation (wins over rules). `None` = uncategorised.
    pub fn set_transaction_category(
        &self,
        transaction_id: i64,
        category_id: Option<i64>,
    ) -> Result<(), CoreError> {
        let db = self.db()?;
        let n = db.execute(
            "UPDATE transactions SET category_id = ?1, rule_id = NULL, category_source = CASE WHEN ?1 IS NULL THEN 'none' ELSE 'manual' END, category_ms = ?3 WHERE id = ?2",
            params![category_id, transaction_id, crate::user_groups::now_ms()],
        )?;
        if n == 0 {
            return Err(CoreError::NotFound {
                what: trf("Buchung {0}", &[&transaction_id]),
            });
        }
        Ok(())
    }

    /// Booking day of one booking ("2026-11-09"); `None` if it does not exist.
    /// Lets the list load far enough back to show a booking it is asked to reveal.
    pub fn booking_date(&self, booking_id: i64) -> Result<Option<String>, CoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare("SELECT booking_date FROM transactions WHERE id = ?1")?;
        let mut rows = stmt.query_map([booking_id], |r| r.get::<_, String>(0))?;
        Ok(rows.next().transpose()?)
    }

    pub fn set_transaction_checked(
        &self,
        transaction_id: i64,
        checked: bool,
    ) -> Result<(), CoreError> {
        self.db()?.execute(
            "UPDATE transactions SET checked = ?1, checked_ms = ?3 WHERE id = ?2",
            params![checked as i64, transaction_id, crate::user_groups::now_ms()],
        )?;
        Ok(())
    }

    /// Manual text correction of a booking's counterparty / purpose.
    pub fn update_transaction_text(
        &self,
        transaction_id: i64,
        counterparty: String,
        purpose: String,
    ) -> Result<(), CoreError> {
        let n = self.db()?.execute(
            "UPDATE transactions SET counterparty = ?1, purpose = ?2, text_ms = ?4 WHERE id = ?3",
            params![
                counterparty.trim(),
                purpose.trim(),
                transaction_id,
                crate::user_groups::now_ms()
            ],
        )?;
        if n == 0 {
            return Err(CoreError::NotFound {
                what: trf("Buchung {0}", &[&transaction_id]),
            });
        }
        Ok(())
    }

    /// Free-text user note of a booking (empty clears it).
    pub fn update_transaction_note(
        &self,
        transaction_id: i64,
        note: String,
    ) -> Result<(), CoreError> {
        let n = self.db()?.execute(
            "UPDATE transactions SET note = ?1, note_ms = ?3 WHERE id = ?2",
            params![note.trim(), transaction_id, crate::user_groups::now_ms()],
        )?;
        if n == 0 {
            return Err(CoreError::NotFound {
                what: trf("Buchung {0}", &[&transaction_id]),
            });
        }
        Ok(())
    }

    // ---------------------------------------------------------------- rules

    pub fn list_rules(&self) -> Result<Vec<Rule>, CoreError> {
        let db = self.db()?;
        Self::load_rules(&db)
    }

    /// Creates (id == 0) or updates a rule. Validates the pattern first.
    pub fn save_rule(&self, rule: Rule) -> Result<i64, CoreError> {
        if rule.pattern.len() > crate::rules::MAX_PATTERN_LEN {
            return Err(CoreError::InvalidInput {
                message: tr("Das Suchmuster ist zu lang.").into(),
            });
        }
        crate::rules::CompiledRule::compile(rule.clone())?;
        if rule.pattern.trim().is_empty() {
            return Err(CoreError::InvalidInput {
                message: tr("Das Suchmuster ist leer.").into(),
            });
        }
        let db = self.db()?;
        let kind = match rule.match_kind {
            MatchKind::Keyword => "keyword",
            MatchKind::Regex => "regex",
            MatchKind::Expression => {
                let expr = crate::search_expr::SearchExpr::parse(&rule.pattern)
                    .map_err(|message| CoreError::InvalidInput { message })?;
                if let Some(f) = expr.unsupported_fields().first() {
                    return Err(CoreError::InvalidInput {
                        message: trf("Das Feld „{0}“ wird nicht unterstützt.", &[f]),
                    });
                }
                "expression"
            }
        };
        if rule.id == 0 {
            db.execute(
                "INSERT INTO rules(name, category_id, field, match_kind, pattern, case_sensitive, min_amount_cents, max_amount_cents, account_id, priority, enabled, updated_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                params![rule.name, rule.category_id, rule.field.as_str(), kind, rule.pattern, rule.case_sensitive as i64,
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_id, rule.priority, rule.enabled as i64,
                        crate::user_groups::now_ms()],
            )?;
            let id = db.last_insert_rowid();
            crate::sync_merge::fill_missing_uuids(&db)?;
            Ok(id)
        } else {
            db.execute(
                "UPDATE rules SET name=?1, category_id=?2, field=?3, match_kind=?4, pattern=?5, case_sensitive=?6, min_amount_cents=?7,
                        max_amount_cents=?8, account_id=?9, priority=?10, enabled=?11, updated_ms=?13 WHERE id=?12",
                params![rule.name, rule.category_id, rule.field.as_str(), kind, rule.pattern, rule.case_sensitive as i64,
                        rule.min_amount_cents, rule.max_amount_cents, rule.account_id, rule.priority, rule.enabled as i64, rule.id,
                        crate::user_groups::now_ms()],
            )?;
            Ok(rule.id)
        }
    }

    pub fn delete_rule(&self, rule_id: i64) -> Result<(), CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        tx.execute("UPDATE transactions SET category_id = NULL, category_source = 'none', rule_id = NULL WHERE rule_id = ?1", [rule_id])?;
        tx.execute(
            "UPDATE rules SET deleted_ms = ?2 WHERE id = ?1 AND deleted_ms IS NULL",
            params![rule_id, crate::user_groups::now_ms()],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Transactions the (unsaved) rule would match, for the live preview in the
    /// rule editor.
    pub fn preview_rule(&self, rule: Rule, limit: u32) -> Result<Vec<Booking>, CoreError> {
        let compiled = crate::rules::CompiledRule::compile(Rule {
            enabled: true,
            ..rule
        })?;
        let page = self.list_transactions(BookingFilter {
            limit: 20000,
            ..Default::default()
        })?;
        let ibans: HashMap<i64, String> = {
            let db = self.db()?;
            let mut st = db.prepare("SELECT id, iban FROM accounts WHERE deleted_ms IS NULL")?;
            let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            rows.collect::<Result<_, _>>()?
        };
        Ok(page
            .transactions
            .into_iter()
            .filter(|t| {
                compiled.matches(&RuleInput {
                    account_id: t.account_id,
                    amount_cents: t.amount_cents,
                    counterparty: &t.counterparty,
                    counterparty_iban: &t.counterparty_iban,
                    purpose: &t.purpose,
                    booking_text: &t.booking_text,
                    note: &t.note,
                    currency: &t.currency,
                    account_iban: ibans.get(&t.account_id).map_or("", String::as_str),
                })
            })
            .take(limit.max(1) as usize)
            .collect())
    }

    /// Runs all rules. `only_uncategorized = false` also re-evaluates
    /// transactions previously categorised by a rule (never manual ones).
    pub fn apply_rules(&self, only_uncategorized: bool) -> Result<u32, CoreError> {
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let n = Self::apply_rules_inner(&tx, only_uncategorized)?;
        tx.commit()?;
        Ok(n)
    }

    // ---------------------------------------------------------------- settings

    pub fn list_settings(&self) -> Result<Vec<SettingEntry>, CoreError> {
        let db = self.db()?;
        let mut out = vec![];
        for (key, label, help, group, secret, default) in KNOWN_SETTINGS {
            let stored: Option<String> = db
                .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                    r.get(0)
                })
                .optional()?;
            let value = stored.clone().unwrap_or_else(|| default.to_string());
            out.push(SettingEntry {
                key: key.to_string(),
                label: tr(label).to_string(),
                help: tr(help).to_string(),
                group: group.to_string(),
                group_title: tr(group).to_string(),
                value: if *secret {
                    String::new()
                } else {
                    value.clone()
                },
                is_secret: *secret,
                has_value: !value.is_empty(),
            });
        }
        Ok(out)
    }

    /// Stored choice of the FinTS product registration: `"builtin"`, `"own"`
    /// or empty (not decided yet).
    pub fn fints_product_id_mode(&self) -> Result<String, CoreError> {
        let db = self.db()?;
        let v = Self::setting_inner(&db, crate::connectors::fints::product_id::MODE_KEY)?
            .unwrap_or_default();
        Ok(crate::connectors::fints::product_id::normalize_mode(&v).to_string())
    }

    /// Stores the choice (`"builtin"` / `"own"`; anything else clears it). The
    /// user's own ID is never touched.
    pub fn set_fints_product_id_mode(&self, mode: String) -> Result<(), CoreError> {
        let mode = crate::connectors::fints::product_id::normalize_mode(&mode);
        self.set_setting(
            crate::connectors::fints::product_id::MODE_KEY.to_string(),
            mode.to_string(),
        )
    }

    /// Which registration would be sent right now: `"builtin"`, `"own"` or
    /// empty when none is available. Never returns the ID itself.
    pub fn fints_product_id_source(&self) -> Result<String, CoreError> {
        use crate::connectors::fints::product_id as pid;
        let db = self.db()?;
        let mode = Self::setting_inner(&db, pid::MODE_KEY)?.unwrap_or_default();
        let own = Self::setting_inner(&db, pid::OWN_KEY)?.unwrap_or_default();
        Ok(pid::resolve(&mode, &own)
            .map(|(s, _)| s.as_str().to_string())
            .unwrap_or_default())
    }

    pub fn get_setting(&self, key: String) -> Result<Option<String>, CoreError> {
        let db = self.db()?;
        Self::setting_inner(&db, &key)
    }

    /// Stores a setting inside the encrypted database. Empty value deletes it.
    pub fn set_setting(&self, key: String, value: String) -> Result<(), CoreError> {
        let value = Zeroizing::new(value);
        let db = self.db()?;
        if value.trim().is_empty() {
            db.execute("DELETE FROM settings WHERE key = ?1", [&key])?;
        } else {
            let secret = KNOWN_SETTINGS.iter().any(|s| s.0 == key && s.4)
                || key.contains("secret")
                || key.contains("private")
                || key.starts_with("pin.");
            db.execute(
                "INSERT INTO settings(key, value, is_secret) VALUES (?1, ?2, ?3)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, is_secret = excluded.is_secret",
                params![key, value.trim(), secret as i64],
            )?;
        }
        Ok(())
    }
}

impl Vault {
    fn delete_account_rows(db: &Connection, account_id: i64) -> Result<(), CoreError> {
        crate::sync_merge::soft_delete_account(db, account_id)
    }

    fn purge_connection(db: &Connection, connection_id: i64) -> Result<(), CoreError> {
        crate::sync_merge::soft_delete_connection(db, connection_id)?;
        // stored secrets of this connection (PIN); the soft delete blanked the session (state_json)
        db.execute(
            "DELETE FROM settings WHERE key = ?1",
            [crate::connections::pin_key(connection_id)],
        )?;
        Ok(())
    }
}

/// Quotes a CSV field (semicolon dialect); text fields are neutralised against
/// spreadsheet formula injection.
fn csv_field(v: &str, text: bool) -> String {
    let mut s = v.replace(['\r', '\n'], " ");
    if text && s.starts_with(['=', '+', '@', '\t']) {
        s.insert(0, '\'');
    }
    if s.contains([';', '"']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s
    }
}

/// Formats cents as `-1234,56` (German decimal comma, no grouping).
fn csv_amount(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let a = cents.unsigned_abs();
    format!("{sign}{},{:02}", a / 100, a % 100)
}

#[uniffi::export]
impl Vault {
    /// Exports all bookings matching `filter` (its paging is ignored) as UTF-8 CSV
    /// with BOM, semicolon-separated, for Excel.
    pub fn export_bookings_csv(&self, filter: BookingFilter) -> Result<String, CoreError> {
        let mut out = String::from(
            "\u{FEFF}Datum;Konto;Name;IBAN;Verwendungszweck;Kategorie;Betrag;Währung\r\n",
        );
        let page_size = 1000u32;
        let mut offset = 0u32;
        loop {
            let mut f = filter.clone();
            f.limit = page_size;
            f.offset = offset;
            let page = self.list_transactions(f)?;
            let n = page.transactions.len() as u32;
            for b in &page.transactions {
                let row = [
                    csv_field(&b.booking_date, false),
                    csv_field(&b.account_name, true),
                    csv_field(&b.counterparty, true),
                    csv_field(&b.counterparty_iban, false),
                    csv_field(&b.purpose, true),
                    csv_field(&b.category_path, true),
                    csv_amount(b.amount_cents),
                    csv_field(&b.currency, false),
                ];
                out.push_str(&row.join(";"));
                out.push_str("\r\n");
            }
            if n < page_size {
                break;
            }
            offset += n;
        }
        Ok(out)
    }
}

#[cfg(test)]
mod merge_tests {
    use super::*;

    fn seed(v: &Vault, checked: bool, note: &str, extra: bool) {
        let c = v.db().unwrap();
        c.execute(
            "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
            [],
        )
        .unwrap();
        c.execute(
            "INSERT OR IGNORE INTO accounts(group_id, external_ref, name) \
             VALUES ((SELECT id FROM account_groups WHERE name='G'), 'A1', 'Konto')",
            [],
        )
        .unwrap();
        c.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, checked, note) \
             VALUES ((SELECT id FROM accounts LIMIT 1), 'T1', '2024-01-01', -100, ?1, ?2)",
            params![checked, note],
        )
        .unwrap();
        if extra {
            c.execute("INSERT INTO categories(name) VALUES ('Food')", [])
                .unwrap();
            c.execute(
                "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents) \
                 VALUES ((SELECT id FROM accounts LIMIT 1), 'T2', '2024-01-02', -5)",
                [],
            )
            .unwrap();
        }
    }

    #[test]
    fn merges_without_duplicates() {
        let dir = std::env::temp_dir().join(format!("gc-merge-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let key = vec![7u8; 32];
        let a = Vault::open(dir.join("a.db").to_string_lossy().into(), key.clone()).unwrap();
        let b = Vault::open(dir.join("b.db").to_string_lossy().into(), key.clone()).unwrap();
        seed(&a, false, "", false);
        seed(&b, true, "hello", true);
        let st = a.merge_other_vault(b.file_path(), key.clone()).unwrap();
        assert_eq!(st.bookings_added, 1);
        assert_eq!(st.bookings_updated, 1);
        assert_eq!(st.categories_added, 1);
        assert_eq!(st.accounts_added, 0);
        let (n, checked, note): (i64, bool, String) = a
            .db()
            .unwrap()
            .query_row(
                "SELECT (SELECT count(*) FROM transactions), checked, note FROM transactions WHERE external_id='T1'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!((n, checked, note.as_str()), (2, true, "hello"));
        // idempotent
        let st2 = a.merge_other_vault(b.file_path(), key).unwrap();
        assert_eq!((st2.bookings_added, st2.bookings_updated), (0, 0));
        let _ = std::fs::remove_dir_all(dir);
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gc-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn path_in(dir: &std::path::Path, name: &str) -> String {
        dir.join(name).to_string_lossy().into()
    }

    fn count(v: &Vault, sql: &str) -> i64 {
        v.db().unwrap().query_row(sql, [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn merge_peer_snapshot_uses_own_key() {
        let dir = temp_dir("peer");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        let b = Vault::open(path_in(&dir, "b.db"), vec![7u8; 32]).unwrap();
        seed(&b, false, "", true);
        let st = a.merge_peer_snapshot(b.file_path()).unwrap();
        assert!(st.bookings_added >= 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn merge_peer_snapshot_rejects_other_key() {
        let dir = temp_dir("peer-key");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        let b = Vault::open(path_in(&dir, "b.db"), vec![8u8; 32]).unwrap();
        seed(&b, false, "", true);
        b.checkpoint().unwrap();
        assert!(matches!(
            a.merge_peer_snapshot(b.file_path()),
            Err(CoreError::WrongKey)
        ));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn write_snapshot_round_trips() {
        let dir = temp_dir("snap");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        seed(&a, true, "note", true);
        let snap = path_in(&dir, "snap.girocrab");
        a.write_snapshot(snap.clone()).unwrap();
        // a second write replaces the first
        a.write_snapshot(snap.clone()).unwrap();
        let s = Vault::open(snap, vec![7u8; 32]).unwrap();
        let q = "SELECT count(*) FROM transactions";
        assert_eq!(count(&s, q), count(&a, q));
        assert_eq!(count(&s, "PRAGMA user_version"), SCHEMA_VERSION);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn write_snapshot_is_consistent_during_writes() {
        let dir = temp_dir("snap-busy");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        seed(&a, false, "", false);
        let writer = {
            let a = a.clone();
            std::thread::spawn(move || {
                for i in 0..500 {
                    a.db()
                        .unwrap()
                        .execute(
                            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents) \
                             VALUES ((SELECT id FROM accounts LIMIT 1), ?1, '2024-02-01', -1)",
                            params![format!("W{i}")],
                        )
                        .unwrap();
                }
            })
        };
        for i in 0..5 {
            let snap = path_in(&dir, &format!("snap{i}.girocrab"));
            a.write_snapshot(snap.clone()).unwrap();
            let s = Vault::open(snap, vec![7u8; 32]).unwrap();
            let ok: String = s
                .db()
                .unwrap()
                .query_row("PRAGMA integrity_check", [], |r| r.get(0))
                .unwrap();
            assert_eq!(ok, "ok");
        }
        writer.join().unwrap();
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn change_count_moves_on_writes_only() {
        let dir = temp_dir("changes");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        let before = a.change_count();
        count(&a, "SELECT count(*) FROM transactions");
        assert_eq!(a.change_count(), before);
        seed(&a, false, "", false);
        assert!(a.change_count() > before);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn merge_reports_the_rows_it_changed() {
        let dir = temp_dir("merge-changes");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        let b = Vault::open(path_in(&dir, "b.db"), vec![7u8; 32]).unwrap();
        seed(&b, true, "hello", true);
        let before = a.change_count();
        let st = a.merge_peer_snapshot(b.file_path()).unwrap();
        assert!(st.changes > 0);
        assert_eq!(a.change_count() - before, st.changes);
        let again = a.merge_peer_snapshot(b.file_path()).unwrap();
        assert_eq!(again.changes, 0);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn rekey_updates_kept_key() {
        let dir = temp_dir("rekey");
        let a = Vault::open(path_in(&dir, "a.db"), vec![7u8; 32]).unwrap();
        seed(&a, false, "", false);
        a.rekey(vec![9u8; 32]).unwrap();
        let snap = path_in(&dir, "snap.girocrab");
        a.write_snapshot(snap.clone()).unwrap();
        assert!(Vault::open(snap.clone(), vec![7u8; 32]).is_err());
        assert!(Vault::open(snap, vec![9u8; 32]).is_ok());
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod expression_rule_tests {
    use super::*;

    #[test]
    fn expression_rules_round_trip_and_apply() {
        let p_dir = crate::test_support::TempDir::new("girocrab-expr");
        let p = p_dir.join("v.db");
        let v = Vault::open(p.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        let cat = {
            let c = v.db().unwrap();
            c.execute(
                "INSERT OR IGNORE INTO account_groups(name) VALUES ('G')",
                [],
            )
            .unwrap();
            c.execute(
                "INSERT INTO accounts(group_id, external_ref, name, iban) \
                 VALUES ((SELECT id FROM account_groups LIMIT 1), 'A1', 'Konto', 'DE02120300000000202051')",
                [],
            )
            .unwrap();
            c.execute("INSERT INTO categories(name) VALUES ('Lebensmittel')", [])
                .unwrap();
            for (ext, cp, amount) in [
                ("T1", "REWE Markt", -2350),
                ("T2", "REWE Markt", 500),
                ("T3", "Lidl", -100),
            ] {
                c.execute(
                    "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty) \
                     VALUES ((SELECT id FROM accounts LIMIT 1), ?1, '2026-01-02', ?2, ?3)",
                    params![ext, amount, cp],
                )
                .unwrap();
            }
            c.query_row(
                "SELECT id FROM categories WHERE name = 'Lebensmittel'",
                [],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
        };
        let rule = Rule {
            id: 0,
            name: "REWE".into(),
            category_id: cat,
            field: RuleField::Any,
            match_kind: MatchKind::Expression,
            pattern: "name:REWE AND amount<0 AND local_account:DE02*".into(),
            case_sensitive: false,
            min_amount_cents: None,
            max_amount_cents: None,
            account_id: None,
            priority: 0,
            enabled: true,
            match_count: 0,
        };
        let id = v.save_rule(rule.clone()).unwrap();
        let listed = v.list_rules().unwrap();
        let saved = listed.iter().find(|r| r.id == id).unwrap();
        assert_eq!(saved.match_kind, MatchKind::Expression);
        assert_eq!(v.preview_rule(rule.clone(), 10).unwrap().len(), 1);
        v.apply_rules(true).unwrap();
        let hits: i64 = v
            .db()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM transactions WHERE rule_id = ?1",
                [id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1, "only the REWE debit");
        let err = v.save_rule(Rule {
            pattern: "reference:X".into(),
            ..rule
        });
        assert!(err.is_err(), "unsupported field can't be saved");
        let _ = std::fs::remove_file(p);
    }
}

#[cfg(test)]
mod upgrade_tests {
    use super::*;

    /// A vault written before #35/#37/#57 (no bank codes, salary flag,
    /// recurring table or mirror column) opens, migrates and keeps its data.
    #[test]
    fn pre_feature_vault_is_migrated_in_place() {
        let dir = std::env::temp_dir().join(format!("gc-upgrade-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v.db").to_string_lossy().to_string();
        {
            let v = Vault::open(path.clone(), vec![2u8; 32]).unwrap();
            let c = v.db().unwrap();
            c.execute("INSERT INTO account_groups(name) VALUES ('G')", [])
                .unwrap();
            c.execute(
                "INSERT INTO accounts(group_id, external_ref, name) VALUES ((SELECT id FROM account_groups), 'A', 'Giro')",
                [],
            )
            .unwrap();
            c.execute(
                "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, purpose)
                 VALUES ((SELECT id FROM accounts), 'x', date('now','-3 days'), 250000, 'ACME', 'Gehalt')",
                [],
            )
            .unwrap();
            c.execute_batch(
                "DROP INDEX tx_salary_marked; -- (an old vault has neither the index nor its column)
                 ALTER TABLE transactions DROP COLUMN purpose_code;
                 ALTER TABLE transactions DROP COLUMN gvc;
                 ALTER TABLE transactions DROP COLUMN salary_flag;
                 ALTER TABLE booking_documents DROP COLUMN exported_at;
                 DROP TABLE recurring_series; DROP TABLE sync_log;
                 PRAGMA user_version = 8; -- written by a probe-based build (before #206)",
            )
            .unwrap();
        }
        let v = Vault::open(path, vec![2u8; 32]).unwrap();
        let cols: Vec<String> = {
            let c = v.db().unwrap();
            let mut st = c
                .prepare("SELECT name FROM pragma_table_info('transactions')")
                .unwrap();
            let names = st
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<Result<_, _>>()
                .unwrap();
            names
        };
        for col in ["purpose_code", "gvc", "salary_flag"] {
            assert!(cols.iter().any(|c| c == col), "{col} missing");
        }
        let page = v.list_transactions(BookingFilter::default()).unwrap();
        assert_eq!(page.transactions.len(), 1);
        assert!(page.transactions[0].is_salary);
        assert!(v.salary_cycle(vec![]).unwrap().is_some());
        assert!(v.list_recurring(vec![]).unwrap().is_empty());
        v.set_booking_salary_flag(page.transactions[0].id, Some(false))
            .unwrap();
        v.reset_document_mirror().unwrap();
        drop(v);
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod index_tests {
    use super::*;

    fn plan(db: &Connection, sql: &str) -> String {
        db.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
            .unwrap()
            .query_map([], |r| r.get::<_, String>(3))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
            .join(" | ")
    }

    /// The queries every reload runs use their indexes (shapes as in
    /// `list_transactions`, `list_accounts` and `marked_salary_ibans`).
    #[test]
    fn reload_queries_use_their_indexes() {
        let path_dir = crate::test_support::TempDir::new("gc-index");
        let path = path_dir.join("v.db");
        let v = Vault::open(path.to_string_lossy().into(), vec![4u8; 32]).unwrap();
        let db = v.db().unwrap();
        // booking list: in index order, no sorting afterwards
        let p = plan(
            &db,
            "SELECT t.id FROM transactions t JOIN accounts a ON a.id = t.account_id
             LEFT JOIN categories cat ON cat.id = t.category_id
             WHERE 1=1 ORDER BY t.booking_date DESC, t.id DESC",
        );
        assert!(
            p.contains("tx_date_id") && !p.contains("TEMP B-TREE"),
            "{p}"
        );
        // sidebar counters: from the index, without reading the bookings
        for (cond, index) in [
            (
                "t.category_id IS NULL",
                "COVERING INDEX tx_account_category",
            ),
            ("t.checked = 0", "COVERING INDEX tx_account_checked"),
        ] {
            let p = plan(
                &db,
                &format!("SELECT count(*) FROM transactions t WHERE t.account_id = 1 AND {cond}"),
            );
            assert!(p.contains(index), "{p}");
        }
        let p = plan(
            &db,
            "SELECT DISTINCT counterparty_iban FROM transactions
             WHERE salary_flag = 1 AND counterparty_iban != '' AND amount_cents > 0",
        );
        assert!(p.contains("tx_salary_marked"), "{p}");
        // the superseded index is gone, also in vaults that had it
        let old: i64 = db
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE name = 'tx_date'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(old, 0);
        drop(db);
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod paging_tests {
    use super::*;

    fn demo() -> (Arc<Vault>, std::path::PathBuf) {
        let p = std::env::temp_dir().join(format!("girocrab-page-{}.db", uuid::Uuid::new_v4()));
        let v = Vault::open(p.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        (v, p)
    }

    #[test]
    fn whole_day_pages_never_split_a_day_and_add_up() {
        let (v, p) = demo();
        let all = v
            .list_transactions(BookingFilter::default())
            .unwrap()
            .transactions;
        assert!(all.len() > 40);
        let mut loaded: Vec<Booking> = Vec::new();
        let mut pages = 0;
        while loaded.len() < all.len() {
            let page = v
                .list_transactions(BookingFilter {
                    limit: 7,
                    offset: loaded.len() as u32,
                    whole_days: true,
                    ..Default::default()
                })
                .unwrap();
            assert_eq!(page.total_count as usize, all.len());
            assert!(
                page.transactions.len() >= 7 || loaded.len() + page.transactions.len() == all.len()
            );
            loaded.extend(page.transactions);
            // the next booking, if any, belongs to another day
            if let Some(next) = all.get(loaded.len()) {
                assert_ne!(next.booking_date, loaded.last().unwrap().booking_date);
            }
            pages += 1;
            assert!(pages < 1000);
        }
        let ids = |l: &[Booking]| l.iter().map(|b| b.id).collect::<Vec<_>>();
        assert_eq!(ids(&loaded), ids(&all));
        // without the flag the limit is exact
        let exact = v
            .list_transactions(BookingFilter {
                limit: 7,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(exact.transactions.len(), 7);
        // an offset behind the end is an empty page, not an error
        let past = v
            .list_transactions(BookingFilter {
                limit: 7,
                offset: all.len() as u32 + 5,
                whole_days: true,
                ..Default::default()
            })
            .unwrap();
        assert!(past.transactions.is_empty());
        let _ = std::fs::remove_file(p);
    }

    #[test]
    fn checked_filter_selects_new_or_checked_bookings() {
        let (v, p) = demo();
        let all = v
            .list_transactions(BookingFilter::default())
            .unwrap()
            .transactions;
        let first = all.first().unwrap();
        assert_eq!(
            v.booking_date(first.id).unwrap().as_deref(),
            Some(first.booking_date.as_str())
        );
        assert_eq!(v.booking_date(-1).unwrap(), None);
        let pick = all.iter().find(|b| !b.checked).expect("a new booking").id;
        v.set_transaction_checked(pick, true).unwrap();
        let of = |checked: Option<bool>| {
            v.list_transactions(BookingFilter {
                checked,
                ..Default::default()
            })
            .unwrap()
        };
        let (new, done) = (of(Some(false)), of(Some(true)));
        assert!(new.transactions.iter().all(|b| !b.checked));
        assert!(done.transactions.iter().all(|b| b.checked));
        assert!(done.transactions.iter().any(|b| b.id == pick));
        assert_eq!(
            new.total_count + done.total_count,
            of(None).total_count,
            "the count follows the filter"
        );
        let _ = std::fs::remove_file(p);
    }
}
