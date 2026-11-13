//! Startsaldo of an account (GiroCrab/GiroCrab#212), as in MoneyMoney.
//!
//! Accounts whose balance GiroCrab computes from bookings instead of getting it
//! from the bank (imports without a connection, connectors that report no
//! balance) start at 0 and miss everything older than the first booking. An
//! opening balance fixes that: `balance = opening + Σ bookings from its date
//! on`. Same pattern as the anchor of a manual loan (`loans.rs`): a dated
//! value in its own table, written to `accounts.balance_cents` by a refresh
//! that runs after every import (via `apply_rules_inner`) and every edit.
//!
//! Unlike the loan anchor ("Stand am Ende des Tages") the date is the start of
//! the day, as in MoneyMoney: bookings on that day count. An empty date means
//! "before the first booking". "Kalibrieren" solves the equation the other way
//! round: it picks the opening amount that yields a given current balance.
//!
//! Accounts whose balance comes from the bank ignore it, depots and loans have
//! none. A cleared opening balance stays as a row with `NULL` cents, so a
//! vault merge does not bring an older value back.

use std::collections::HashMap;

use chrono::NaiveDate;
use rusqlite::{params, Connection, OptionalExtension};

use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::vault::Vault;

/// Accounts whose balance is computed from bookings (SQL condition on `a`).
/// A MoneyMoney import shows its accounts under their bank login right away,
/// but until a sync takes one over (new `external_ref`) the bank has never
/// reported a balance for it: it still counts as computed (#212).
pub(crate) const DERIVED_SQL: &str = "a.deleted_ms IS NULL AND a.kind NOT IN ('brokerage', 'loan')
     AND (a.connection_id IS NULL OR a.balance_derived = 1 OR a.external_ref LIKE 'moneymoney-db:%')";

fn invalid(message: String) -> CoreError {
    CoreError::InvalidInput { message }
}

fn not_found(account_id: i64) -> CoreError {
    CoreError::NotFound {
        what: trf("Konto {0}", &[&account_id]),
    }
}

fn bank_balance() -> CoreError {
    invalid(
        tr("Der Saldo dieses Kontos kommt von der Bank. Ein Startsaldo gilt nur für Konten, deren Saldo GiroCrab aus den Umsätzen berechnet.")
            .to_string(),
    )
}

fn normalize_date(date: &str) -> CoreResult<String> {
    let d = date.trim();
    if d.is_empty() {
        return Ok(String::new());
    }
    NaiveDate::parse_from_str(d, "%Y-%m-%d")
        .map(|d| d.format("%Y-%m-%d").to_string())
        .map_err(|_| invalid(trf("Ungültiges Datum: {0}", &[&d])))
}

/// Whether `account_id` is a live account with a computed balance.
fn is_derived(conn: &Connection, account_id: i64) -> CoreResult<bool> {
    conn.query_row(
        &format!("SELECT {DERIVED_SQL} FROM accounts a WHERE a.id = ?1 AND a.deleted_ms IS NULL"),
        [account_id],
        |r| r.get(0),
    )
    .optional()?
    .ok_or_else(|| not_found(account_id))
}

/// The stored opening balance: (cents, date); `None` when unset or cleared.
pub(crate) fn load(conn: &Connection, account_id: i64) -> CoreResult<Option<(i64, String)>> {
    Ok(conn
        .query_row(
            "SELECT opening_cents, opening_date FROM opening_balances
              WHERE account_id = ?1 AND opening_cents IS NOT NULL",
            [account_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?)
}

/// Σ and newest date of the account's bookings on or after `date`, in the
/// account currency (bookings without a currency count too).
fn sum_from(conn: &Connection, account_id: i64, date: &str) -> CoreResult<(i64, String)> {
    Ok(conn.query_row(
        "SELECT IFNULL(SUM(t.amount_cents), 0), IFNULL(MAX(substr(t.booking_date, 1, 10)), '')
           FROM transactions t JOIN accounts a ON a.id = t.account_id
          WHERE t.account_id = ?1 AND t.deleted_ms IS NULL AND t.booking_date >= ?2
            AND (t.currency = '' OR upper(t.currency) = upper(a.currency))",
        params![account_id, date],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?)
}

/// What an opening balance at `date` would count, for the editor's preview
/// and "Kalibrieren" (balance = opening + `sum_cents`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct OpeningBalancePreview {
    /// Σ of the bookings on or after the date (account currency).
    pub sum_cents: i64,
    /// Bookings that count.
    pub counted: u32,
    /// Older bookings, covered by the opening balance.
    pub older: u32,
}

fn preview_in(conn: &Connection, account_id: i64, date: &str) -> CoreResult<OpeningBalancePreview> {
    Ok(conn.query_row(
        "SELECT IFNULL(SUM(CASE WHEN t.booking_date >= ?2 THEN t.amount_cents END), 0),
                count(CASE WHEN t.booking_date >= ?2 THEN 1 END),
                count(CASE WHEN t.booking_date < ?2 THEN 1 END)
           FROM transactions t JOIN accounts a ON a.id = t.account_id
          WHERE t.account_id = ?1 AND t.deleted_ms IS NULL
            AND (t.currency = '' OR upper(t.currency) = upper(a.currency))",
        params![account_id, date],
        |r| {
            Ok(OpeningBalancePreview {
                sum_cents: r.get(0)?,
                counted: r.get::<_, i64>(1)? as u32,
                older: r.get::<_, i64>(2)? as u32,
            })
        },
    )?)
}

/// Writes `opening + Σ bookings` to the account row. No-op for accounts
/// without an opening balance or with a balance from the bank.
pub(crate) fn refresh(conn: &Connection, account_id: i64) -> CoreResult<()> {
    if !is_derived(conn, account_id)? {
        return Ok(());
    }
    let Some((cents, date)) = load(conn, account_id)? else {
        return Ok(());
    };
    let (sum, last) = sum_from(conn, account_id, &date)?;
    // a newer date stays (e.g. MoneyMoney's balance timestamp): no booking since
    conn.execute(
        "UPDATE accounts SET balance_cents = ?1, balance_date = max(balance_date, ?2) WHERE id = ?3",
        params![cents + sum, last.max(date), account_id],
    )?;
    Ok(())
}

/// After removing the opening balance: balance = Σ of all bookings. Applied
/// once on removal, not on every refresh, so later bank-less balances stay.
fn reset_to_sum(conn: &Connection, account_id: i64) -> CoreResult<()> {
    if !is_derived(conn, account_id)? {
        return Ok(());
    }
    let (sum, last) = sum_from(conn, account_id, "")?;
    conn.execute(
        "UPDATE accounts SET balance_cents = ?1, balance_date = max(balance_date, ?2) WHERE id = ?3",
        params![sum, last, account_id],
    )?;
    Ok(())
}

/// Refreshes every account with an opening balance. Called after every import
/// and booking change (via `apply_rules_inner`) and after vault merges.
pub(crate) fn refresh_all(conn: &Connection) -> CoreResult<()> {
    let ids: Vec<i64> = {
        let mut st = conn.prepare(&format!(
            "SELECT o.account_id FROM opening_balances o JOIN accounts a ON a.id = o.account_id
              WHERE o.opening_cents IS NOT NULL AND {DERIVED_SQL} ORDER BY o.account_id"
        ))?;
        let rows = st.query_map([], |r| r.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    for id in ids {
        refresh(conn, id)?;
    }
    Ok(())
}

/// Stores (or clears with `None`) the opening balance, stamped now.
pub(crate) fn store(
    conn: &Connection,
    account_id: i64,
    cents: Option<i64>,
    date: &str,
) -> CoreResult<()> {
    conn.execute(
        "INSERT INTO opening_balances(account_id, opening_date, opening_cents, updated_ms)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(account_id) DO UPDATE SET opening_date = ?2, opening_cents = ?3, updated_ms = ?4",
        params![account_id, date, cents, crate::user_groups::now_ms()],
    )?;
    Ok(())
}

/// The opening amount that makes the account's balance `target_cents`,
/// keeping the stored date (MoneyMoney's "Kalibrieren"). Stores it.
pub(crate) fn calibrate_in(
    conn: &Connection,
    account_id: i64,
    target_cents: i64,
) -> CoreResult<i64> {
    let date = conn
        .query_row(
            "SELECT opening_date FROM opening_balances WHERE account_id = ?1",
            [account_id],
            |r| r.get::<_, String>(0),
        )
        .optional()?
        .unwrap_or_default();
    let (sum, _) = sum_from(conn, account_id, &date)?;
    let cents = target_cents - sum;
    store(conn, account_id, Some(cents), &date)?;
    refresh(conn, account_id)?;
    Ok(cents)
}

/// Vault merge: the newer edit per account wins; then refreshes balances.
pub(crate) fn merge_attached(conn: &Connection, acc_map: &HashMap<i64, i64>) -> CoreResult<()> {
    let has: i64 = conn.query_row(
        "SELECT count(*) FROM other.sqlite_master WHERE type = 'table' AND name = 'opening_balances'",
        [],
        |r| r.get(0),
    )?;
    if has > 0 {
        let mut st = conn.prepare(
            "SELECT account_id, opening_date, opening_cents, updated_ms FROM other.opening_balances",
        )?;
        let rows: Vec<(i64, String, Option<i64>, i64)> = st
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))?
            .collect::<Result<_, _>>()?;
        for (oid, date, cents, ms) in rows {
            if let Some(id) = acc_map.get(&oid) {
                let changed = conn.execute(
                    "INSERT INTO opening_balances(account_id, opening_date, opening_cents, updated_ms)
                     VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(account_id) DO UPDATE SET opening_date = ?2, opening_cents = ?3, updated_ms = ?4
                      WHERE excluded.updated_ms > opening_balances.updated_ms",
                    params![id, date, cents, ms],
                )?;
                // a newer removal from the other vault: back to the booking sum
                if changed > 0 && cents.is_none() {
                    reset_to_sum(conn, *id)?;
                }
            }
        }
    }
    refresh_all(conn)
}

#[uniffi::export]
impl Vault {
    /// Sets (or clears with `None`) the opening balance ("Startsaldo") of an
    /// account with a computed balance, at the start of `date` (`""` = before
    /// the first booking), and recomputes its balance. A cleared opening
    /// balance leaves the current balance as it is.
    pub fn set_account_opening_balance(
        &self,
        account_id: i64,
        cents: Option<i64>,
        date: String,
    ) -> Result<(), CoreError> {
        let date = normalize_date(&date)?;
        let db = self.db()?;
        if !is_derived(&db, account_id)? {
            return Err(bank_balance());
        }
        let tx = db.unchecked_transaction()?;
        store(&tx, account_id, cents, &date)?;
        if cents.is_some() {
            refresh(&tx, account_id)?;
        } else {
            // removed: back to the pure sum of the bookings
            reset_to_sum(&tx, account_id)?;
        }
        tx.commit()?;
        Ok(())
    }

    /// What an opening balance at `date` (`""` = all bookings) would count;
    /// nothing is stored. The new balance is `opening + sum_cents`, and the
    /// opening balance for a target balance is `target - sum_cents`.
    pub fn preview_account_opening_balance(
        &self,
        account_id: i64,
        date: String,
    ) -> Result<OpeningBalancePreview, CoreError> {
        let date = normalize_date(&date)?;
        let db = self.db()?;
        if !is_derived(&db, account_id)? {
            return Err(bank_balance());
        }
        preview_in(&db, account_id, &date)
    }

    /// "Kalibrieren": sets the opening balance so that the account's balance
    /// becomes `target_cents` (e.g. the balance on the latest statement),
    /// keeping the opening date. Returns the new opening balance.
    pub fn calibrate_account_opening_balance(
        &self,
        account_id: i64,
        target_cents: i64,
    ) -> Result<i64, CoreError> {
        let db = self.db()?;
        if !is_derived(&db, account_id)? {
            return Err(bank_balance());
        }
        let tx = db.unchecked_transaction()?;
        let cents = calibrate_in(&tx, account_id, target_cents)?;
        tx.commit()?;
        Ok(cents)
    }
}

#[cfg(test)]
mod tests;
