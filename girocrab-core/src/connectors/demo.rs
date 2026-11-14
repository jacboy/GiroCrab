//! Simulated connector for verification mode: shows the real two-phase flow
//! (push-TAN, code, PSD2 redirect) without touching any bank.

use async_trait::async_trait;

use super::{
    BankConnector, Challenge, ChallengeKind, ChallengeResponse, ConnectContext, FetchResult, Phase,
    RemoteAccount, RemoteTransaction, TransferJob,
};
use crate::demo::DEMO_ACCOUNTS;
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::ConnectorKind;

pub struct DemoConnector {
    kind: ConnectorKind,
    polls: u32,
    challenge: Option<Challenge>,
    result: super::TransferResult,
    /// Demo scenario for the approval reply of the current transfer.
    after_approval: DemoApproval,
    order_submitted: bool,
    /// Orders "sent" to the demo bank (tests: never more than one).
    pub orders_sent: u32,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DemoApproval {
    Executed,
    Unclear,
    ConnectionLost,
}

impl DemoConnector {
    pub fn new(kind: ConnectorKind) -> Self {
        DemoConnector {
            kind,
            polls: 0,
            challenge: None,
            result: super::TransferResult::default(),
            after_approval: DemoApproval::Executed,
            order_submitted: false,
            orders_sent: 0,
        }
    }
}

impl DemoConnector {
    /// Approval done (login or transfer). For a transfer, apply the scenario.
    fn approved(&mut self) -> CoreResult<Phase> {
        if !self.order_submitted {
            return Ok(Phase::Ready);
        }
        match self.after_approval {
            DemoApproval::Executed => {}
            DemoApproval::Unclear => {
                self.result = super::TransferResult::Unknown {
                    reason: tr("Demo: 9800 Dialog abgebrochen.").to_string(),
                };
            }
            DemoApproval::ConnectionLost => {
                return Err(CoreError::Network {
                    message: tr("Demo: Verbindung zur Bank unterbrochen.").into(),
                });
            }
        }
        Ok(Phase::Ready)
    }
}

#[async_trait]
impl BankConnector for DemoConnector {
    async fn begin(&mut self, _ctx: &ConnectContext) -> CoreResult<Phase> {
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        let c = match self.kind {
            ConnectorKind::VolksbankKasselGoettingen | ConnectorKind::Direkt1822 | ConnectorKind::FinTsGeneric | ConnectorKind::Comdirect | ConnectorKind::ScalableCapital => Challenge {
                kind: ChallengeKind::DecoupledPush,
                title: tr("Bitte in der Banking-App freigeben").into(),
                message: tr("Demo: Eine Push-Nachricht wurde „gesendet“. Die Freigabe wird nach wenigen Sekunden simuliert.").into(),
                method_name: match self.kind {
                    ConnectorKind::VolksbankKasselGoettingen => "SecureGo plus (Demo)".into(),
                    ConnectorKind::Direkt1822 => "pushTAN (Demo)".into(),
                    ConnectorKind::ScalableCapital => "Browser-Anmeldung (Demo)".into(),
                    _ => "photoTAN push (Demo)".into(),
                },
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(300),
                poll_interval_seconds: 2,
            },
            ConnectorKind::Easybank => Challenge {
                kind: ChallengeKind::Code,
                title: "easybank SMS-TAN".into(),
                message: tr("Demo: beliebigen 6-stelligen Code eingeben.").into(),
                method_name: tr("SMS-TAN (Demo)").into(),
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(300),
                poll_interval_seconds: 0,
            },
            ConnectorKind::TradeRepublic => Challenge {
                kind: ChallengeKind::Code,
                title: "Trade Republic 2FA".into(),
                message: tr("Demo: beliebigen 4-stelligen Code eingeben.").into(),
                method_name: tr("App-Code (Demo)").into(),
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(120),
                poll_interval_seconds: 0,
            },
            ConnectorKind::AmericanExpress
            | ConnectorKind::AmazonVisa
            | ConnectorKind::AmazonOrders
            | ConnectorKind::Quirion
            | ConnectorKind::Fnz
            | ConnectorKind::EnableBanking => Challenge {
                kind: ChallengeKind::Redirect,
                title: tr("Zustimmung beim Kartenherausgeber erteilen").into(),
                message: tr("Demo: Es wird keine echte Seite geöffnet. Beliebigen Text einfügen (z. B. https://localhost/cb?code=demo).").into(),
                method_name: tr("PSD2-Weiterleitung (Demo)").into(),
                redirect_url: Some("https://example.org/psd2-consent-demo".into()),
                image: None,
                expires_in_seconds: Some(900),
                poll_interval_seconds: 0,
            },
            ConnectorKind::PayPal | ConnectorKind::Bunq | ConnectorKind::Ibkr => return Ok(Phase::Ready),
        };
        self.challenge = Some(c.clone());
        Ok(Phase::Challenge(c))
    }

    async fn respond(
        &mut self,
        _ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        match response {
            ChallengeResponse::Poll => {
                self.polls += 1;
                if self.polls < 2 {
                    Ok(Phase::Pending(
                        self.challenge.clone().ok_or(CoreError::SessionClosed)?,
                    ))
                } else {
                    self.approved()
                }
            }
            ChallengeResponse::ConfirmPayee => {
                // The transfer challenge was held back until the user confirmed.
                Ok(Phase::Challenge(
                    self.challenge.clone().ok_or(CoreError::SessionClosed)?,
                ))
            }
            ChallengeResponse::Code(code) => {
                if self.kind == ConnectorKind::TradeRepublic
                    && !(matches!(code.expose().len(), 4 | 6)
                        && code.expose().chars().all(|c| c.is_ascii_digit()))
                {
                    return Err(CoreError::Authentication {
                        message: tr("Demo: Der Code muss 4 Ziffern haben").into(),
                    });
                }
                self.approved()
            }
        }
    }

    async fn send_transfer(
        &mut self,
        _ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<Phase> {
        self.polls = 0;
        // Demo scenarios by recipient name (instant only):
        //   "…langsam…"    – bank does not offer instant: declined, nothing sent
        //   "…unklar…"     – ambiguous bank reply after the approval
        //   "…netzfehler…" – connection lost after the approval
        let name = job.recipient_name.to_lowercase();
        self.result = super::TransferResult::Executed {
            instant: job.instant,
        };
        self.after_approval = DemoApproval::Executed;
        if job.instant && name.contains("langsam") {
            self.result = super::TransferResult::InstantDeclined {
                reason: tr(
                    "Demo: Die Empfängerbank ist für Echtzeitüberweisungen gerade nicht erreichbar.",
                )
                .to_string(),
            };
            return Ok(Phase::Ready);
        }
        if job.instant && name.contains("unklar") {
            self.after_approval = DemoApproval::Unclear;
        } else if job.instant && name.contains("netzfehler") {
            self.after_approval = DemoApproval::ConnectionLost;
        }
        self.order_submitted = true;
        self.orders_sent += 1;
        let c = Challenge {
            kind: ChallengeKind::DecoupledPush,
            title: tr("Überweisung in der Banking-App freigeben").into(),
            message: trf(
                "Demo: {0} an {1} wird nach wenigen Sekunden „freigegeben“.",
                &[
                    &crate::money::format_cents(job.amount_cents, "EUR".into()),
                    &job.recipient_name,
                ],
            ),
            method_name: "pushTAN (Demo)".into(),
            redirect_url: None,
            image: None,
            expires_in_seconds: Some(300),
            poll_interval_seconds: 2,
        };
        self.challenge = Some(c.clone());
        // Demo name check: "…fast…" = close match, "…falsch…" = no match.
        let name = job.recipient_name.to_lowercase();
        let result = if name.contains("fast") {
            Some(super::PayeeMatch::CloseMatch)
        } else if name.contains("falsch") {
            Some(super::PayeeMatch::NoMatch)
        } else {
            None
        };
        if let Some(result) = result {
            return Ok(Phase::ConfirmPayee(super::PayeeCheck {
                result,
                entered_name: job.recipient_name.clone(),
                iban: job.recipient_iban.clone(),
                bank_name: (result == super::PayeeMatch::CloseMatch)
                    .then(|| "Erika Mustermann".to_string()),
                reason: None,
                notice: Some(
                    tr("Demo: Wenn Sie die Überweisung trotzdem freigeben, kann das Geld auf einem Konto landen, das nicht dem gewünschten Empfänger gehört.")
                        .into(),
                ),
            }));
        }
        Ok(Phase::Challenge(c))
    }

    async fn send_batch_transfer(
        &mut self,
        ctx: &ConnectContext,
        job: &super::BatchTransferJob,
    ) -> CoreResult<Phase> {
        let total = job.payments.iter().map(|p| p.amount_cents).sum();
        let summary = TransferJob {
            source_iban: job.source_iban.clone(),
            source_owner: job.source_owner.clone(),
            recipient_name: "Sammelüberweisung".into(),
            recipient_iban: String::new(),
            recipient_bic: None,
            amount_cents: total,
            purpose: String::new(),
            instant: false,
            execution_date: job.execution_date.clone(),
            end_to_end_id: String::new(),
        };
        self.send_transfer(ctx, &summary).await
    }

    fn transfer_result(&self) -> super::TransferResult {
        self.result.clone()
    }

    fn order_submitted(&self) -> bool {
        self.order_submitted
    }

    async fn fetch(&mut self, _ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let today = super::today();
        let stamp = chrono::Local::now().timestamp();
        let mut out = FetchResult::default();
        // A magic-login connection at a bank without own demo accounts (generic
        // FinTS, comdirect, …) shows the demo giro bank's accounts.
        let kind = if DEMO_ACCOUNTS.iter().any(|s| s.connector == self.kind) {
            self.kind
        } else {
            ConnectorKind::VolksbankKasselGoettingen
        };
        for spec in DEMO_ACCOUNTS.iter().filter(|s| s.connector == kind) {
            out.accounts.push(RemoteAccount {
                external_ref: spec.external_ref.into(),
                name: spec.name.into(),
                owner: "Erika Mustermann".into(),
                iban: spec.iban.into(),
                account_number: String::new(),
                currency: "EUR".into(),
                kind: spec.kind,
                balance_cents: spec.opening_cents,
                balance_date: today.clone(),
            });
        }
        if let Some(first) = DEMO_ACCOUNTS
            .iter()
            .find(|s| s.connector == kind && s.kind != crate::models::AccountKind::Brokerage)
        {
            let (cp, purpose, cents) = match self.kind {
                ConnectorKind::PayPal => ("Lieferando.de", "Bestellung Lieferando", -23_40),
                ConnectorKind::TradeRepublic => ("Trade Republic", "Zinsen", 3_87),
                ConnectorKind::ScalableCapital => ("Scalable Capital", "Zinsen Overnight", 5_12),
                ConnectorKind::AmericanExpress
                | ConnectorKind::AmazonVisa
                | ConnectorKind::AmazonOrders
                | ConnectorKind::EnableBanking => ("AMZN Mktp DE", "Amazon.de Bestellung", -34_99),
                _ => (
                    "REWE Markt GmbH",
                    "Kartenzahlung girocard (Demo-Sync)",
                    -27_65,
                ),
            };
            out.transactions.push(RemoteTransaction {
                account_ref: first.external_ref.into(),
                external_id: format!("demo-sync-{stamp}"),
                booking_date: today.clone(),
                value_date: today.clone(),
                amount_cents: cents,
                currency: "EUR".into(),
                counterparty: cp.into(),
                counterparty_iban: String::new(),
                purpose: purpose.into(),
                booking_text: "DEMO".into(),
                ..Default::default()
            });
        }
        // Balances are not re-reported by the simulated bank; the vault adds
        // the new bookings to the stored balances instead.
        out.adjust_balances = true;
        out.simulated = true;
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connectors::{BankConnector, TransferResult};
    use crate::secret::SecretString;

    fn ctx() -> ConnectContext {
        ConnectContext {
            connection_id: 1,
            login_name: String::new(),
            secret: SecretString::new("pin".into()),
            settings: Default::default(),
            state: serde_json::Value::Null,
            since: String::new(),
            since_by_account: Default::default(),
        }
    }

    fn job(name: &str) -> TransferJob {
        TransferJob {
            source_iban: "DE02120300000000202051".into(),
            source_owner: String::new(),
            recipient_name: name.into(),
            recipient_iban: "DE89370400440532013000".into(),
            recipient_bic: None,
            amount_cents: 100,
            purpose: String::new(),
            instant: true,
            execution_date: None,
            end_to_end_id: "GCTEST".into(),
        }
    }

    /// No scenario ever sends a second order: declined instant sends none,
    /// unclear / lost connection after approval stay at exactly one.
    #[tokio::test]
    async fn never_sends_a_second_order() {
        let c = ctx();
        for (name, sent, want_unknown) in [
            ("Langsam AG", 0, false),
            ("Unklar KG", 1, true),
            ("Netzfehler GmbH", 1, true),
            ("Schnell GmbH", 1, false),
        ] {
            let mut d = DemoConnector::new(ConnectorKind::FinTsGeneric);
            let mut phase = d.send_transfer(&c, &job(name)).await;
            while let Ok(Phase::Challenge(_) | Phase::Pending(_)) = phase {
                phase = d.respond(&c, ChallengeResponse::Poll).await;
            }
            assert_eq!(d.orders_sent, sent, "{name}");
            let unknown = matches!(d.transfer_result(), TransferResult::Unknown { .. })
                || (phase.is_err() && d.order_submitted());
            assert_eq!(unknown, want_unknown, "{name}");
        }
    }
}
