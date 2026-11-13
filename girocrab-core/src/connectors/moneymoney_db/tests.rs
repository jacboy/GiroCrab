//! Tests with fake MoneyMoney databases (real column layout, invented data,
//! SQLCipher-encrypted with a test password).

use super::*;
use crate::models::{BookingFilter, CategorySource, MatchKind};
use std::path::PathBuf;
use std::sync::Arc;

pub(crate) const PW: &str = "Test-Passwort 'mit' Anführungszeichen";

/// The relevant MoneyMoney tables with their real columns.
const SCHEMA: &str = r#"
CREATE TABLE account_groups (rowid INTEGER PRIMARY KEY, name TEXT, perspective TEXT, group_key INTEGER, sort INTEGER, icon TEXT, expanded INTEGER, sidebar INTEGER, userdata BLOB);
CREATE TABLE accounts (rowid INTEGER PRIMARY KEY, bank_key INTEGER, account TEXT, subaccount TEXT, bankcode TEXT, portfolio INTEGER, iban TEXT, bic TEXT, currency TEXT, name TEXT, owner TEXT, kind INTEGER, type INTEGER, sort INTEGER, icon TEXT, balances BLOB, pending_balances BLOB, overdraft_limit REAL, available_funds REAL, initial_balance REAL, cub INTEGER, cub_tsp INTEGER, recipient_key INTEGER, refresh_tsp INTEGER, balance_tsp INTEGER, transaction_tsp INTEGER, payment_tsp INTEGER, error_tsp INTEGER, cancel_tsp INTEGER, statements INTEGER, refresh_actions INTEGER, refresh INTEGER, userdata BLOB, cred TEXT, transientdata BLOB, perspective TEXT, group_key INTEGER, error TEXT, web_ops BLOB);
CREATE TABLE balances (account_key INTEGER, currency TEXT, timestamp INTEGER, initial_balance REAL, PRIMARY KEY (account_key, currency, timestamp DESC));
CREATE TABLE banks (rowid INTEGER PRIMARY KEY, country TEXT, bankcode TEXT, username TEXT, customer TEXT, credential TEXT, name TEXT, server TEXT, protocol REAL, tanmethod TEXT, tanmedium TEXT, systemid TEXT, tanmethods TEXT, bpd BLOB, upd BLOB, spa INTEGER, spa_tsp INTEGER, local_storage TEXT, pubkey BLOB, privkey BLOB, userdata BLOB);
CREATE TABLE categories (rowid INTEGER PRIMARY KEY, name TEXT, type INTEGER, perspective TEXT, group_key INTEGER, sort INTEGER, color TEXT, rules TEXT, apply_to_account TEXT, currency TEXT, is_valid_sum INTEGER, userdata BLOB);
CREATE TABLE category_groups (rowid INTEGER PRIMARY KEY, name TEXT, perspective TEXT, group_key INTEGER, sort INTEGER, color TEXT, expanded INTEGER, currency TEXT, userdata BLOB);
CREATE TABLE pins (bank_key INTEGER PRIMARY KEY, pin TEXT);
CREATE TABLE recipients (local_account_key INTEGER, name TEXT, owner TEXT, account TEXT, subaccount TEXT, bankcode TEXT, iban TEXT, bic TEXT, type INTEGER);
CREATE TABLE securities (rowid INTEGER PRIMARY KEY, account_key INTEGER, ident TEXT, isin TEXT, wpn TEXT, symbol TEXT, quantity REAL, quantity_cur TEXT, amount REAL, amount_cur TEXT, ocmt REAL, ocmt_cur TEXT, purchase REAL, purchase_cur TEXT, price REAL, price_cur TEXT, exch REAL, trade_date INTEGER, trade_tsp INTEGER, purchase_tsp INTEGER, market TEXT, comment TEXT, userdata BLOB, visited INTEGER, deleted INTEGER, asset_class INTEGER);
CREATE TABLE statements (rowid INTEGER PRIMARY KEY, account_key INTEGER, name TEXT, directory TEXT, filename TEXT, created_tsp INTEGER, fetched_tsp INTEGER, orderid INTEGER, userorder INTEGER, imported INTEGER, visited INTEGER, deleted INTEGER, number TEXT, year TEXT, identifier BLOB, digest TEXT);
CREATE TABLE transactions (rowid INTEGER PRIMARY KEY, local_account_key INTEGER, account TEXT, bankcode TEXT, amount REAL, currency TEXT, timestamp INTEGER, value_timestamp INTEGER, pn TEXT, eref TEXT, mref TEXT, kref TEXT, cred TEXT, dept TEXT, rtcd TEXT, rtrn TEXT, ocmt REAL, ocmt_cur TEXT, chgs REAL, chgs_cur TEXT, coam REAL, coam_cur TEXT, oamt REAL, oamt_cur TEXT, exch REAL, abwe TEXT, abwa TEXT, seq TEXT, comment TEXT, attachment TEXT, booked INTEGER, nopretty INTEGER, unformatted_type TEXT, unformatted_name TEXT, unformatted_purpose TEXT, identifier TEXT, name TEXT, a1490107618 TEXT, visited INTEGER, checkmark INTEGER, splitted INTEGER, split_key INTEGER, reverse_key INTEGER, category_key INTEGER);
"#;

// Invented data only (public example IBANs, fictional names).
const DATA: &str = r#"
INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
  (1, 'DE', '20041111', '1234567', '1234567', 'GEHEIM-1', 'comdirect', 'SYS', 'LS'),
  (2, 'DE', '52090000', 'VRNK4711', 'VRNK4711', 'GEHEIM-2', 'Volksbank Kassel Göttingen', 'SYS', 'LS'),
  (3, 'DE', '12345678', 'max.m', '', 'GEHEIM-3', 'Sparkasse Musterstadt', 'SYS', 'LS');
INSERT INTO pins (bank_key, pin) VALUES (1, '11111'), (2, '22222'), (3, '33333');
INSERT INTO account_groups (rowid, name, group_key, sort) VALUES (1, 'Privat', 0, 1);
INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred) VALUES
  (1, 1, '0532013000', '20041111', 0, 'DE89 3704 0044 0532 0130 00', 'EUR', 'Girokonto', 'Max Mustermann', 0, 0, 1, 50.0, 1, 'GEHEIM'),
  (2, 1, '4711', '20041111', 0, '', 'EUR', 'Visa-Karte', 'Max Mustermann', 0, 3, 2, 0, 1, 'GEHEIM'),
  (3, 1, '9999', '20041111', 1, '', 'EUR', 'Depot', 'Max Mustermann', 0, 7, 3, 0, 0, 'GEHEIM'),
  (4, 3, '1000', '12345678', 0, '', 'USD', 'Dollar-Konto', 'Max Mustermann', 0, 0, 4, 10.5, 0, 'GEHEIM');
INSERT INTO balances (account_key, currency, timestamp, initial_balance) VALUES
  (1, 'EUR', 1104580800, 80.0),
  (1, 'EUR', 1577880000, 100.0);
INSERT INTO category_groups (rowid, name, group_key, sort) VALUES
  (1, 'Haushalt', 0, 1), (2, 'Wohnen', 0, 2), (3, 'Nebenkosten', 2, 1);
INSERT INTO categories (rowid, name, type, group_key, sort) VALUES
  (1, '', 0, 0, 0),
  (2, 'Supermarkt', 1, 1, 1),
  (3, 'Gehalt', 1, 0, 2),
  (4, 'Strom', 1, 3, 1),
  (5, 'Steuern / Büro', 1, 0, 3);
INSERT INTO transactions (rowid, local_account_key, account, bankcode, amount, currency, timestamp, value_timestamp, pn, eref, mref, cred, comment, booked, unformatted_type, unformatted_purpose, name, checkmark, splitted, split_key, category_key) VALUES
  (1, 1, 'DE02120300000000202051', 'BYLADEM1001', 2500.0, 'EUR', 1104580800, 1104580800, 'X', '', '', '', 'erstes Gehalt', 1, 'GUTSCHRIFT', 'Gehalt Januar', 'Arbeitgeber GmbH', 1, 0, 1, 3),
  (2, 1, 'DE02100100100006820101', 'PBNKDEFFXXX', -45.67, 'EUR', 1772712000, 1772712000, '', 'E2E-1', 'MANDAT-1', 'DE98ZZZ09999999999', '', 1, 'LASTSCHRIFT', 'Einkauf Filiale 12', 'REWE Markt', 0, 0, 2, 2),
  (3, 1, '12345', '10010010', -12.3, 'EUR', 1772798400, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Brötchen', 'Bäckerei Schmidt', 0, 0, 3, 1),
  (4, 1, '', '', -9.99, 'EUR', 1772971200, 0, '', '', '', '', '', 0, 'VORMERKUNG', 'Vorgemerkt', 'Streaming AG', 0, 0, 4, 1),
  (5, 1, '', '', -100.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf', 'Kaufhaus Muster', 0, 1, 5, 1),
  (6, 1, '', '', -60.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf Lebensmittel', 'Kaufhaus Muster', 0, 0, 5, 2),
  (7, 1, '', '', -40.0, 'EUR', 1772884800, 0, '', '', '', '', '', 1, 'KARTENZAHLUNG', 'Einkauf Lampe', 'Kaufhaus Muster', 0, 0, 5, 4),
  (8, 2, '', '', -19.99, 'EUR', 1709208000, 0, '', '', '', '', 'Abo kündigen', 1, 'KARTENZAHLUNG', 'Monatsabo', 'Streaming AG', 0, 0, 8, 5),
  (9, 4, '', '', 25.255, 'USD', 1772712000, 0, '', '', '', '', '', 1, 'GUTSCHRIFT', 'Dividende', 'Muster Inc', 0, 0, 9, 1);
INSERT INTO recipients (local_account_key, name, iban) VALUES (1, 'Erika Mustermann', 'DE02120300000000202051');
-- Depot: balance only in the displayed-balance blob, positions in securities (one sold)
UPDATE accounts SET balances = CAST('12:12345.670000,3:EUR,' AS BLOB), balance_tsp = 1772884800 WHERE rowid = 3;
INSERT INTO securities (rowid, account_key, ident, isin, wpn, quantity, amount, amount_cur, purchase, price, trade_date, deleted) VALUES
  (1, 3, 'Muster World ETF', 'IE00B4L5Y983', 'A0RPWH', 12.5, 1000.0, 'EUR', 70.0, 80.0, 1772884800, 0),
  (2, 3, 'Liquidität', '', '', NULL, 345.67, 'EUR', NULL, NULL, 1772884800, 0),
  (3, 3, 'Verkauft AG', 'DE0000000001', '', 1, 1, 'EUR', 1, 1, 1772884800, 1);
"#;

fn temp(name: &str) -> PathBuf {
    crate::test_support::thread_temp_path(&format!("mmdb-{name}"))
}

fn fake_db_with(compat3: bool, extra: &str) -> String {
    let path = temp("src.sqlite");
    let c = Connection::open(&path).unwrap();
    c.execute_batch(&format!("PRAGMA key = '{}';", PW.replace('\'', "''")))
        .unwrap();
    if compat3 {
        c.execute_batch("PRAGMA cipher_compatibility = 3;").unwrap();
    }
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(DATA).unwrap();
    c.execute_batch(extra).unwrap();
    path.to_string_lossy().to_string()
}

fn fake_db_unencrypted() -> String {
    let path = temp("plain-src.sqlite");
    let c = Connection::open(&path).unwrap();
    c.execute_batch(SCHEMA).unwrap();
    c.execute_batch(DATA).unwrap();
    path.to_string_lossy().to_string()
}

pub(crate) fn fake_db() -> String {
    fake_db_with(false, "")
}

fn vault() -> Arc<Vault> {
    Vault::open(
        temp("vault.db").to_string_lossy().to_string(),
        vec![7u8; 32],
    )
    .unwrap()
}

/// Options as the UI would send them: every account, suggested kind and target.
pub(crate) fn options_from(
    p: &MoneyMoneyDbPreview,
    connections: bool,
    pins: bool,
) -> MoneyMoneyDbImportOptions {
    MoneyMoneyDbImportOptions {
        accounts: p
            .accounts
            .iter()
            .map(|a| MoneyMoneyDbAccountChoice {
                mm_id: a.mm_id,
                import: true,
                kind: a.suggested_kind,
                target_account_id: a.existing_account_id,
            })
            .collect(),
        import_categories: true,
        import_notes: true,
        create_connections: connections,
        import_pins: pins,
        import_groups: true,
        import_statements: true,
        statements_dir: None,
        bank_choices: vec![],
    }
}

/// The Enable Banking option the preview offers for a bank, if any.
fn eb_option(p: &MoneyMoneyDbPreview, bank: i64) -> Option<MoneyMoneyDbConnectionOption> {
    p.banks
        .iter()
        .find(|b| b.mm_id == bank)?
        .connection_options
        .iter()
        .find(|o| o.via == MoneyMoneyDbConnectionVia::EnableBanking)
        .cloned()
}

fn bookings(v: &Vault, account_id: i64) -> Vec<crate::models::Booking> {
    v.list_transactions(BookingFilter {
        account_ids: vec![account_id],
        ..Default::default()
    })
    .unwrap()
    .transactions
}

fn account_by_name(v: &Vault, name: &str) -> crate::models::Account {
    v.list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.name == name)
        .unwrap()
}

#[test]
fn amount_and_date_conversion_edge_cases() {
    assert_eq!(real_to_cents(1234.56), Some(123_456));
    assert_eq!(real_to_cents(-45.67), Some(-4567));
    assert_eq!(real_to_cents(0.285), Some(29)); // (0.285 * 100.0).round() would give 28
    assert_eq!(real_to_cents(-0.285), Some(-29));
    assert_eq!(real_to_cents(0.1 + 0.2), Some(30));
    assert_eq!(real_to_cents(-0.004), Some(0));
    assert_eq!(real_to_cents(-0.005), Some(-1));
    assert_eq!(real_to_cents(1e-9), Some(0));
    assert_eq!(real_to_cents(99_999_999.99), Some(9_999_999_999));
    assert_eq!(real_to_cents(f64::NAN), None);
    assert_eq!(real_to_cents(f64::INFINITY), None);
    assert_eq!(unix_to_date(1104580800).as_deref(), Some("2005-01-01"));
    assert_eq!(unix_to_date(1709208000).as_deref(), Some("2024-02-29"));
    // 12:00 UTC is the convention; the whole UTC day maps to the same date
    assert_eq!(
        unix_to_date(1104580800 - 12 * 3600).as_deref(),
        Some("2005-01-01")
    );
    assert_eq!(
        unix_to_date(1104580800 + 12 * 3600 - 1).as_deref(),
        Some("2005-01-01")
    );
    assert_eq!(unix_to_date(0).as_deref(), Some("1970-01-01"));
}

#[test]
fn wrong_password_and_missing_file() {
    let path = fake_db();
    let v = vault();
    let err = v
        .preview_moneymoney_database(path.clone(), "falsch".into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
    assert!(err.to_string().contains("Falsches Passwort"));
    assert!(!err.to_string().contains("falsch\""));
    let err = v
        .preview_moneymoney_database(path, String::new(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
    let err = v
        .preview_moneymoney_database("/nonexistent/MoneyMoney.sqlite".into(), PW.into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::NotFound { .. }));
    // an unencrypted SQLite file that is not MoneyMoney's
    let plain = temp("plain.sqlite");
    Connection::open(&plain)
        .unwrap()
        .execute_batch("CREATE TABLE x (a);")
        .unwrap();
    let err = v
        .preview_moneymoney_database(plain.to_string_lossy().to_string(), PW.into(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
}

#[test]
fn unencrypted_database_opens_with_empty_password() {
    let path = fake_db_unencrypted();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), String::new(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
    // a password typed for an unencrypted file is ignored, not "wrong"
    let p = v
        .preview_moneymoney_database(path, PW.into(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
}

#[test]
fn encrypted_database_without_password_explains_moneymoney_key() {
    // MoneyMoney encrypts with a key of its own when no database password
    // is set; an empty password must say so instead of "wrong password".
    let enc = fake_db();
    let err = vault()
        .preview_moneymoney_database(enc, String::new(), None)
        .unwrap_err();
    assert!(matches!(err, CoreError::Authentication { .. }));
    let msg = err.to_string();
    assert!(msg.contains("Einstellungen → Sicherheit"), "{msg}");
    assert!(!msg.contains("Falsches Passwort"), "{msg}");
}

#[test]
fn plain_sqlite_header_detection() {
    let plain = fake_db_unencrypted();
    assert!(is_plain_sqlite(&plain));
    assert!(!is_plain_sqlite(&fake_db()));
    // too short / missing files are not plain SQLite
    let short = temp("short.sqlite");
    std::fs::write(&short, b"SQLite").unwrap();
    assert!(!is_plain_sqlite(&short.to_string_lossy()));
    assert!(!is_plain_sqlite("/nonexistent/MoneyMoney.sqlite"));
}

#[test]
fn older_cipher_compatibility_3_opens() {
    let path = fake_db_with(true, "");
    let p = vault()
        .preview_moneymoney_database(path, PW.into(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
}

#[test]
fn source_file_bytes_unchanged_after_preview_and_import() {
    let path = fake_db();
    let before = std::fs::read(&path).unwrap();
    let modified = std::fs::metadata(&path).unwrap().modified().unwrap();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), before);
    assert_eq!(
        std::fs::metadata(&path).unwrap().modified().unwrap(),
        modified
    );
    // and the connection really is read-only
    let c = open_source(&path, &SecretString::new(PW.into())).unwrap();
    assert!(c.execute("DELETE FROM pins", []).is_err());
}

#[test]
fn preview_lists_accounts_banks_categories_and_totals() {
    let v = vault();
    let p = v
        .preview_moneymoney_database(fake_db(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.mm_id == 1).unwrap();
    assert_eq!(giro.iban, "DE89370400440532013000");
    assert_eq!(giro.group_name, "Privat");
    assert_eq!(giro.bank_name, "comdirect");
    assert_eq!(giro.suggested_kind, AccountKind::Checking);
    // 5 = salary, REWE, bakery, 2 split parts (parent + pending not counted)
    assert_eq!((giro.booking_count, giro.pending_count), (5, 1));
    assert_eq!(giro.first_date.as_deref(), Some("2005-01-01"));
    assert_eq!(giro.last_date.as_deref(), Some("2026-03-07"));
    // newest `balances` row (100,00, 2020-01-01) + booked bookings from that
    // date on (parent, not parts); the 2005 salary is part of the initial balance
    assert_eq!(giro.computed_balance_cents, 10_000 - 4567 - 1230 - 10_000);
    assert!(giro.balance_source.contains("Saldenverlauf"));
    let kind = |id: i64| {
        p.accounts
            .iter()
            .find(|a| a.mm_id == id)
            .unwrap()
            .suggested_kind
    };
    assert_eq!(kind(2), AccountKind::CreditCard);
    assert_eq!(kind(3), AccountKind::Brokerage);
    let usd = p.accounts.iter().find(|a| a.mm_id == 4).unwrap();
    assert_eq!(usd.currency, "USD");
    // accounts.initial_balance (10,50) + 25,255 → 25,26
    assert_eq!(usd.computed_balance_cents, 1050 + 2526);
    assert_eq!(
        p.category_paths,
        vec![
            "Gehalt",
            "Steuern / Büro",
            "Haushalt › Supermarkt",
            "Wohnen › Nebenkosten › Strom"
        ]
    );
    assert_eq!(
        (p.total_bookings, p.pending_bookings, p.split_parts),
        (7, 1, 2)
    );
    assert_eq!(p.notes_count, 2);
    assert_eq!(p.date_range_start.as_deref(), Some("2005-01-01"));
    let bank = |id: i64| p.banks.iter().find(|b| b.mm_id == id).unwrap();
    assert_eq!(bank(1).connector, Some(ConnectorKind::Comdirect));
    assert_eq!(bank(1).login_name, "1234567");
    assert_eq!(
        bank(2).connector,
        Some(ConnectorKind::VolksbankKasselGoettingen)
    );
    assert_eq!(bank(3).connector, None);
    assert!(bank(1).has_saved_pin);
    assert_eq!(bank(1).account_count, 3);
    // the preview never stores anything
    assert!(v.list_accounts().unwrap().is_empty());
    assert!(v.list_bank_connections().unwrap().is_empty());
}

#[test]
fn import_categories_splits_pending_notes_and_balance() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.accounts_created, r.accounts_merged), (4, 0));
    assert_eq!(
        (r.bookings_new, r.bookings_duplicates, r.pending_skipped),
        (7, 0, 1)
    );
    assert_eq!(r.notes_imported, 2);
    // Haushalt, Supermarkt, Gehalt, Wohnen, Nebenkosten, Strom, Steuern / Büro
    assert_eq!(r.categories_created, 7);
    assert_eq!(r.connections_created, 0);

    let giro = account_by_name(&v, "Girokonto");
    assert_eq!(giro.iban, "DE89370400440532013000");
    assert_eq!(giro.bank_name, "comdirect");
    assert_eq!(giro.balance_cents, 10_000 - 4567 - 1230 - 10_000);
    assert_eq!(giro.balance_date, "2026-03-07");
    let bs = bookings(&v, giro.id);
    assert_eq!(bs.len(), 5);
    let find = |name: &str, cents: i64| {
        bs.iter()
            .find(|b| b.counterparty == name && b.amount_cents == cents)
            .unwrap_or_else(|| panic!("{name} {cents}"))
    };
    // grouped category path
    let rewe = find("REWE Markt", -4567);
    assert_eq!(rewe.category_path, "Haushalt › Supermarkt");
    assert_eq!(rewe.counterparty_iban, "DE02100100100006820101");
    assert_eq!(rewe.booking_text, "LASTSCHRIFT");
    assert!(rewe.purpose.starts_with("Einkauf Filiale 12"));
    assert!(rewe.purpose.contains("MREF: MANDAT-1"));
    assert!(rewe.purpose.contains("CRED: DE98ZZZ09999999999"));
    assert!(rewe.purpose.contains("EREF: E2E-1"));
    assert_eq!(rewe.booking_date, "2026-03-05");
    // uncategorised in MoneyMoney → no MoneyMoney category
    let bakery = find("Bäckerei Schmidt", -1230);
    assert_ne!(bakery.category_source, CategorySource::Manual);
    assert_eq!(bakery.counterparty_iban, ""); // "12345" is no IBAN
    assert_eq!(bakery.value_date, "");
    // note
    let salary = find("Arbeitgeber GmbH", 250_000);
    assert_eq!(salary.note, "erstes Gehalt");
    assert_eq!(salary.category_path, "Gehalt");
    assert_eq!(salary.booking_date, "2005-01-01");
    // splits: parts with own categories, parent not imported
    assert_eq!(
        find("Kaufhaus Muster", -6000).category_path,
        "Haushalt › Supermarkt"
    );
    assert_eq!(
        find("Kaufhaus Muster", -4000).category_path,
        "Wohnen › Nebenkosten › Strom"
    );
    assert!(!bs.iter().any(|b| b.amount_cents == -10_000));
    // pending not imported
    assert!(!bs.iter().any(|b| b.counterparty == "Streaming AG"));

    // category name containing " / " stays one category
    let visa = account_by_name(&v, "Visa-Karte");
    assert_eq!(visa.kind, AccountKind::CreditCard);
    let vb = bookings(&v, visa.id);
    assert_eq!(vb[0].category_path, "Steuern / Büro");
    assert_eq!(vb[0].note, "Abo kündigen");
    let groups = v.list_account_groups().unwrap();
    assert!(groups
        .iter()
        .any(|g| g.name == "Kreditkarten" && g.accounts.iter().any(|a| a.id == visa.id)));
    assert!(groups
        .iter()
        .any(|g| g.name == "Depots & ETFs" && g.accounts.iter().any(|a| a.name == "Depot")));
    let usd = account_by_name(&v, "Dollar-Konto");
    assert_eq!(usd.currency, "USD");
    assert_eq!(bookings(&v, usd.id)[0].amount_cents, 2526);

    // #212: MoneyMoney's opening balances carry over and keep driving the balance
    assert!(giro.balance_derived);
    assert_eq!(
        (
            giro.opening_balance_cents,
            giro.opening_balance_date.as_str()
        ),
        (Some(10_000), "2020-01-01")
    );
    assert_eq!(
        (usd.opening_balance_cents, usd.opening_balance_date.as_str()),
        (Some(1050), "")
    );
    assert_eq!(usd.balance_cents, 1050 + 2526);
    assert_eq!(visa.opening_balance_cents, None);
    assert_eq!(account_by_name(&v, "Depot").opening_balance_cents, None);
    v.calibrate_account_opening_balance(giro.id, 0).unwrap();
    let giro = account_by_name(&v, "Girokonto");
    assert_eq!(giro.opening_balance_cents, Some(4567 + 1230 + 10_000));
    assert_eq!(giro.balance_cents, 0);
}

#[test]
fn reimport_is_idempotent() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let first = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, true))
        .unwrap();
    let count = |v: &Vault| {
        let db = v.db().unwrap();
        let q = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        (
            q("SELECT count(*) FROM accounts"),
            q("SELECT count(*) FROM transactions"),
            q("SELECT count(*) FROM categories"),
            q("SELECT count(*) FROM bank_connections"),
            q("SELECT count(*) FROM settings WHERE key LIKE 'pin.conn.%'"),
        )
    };
    let after_first = count(&v);
    // second run with the options a fresh preview suggests …
    let p2 = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p2.accounts.iter().all(|a| a.existing_account_id.is_some()));
    assert!(p2.banks[..2]
        .iter()
        .all(|b| b.existing_connection_id.is_some()));
    let second = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p2, true, true))
        .unwrap();
    // … and a third one that still says "new account" everywhere
    let third = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .unwrap();
    for r in [&second, &third] {
        assert_eq!((r.accounts_created, r.accounts_merged), (0, 4));
        assert_eq!(
            (r.bookings_new, r.bookings_duplicates),
            (0, first.bookings_new)
        );
        assert_eq!((r.categories_created, r.connections_created), (0, 0));
        assert_eq!((r.connections_existing, r.pins_stored), (2, 0));
    }
    assert_eq!(count(&v), after_first);
    assert_eq!(
        account_by_name(&v, "Girokonto").balance_cents,
        10_000 - 4567 - 1230 - 10_000
    );
}

#[test]
fn iban_match_merges_into_existing_synced_account() {
    let v = vault();
    let conn_id = v
        .add_bank_connection(
            ConnectorKind::Comdirect,
            "comdirect".into(),
            "1234567".into(),
        )
        .unwrap();
    let existing = {
        let db = v.db().unwrap();
        let gid = Vault::ensure_group(&db, "Giro & Tagesgeld", "building.columns", 1).unwrap();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, iban, currency, kind, balance_cents)
             VALUES (?1, ?2, 'abc-123', 'Mein Giro', 'DE89 3704 0044 0532 0130 00', 'EUR', 'checking', 123456)",
            params![conn_id, gid],
        )
        .unwrap();
        let id = db.last_insert_rowid();
        // already fetched by the bank: the REWE booking without category
        db.execute(
            "INSERT INTO transactions(account_id, external_id, booking_date, amount_cents, counterparty, counterparty_iban, purpose)
             VALUES (?1, 'bank-1', '2026-03-05', -4567, 'REWE Markt', 'DE02100100100006820101', 'Einkauf Filiale 12')",
            [id],
        )
        .unwrap();
        id
    };
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.mm_id == 1).unwrap();
    assert_eq!(giro.existing_account_id, Some(existing));
    assert_eq!(giro.existing_account_name.as_deref(), Some("Mein Giro"));
    assert_eq!(p.banks[0].existing_connection_id, Some(conn_id));
    let mut o = options_from(&p, true, false);
    o.accounts.retain(|c| c.mm_id == 1);
    let r = v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!((r.accounts_created, r.accounts_merged), (0, 1));
    assert_eq!(
        (r.bookings_new, r.bookings_duplicates, r.bookings_enriched),
        (4, 1, 1)
    );
    assert_eq!((r.connections_created, r.connections_existing), (1, 1));
    let acc = v
        .list_accounts()
        .unwrap()
        .into_iter()
        .find(|a| a.id == existing)
        .unwrap();
    // the bank's balance stays authoritative for synced accounts
    assert_eq!(acc.balance_cents, 123_456);
    assert_eq!(acc.name, "Mein Giro");
    let bs = bookings(&v, existing);
    assert_eq!(bs.len(), 5);
    let rewe = bs.iter().find(|b| b.counterparty == "REWE Markt").unwrap();
    assert_eq!(rewe.category_path, "Haushalt › Supermarkt");
    assert_eq!(v.list_accounts().unwrap().len(), 1);
}

#[test]
fn first_bank_sync_adopts_imported_account_by_iban() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let giro = account_by_name(&v, "Girokonto");
    let conn_id = v.list_bank_connections().unwrap()[0].id;
    let db = v.db().unwrap();
    assert_eq!(
        adopt_account(&db, conn_id, "remote-1", "", "", AccountKind::Checking).unwrap(),
        None
    );
    let adopted = adopt_account(
        &db,
        conn_id,
        "remote-1",
        "DE89 3704 0044 0532 0130 00",
        "",
        AccountKind::Checking,
    )
    .unwrap();
    assert_eq!(adopted, Some(giro.id));
    let (c, e): (Option<i64>, String) = db
        .query_row(
            "SELECT connection_id, external_ref FROM accounts WHERE id = ?1",
            [giro.id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    assert_eq!((c, e.as_str()), (Some(conn_id), "remote-1"));
    // only once
    assert_eq!(
        adopt_account(
            &db,
            conn_id,
            "remote-2",
            "DE89370400440532013000",
            "",
            AccountKind::Checking
        )
        .unwrap(),
        None
    );
}

#[test]
fn adopting_wallets_sharing_an_iban_follows_the_currency() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let conn_id = v.list_bank_connections().unwrap()[0].id;
    let db = v.db().unwrap();
    // two imported wallets under one IBAN, the USD one imported first
    let mut ids = Vec::new();
    for (n, cur) in [("1", "USD"), ("2", "EUR")] {
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, iban, currency)
             VALUES ((SELECT id FROM account_groups LIMIT 1), ?1, 'Wallet', 'GB51TCCL00000000000001', ?2)",
            params![format!("moneymoney-db:w{n}"), cur],
        )
        .unwrap();
        ids.push(db.last_insert_rowid());
    }
    let (usd, eur) = (ids[0], ids[1]);
    let iban = "GB51 TCCL 0000 0000 0000 01";
    assert_eq!(
        adopt_account(&db, conn_id, "w:EUR", iban, "EUR", AccountKind::Checking).unwrap(),
        Some(eur)
    );
    assert_eq!(
        adopt_account(&db, conn_id, "w:USD", iban, "USD", AccountKind::Checking).unwrap(),
        Some(usd)
    );
    // a third currency finds no wallet to take over
    assert_eq!(
        adopt_account(&db, conn_id, "w:GBP", iban, "GBP", AccountKind::Checking).unwrap(),
        None
    );
}

#[test]
fn connections_for_supported_banks_only_and_pins_on_request() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    // without import_pins: connections, but no PIN
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, false))
        .unwrap();
    assert_eq!(
        (
            r.connections_created,
            r.banks_skipped_unsupported,
            r.pins_stored
        ),
        (2, 1, 0)
    );
    let conns = v.list_bank_connections().unwrap();
    assert_eq!(conns.len(), 2);
    let comdirect = conns
        .iter()
        .find(|c| c.connector == ConnectorKind::Comdirect)
        .unwrap();
    assert_eq!(comdirect.login_name, "1234567");
    let vb = conns
        .iter()
        .find(|c| c.connector == ConnectorKind::VolksbankKasselGoettingen)
        .unwrap();
    assert_eq!(vb.login_name, "VRNK4711");
    for c in &conns {
        assert!(!v.connection_status(c.id).unwrap().has_pin);
    }
    // with import_pins: stored for the supported banks only
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .unwrap();
    assert_eq!((r.connections_created, r.pins_stored), (0, 2));
    let db = v.db().unwrap();
    let pin = |id: i64| -> String {
        db.query_row(
            "SELECT value FROM settings WHERE key = ?1 AND is_secret = 1",
            [crate::connections::pin_key(id)],
            |r| r.get(0),
        )
        .unwrap()
    };
    assert_eq!(pin(comdirect.id), "11111");
    assert_eq!(pin(vb.id), "22222");
    let n: i64 = db
        .query_row(
            "SELECT count(*) FROM settings WHERE value = '33333'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(n, 0);
}

/// Replaces the secret columns of `banks`, `accounts` and `pins.pin` by views
/// whose secret columns raise an error when evaluated. The importer must still
/// work – proving it never reads them (and `pins.pin` only on request).
const TRAP: &str = r#"
ALTER TABLE banks RENAME TO banks_data;
CREATE VIEW banks AS SELECT rowid, country, bankcode, username, customer, json('x') AS credential, name, server,
  protocol, tanmethod, tanmedium, json('x') AS systemid, tanmethods, json('x') AS bpd, json('x') AS upd, spa, spa_tsp,
  json('x') AS local_storage, json('x') AS pubkey, json('x') AS privkey, json('x') AS userdata FROM banks_data;
ALTER TABLE accounts RENAME TO accounts_data;
CREATE VIEW accounts AS SELECT rowid, bank_key, account, subaccount, bankcode, portfolio, iban, bic, currency, name,
  owner, kind, type, sort, icon, balances, pending_balances, overdraft_limit, available_funds, initial_balance, cub,
  cub_tsp, recipient_key, refresh_tsp, balance_tsp, transaction_tsp, payment_tsp, error_tsp, cancel_tsp, statements,
  refresh_actions, refresh, json('x') AS userdata, json('x') AS cred, json('x') AS transientdata, perspective,
  group_key, error, json('x') AS web_ops FROM accounts_data;
ALTER TABLE pins RENAME TO pins_data;
CREATE VIEW pins AS SELECT bank_key, json('x') AS pin FROM pins_data;
"#;

#[test]
fn secret_columns_and_pins_are_never_read_unless_requested() {
    let path = fake_db_with(false, TRAP);
    // positive control: evaluating a trapped column fails
    let c = open_source(&path, &SecretString::new(PW.into())).unwrap();
    assert!(c
        .query_row("SELECT pin FROM pins LIMIT 1", [], |r| r
            .get::<_, String>(0))
        .is_err());
    assert!(c
        .query_row("SELECT credential FROM banks LIMIT 1", [], |r| r
            .get::<_, String>(0))
        .is_err());
    drop(c);
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.banks[0].has_saved_pin);
    // connections without PINs, and PINs requested without connections: pin column untouched
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, false))
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, true))
        .unwrap();
    // only now the (trapped) pin column is read
    assert!(v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .is_err());
}

#[test]
fn kind_override_on_reimport() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let mut o = options_from(&p, false, false);
    for c in &mut o.accounts {
        c.import = c.mm_id == 2;
        c.kind = AccountKind::Checking;
    }
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), o.clone())
        .unwrap();
    assert_eq!((r.accounts_created, r.bookings_new), (1, 1));
    assert_eq!(
        account_by_name(&v, "Visa-Karte").kind,
        AccountKind::Checking
    );
    // changing the kind on a later run re-files the importer's own account
    o.accounts
        .iter_mut()
        .for_each(|c| c.kind = AccountKind::CreditCard);
    v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!(
        account_by_name(&v, "Visa-Karte").kind,
        AccountKind::CreditCard
    );
    assert_eq!(v.list_accounts().unwrap().len(), 1);
}

#[test]
fn imported_accounts_are_linked_to_their_bank_login() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let comdirect = v.list_bank_connections().unwrap()[0].id;
    for name in ["Girokonto", "Visa-Karte", "Depot"] {
        assert_eq!(
            account_by_name(&v, name).connection_id,
            Some(comdirect),
            "{name}"
        );
    }
    // unsupported bank: no login, account stays on its own
    assert_eq!(account_by_name(&v, "Dollar-Konto").connection_id, None);
}

#[test]
fn opening_balance_applies_to_accounts_linked_to_a_bank_login() {
    // #212: the import shows the accounts under their bank login right away;
    // until a sync takes one over, its balance is still computed here.
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let giro = account_by_name(&v, "Girokonto");
    assert!(giro.connection_id.is_some());
    assert!(giro.balance_derived);
    assert_eq!(giro.opening_balance_cents, Some(10_000));
    v.calibrate_account_opening_balance(giro.id, 0).unwrap();
    assert_eq!(account_by_name(&v, "Girokonto").balance_cents, 0);
    // taken over by a sync: the bank's balance counts, not the Startsaldo
    v.db()
        .unwrap()
        .execute(
            "UPDATE accounts SET external_ref = 'bank:1' WHERE id = ?1",
            [giro.id],
        )
        .unwrap();
    assert!(!account_by_name(&v, "Girokonto").balance_derived);
}

#[test]
fn accounts_stay_unlinked_without_bank_logins() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert!(v
        .list_accounts()
        .unwrap()
        .iter()
        .all(|a| a.connection_id.is_none()));
}

#[test]
fn first_bank_sync_adopts_imported_card_without_iban_by_kind() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let visa = account_by_name(&v, "Visa-Karte");
    let conn_id = v.list_bank_connections().unwrap()[0].id;
    let db = v.db().unwrap();
    // a fetched account with an IBAN never takes over an account by kind
    assert_eq!(
        adopt_account(
            &db,
            conn_id,
            "card-x",
            "DE02120300000000202051",
            "",
            AccountKind::CreditCard
        )
        .unwrap(),
        None
    );
    assert_eq!(
        adopt_account(&db, conn_id, "card-1", "", "", AccountKind::CreditCard).unwrap(),
        Some(visa.id)
    );
    // only once, and never for another login
    assert_eq!(
        adopt_account(&db, conn_id, "card-2", "", "", AccountKind::CreditCard).unwrap(),
        None
    );
    assert_eq!(
        adopt_account(&db, conn_id + 1, "dep-1", "", "", AccountKind::Brokerage).unwrap(),
        None
    );
}

#[test]
fn amazon_visa_filed_as_openbank_gets_its_connector_and_is_adopted() {
    // MoneyMoney files the Amazon Visa as "Openbank" (bank code 50034200) and
    // stores an IBAN for the card; an Open Bank current account stays unsupported.
    let extra = "
INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
  (20, 'DE', '50034200', 'card-login', '', 'GEHEIM-20', 'Openbank', 'SYS', 'LS'),
  (21, 'DE', '50034200', 'giro-login', '', 'GEHEIM-21', 'Openbank', 'SYS', 'LS');
INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred) VALUES
  (20, 20, '', '50034200', 0, 'DE12 5003 4200 0000 0000 01', 'EUR', 'Amazon Visa', 'Max Mustermann', 0, 3, 20, 0, 1, 'GEHEIM'),
  (21, 21, '', '50034200', 0, 'DE12 5003 4200 0000 0000 02', 'EUR', 'Girokonto', 'Max Mustermann', 0, 0, 21, 0, 1, 'GEHEIM');
";
    let v = vault();
    let path = fake_db_with(false, extra);
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let bank = |id| p.banks.iter().find(|b| b.mm_id == id).unwrap().connector;
    assert_eq!(bank(20), Some(ConnectorKind::AmazonVisa));
    assert_eq!(bank(21), None);
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    let conn = v
        .list_bank_connections()
        .unwrap()
        .into_iter()
        .find(|c| c.connector == ConnectorKind::AmazonVisa)
        .unwrap();
    assert_eq!(conn.login_name, "card-login");
    let card = account_by_name(&v, "Amazon Visa");
    assert_eq!(card.connection_id, Some(conn.id));
    // the web login reports the card without an IBAN: still taken over, once
    let db = v.db().unwrap();
    assert_eq!(
        adopt_account(&db, conn.id, "amazon-1", "", "", AccountKind::CreditCard).unwrap(),
        Some(card.id)
    );
    db.execute(
        "UPDATE accounts SET external_ref = 'amazon-1' WHERE id = ?1",
        [card.id],
    )
    .unwrap();
    assert_eq!(
        adopt_account(&db, conn.id, "amazon-2", "", "", AccountKind::CreditCard).unwrap(),
        None
    );
}

#[test]
fn starter_categories_are_replaced_in_an_empty_vault() {
    let v = vault();
    assert!(v.seed_starter_categories().unwrap() > 0);
    assert!(!v.list_rules().unwrap().is_empty());
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.replaces_starter_categories);
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let mut names: Vec<String> = v
        .list_categories(None, None)
        .unwrap()
        .into_iter()
        .map(|c| c.name)
        .collect();
    names.sort();
    assert_eq!(
        names,
        [
            "Gehalt",
            "Haushalt",
            "Nebenkosten",
            "Steuern / Büro",
            "Strom",
            "Supermarkt",
            "Wohnen"
        ]
    );
    assert!(v.list_rules().unwrap().is_empty());
}

#[test]
fn category_colors_are_taken_over_without_overwriting_own_ones() {
    let v = vault();
    let path = fake_db_with(
        false,
        "UPDATE category_groups SET color = '#ff9500' WHERE rowid = 1;  -- Haushalt
         UPDATE category_groups SET color = '#0a0' WHERE rowid = 2;     -- Wohnen (#rgb)
         UPDATE categories SET color = '#34C759ff' WHERE rowid = 2;     -- Supermarkt (#rrggbbaa)
         UPDATE categories SET color = '''#ff3b30''' WHERE rowid = 4;   -- Strom (quoted)
         UPDATE categories SET color = 'blau' WHERE rowid = 3;          -- Gehalt (invalid)
         INSERT INTO category_groups (rowid, name, group_key, sort, color)
           VALUES (9, 'Leer', 0, 9, '#123456');                         -- no categories",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    let color = |name: &str| {
        v.list_categories(None, None)
            .unwrap()
            .into_iter()
            .find(|c| c.name == name)
            .map(|c| c.color_hex)
    };
    assert_eq!(color("Haushalt").as_deref(), Some("#FF9500"));
    assert_eq!(color("Wohnen").as_deref(), Some("#00AA00"));
    assert_eq!(color("Supermarkt").as_deref(), Some("#34C759"));
    assert_eq!(color("Strom").as_deref(), Some("#FF3B30"));
    {
        // taken-over colours are stamped for the sync merge, grey ones not touched
        let db = v.db().unwrap();
        let ms = |name: &str| -> i64 {
            db.query_row(
                "SELECT color_ms FROM categories WHERE name = ?1 AND deleted_ms IS NULL",
                [name],
                |r| r.get(0),
            )
            .unwrap()
        };
        assert!(
            ms("Strom") >= ms("Gehalt"),
            "colour stamp not older than creation"
        );
        assert!(ms("Strom") > 0);
    }
    assert_eq!(color("Gehalt").as_deref(), Some(DEFAULT_CATEGORY_COLOR));
    assert_eq!(
        color("Nebenkosten").as_deref(),
        Some(DEFAULT_CATEGORY_COLOR)
    );
    assert_eq!(color("Leer"), None, "empty groups are not created");

    // a colour chosen in GiroCrab survives a second import
    let strom = v
        .list_categories(None, None)
        .unwrap()
        .into_iter()
        .find(|c| c.name == "Strom")
        .unwrap();
    v.update_category(
        strom.id,
        strom.name,
        strom.parent_id,
        strom.sf_symbol,
        "#5856D6".into(),
    )
    .unwrap();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(color("Strom").as_deref(), Some("#5856D6"));
    assert_eq!(color("Haushalt").as_deref(), Some("#FF9500"));
}

#[test]
fn mm_color_formats() {
    assert_eq!(mm_color("#ff9500").as_deref(), Some("#FF9500"));
    assert_eq!(mm_color(" '#FF9500' ").as_deref(), Some("#FF9500"));
    assert_eq!(mm_color("#abc").as_deref(), Some("#AABBCC"));
    assert_eq!(mm_color("#11223344").as_deref(), Some("#112233"));
    for bad in ["", "ff9500", "#ff95", "#gg9500", "rot", "#"] {
        assert_eq!(mm_color(bad), None, "{bad:?}");
    }
}

#[test]
fn starter_categories_stay_when_the_vault_has_bookings() {
    let v = vault();
    let starter = v.seed_starter_categories().unwrap() as usize;
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    // second run: the vault now has bookings, nothing is replaced
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(!p.replaces_starter_categories);
    let before = v.list_categories(None, None).unwrap().len();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(v.list_categories(None, None).unwrap().len(), before);

    let v = vault();
    v.seed_starter_categories().unwrap();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    // categories not wanted: the starter set stays
    let mut o = options_from(&p, false, false);
    o.import_categories = false;
    v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!(v.list_categories(None, None).unwrap().len(), starter);
}

/// Soft-deleted bookings are no bookings: the vault counts as empty.
#[test]
fn deleted_bookings_do_not_count_as_existing() {
    let v = vault();
    v.seed_starter_categories().unwrap();
    {
        let db = v.db().unwrap();
        db.execute_batch(
            "INSERT INTO account_groups(id, name) VALUES (1, 'G');
             INSERT INTO accounts(id, group_id, external_ref, name) VALUES (1, 1, 'x', 'X');
             INSERT INTO transactions(account_id, external_id, booking_date, amount_cents)
             VALUES (1, 'e1', '2026-01-01', -5);",
        )
        .unwrap();
    }
    v.set_account_archived(1, true).unwrap();
    v.delete_account(1).unwrap();
    let p = v
        .preview_moneymoney_database(fake_db(), PW.into(), None)
        .unwrap();
    assert!(p.replaces_starter_categories);
}

#[test]
fn directory_banks_map_to_fints_keys() {
    // (bank code, name) -> stored connector key
    for (code, name, key) in [
        ("50010517", "ING", "fints:50010517"),
        ("43060967", "GLS Gemeinschaftsbank", "fints:43060967"),
        ("12030000", "DKB", "fints:12030000"),
        ("76030080", "Consorsbank", "fints:76030080"),
        ("10077777", "Norisbank", "fints:10077777"),
        ("66090800", "BBBank", "fints:66090800"),
        ("30060601", "apoBank", "fints:30060601"),
        ("83094495", "EthikBank", "fints:83094495"),
        ("10050000", "Berliner Sparkasse", "fints:10050000"),
        ("10070000", "Deutsche Bank", "fints:10070000"),
        ("70020270", "HypoVereinsbank", "fints:70020270"),
        ("1005 0000", "Berliner Sparkasse", "fints:10050000"),
    ] {
        let (kind, k) = connector_key_for(code, name).unwrap_or_else(|| panic!("{code}"));
        assert_eq!(kind, ConnectorKind::FinTsGeneric, "{code}");
        assert_eq!(k, key);
    }
    // dedicated connectors keep precedence over the directory
    assert_eq!(
        connector_key_for("20041111", "comdirect").unwrap().0,
        ConnectorKind::Comdirect
    );
    assert_eq!(
        connector_key_for("52090000", "Volksbank Kassel Göttingen")
            .unwrap()
            .1,
        "fints:52090000"
    );
    // unknown German bank code stays unsupported
    assert!(connector_key_for("12345678", "Sparkasse Musterstadt").is_none());
}

#[test]
fn generic_enable_banking_connection_is_stored_once() {
    let v = vault();
    let a = v
        .add_enable_banking_connection("N26".into(), "de".into(), "".into(), "".into())
        .unwrap();
    let b = v
        .add_enable_banking_connection("N26".into(), "DE".into(), "N26".into(), "".into())
        .unwrap();
    assert_eq!(a, b);
    assert!(v
        .add_enable_banking_connection("".into(), "DE".into(), "".into(), "".into())
        .is_err());
    assert!(v
        .add_enable_banking_connection("N26".into(), "DEU".into(), "".into(), "".into())
        .is_err());
    let c = v.list_bank_connections().unwrap();
    assert_eq!(c.len(), 1);
    assert_eq!(c[0].connector, ConnectorKind::EnableBanking);
    assert_eq!(c[0].display_name, "N26");
}

fn sha256(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect()
}

fn pdf(text: &str) -> Vec<u8> {
    format!("%PDF-1.4\n{text}\n%%EOF").into_bytes()
}

/// A MoneyMoney database listing four documents (and a deleted one) the way
/// MoneyMoney does: bank folder, file name, date, upper-case SHA-256.
fn statements_db() -> String {
    let (a, b, c, d) = (pdf("A"), pdf("B"), pdf("C"), pdf("D"));
    fake_db_with(
        false,
        &format!(
            "INSERT INTO statements (rowid, account_key, name, directory, filename, created_tsp, deleted, digest) VALUES
               (1, 1, 'Girokonto', 'Musterbank', 'Kontoauszug_2026_001.pdf', 1767225600, 0, '{}'),
               (2, 1, 'Girokonto', 'Musterbank', 'Steuerbescheinigung_2025.pdf', 1767312000, 0, '{}'),
               (3, 1, 'Girokonto', 'Musterbank', 'Kreditkartenabrechnung_2026_01.pdf', 1767398400, 0, '{}'),
               (4, 1, 'Girokonto', 'Musterbank', 'Geloescht.pdf', 1767398400, 1, ''),
               (5, 2, 'Visa-Karte', 'Musterbank', 'Vertragsinformationen.pdf', 1767484800, 0, '{}');",
            sha256(&a),
            sha256(&b),
            sha256(&c),
            sha256(&d)
        ),
    )
}

fn docs(v: &Vault) -> Vec<(String, String, String, String)> {
    let mut out: Vec<_> = v
        .list_all_documents(crate::documents::DocumentFilter::default())
        .unwrap()
        .into_iter()
        .map(|d| (d.file_name, d.doc_type, d.doc_date, d.title))
        .collect();
    out.sort();
    out
}

#[test]
fn statements_are_imported_from_the_moneymoney_folder() {
    // <folder>/Database/MoneyMoney.sqlite + <folder>/Statements/<bank>/<file>
    let folder = temp("mm-folder");
    let bank = folder.join("Statements").join("Musterbank");
    std::fs::create_dir_all(&bank).unwrap();
    std::fs::create_dir_all(folder.join("Database")).unwrap();
    std::fs::rename(
        statements_db(),
        folder.join("Database").join("MoneyMoney.sqlite"),
    )
    .unwrap();
    std::fs::write(bank.join("Kontoauszug_2026_001.pdf"), pdf("A")).unwrap();
    // B is missing, C has other content than the database says, D is fine
    std::fs::write(bank.join("Kreditkartenabrechnung_2026_01.pdf"), pdf("X")).unwrap();
    std::fs::write(bank.join("Vertragsinformationen.pdf"), pdf("D")).unwrap();
    std::fs::write(bank.join("Fremd.pdf"), pdf("F")).unwrap();
    let path = folder.to_string_lossy().to_string();

    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert!(p.database_path.ends_with("MoneyMoney.sqlite"));
    assert!(p.statements_dir.as_deref().unwrap().ends_with("Statements"));
    assert_eq!((p.statement_count, p.statements_found), (4, 3));
    assert_eq!(p.statements_bytes, 3 * pdf("A").len() as u64);
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert_eq!(giro.statement_count, 3, "the deleted one is not counted");

    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_missing,
            r.documents_mismatched,
            r.documents_unlisted
        ),
        (2, 1, 1, 1)
    );
    assert_eq!(
        docs(&v),
        vec![
            (
                "Kontoauszug_2026_001.pdf".to_string(),
                "kontoauszug".to_string(),
                "2026-01-01".to_string(),
                "Kontoauszug 2026 001".to_string()
            ),
            (
                "Vertragsinformationen.pdf".to_string(),
                "postbox".to_string(),
                "2026-01-04".to_string(),
                "Vertragsinformationen".to_string()
            ),
        ]
    );
    // linked to their accounts
    let giro_id = account_by_name(&v, "Girokonto").id;
    let of_giro = v
        .list_all_documents(crate::documents::DocumentFilter {
            account_id: Some(giro_id),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(of_giro.len(), 1);

    // again: nothing twice; and without the option nothing at all
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.documents_imported, r.documents_existing), (0, 2));
    let mut off = options_from(&p, false, false);
    off.import_statements = false;
    let r = v.import_moneymoney_database(path, PW.into(), off).unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_existing,
            r.documents_missing
        ),
        (0, 0, 0)
    );
    assert_eq!(docs(&v).len(), 2);
    let _ = std::fs::remove_dir_all(folder);
}

#[test]
fn statements_of_a_backup_come_from_a_separately_saved_folder() {
    // a single database file somewhere: documents are listed, but no files
    let path = statements_db();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    assert_eq!(
        (
            p.statement_count,
            p.statements_found,
            p.statements_dir.clone()
        ),
        (4, 0, None)
    );
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.documents_imported, r.documents_missing), (0, 4));

    // later, with a manual backup of the PDFs: A renamed in a subfolder (found
    // by checksum), B by its name without the bank folder, C and D not saved
    let saved = temp("mm-saved");
    std::fs::create_dir_all(saved.join("alt")).unwrap();
    std::fs::write(saved.join("alt").join("scan 1.PDF"), pdf("A")).unwrap();
    std::fs::write(saved.join("Steuerbescheinigung_2025.pdf"), pdf("B")).unwrap();
    std::fs::write(saved.join("notiz.txt"), b"kein PDF").unwrap();
    let dir = saved.to_string_lossy().to_string();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), Some(dir.clone()))
        .unwrap();
    assert_eq!((p.statement_count, p.statements_found), (4, 2));
    let mut options = options_from(&p, false, false);
    options.statements_dir = Some(dir);
    let r = v
        .import_moneymoney_database(path, PW.into(), options)
        .unwrap();
    assert_eq!(
        (
            r.documents_imported,
            r.documents_missing,
            r.documents_mismatched,
            r.documents_unlisted
        ),
        (2, 2, 0, 0)
    );
    let d = docs(&v);
    assert_eq!(d.len(), 2);
    // the original file name and date come from the database
    assert_eq!(d[0].0, "Kontoauszug_2026_001.pdf");
    assert_eq!(
        (d[1].0.as_str(), d[1].1.as_str(), d[1].2.as_str()),
        ("Steuerbescheinigung_2025.pdf", "steuer", "2026-01-02")
    );
    let _ = std::fs::remove_dir_all(saved);
}

#[test]
fn brand_banks_with_pseudo_bank_code_map_to_their_connector() {
    assert_eq!(
        connector_for("10012345", "Trade Republic"),
        Some(ConnectorKind::TradeRepublic)
    );
    assert_eq!(connector_for("", "PayPal"), Some(ConnectorKind::PayPal));
    assert_eq!(connector_for("12345678", "Sparkasse Musterstadt"), None);
    assert_eq!(
        connector_for("20041111", "comdirect"),
        Some(ConnectorKind::Comdirect)
    );
    // bunq: MoneyMoney files it under its German bank code; the login is an
    // API key, never a stored PIN, so no PIN is carried over.
    assert_eq!(connector_for("37019000", "bunq"), Some(ConnectorKind::Bunq));
    assert_eq!(connector_for("", "bunq"), Some(ConnectorKind::Bunq));
    assert_eq!(connector_for("BUNQNL2A", ""), Some(ConnectorKind::Bunq));
    assert!(!pin_usable(ConnectorKind::Bunq));
}

#[test]
fn bunq_accounts_are_recognised_in_every_country() {
    // BIC of any bunq branch
    for bic in [
        "BUNQNL2A",
        "BUNQDE82",
        "BUNQFRP2",
        "BUNQESM2",
        "bunqitm2",
        "BUNQNL2AXXX",
    ] {
        assert!(is_bunq_account(bic, "", ""), "{bic}");
    }
    // bank code: German branch, or a BIC MoneyMoney put in the bank code field
    assert!(is_bunq_account("", "", "370 190 00"));
    assert!(is_bunq_account("", "", "BUNQFRP2"));
    // IBAN alone: Dutch (bank id BUNQ) and German (bank code 37019000)
    assert!(is_bunq_account("", "NL12 BUNQ 0123 4567 89", ""));
    assert!(is_bunq_account("", "DE12 3701 9000 1234 5678 90", ""));
    // not bunq
    assert!(!is_bunq_account("INGBNL2A", "NL12 INGB 0123 4567 89", ""));
    assert!(!is_bunq_account(
        "",
        "DE89 3704 0044 0532 0130 00",
        "37040044"
    ));
    assert!(!is_bunq_account("BUNQ", "", "")); // too short for a BIC
    assert!(!is_bunq_account("", "", ""));
}

#[test]
fn bunq_logins_under_foreign_codes_get_a_bunq_connection_without_pin() {
    // Two bunq logins MoneyMoney filed without the German bank code: one
    // recognised by a Dutch IBAN, one by a French branch BIC only.
    let extra = "
INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
  (10, 'NL', '', 'me@example.com', '', 'GEHEIM-10', 'Mein Bankkonto', 'SYS', 'LS'),
  (11, 'FR', '', 'other@example.com', '', 'GEHEIM-11', 'Compte', 'SYS', 'LS');
INSERT INTO pins (bank_key, pin) VALUES (10, '1010');
INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, bic, currency, name, owner, kind, type, sort, initial_balance, group_key, cred) VALUES
  (10, 10, '', '', 0, 'NL12 BUNQ 0123 4567 89', '', 'EUR', 'Alltag', 'Max Mustermann', 0, 0, 10, 0, 1, 'GEHEIM'),
  (11, 11, '', '', 0, 'FR76 1234 5123 4512 3456 7890 123', 'BUNQFRP2', 'EUR', 'Courant', 'Max Mustermann', 0, 0, 11, 0, 1, 'GEHEIM');
";
    let v = vault();
    let path = fake_db_with(false, extra);
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    for id in [10, 11] {
        let b = p.banks.iter().find(|b| b.mm_id == id).unwrap();
        assert_eq!(b.connector, Some(ConnectorKind::Bunq), "bank {id}");
    }
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, true, true))
        .unwrap();
    let bunq: Vec<_> = v
        .list_bank_connections()
        .unwrap()
        .into_iter()
        .filter(|c| c.connector == ConnectorKind::Bunq)
        .collect();
    let mut logins: Vec<_> = bunq.iter().map(|c| c.login_name.as_str()).collect();
    logins.sort();
    assert_eq!(logins, ["me@example.com", "other@example.com"]);
    // bunq signs in with an API key: no MoneyMoney PIN is carried over
    for c in &bunq {
        assert!(!v.connection_status(c.id).unwrap().has_pin);
    }
    assert_eq!(r.banks_skipped_unsupported, 1); // only the Sparkasse
    assert_eq!(r.banks_skipped_names.len(), 1);
}

#[test]
fn depot_balance_from_shown_balance_and_holdings() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let depot = p.accounts.iter().find(|a| a.name == "Depot").unwrap();
    assert!(depot.is_portfolio);
    assert_eq!(depot.computed_balance_cents, 1_234_567);
    assert!(
        depot.balance_source.contains("MoneyMoney"),
        "{}",
        depot.balance_source
    );
    assert_eq!(depot.holding_count, 2, "sold position skipped");
    // accounts without the blob keep the derived balance
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert!(giro.balance_source.contains("Saldenverlauf"));

    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.holdings_imported, 2);
    let acc = account_by_name(&v, "Depot");
    assert_eq!(acc.balance_cents, 1_234_567);
    assert_eq!(acc.balance_date, "2026-03-07");
    let h = v.list_holdings(acc.id).unwrap();
    assert_eq!(h.len(), 2);
    let etf = h.iter().find(|x| x.isin == "IE00B4L5Y983").unwrap();
    assert_eq!(
        (
            etf.name.as_str(),
            etf.wkn.as_str(),
            etf.quantity,
            etf.current_price_cents,
            etf.purchase_price_cents,
            etf.value_cents
        ),
        ("Muster World ETF", "A0RPWH", 12.5, 8000, 7000, 100_000)
    );
    let cash = h.iter().find(|x| x.name == "Liquidität").unwrap();
    assert_eq!((cash.quantity, cash.value_cents), (0.0, 34_567));

    // second run replaces instead of duplicating
    let p2 = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r2 = v
        .import_moneymoney_database(path, PW.into(), options_from(&p2, false, false))
        .unwrap();
    assert_eq!(r2.holdings_imported, 2);
    assert_eq!(v.list_holdings(acc.id).unwrap().len(), 2);
}

#[test]
fn balances_blob_parsing() {
    assert_eq!(
        parse_balances_blob(Value::Text("11:4094.320000,3:EUR,".into())),
        Some((409_432, "EUR".into()))
    );
    assert_eq!(
        parse_balances_blob(Value::Blob(b"11:-671.230000,3:EUR,".to_vec())),
        Some((-67_123, "EUR".into()))
    );
    assert_eq!(parse_balances_blob(Value::Text(String::new())), None);
    assert_eq!(parse_balances_blob(Value::Null), None);
}

#[test]
fn reimport_of_emptied_depot_removes_stale_holdings() {
    let v = vault();
    let p = v
        .preview_moneymoney_database(fake_db(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(fake_db(), PW.into(), options_from(&p, false, false))
        .unwrap();
    let depot = account_by_name(&v, "Depot");
    assert_eq!(v.list_holdings(depot.id).unwrap().len(), 2);

    // MoneyMoney later: all positions sold, balance down to the cash remainder
    let sold = fake_db_with(
        false,
        "UPDATE securities SET deleted = 1 WHERE account_key = 3;
         UPDATE accounts SET balances = CAST('6:0.010000,3:EUR,' AS BLOB) WHERE rowid = 3;",
    );
    let p2 = v
        .preview_moneymoney_database(sold.clone(), PW.into(), None)
        .unwrap();
    let d2 = p2.accounts.iter().find(|a| a.name == "Depot").unwrap();
    assert_eq!(d2.holding_count, 0);
    assert_eq!(
        d2.existing_account_id,
        Some(depot.id),
        "recognised by external ref"
    );
    let r = v
        .import_moneymoney_database(sold, PW.into(), options_from(&p2, false, false))
        .unwrap();
    assert_eq!(r.holdings_imported, 0);
    assert!(
        v.list_holdings(depot.id).unwrap().is_empty(),
        "stale positions removed"
    );
    assert_eq!(account_by_name(&v, "Depot").balance_cents, 1);
}

#[test]
fn shown_balance_also_wins_for_checking_accounts() {
    // MoneyMoney's displayed balance is authoritative for every account type:
    // it is what the user sees in MoneyMoney, independent of how far back the
    // booking history goes. The derived balance (initial balance + bookings)
    // remains the fallback for databases without the blob.
    let v = vault();
    let path = fake_db_with(
        false,
        "UPDATE accounts SET balances = CAST('10:1234.560000,3:EUR,' AS BLOB), balance_tsp = 1772971200 WHERE rowid = 1;",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let giro = p.accounts.iter().find(|a| a.name == "Girokonto").unwrap();
    assert_eq!(giro.computed_balance_cents, 123_456);
    assert!(
        giro.balance_source.contains("Saldo laut MoneyMoney"),
        "{}",
        giro.balance_source
    );
    // other accounts (no blob) keep the derived value and its source text
    let visa = p.accounts.iter().find(|a| a.name == "Visa-Karte").unwrap();
    assert!(
        visa.balance_source.contains("Umsätze"),
        "{}",
        visa.balance_source
    );

    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let acc = account_by_name(&v, "Girokonto");
    assert_eq!(acc.balance_cents, 123_456);
    // balance date = max(newest booking, balance timestamp)
    assert_eq!(acc.balance_date, "2026-03-08");
    // #212: the opening balance is calibrated to MoneyMoney's own balance,
    // its date kept, so later bookings continue from the shown value
    assert_eq!(acc.opening_balance_date, "2020-01-01");
    assert_eq!(
        acc.opening_balance_cents,
        Some(123_456 + 4567 + 1230 + 10_000)
    );
}

#[test]
fn import_takes_over_moneymoney_groups() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 1);
    let gs = v.list_user_groups().unwrap();
    let privat = gs
        .iter()
        .find(|g| g.name == "Privat")
        .expect("group 'Privat'");
    let mut n: Vec<_> = privat.accounts.iter().map(|a| a.name.as_str()).collect();
    n.sort();
    assert_eq!(n, ["Girokonto", "Visa-Karte"]);
    assert!(
        gs.iter().any(|g| g.is_ungrouped),
        "accounts without MoneyMoney group stay ungrouped"
    );
    // idempotent: no second group, a user move is kept on re-import
    let giro = privat
        .accounts
        .iter()
        .find(|a| a.name == "Girokonto")
        .unwrap()
        .id;
    v.move_account_to_group(giro, None, None).unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 0);
    let gs = v.list_user_groups().unwrap();
    assert!(gs
        .iter()
        .find(|g| g.is_ungrouped)
        .unwrap()
        .accounts
        .iter()
        .any(|a| a.id == giro));
}

#[test]
fn import_takes_over_nested_groups_in_moneymoney_order() {
    let v = vault();
    // "Immobilien" (before "Privat") with two subgroups, listed Heilbronn before Neckarsulm
    let path = fake_db_with(
        false,
        "INSERT INTO account_groups (rowid, name, group_key, sort) VALUES
           (2, 'Immobilien', 0, 0), (3, 'ETW Neckarsulm', 2, 2), (4, 'ETW Heilbronn', 2, 1);
         UPDATE accounts SET group_key = 3 WHERE rowid = 3;
         UPDATE accounts SET group_key = 4 WHERE rowid = 4;",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let shown = |name: &str| {
        p.accounts
            .iter()
            .find(|a| a.name == name)
            .unwrap()
            .group_name
            .clone()
    };
    assert_eq!(shown("Depot"), "Immobilien › ETW Neckarsulm");
    assert_eq!(shown("Girokonto"), "Privat");
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 4);
    let tree = |v: &Vault| -> Vec<(String, u32, Vec<String>)> {
        v.list_user_groups()
            .unwrap()
            .into_iter()
            .map(|g| {
                let mut names: Vec<String> = g.accounts.into_iter().map(|a| a.name).collect();
                names.sort();
                (g.name, g.depth, names)
            })
            .collect()
    };
    let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    assert_eq!(
        tree(&v),
        vec![
            ("Immobilien".to_string(), 0, vec![]),
            ("ETW Heilbronn".to_string(), 1, s(&["Dollar-Konto"])),
            ("ETW Neckarsulm".to_string(), 1, s(&["Depot"])),
            ("Privat".to_string(), 0, s(&["Girokonto", "Visa-Karte"])),
        ]
    );
    // the parent's sum covers its subgroups
    let groups = v.list_user_groups().unwrap();
    assert_eq!(
        groups[0].balance_cents,
        groups[1].balance_cents + groups[2].balance_cents
    );

    // re-import: nothing new, and a group the user moved stays where it is
    let heilbronn = groups[1].uuid.clone();
    v.set_user_group_parent(heilbronn, None).unwrap();
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.groups_created, 0);
    let after = tree(&v);
    assert_eq!(after.iter().find(|g| g.0 == "ETW Heilbronn").unwrap().1, 0);
    assert_eq!(after.iter().find(|g| g.0 == "ETW Neckarsulm").unwrap().1, 1);
}

#[test]
fn imports_category_rules() {
    let v = vault();
    let path = fake_db_with(
        false,
        "UPDATE categories SET rules = 'name:REWE OR name:EDEKA' WHERE rowid = 2;
         UPDATE categories SET rules = '(Gehalt' WHERE rowid = 3;
         UPDATE categories SET rules = 'purpose:Strom* AND amount<0' WHERE rowid = 4;
         UPDATE categories SET rules = 'name:Finanzamt', apply_to_account = '1' WHERE rowid = 5;
         INSERT INTO categories (rowid, name, type, group_key, sort, rules) VALUES
           (6, 'Spenden', 1, 0, 4, 'reference:X'),
           (7, 'Sonstiges', 1, 0, 5, '   ');",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((r.rules_created, r.rules_disabled), (5, 3));

    let rules = v.list_rules().unwrap();
    let by_name = |n: &str| rules.iter().find(|r| r.name == n).unwrap().clone();
    let supermarkt = by_name("Supermarkt");
    assert_eq!(supermarkt.match_kind, MatchKind::Expression);
    assert_eq!(supermarkt.pattern, "name:REWE OR name:EDEKA");
    assert!(supermarkt.enabled);
    assert!(supermarkt.priority >= 1000);
    assert!(by_name("Strom").enabled);
    assert!(
        by_name("Strom").priority > supermarkt.priority,
        "MoneyMoney order"
    );
    assert!(!by_name("Gehalt").enabled, "broken syntax");
    assert!(
        !by_name("Steuern / Büro (nur für bestimmte Konten)").enabled,
        "account restriction is named in the rule"
    );
    assert!(!by_name("Spenden").enabled, "unsupported field");
    assert!(
        rules.iter().all(|r| r.name != "Sonstiges"),
        "blank rule skipped"
    );

    let again = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!((again.rules_created, again.rules_disabled), (0, 0));
    assert_eq!(v.list_rules().unwrap().len(), rules.len());
}

/// Records every progress report; cancels after `cancel_after` of them.
struct Recorder {
    seen: std::sync::Mutex<Vec<MoneyMoneyDbImportProgress>>,
    cancel_after: Option<usize>,
}

impl MoneyMoneyImportObserver for Recorder {
    fn progress(&self, progress: MoneyMoneyDbImportProgress) -> bool {
        let mut seen = self.seen.lock().unwrap();
        seen.push(progress);
        self.cancel_after.is_none_or(|n| seen.len() < n)
    }
}

#[test]
fn import_reports_progress_and_can_be_cancelled() {
    let folder = temp("mm-progress");
    let bank = folder.join("Statements").join("Musterbank");
    std::fs::create_dir_all(&bank).unwrap();
    std::fs::create_dir_all(folder.join("Database")).unwrap();
    std::fs::rename(
        statements_db(),
        folder.join("Database").join("MoneyMoney.sqlite"),
    )
    .unwrap();
    std::fs::write(bank.join("Kontoauszug_2026_001.pdf"), pdf("A")).unwrap();
    let path = folder.to_string_lossy().to_string();
    let v = vault();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();

    // cancelled in the middle: an error, and nothing at all is stored
    let stop = Arc::new(Recorder {
        seen: Default::default(),
        cancel_after: Some(4),
    });
    let r = v.import_moneymoney_database_with_progress(
        path.clone(),
        PW.into(),
        options_from(&p, true, false),
        stop.clone(),
    );
    assert!(matches!(r, Err(CoreError::InvalidInput { .. })));
    assert_eq!(stop.seen.lock().unwrap().len(), 4);
    assert!(v.list_accounts().unwrap().is_empty());
    assert!(v.list_bank_connections().unwrap().is_empty());
    assert!(docs(&v).is_empty());

    // a full run: from "reading" over every account to the end
    let all = Arc::new(Recorder {
        seen: Default::default(),
        cancel_after: None,
    });
    let r = v
        .import_moneymoney_database_with_progress(
            path,
            PW.into(),
            options_from(&p, false, false),
            all.clone(),
        )
        .unwrap();
    assert_eq!(r.documents_imported, 1);
    let seen = all.seen.lock().unwrap();
    let (first, last) = (seen.first().unwrap(), seen.last().unwrap());
    assert_eq!((first.account_index, first.account_count), (0, 0));
    let n = p.accounts.len() as u32;
    assert_eq!((last.account_index, last.account_count), (n + 1, n));
    assert_eq!(last.fraction, 1.0);
    assert_eq!(last.bookings_done, last.bookings_total);
    assert_eq!((last.documents_done, last.documents_total), (4, 4));
    assert!(last.account_name.is_empty());
    assert!(seen
        .windows(2)
        .all(|w| w[0].fraction <= w[1].fraction && w[0].account_index <= w[1].account_index));
    assert!(seen.iter().any(|s| s.account_name == "Girokonto"));
    let _ = std::fs::remove_dir_all(folder);
}

/// The "already imported?" lookup runs once per document: it must use the
/// index on `source_url`, not scan the table (and with it every stored PDF).
#[test]
fn document_lookup_uses_the_source_index() {
    let v = vault();
    let db = v.db().unwrap();
    let plan: Vec<String> = db
        .prepare(&format!("EXPLAIN QUERY PLAN {DOCUMENT_EXISTS_SQL}"))
        .unwrap()
        .query_map(["moneymoney:1:abc"], |r| r.get::<_, String>(3))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let plan = plan.join(" | ");
    assert!(plan.contains("booking_documents_source"), "{plan}");
    assert!(!plan.contains("SCAN booking_documents"), "{plan}");
}

/// Issue #94: transfers between own imported accounts (matched by IBAN or a
/// MoneyMoney "Umbuchung" category) must not inflate income / expenses.
#[test]
fn transfers_between_own_accounts_are_neutral_in_kpis() {
    let kpis = |path: String| {
        let v = vault();
        let p = v
            .preview_moneymoney_database(path.clone(), PW.into(), None)
            .unwrap();
        v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
            .unwrap();
        let page = v.list_transactions(BookingFilter::default()).unwrap();
        (page.income_cents, page.expense_cents, page.total_count)
    };
    let base = kpis(fake_db());
    let extra = r#"
INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred) VALUES
  (5, 1, '0648489890', '20041111', 0, 'DE12 5001 0517 0648 4898 90', 'EUR', 'Tagesgeld', 'Max Mustermann', 0, 1, 5, 0, 1, '');
INSERT INTO categories (rowid, name, type, group_key, sort) VALUES (6, 'Umbuchung', 1, 7, 1);
INSERT INTO category_groups (rowid, name, group_key, sort) VALUES (7, 'Finanzen', 0, 3);
INSERT INTO transactions (rowid, local_account_key, account, bankcode, amount, currency, timestamp, value_timestamp, comment, booked, unformatted_type, unformatted_purpose, name, checkmark, splitted, split_key, category_key) VALUES
  (10, 1, 'DE12500105170648489890', 'COBADEFFXXX', -500.0, 'EUR', 1772712000, 0, '', 1, 'UEBERWEISUNG', 'Sparen', 'Max Mustermann', 0, 0, 10, 1),
  (11, 5, 'DE89370400440532013000', 'COBADEFFXXX', 500.0, 'EUR', 1772712000, 0, '', 1, 'GUTSCHRIFT', 'Sparen', 'Max Mustermann', 0, 0, 11, 1),
  (12, 1, '', '', -200.0, 'EUR', 1772798400, 0, '', 1, 'UEBERWEISUNG', 'Ausgleich Karte', 'comdirect', 0, 0, 12, 6),
  (13, 2, '', '', 200.0, 'EUR', 1772798400, 0, '', 1, 'GUTSCHRIFT', 'Ausgleich Karte', 'comdirect', 0, 0, 13, 6);
"#;
    let with = kpis(fake_db_with(false, extra));
    assert_eq!(with.2, base.2 + 4, "transfers are still listed");
    assert_eq!(
        (with.0, with.1),
        (base.0, base.1),
        "but don't count as income / expense"
    );
}

fn src_acc(id: i64, account: &str, bankcode: &str, iban: &str, currency: &str) -> SrcAccount {
    SrcAccount {
        id,
        account: account.into(),
        bankcode: bankcode.into(),
        iban: sepa::normalize_iban(iban),
        currency: currency.into(),
        ..Default::default()
    }
}

fn src_tx(id: i64, account: i64, cp: &str, cp_bank: &str, amount: f64, ts: i64) -> SrcTx {
    SrcTx {
        id,
        account_key: account,
        cp_account: cp.into(),
        cp_bankcode: cp_bank.into(),
        amount: Some(amount),
        ts: Some(ts),
        booked: true,
        ..Default::default()
    }
}

#[test]
fn own_accounts_are_found_by_account_number_and_bank_code() {
    // Issue #94: pre-SEPA bookings / cards / depots carry only Kto + BLZ
    let giro = src_acc(
        1,
        "0532013000",
        "37040044",
        "DE89 3704 0044 0532 0130 00",
        "EUR",
    );
    let tagesgeld = src_acc(2, "0098765432", "37040044", "", "EUR");
    let card = src_acc(3, "4711", "37040044", "", "EUR");
    let src = Source {
        accounts: vec![giro.clone(), tagesgeld.clone(), card.clone()],
        ..Default::default()
    };
    let own = |from: &SrcAccount, cp: &str, bank: &str| {
        src.own_counter_account(from, cp, bank).map(|a| a.id)
    };
    // Kto/BLZ against the BLZ/Kto inside the own German IBAN
    assert_eq!(own(&tagesgeld, "532013000", "37040044"), Some(1));
    // Kto without IBAN on the own side, leading zeros ignored
    assert_eq!(own(&giro, "98765432", "37040044"), Some(2));
    assert_eq!(own(&giro, "4711", ""), Some(3));
    // German IBAN pointing at an own account that only has Kto/BLZ
    let iban = "DE77370400440098765432";
    assert!(sepa::validate_iban(iban));
    assert_eq!(own(&giro, iban, ""), Some(2));
    // other bank code, foreign account, too short, itself: no match
    assert_eq!(own(&giro, "98765432", "10010010"), None);
    assert_eq!(own(&giro, "12345678", "37040044"), None);
    assert_eq!(own(&giro, "47", ""), None);
    assert_eq!(own(&giro, "532013000", "37040044"), None);
}

#[test]
fn own_transfers_get_the_own_iban_and_the_transfer_category() {
    let giro = src_acc(
        1,
        "0532013000",
        "37040044",
        "DE89 3704 0044 0532 0130 00",
        "EUR",
    );
    let tagesgeld = src_acc(2, "0098765432", "37040044", "", "EUR");
    let src = Source {
        accounts: vec![giro.clone(), tagesgeld.clone()],
        txs: vec![
            src_tx(1, 2, "532013000", "37040044", 100.0, 1_600_000_000),
            src_tx(2, 1, "98765432", "37040044", -100.0, 1_600_000_000),
            src_tx(3, 1, "12345", "10010010", -5.0, 1_600_000_000),
        ],
        ..Default::default()
    };
    let rows = src.rows_for(&tagesgeld).rows;
    assert_eq!(rows[0].iban, "DE89370400440532013000");
    assert_eq!(rows[0].category_parts, vec!["Umbuchungen".to_string()]);
    let rows = src.rows_for(&giro).rows;
    let to_tg = rows.iter().find(|r| r.amount_cents == -10_000).unwrap();
    assert_eq!(to_tg.iban, "", "own account without IBAN: no invented IBAN");
    assert_eq!(to_tg.category_parts, vec!["Umbuchungen".to_string()]);
    let other = rows.iter().find(|r| r.amount_cents == -500).unwrap();
    assert!(other.category_parts.is_empty());
}

#[test]
fn fallback_balance_counts_account_currency_from_the_initial_balance_date_on() {
    let acc = src_acc(1, "1", "", "", "EUR");
    let mut usd = src_tx(3, 1, "", "", -50.0, 1_700_000_000);
    usd.currency = "USD".into();
    let mut balances = HashMap::new();
    // initial balance 100,00 as of 2020-09-13 (1_600_000_000)
    balances.insert((1, "EUR".to_string()), (1_600_000_000, 100.0));
    let src = Source {
        accounts: vec![acc.clone()],
        txs: vec![
            src_tx(1, 1, "", "", 2500.0, 1_500_000_000), // before: part of the 100,00
            src_tx(2, 1, "", "", -20.0, 1_600_000_000),  // same day: counts
            usd,                                         // other currency: not summed
        ],
        balances,
        ..Default::default()
    };
    let r = src.rows_for(&acc);
    assert_eq!(r.rows.len(), 3, "all bookings are still imported");
    assert_eq!(r.balance_cents, 10_000 - 2_000);
}

#[test]
fn starter_wipe_on_import_soft_deletes_starter_categories() {
    let v = vault();
    let starter = v.seed_starter_categories().unwrap() as i64;
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let db = v.db().unwrap();
    let n = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert_eq!(
        n("SELECT count(*) FROM categories WHERE deleted_ms IS NOT NULL"),
        starter
    );
    assert_eq!(n("SELECT count(*) FROM rules WHERE deleted_ms IS NULL"), 0);
    assert!(n("SELECT count(*) FROM rules WHERE deleted_ms IS NOT NULL") > 0);
    // the imported tree is live and stamped, with unique uuids
    assert_eq!(
        n("SELECT count(*) FROM categories WHERE deleted_ms IS NULL"),
        7
    );
    assert_eq!(
        n("SELECT count(*) FROM categories WHERE deleted_ms IS NULL AND name_ms > 0 AND uuid IS NOT NULL"),
        7
    );
    assert_eq!(
        n("SELECT count(DISTINCT uuid) FROM categories"),
        starter + 7
    );
}

#[test]
fn import_stamps_manual_category_and_note() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    {
        let db = v.db().unwrap();
        let n = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        assert!(n("SELECT count(*) FROM transactions WHERE category_source = 'manual' AND category_ms > 0") > 0);
        assert_eq!(n("SELECT count(*) FROM transactions WHERE category_source = 'manual' AND category_ms = 0"), 0);
        assert_eq!(
            n("SELECT count(*) FROM transactions WHERE note != '' AND note_ms = 0"),
            0
        );
        assert!(n("SELECT count(*) FROM transactions WHERE note != '' AND note_ms > 0") > 0);
        // pretend the bookings existed without category and note: the re-import enriches them
        db.execute("UPDATE transactions SET category_id = NULL, category_source = 'none', note = '', category_ms = 0, note_ms = 0", []).unwrap();
    }
    v.import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let db = v.db().unwrap();
    let n = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert!(n("SELECT count(*) FROM transactions WHERE category_source = 'manual' AND category_ms > 0") > 0);
    assert_eq!(n("SELECT count(*) FROM transactions WHERE category_source = 'manual' AND category_ms = 0"), 0);
    assert!(n("SELECT count(*) FROM transactions WHERE note != '' AND note_ms > 0") > 0);
    assert_eq!(
        n("SELECT count(*) FROM transactions WHERE note != '' AND note_ms = 0"),
        0
    );
}

#[test]
fn reimport_revives_deleted_account_with_its_cascade_bookings_only() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path.clone(), PW.into(), options_from(&p, true, false))
        .unwrap();
    let giro = account_by_name(&v, "Girokonto").id;
    let live = |v: &Vault| -> i64 {
        v.db()
            .unwrap()
            .query_row(
                "SELECT count(*) FROM transactions WHERE account_id = ?1 AND deleted_ms IS NULL",
                [giro],
                |r| r.get(0),
            )
            .unwrap()
    };
    let total = live(&v);
    assert!(total >= 2);
    v.db()
        .unwrap()
        .execute(
            "UPDATE transactions SET deleted_ms = 5 WHERE id = (SELECT min(id) FROM transactions WHERE account_id = ?1)",
            [giro],
        )
        .unwrap();
    v.set_account_archived(giro, true).unwrap();
    v.delete_account(giro).unwrap();
    assert_eq!(live(&v), 0);
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    v.import_moneymoney_database(path, PW.into(), options_from(&p, true, false))
        .unwrap();
    assert_eq!(
        v.list_accounts()
            .unwrap()
            .iter()
            .filter(|a| a.id == giro)
            .count(),
        1
    );
    assert_eq!(
        live(&v),
        total - 1,
        "individually deleted booking stays deleted"
    );
}

#[test]
fn account_checks_confirm_a_complete_import() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    assert_eq!(r.account_checks.len(), 4);
    for c in &r.account_checks {
        assert!(c.ok, "{c:?}");
        assert_eq!(c.found_bookings, c.mm_bookings, "{c:?}");
        assert_eq!((c.deleted_bookings, c.other_bookings), (0, 0), "{c:?}");
        assert_eq!(c.girocrab_balance_cents, c.mm_balance_cents, "{c:?}");
    }
    let giro = r
        .account_checks
        .iter()
        .find(|c| c.name == "Girokonto")
        .unwrap();
    assert_eq!(giro.mm_bookings, 5);
    let total: u32 = r.account_checks.iter().map(|c| c.mm_bookings).sum();
    assert_eq!(total, r.bookings_new);

    // a booking deleted in GiroCrab stays deleted – and still counts as there
    v.db()
        .unwrap()
        .execute(
            "UPDATE transactions SET deleted_ms = 1 WHERE id = (SELECT min(id) FROM transactions WHERE account_id = ?1)",
            [giro.account_id],
        )
        .unwrap();
    let r = v
        .import_moneymoney_database(path, PW.into(), options_from(&p, false, false))
        .unwrap();
    let giro = r
        .account_checks
        .iter()
        .find(|c| c.name == "Girokonto")
        .unwrap();
    assert!(giro.ok, "{giro:?}");
    assert_eq!((giro.found_bookings, giro.deleted_bookings), (4, 1));
}

#[test]
fn account_check_flags_missing_bookings_and_a_wrong_balance() {
    let v = vault();
    let path = fake_db();
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), options_from(&p, false, false))
        .unwrap();
    let giro = r
        .account_checks
        .iter()
        .find(|c| c.name == "Girokonto")
        .unwrap()
        .clone();
    // something went wrong behind the import's back: a booking vanished,
    // the balance is off
    {
        let db = v.db().unwrap();
        db.execute(
            "DELETE FROM transactions WHERE id = (SELECT min(id) FROM transactions WHERE account_id = ?1)",
            [giro.account_id],
        )
        .unwrap();
        db.execute(
            "UPDATE accounts SET balance_cents = balance_cents + 1 WHERE id = ?1",
            [giro.account_id],
        )
        .unwrap();
    }
    let src = read_source(&path, &SecretString::new(PW.into()), false).unwrap();
    let a = src.accounts.iter().find(|a| a.id == giro.mm_id).unwrap();
    let db = v.db().unwrap();
    let c = check_account(
        &db,
        a,
        "Girokonto",
        giro.account_id,
        &src.rows_for(a),
        false,
    )
    .unwrap();
    assert!(!c.ok);
    assert_eq!((c.mm_bookings, c.found_bookings), (5, 4));
    assert_eq!(c.girocrab_balance_cents, c.mm_balance_cents + 1);
    // a bank-synced account keeps the bank's balance: only the bookings count
    let c = check_account(&db, a, "Girokonto", giro.account_id, &src.rows_for(a), true).unwrap();
    assert!(!c.ok, "a missing booking is still flagged");
}

#[test]
fn banks_without_own_connector_are_set_up_through_enable_banking() {
    let v = vault();
    let path = fake_db_with(
        false,
        "INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage)
           VALUES (30, 'DE', '50024024', 'c24-login', '', 'GEHEIM-30', 'C24 Bank', 'SYS', 'LS');
         INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred)
           VALUES (30, 30, '1234567890', '50024024', 0, 'DE02 5002 4024 1234 5678 90', 'EUR', 'C24 Smartkonto', 'Max Mustermann', 0, 0, 30, 0, 0, 'GEHEIM'),
                  (31, 30, '0987654321', '50024024', 0, '', 'EUR', 'C24 Pocket', 'Max Mustermann', 0, 0, 31, 0, 0, 'GEHEIM');",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let c24 = p.banks.iter().find(|b| b.mm_id == 30).unwrap();
    assert_eq!(c24.connector, None);
    assert_eq!(c24.connection_options.len(), 1);
    let eb = eb_option(&p, 30).expect("C24 is in the PSD2 catalogue");
    let psd2 = eb.psd2_bank.clone().unwrap();
    assert_eq!((psd2.aspsp.as_str(), psd2.country.as_str()), ("C24", "DE"));
    assert_eq!(eb.key, "enablebanking:DE:C24");
    // the Sparkasse stays unsupported: neither FinTS-known here nor PSD2
    let spk = p.banks.iter().find(|b| b.mm_id == 3).unwrap();
    assert!(spk.connection_options.is_empty());

    let mut o = options_from(&p, true, false);
    o.bank_choices = vec![MoneyMoneyDbBankChoice {
        mm_bank_id: 30,
        connection: Some(eb),
    }];
    let r = v
        .import_moneymoney_database(path.clone(), PW.into(), o.clone())
        .unwrap();
    assert_eq!(r.psd2_connections.len(), 1);
    let pc = &r.psd2_connections[0];
    assert!(pc.created);
    assert_eq!(pc.bank_name, "C24 Bank");
    let mut names: Vec<&str> = pc.accounts.iter().map(|a| a.name.as_str()).collect();
    names.sort();
    assert_eq!(names, ["C24 Pocket", "C24 Smartkonto"]);
    assert!(pc
        .accounts
        .iter()
        .any(|a| a.iban.replace(' ', "") == "DE02500240241234567890"));
    let conn = v
        .list_bank_connections()
        .unwrap()
        .into_iter()
        .find(|c| c.id == pc.connection_id)
        .unwrap();
    assert_eq!(conn.connector, ConnectorKind::EnableBanking);
    // Sparkasse: no choice → still skipped, by name
    assert_eq!(r.banks_skipped_unsupported, 1);
    assert_eq!(r.banks_skipped_names.len(), 1);
    assert!(!r
        .psd2_connections
        .iter()
        .any(|p| r.banks_skipped_names.contains(&p.bank_name)));

    // second run: the same connection, nothing new
    let r = v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert_eq!(r.psd2_connections.len(), 1);
    assert!(!r.psd2_connections[0].created);
    assert_eq!(r.psd2_connections[0].connection_id, pc.connection_id);
    let eb = v
        .list_bank_connections()
        .unwrap()
        .into_iter()
        .filter(|c| c.connector == ConnectorKind::EnableBanking)
        .count();
    assert_eq!(eb, 1);
}

#[test]
fn psd2_choice_without_create_connections_does_nothing() {
    let v = vault();
    let path = fake_db_with(
        false,
        "INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage)
           VALUES (30, 'DE', '50024024', 'c24-login', '', 'GEHEIM-30', 'C24 Bank', 'SYS', 'LS');",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let mut o = options_from(&p, false, false);
    o.bank_choices = vec![MoneyMoneyDbBankChoice {
        mm_bank_id: 30,
        connection: eb_option(&p, 30),
    }];
    let r = v.import_moneymoney_database(path, PW.into(), o).unwrap();
    assert!(r.psd2_connections.is_empty());
    assert!(v.list_bank_connections().unwrap().is_empty());
}

#[test]
fn connection_priority_fints_then_own_api_then_enable_banking() {
    let v = vault();
    let path = fake_db_with(
        false,
        "INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
           (40, 'DE', '12030000', 'hb-login', '', 'X', 'Hanseatic Bank', 'SYS', 'LS'),
           (41, 'DE', '50024024', 'c24-login', '', 'X', 'C24 Bank', 'SYS', 'LS'),
           (42, 'DE', '', 'pp-login', '', 'X', 'PayPal', 'SYS', 'LS');",
    );
    let p = v
        .preview_moneymoney_database(path, PW.into(), None)
        .unwrap();
    let bank = |id: i64| p.banks.iter().find(|b| b.mm_id == id).unwrap();
    // 1. FinTS wins: the bank code is FinTS-known, although the name is in
    //    the PSD2 catalogue too
    assert_eq!(bank(40).connector, Some(ConnectorKind::FinTsGeneric));
    let vias: Vec<_> = bank(40).connection_options.iter().map(|o| o.via).collect();
    assert_eq!(
        vias,
        [
            MoneyMoneyDbConnectionVia::FinTs,
            MoneyMoneyDbConnectionVia::EnableBanking
        ]
    );
    // 2. own API: comdirect (no FinTS entry on purpose), PayPal
    assert_eq!(bank(1).connector, Some(ConnectorKind::Comdirect));
    assert_eq!(bank(42).connector, Some(ConnectorKind::PayPal));
    assert_eq!(
        bank(42).connection_options[0].via,
        MoneyMoneyDbConnectionVia::OwnApi
    );
    // 3. Enable Banking only without either
    assert_eq!(bank(41).connector, None);
    assert_eq!(
        eb_option(&p, 41).and_then(|o| o.psd2_bank).map(|b| b.aspsp),
        Some("C24".to_string())
    );
}

#[test]
fn a_bank_can_be_switched_to_enable_banking_or_left_out() {
    let v = vault();
    // Hanseatic Bank: FinTS-known code, but also in the PSD2 catalogue
    let path = fake_db_with(
        false,
        "INSERT INTO banks (rowid, country, bankcode, username, customer, credential, name, systemid, local_storage) VALUES
           (40, 'DE', '12030000', 'hb-login', '', 'X', 'Hanseatic Bank', 'SYS', 'LS');
         INSERT INTO accounts (rowid, bank_key, account, bankcode, portfolio, iban, currency, name, owner, kind, type, sort, initial_balance, group_key, cred)
           VALUES (40, 40, '1234567890', '12030000', 0, 'DE02 1203 0000 1234 5678 90', 'EUR', 'Hanseatic Giro', 'Max', 0, 0, 40, 0, 0, 'X');",
    );
    let p = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap();
    let mut o = options_from(&p, true, false);
    o.bank_choices = vec![
        // FinTS bank → Enable Banking instead
        MoneyMoneyDbBankChoice {
            mm_bank_id: 40,
            connection: eb_option(&p, 40),
        },
        // comdirect → not connected at all
        MoneyMoneyDbBankChoice {
            mm_bank_id: 1,
            connection: None,
        },
    ];
    let r = v.import_moneymoney_database(path, PW.into(), o).unwrap();
    let conns = v.list_bank_connections().unwrap();
    assert!(conns
        .iter()
        .all(|c| c.connector != ConnectorKind::Comdirect));
    assert!(conns.iter().all(
        |c| c.connector != ConnectorKind::FinTsGeneric || !c.display_name.contains("Hanseatic")
    ));
    assert_eq!(r.psd2_connections.len(), 1);
    assert_eq!(r.psd2_connections[0].bank_name, "Hanseatic Bank");
    assert_eq!(r.psd2_connections[0].accounts.len(), 1);
    // the comdirect accounts are still imported, just without a login
    assert!(r
        .account_checks
        .iter()
        .any(|c| c.name == "Girokonto" && c.ok));
}

/// #201: a database locked by a running MoneyMoney is reported as such –
/// quickly and not as a wrong password – and reads fine once released.
#[test]
fn database_locked_by_running_moneymoney_is_not_a_wrong_password() {
    let path = fake_db();
    let v = vault();
    let holder = Connection::open(&path).unwrap();
    holder
        .execute_batch(&format!("PRAGMA key = '{}';", PW.replace('\'', "''")))
        .unwrap();
    holder
        .execute_batch(
            "PRAGMA locking_mode = EXCLUSIVE; BEGIN; UPDATE accounts SET sort = sort; COMMIT;",
        )
        .unwrap();
    let started = std::time::Instant::now();
    let err = v
        .preview_moneymoney_database(path.clone(), PW.into(), None)
        .unwrap_err();
    assert!(started.elapsed() < std::time::Duration::from_secs(3));
    assert!(matches!(err, CoreError::Authentication { .. }));
    let msg = err.to_string();
    assert!(msg.contains("noch geöffnet"), "{msg}");
    assert!(!msg.contains("Falsches Passwort"), "{msg}");
    drop(holder);
    let p = v
        .preview_moneymoney_database(path, PW.into(), None)
        .unwrap();
    assert_eq!(p.accounts.len(), 4);
}

/// Issue #94: MoneyMoney keeps closed accounts with the same IBAN; they must
/// not all be merged into the one vault account that has this IBAN.
#[test]
fn accounts_sharing_an_iban_are_merged_into_different_vault_accounts() {
    let v = vault();
    let existing = {
        let db = v.db().unwrap();
        let gid = Vault::ensure_group(&db, "Giro & Tagesgeld", "building.columns", 1).unwrap();
        db.execute(
            "INSERT INTO accounts(connection_id, group_id, external_ref, name, iban, currency, kind, balance_cents)
             VALUES (NULL, ?1, 'abc-123', 'Mein Giro', 'DE89370400440532013000', 'EUR', 'checking', 0)",
            params![gid],
        )
        .unwrap();
        db.last_insert_rowid()
    };
    let path = temp("dup-iban.db").to_string_lossy().to_string();
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(SCHEMA).unwrap();
    conn.execute_batch(
        "INSERT INTO accounts (rowid, account, bankcode, iban, currency, name, kind, type, sort) VALUES
           (1, '0532013000', '20041111', 'DE89 3704 0044 0532 0130 00', 'EUR', 'Sparbrief alt', 0, 0, 1),
           (2, '0532013000', '20041111', 'DE89 3704 0044 0532 0130 00', 'EUR', 'Sparbrief neu', 0, 0, 2);",
    )
    .unwrap();
    drop(conn);
    let p = v
        .preview_moneymoney_database(path, String::new(), None)
        .unwrap();
    let ids: Vec<Option<i64>> = p.accounts.iter().map(|a| a.existing_account_id).collect();
    assert_eq!(ids, vec![Some(existing), None]);
}
