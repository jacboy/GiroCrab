use std::sync::Arc;

use crate::connectors::TransferJob;
use crate::vault::Vault;

fn vault(tag: &str) -> Arc<Vault> {
    Vault::open(
        crate::test_support::thread_temp_path(tag)
            .to_string_lossy()
            .into(),
        vec![7u8; 32],
    )
    .unwrap()
}

fn account(v: &Vault, name: &str) -> i64 {
    let db = v.db().unwrap();
    db.execute(
        "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)
         ON CONFLICT DO NOTHING",
        [],
    )
    .unwrap();
    db.execute(
        "INSERT INTO accounts(group_id, external_ref, name, kind)
         VALUES ((SELECT min(id) FROM account_groups), ?1, ?1, 'checking')",
        [name],
    )
    .unwrap();
    db.last_insert_rowid()
}

fn job(e2e: &str, date: Option<&str>, cents: i64) -> TransferJob {
    TransferJob {
        source_iban: "DE02120300000000202051".into(),
        source_owner: "Max".into(),
        recipient_name: "Vermieter".into(),
        recipient_iban: "DE89370400440532013000".into(),
        recipient_bic: None,
        amount_cents: cents,
        purpose: "Miete".into(),
        instant: false,
        execution_date: date.map(str::to_string),
        end_to_end_id: e2e.into(),
    }
}

#[test]
fn scheduled_transfer_is_listed_as_outgoing() {
    let v = vault("planned-list");
    let a = account(&v, "Giro");
    v.record_planned_transfer(a, &job("E1", Some("2999-01-15"), 85_000))
        .unwrap();
    let rows = v.list_planned_payments(None, None, vec![]).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].amount_cents, -85_000);
    assert_eq!(rows[0].date, "2999-01-15");
    assert_eq!(rows[0].account_name, "Giro");
    let t = v.planned_payment_totals(None, None, vec![]).unwrap();
    assert_eq!(
        (t.count, t.outgoing_cents, t.incoming_cents),
        (1, -85_000, 0)
    );
}

#[test]
fn same_order_is_stored_once_and_without_date_not_at_all() {
    let v = vault("planned-dup");
    let a = account(&v, "Giro");
    let j = job("E1", Some("2999-01-15"), 100);
    v.record_planned_transfer(a, &j).unwrap();
    v.record_planned_transfer(a, &j).unwrap();
    v.record_planned_transfer(a, &job("E2", None, 100)).unwrap();
    assert_eq!(
        v.list_planned_payments(None, None, vec![]).unwrap().len(),
        1
    );
}

#[test]
fn past_orders_range_and_account_filter() {
    let v = vault("planned-filter");
    let a = account(&v, "Giro");
    let b = account(&v, "Tagesgeld");
    v.record_planned_transfer(a, &job("OLD", Some("2000-01-01"), 1))
        .unwrap();
    v.record_planned_transfer(a, &job("E1", Some("2999-01-15"), 10))
        .unwrap();
    v.record_planned_transfer(b, &job("E2", Some("2999-03-01"), 20))
        .unwrap();
    // executed in the past: gone from the default view
    assert_eq!(
        v.list_planned_payments(None, None, vec![]).unwrap().len(),
        2
    );
    let r = v
        .list_planned_payments(None, Some("2999-02-01".into()), vec![])
        .unwrap();
    assert_eq!(r.len(), 1);
    let r = v.list_planned_payments(None, None, vec![b]).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].account_id, b);
    assert!(v
        .list_planned_payments(Some("kaputt".into()), None, vec![])
        .is_err());
}
