//! Batch transfers: the connector gets the whole batch, and what the session
//! records afterwards depends on the booking mode and the execution date.

use std::sync::Arc;

use async_trait::async_trait;

use super::*;
use crate::connectors::fints::sepa::BatchPayment;
use crate::vault::Vault;

struct Accepting;

#[async_trait]
impl BankConnector for Accepting {
    async fn begin(&mut self, _: &ConnectContext) -> CoreResult<Phase> {
        Ok(Phase::Ready)
    }
    async fn respond(&mut self, _: &ConnectContext, _: ChallengeResponse) -> CoreResult<Phase> {
        Ok(Phase::Ready)
    }
    async fn fetch(&mut self, _: &ConnectContext) -> CoreResult<FetchResult> {
        Ok(FetchResult::default())
    }
    async fn send_batch_transfer(
        &mut self,
        _: &ConnectContext,
        job: &BatchTransferJob,
    ) -> CoreResult<Phase> {
        assert_eq!(job.payments.len(), 3);
        Ok(Phase::Ready)
    }
}

fn payment(n: u32, cents: i64) -> BatchPayment {
    BatchPayment {
        name: format!("Empfänger {n}"),
        iban: "DE89370400440532013000".into(),
        bic: None,
        amount_cents: cents,
        purpose: format!("Zweck {n}"),
        end_to_end_id: format!("GCB{n}"),
    }
}

async fn run(batch_booking: bool, date: Option<&str>) -> (i64, i64, i64, i64) {
    let vault = Vault::open(
        crate::test_support::thread_temp_path("batch")
            .to_string_lossy()
            .into(),
        vec![8u8; 32],
    )
    .unwrap();
    let account_id = {
        let db = vault.db().unwrap();
        db.execute(
            "INSERT INTO account_groups(name, sf_symbol, sort_order) VALUES ('G', 'tray', 1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO accounts(group_id, external_ref, name, kind)
             VALUES ((SELECT min(id) FROM account_groups), 'a', 'a', 'checking')",
            [],
        )
        .unwrap();
        db.last_insert_rowid()
    };
    let batch = BatchTransferJob {
        source_iban: "DE02120300000000202051".into(),
        source_owner: "A".into(),
        payments: vec![payment(1, 1_000), payment(2, 2_050), payment(3, 500)],
        batch_booking,
        execution_date: date.map(str::to_string),
    };
    let summary = TransferJob {
        source_iban: batch.source_iban.clone(),
        source_owner: "A".into(),
        recipient_name: "Sammelüberweisung (3 Zahlungen)".into(),
        recipient_iban: String::new(),
        recipient_bic: None,
        amount_cents: 3_550,
        purpose: String::new(),
        instant: false,
        execution_date: batch.execution_date.clone(),
        end_to_end_id: "GCSUM".into(),
    };
    let ctx = ConnectContext {
        connection_id: 1,
        login_name: String::new(),
        secret: crate::secret::SecretString::new(String::new()),
        settings: Default::default(),
        state: serde_json::Value::Null,
        since: "2020-01-01".into(),
        since_by_account: Default::default(),
    };
    let s = TransferSession::new_batch(
        Arc::clone(&vault),
        Box::new(Accepting),
        ctx,
        batch,
        summary,
        account_id,
    );
    assert!(matches!(
        s.start().await.unwrap(),
        TransferStep::Finished { .. }
    ));
    let db = vault.db().unwrap();
    let one = |sql: &str| db.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    (
        one("SELECT count(*) FROM transactions WHERE external_id LIKE 'pending-%'"),
        one("SELECT IFNULL(sum(amount_cents),0) FROM transactions WHERE external_id LIKE 'pending-%'"),
        one("SELECT count(*) FROM planned_transfers"),
        one("SELECT IFNULL(sum(amount_cents),0) FROM planned_transfers"),
    )
}

#[tokio::test]
async fn sum_booking_records_one_pending_booking() {
    assert_eq!(run(true, None).await, (1, -3_550, 0, 0));
}

#[tokio::test]
async fn single_bookings_record_one_booking_per_payment() {
    assert_eq!(run(false, None).await, (3, -3_550, 0, 0));
}

#[tokio::test]
async fn scheduled_batches_go_to_planned_not_to_bookings() {
    let date = (chrono::Local::now().date_naive() + chrono::Duration::days(10)).to_string();
    assert_eq!(run(true, Some(&date)).await, (0, 0, 1, 3_550));
    assert_eq!(run(false, Some(&date)).await, (0, 0, 3, 3_550));
}
