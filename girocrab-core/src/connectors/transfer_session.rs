//! `TransferSession`: the two-phase SEPA transfer state machine exposed via FFI.

use std::sync::Arc;

use tokio::sync::Mutex as AsyncMutex;

use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;
use crate::secret::SecretString;
use crate::vault::Vault;

use super::*;

struct TransferState {
    connector: Box<dyn BankConnector>,
    ctx: ConnectContext,
    job: TransferJob,
    account_id: i64,
    /// false = still logging in, true = transfer submitted (waiting for TAN).
    submitted: bool,
    /// The dialog is over (finished, failed or cancelled): no further steps.
    /// This is internal; it says nothing about whether the bank still holds
    /// an open order (see `cancel` and `BankConnector::has_open_order`).
    done: bool,
    /// The bank confirmed the order is not payable any more.
    cancel_confirmed: bool,
    /// The order was executed: it can no longer be cancelled.
    executed: bool,
}

/// After the order was handed to the bank, only errors that prove it was
/// refused (wrong credentials, invalid input) mean "not executed". Anything
/// else (network, garbled reply, ...) leaves the result unknown.
pub(super) fn error_leaves_outcome_unknown(e: &CoreError) -> bool {
    !matches!(
        e,
        CoreError::Authentication { .. } | CoreError::InvalidInput { .. }
    )
}

/// One SEPA transfer. Created by `Vault::begin_transfer`; same two-phase
/// challenge handling as `SyncSession` (login SCA, then transfer SCA).
#[derive(uniffi::Object)]
pub struct TransferSession {
    vault: Arc<Vault>,
    state: AsyncMutex<TransferState>,
}

impl TransferSession {
    pub(super) fn new(
        vault: Arc<Vault>,
        connector: Box<dyn BankConnector>,
        ctx: ConnectContext,
        job: TransferJob,
        account_id: i64,
    ) -> Self {
        Self {
            vault,
            state: AsyncMutex::new(TransferState {
                connector,
                ctx,
                job,
                account_id,
                submitted: false,
                done: false,
                cancel_confirmed: false,
                executed: false,
            }),
        }
    }

    async fn advance(
        &self,
        phase: CoreResult<Phase>,
        st: &mut TransferState,
    ) -> CoreResult<TransferStep> {
        let mut phase = phase;
        loop {
            match phase {
                Err(e) => {
                    st.done = true;
                    // A dropped connection after the order reached the bank:
                    // it may have been executed, so never report "failed".
                    let unknown = st.submitted
                        && st.connector.order_submitted()
                        && error_leaves_outcome_unknown(&e);
                    st.connector.finish(&st.ctx).await;
                    if unknown {
                        return self.outcome_unknown(st, e.to_string());
                    }
                    return Err(e);
                }
                Ok(Phase::Challenge(c)) => {
                    return Ok(TransferStep::NeedsChallenge { challenge: c })
                }
                Ok(Phase::Pending(c)) => return Ok(TransferStep::StillWaiting { challenge: c }),
                Ok(Phase::ConfirmPayee(check)) => {
                    return Ok(TransferStep::NeedsPayeeConfirmation { check })
                }
                Ok(Phase::Ready) if !st.submitted => {
                    st.submitted = true;
                    phase = st.connector.send_transfer(&st.ctx, &st.job).await;
                }
                Ok(Phase::Ready) => {
                    st.connector.finish(&st.ctx).await;
                    st.done = true;
                    return match st.connector.transfer_result() {
                        TransferResult::Executed { instant } => {
                            st.executed = true;
                            if st.job.execution_date.is_some() {
                                // scheduled: shown under "Geplant" until the
                                // bank books it, not as a booking dated today
                                self.vault.record_planned_transfer(st.account_id, &st.job)?;
                            } else {
                                self.vault.record_pending_transfer(
                                    st.account_id,
                                    &st.job,
                                    if instant {
                                        "Echtzeitüberweisung (vorgemerkt)"
                                    } else {
                                        "Überweisung (vorgemerkt)"
                                    },
                                )?;
                            }
                            Ok(TransferStep::Finished {
                                outcome: TransferOutcome {
                                    instant,
                                    end_to_end_id: st.job.end_to_end_id.clone(),
                                },
                            })
                        }
                        TransferResult::InstantDeclined { reason } => {
                            Ok(TransferStep::InstantDeclined { reason })
                        }
                        TransferResult::Unknown { reason } => self.outcome_unknown(st, reason),
                    };
                }
            }
        }
    }

    /// Stores a booking marked "Status unklar" so the possibly executed order
    /// stays visible (until the bank's booking arrives or 14 days pass).
    fn outcome_unknown(&self, st: &TransferState, reason: String) -> CoreResult<TransferStep> {
        self.vault.record_pending_transfer(
            st.account_id,
            &st.job,
            if st.job.instant {
                "Echtzeitüberweisung (Status unklar)"
            } else {
                "Überweisung (Status unklar)"
            },
        )?;
        Ok(TransferStep::OutcomeUnknown {
            reason,
            end_to_end_id: st.job.end_to_end_id.clone(),
        })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl TransferSession {
    pub async fn start(&self) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector.begin(ctx).await;
        self.advance(phase, &mut st).await
    }

    pub async fn submit_code(&self, code: String) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector
            .respond(ctx, ChallengeResponse::Code(SecretString::new(code)))
            .await;
        self.advance(phase, &mut st).await
    }

    pub async fn poll(&self) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector.respond(ctx, ChallengeResponse::Poll).await;
        self.advance(phase, &mut st).await
    }

    /// Send the transfer although the name check did not confirm the
    /// recipient (after `NeedsPayeeConfirmation`).
    pub async fn confirm_payee(&self) -> Result<TransferStep, CoreError> {
        let mut st = self.state.lock().await;
        if st.done {
            return Err(CoreError::SessionClosed);
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let phase = connector
            .respond(ctx, ChallengeResponse::ConfirmPayee)
            .await;
        self.advance(phase, &mut st).await
    }

    /// Cancels the transfer. The result says whether the bank confirmed it:
    /// only `Cancelled` is final. For `CancellationPending`, `-Unknown` and
    /// `-Failed` the order stays tracked and `cancel()` can simply be called
    /// again; it re-checks the bank's status and never resends the order.
    /// Calling it again after `Cancelled` is a no-op.
    pub async fn cancel(&self) -> CancelOutcome {
        let mut st = self.state.lock().await;
        if st.cancel_confirmed {
            return CancelOutcome::Cancelled;
        }
        if st.executed {
            return CancelOutcome::CancellationFailed {
                reason: tr("Die Überweisung wurde bereits ausgeführt.").into(),
            };
        }
        // A closed session only needs another round if the bank may still
        // hold an open order from an earlier, unconfirmed cancellation.
        if st.done && !st.connector.has_open_order() {
            return CancelOutcome::Cancelled;
        }
        let TransferState { connector, ctx, .. } = &mut *st;
        let outcome = connector.cancel_transfer(ctx).await;
        st.done = true;
        st.cancel_confirmed = outcome == CancelOutcome::Cancelled;
        outcome
    }
}

/// "GC" + 30 hex digits: unique, within the 35-char SEPA limit and the
/// restricted character set.
pub(super) fn new_end_to_end_id() -> String {
    format!(
        "GC{}",
        &uuid::Uuid::new_v4().simple().to_string().to_uppercase()[..30]
    )
}

/// ISO 13616 Mod-97 IBAN check (whitespace and case ignored).
#[uniffi::export]
pub fn validate_iban(iban: String) -> bool {
    crate::connectors::fints::sepa::validate_iban(&iban)
}
