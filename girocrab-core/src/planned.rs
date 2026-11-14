//! Planned payments (#240): everything that is already ordered at the bank
//! but not booked yet. Today that are scheduled transfers (HKCSE); standing
//! orders, direct-debit collections and batch transfers add their own sources
//! to [`Vault::list_planned_payments`]. Only real orders appear here, never
//! guesses from the booking history (`recurring.rs`).

use rusqlite::{params, Connection};

use crate::connectors::TransferJob;
use crate::error::{CoreError, CoreResult};
use crate::vault::Vault;

/// Step 15: scheduled transfers sent to the bank. `end_to_end_id` is the merge
/// key. Rows stay until the execution date has passed; the bank's booking
/// then arrives through the normal sync. Idempotent like the steps before.
pub(crate) fn planned_transfers(conn: &Connection) -> CoreResult<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS planned_transfers (
            id              INTEGER PRIMARY KEY,
            account_id      INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            end_to_end_id   TEXT    NOT NULL UNIQUE,
            execution_date  TEXT    NOT NULL,          -- YYYY-MM-DD
            recipient_name  TEXT    NOT NULL DEFAULT '',
            recipient_iban  TEXT    NOT NULL DEFAULT '',
            amount_cents    INTEGER NOT NULL,          -- positive = outgoing
            purpose         TEXT    NOT NULL DEFAULT '',
            created_ms      INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS planned_transfers_date
            ON planned_transfers(execution_date);",
    )?;
    Ok(())
}

/// What kind of order a planned payment comes from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum PlannedKind {
    /// Scheduled transfer (Terminüberweisung, HKCSE).
    ScheduledTransfer,
}

/// One future payment with an order at the bank.
#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct PlannedPayment {
    /// Stable across reloads, e.g. `transfer-12`.
    pub id: String,
    pub kind: PlannedKind,
    pub account_id: i64,
    pub account_name: String,
    /// Execution date `YYYY-MM-DD`.
    pub date: String,
    pub counterparty: String,
    pub counterparty_iban: String,
    /// Negative = outgoing, like bookings.
    pub amount_cents: i64,
    pub purpose: String,
}

/// Sums of the planned payments in a period (SQL aggregate, no row loading).
#[derive(Debug, Clone, Default, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct PlannedTotals {
    pub count: u32,
    /// Sum of the outgoing payments (negative or 0).
    pub outgoing_cents: i64,
    /// Sum of the incoming payments (positive or 0).
    pub incoming_cents: i64,
}

fn today() -> String {
    chrono::Local::now().format("%Y-%m-%d").to_string()
}

impl Vault {
    /// Remembers a scheduled transfer the bank accepted.
    pub(crate) fn record_planned_transfer(
        &self,
        account_id: i64,
        job: &TransferJob,
    ) -> CoreResult<()> {
        let Some(date) = job.execution_date.as_deref() else {
            return Ok(());
        };
        let db = self.db()?;
        db.execute(
            "INSERT OR IGNORE INTO planned_transfers(account_id, end_to_end_id, execution_date,
                    recipient_name, recipient_iban, amount_cents, purpose, created_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                account_id,
                job.end_to_end_id,
                date,
                job.recipient_name,
                job.recipient_iban,
                job.amount_cents,
                job.purpose,
                crate::user_groups::now_ms()
            ],
        )?;
        Ok(())
    }
}

fn check_date(label: &str, d: &str) -> CoreResult<()> {
    chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d")
        .map(|_| ())
        .map_err(|_| CoreError::InvalidInput {
            message: format!("{label}: {d}"),
        })
}

#[uniffi::export]
impl Vault {
    /// Planned payments with execution date in `[from, to]` (`YYYY-MM-DD`,
    /// `None` = from today / open end), oldest first. `account_ids` empty = all.
    pub fn list_planned_payments(
        &self,
        from: Option<String>,
        to: Option<String>,
        account_ids: Vec<i64>,
    ) -> Result<Vec<PlannedPayment>, CoreError> {
        let from = from.unwrap_or_else(today);
        check_date("from", &from)?;
        if let Some(t) = &to {
            check_date("to", t)?;
        }
        let db = self.db()?;
        let mut q = db.prepare(
            "SELECT p.id, p.account_id, a.name, p.execution_date, p.recipient_name,
                    p.recipient_iban, p.amount_cents, p.purpose
             FROM planned_transfers p JOIN accounts a ON a.id = p.account_id
             WHERE a.deleted_ms IS NULL AND p.execution_date >= ?1
               AND (?2 IS NULL OR p.execution_date <= ?2)
             ORDER BY p.execution_date, p.id",
        )?;
        let rows = q.query_map(params![from, to], |r| {
            Ok(PlannedPayment {
                id: format!("transfer-{}", r.get::<_, i64>(0)?),
                kind: PlannedKind::ScheduledTransfer,
                account_id: r.get(1)?,
                account_name: r.get(2)?,
                date: r.get(3)?,
                counterparty: r.get(4)?,
                counterparty_iban: r.get(5)?,
                amount_cents: -r.get::<_, i64>(6)?,
                purpose: r.get(7)?,
            })
        })?;
        let mut out = Vec::new();
        for p in rows {
            let p = p?;
            if account_ids.is_empty() || account_ids.contains(&p.account_id) {
                out.push(p);
            }
        }
        Ok(out)
    }

    /// Sums of [`Self::list_planned_payments`] without loading the rows.
    pub fn planned_payment_totals(
        &self,
        from: Option<String>,
        to: Option<String>,
        account_ids: Vec<i64>,
    ) -> Result<PlannedTotals, CoreError> {
        let rows = self.list_planned_payments(from, to, account_ids)?;
        let mut t = PlannedTotals::default();
        for p in rows {
            t.count += 1;
            if p.amount_cents < 0 {
                t.outgoing_cents += p.amount_cents;
            } else {
                t.incoming_cents += p.amount_cents;
            }
        }
        Ok(t)
    }
}

/// Vault merge: adds the other vault's scheduled transfers we do not have yet
/// (by `end_to_end_id`); account ids are mapped.
pub(crate) fn merge_attached(
    conn: &Connection,
    acc_map: &std::collections::HashMap<i64, i64>,
) -> CoreResult<()> {
    let has: i64 = conn.query_row(
        "SELECT count(*) FROM other.sqlite_master WHERE type = 'table' AND name = 'planned_transfers'",
        [],
        |r| r.get(0),
    )?;
    if has == 0 {
        return Ok(());
    }
    let rows: Vec<(i64, String, String, String, String, i64, String, i64)> = {
        let mut q = conn.prepare(
            "SELECT account_id, end_to_end_id, execution_date, recipient_name, recipient_iban,
                    amount_cents, purpose, created_ms
             FROM other.planned_transfers",
        )?;
        let it = q.query_map([], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
                r.get(6)?,
                r.get(7)?,
            ))
        })?;
        it.collect::<Result<_, _>>()?
    };
    for (acc, e2e, date, name, iban, cents, purpose, created) in rows {
        let Some(&mine) = acc_map.get(&acc) else {
            continue;
        };
        conn.execute(
            "INSERT OR IGNORE INTO planned_transfers(account_id, end_to_end_id, execution_date,
                    recipient_name, recipient_iban, amount_cents, purpose, created_ms)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
            params![mine, e2e, date, name, iban, cents, purpose, created],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests;
