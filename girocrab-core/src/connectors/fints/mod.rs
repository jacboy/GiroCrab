//! FinTS 3.0 PIN/TAN connector (HBCI+), clean-room implementation of the
//! public DK specification ("FinTS 3.0 Formals", "Sicherheitsverfahren
//! PIN/TAN", "Messages – Multibankfähige Geschäftsvorfälle").
//!
//! Flow:
//!   1. Synchronisation dialog (first run only): HKIDN/HKVVB/HKSYN with
//!      security function 999 -> customer system ID, bank parameters (BPD) and
//!      the TAN methods allowed for this user (code 3920).
//!   2. Authenticated dialog: HKIDN/HKVVB + HKTAN process 4 (PSD2 SCA).
//!      The bank answers with
//!        * 3955 -> decoupled: approve in the app; poll with HKTAN process S
//!        * 0030 -> enter TAN; send HKTAN process 2 + PIN:TAN in HNSHA
//!        * 3076 / success -> no SCA needed.
//!   3. Accounts from the UPD (HIUPD, incl. the business transactions each
//!      account allows) merged with HKSPA; per account only what the bank
//!      allows: HKSAL (balance) and statements via HKCAZ (camt.052, preferred)
//!      or HKKAZ (MT940, fallback). Loan accounts get statements only if their HIUPD allows it.
//!      Depots (Kontoart 30-39/60-69) get their value from HKWPD (MT535 holdings).
//!      Segment versions are negotiated from the BPD ("HIxxxS" parameter
//!      segments): always the highest version both sides support.
//!   4. Any 9xxx return code is reported with the code and the offending
//!      segment ("9050 [HKKAZ #3] Auftragsart wird nicht unterstützt").
//!   5. Transfers: HKCCS (regular SEPA) or HKIPZ (SEPA Instant), each with
//!      HKTAN process 4. An instant transfer the bank does not offer or rejects
//!      (on submission or after the approval) is reported as declined; nothing
//!      is resent automatically. The app may offer a regular transfer, which
//!      is a new order with its own approval. Ambiguous replies and lost
//!      connections after submission mean "outcome unknown".
//!   6. Name check (Verification of Payee), where the BPD (HIVPPS) requires it
//!      for the order: HKVPP goes in front of the order; the bank answers with
//!      HIVPP (VOP-ID + result, possibly after polling). A match continues to
//!      the approval (HKVPA is sent with the TAN). Anything else is shown to
//!      the user; on confirmation, HKVPA + order + HKTAN is sent again. Cancel
//!      ends the dialog without HKVPA, so the order is never approved.
//!
//! The registration-bound product ID is never hardcoded; it comes from
//! Settings (`fints.product_id`).

pub mod camt;
pub mod mt535;
pub mod mt940;
pub mod product_id;
pub mod sepa;
pub mod syntax;

use std::collections::{HashMap, HashSet};

use async_trait::async_trait;
use base64::Engine;
use serde::{Deserialize, Serialize};

use self::syntax::{escape, parse_response, Segment, SegmentBuilder};
use super::{
    BankConnector, BatchTransferJob, Challenge, ChallengeKind, ChallengeResponse, ConnectContext,
    FetchResult, PayeeCheck, PayeeMatch, Phase, RemoteAccount, TransferJob, TransferResult,
};
use crate::error::{CoreError, CoreResult};
use crate::i18n::{tr, trf};
use crate::models::AccountKind;
use crate::money::parse_cents;

const COUNTRY: &str = "280";

/// Persisted between syncs (in bank_connections.state_json).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct FinTsState {
    system_id: String,
    /// Chosen two-step security function (e.g. "946"), "999" = one-step.
    sec_func: String,
    tan_method_name: String,
    tan_medium: String,
    /// Supported versions per business transaction (from BPD "...S" segments).
    versions: HashMap<String, Vec<u32>>,
    /// HKxxx -> TAN required (HIPINS).
    tan_required: HashMap<String, bool>,
    /// camt descriptors from HICAZS, best first.
    #[serde(default)]
    camt_formats: Vec<String>,
    /// pain.001 descriptors per transfer transaction (HKCCS/HKIPZ/HKCSE) from the BPD
    /// parameter segments HICCSS / HIIPZS / HICSES.
    #[serde(default)]
    pain_formats: HashMap<String, Vec<String>>,
    /// Batch transfer parameters from HICCMS; `None` = not offered.
    #[serde(default)]
    batch_params: Option<BatchParams>,
    /// Payment status report format for the name check (HIVPPS), "" = none.
    #[serde(default)]
    vop_format: String,
    /// Orders that need a name check first (HIVPPS), e.g. HKCCS, HKIPZ.
    #[serde(default)]
    vop_orders: Vec<String>,
    /// The bank rejected the two-step dialog init (900 + HKTAN) with 9010; from then on
    /// the dialog is opened with the one-step function 999 and without HKTAN.
    #[serde(default)]
    single_step: bool,
}

/// Versions of each business transaction this client implements.
const IMPLEMENTED: &[(&str, &[u32])] = &[
    ("HKSAL", &[5, 6, 7, 8]),
    ("HKCAZ", &[1]),
    ("HKCCS", &[1]),
    ("HKIPZ", &[1]),
    ("HKCSE", &[1]),
    ("HKCCM", &[1]),
    ("HKVPP", &[1]),
    ("HKKAZ", &[5, 6, 7]),
    ("HKTAN", &[6, 7]),
    ("HKSPA", &[1, 2, 3]),
    ("HKTAB", &[4, 5]),
    ("HKEKA", &[3, 4, 5]),
    ("HKWPD", &[5, 6]),
];

/// What the bank allows for batch transfers (BPD HICCMS).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
struct BatchParams {
    /// Most payments in one order, 0 = not stated.
    max_count: u32,
    /// The order must carry the control sum (Summenfeld).
    sum_required: bool,
    /// The bank accepts "one booking per payment".
    single_booking_allowed: bool,
}

/// HICCMS: header, max. orders, signatures, security class, then the
/// parameter DEG: max. payments, Summenfeld required, single booking
/// allowed, pain descriptors. Tolerates missing fields (stricter reading
/// is only possible against a real BPD).
fn parse_batch_params(seg: &Segment) -> BatchParams {
    let flag = |s: &str| s == "J";
    BatchParams {
        max_count: seg.get(4, 0).parse().unwrap_or(0),
        sum_required: flag(seg.get(4, 1)),
        single_booking_allowed: flag(seg.get(4, 2)),
    }
}

/// Account from the user parameter data (HIUPD).
#[derive(Debug, Clone, Default)]
struct UpdAccount {
    iban: String,
    account_number: String,
    sub_account: String,
    blz: String,
    kind_code: u32,
    currency: String,
    owner: String,
    product: String,
    /// Business transactions allowed for this account (empty = unknown, all).
    allowed: HashSet<String>,
}

/// Consorsbank (BNP Paribas): see `docs/consorsbank-connector.md`.
const CONSORSBANK_BLZ: &str = "76030080";

fn kind_from_code(code: u32) -> AccountKind {
    // FinTS Kontoart: 1-9 Kontokorrent, 10-19 Sparkonto, 20-29 Festgeld,
    // 30-39 Depot, 40-49 Darlehen, 50-59 Kreditkarte, 60-69 Fonds-Depot,
    // 70-79 Bausparvertrag, 80-89 Versicherung, 90-99 Sonstige
    match code {
        10..=29 | 70..=79 => AccountKind::Savings,
        30..=39 | 60..=69 => AccountKind::Brokerage,
        40..=49 => AccountKind::Loan,
        50..=59 => AccountKind::CreditCard,
        _ => AccountKind::Checking,
    }
}

/// FinTS date `YYYYMMDD` → `YYYY-MM-DD`; `None` unless exactly 8 ASCII digits
/// (no byte slicing into a multi-byte character).
fn fints_date(d: &str) -> Option<String> {
    if d.len() != 8 || !d.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(format!("{}-{}-{}", &d[..4], &d[4..6], &d[6..]))
}

fn is_segment_code(s: &str) -> bool {
    s.len() == 5
        && (s.starts_with("HK") || s.starts_with("DK"))
        && s[2..].chars().all(|c| c.is_ascii_uppercase())
}

/// Parses one HIUPD segment (v4–v6).
fn parse_upd(upd: &Segment) -> UpdAccount {
    let mut a = UpdAccount {
        account_number: upd.get(1, 0).to_string(),
        sub_account: upd.get(1, 1).to_string(),
        blz: upd.get(1, 3).to_string(),
        iban: upd.get(2, 0).to_string(),
        kind_code: upd.get(4, 0).parse().unwrap_or(1),
        currency: upd.get(5, 0).to_string(),
        owner: format!("{} {}", upd.get(6, 0), upd.get(7, 0))
            .trim()
            .to_string(),
        product: upd.get(8, 0).to_string(),
        allowed: HashSet::new(),
    };
    // HIUPD v4/v5 have no IBAN element: shift if element 2 is the customer id
    if !a.iban.is_empty()
        && !(a.iban.len() >= 15 && a.iban.chars().take(2).all(|c| c.is_ascii_uppercase()))
    {
        a.iban.clear();
    }
    for el in upd.elements.iter().skip(9) {
        if let Some(first) = el.first() {
            if is_segment_code(first.text()) {
                a.allowed.insert(first.text().to_string());
            }
        }
    }
    a
}

#[derive(Debug, Clone)]
struct SepaAccount {
    iban: String,
    bic: String,
    account_number: String,
    sub_account: String,
    blz: String,
}

#[derive(Debug, Clone)]
struct BankReply {
    segments: Vec<Segment>,
    /// (code, reference segment number, text, params)
    codes: Vec<(String, Option<u32>, String, Vec<String>)>,
    /// Segment number -> segment id of the request (for error messages).
    sent: HashMap<u32, String>,
}

impl BankReply {
    fn has(&self, code: &str) -> bool {
        self.codes.iter().any(|c| c.0 == code)
    }
    fn code(&self, code: &str) -> Option<&(String, Option<u32>, String, Vec<String>)> {
        self.codes.iter().find(|c| c.0 == code)
    }
    fn errors(&self) -> Vec<&(String, Option<u32>, String, Vec<String>)> {
        self.codes.iter().filter(|c| c.0.starts_with('9')).collect()
    }
    fn first(&self, id: &str) -> Option<&Segment> {
        self.segments.iter().find(|s| s.id() == id)
    }
    fn all<'a>(&'a self, id: &'a str) -> impl Iterator<Item = &'a Segment> + 'a {
        self.segments.iter().filter(move |s| s.id() == id)
    }
    /// "9050 [HKKAZ #3] Auftragsart wird nicht unterstützt"
    fn describe(&self, code: &(String, Option<u32>, String, Vec<String>)) -> String {
        let seg = match code.1 {
            Some(n) => format!(
                "[{} #{n}]",
                self.sent
                    .get(&n)
                    .cloned()
                    .unwrap_or_else(|| "Segment".into())
            ),
            None => "[Nachricht]".into(),
        };
        let params = if code.3.is_empty() {
            String::new()
        } else {
            format!(" ({})", code.3.join(", "))
        };
        format!("{} {} {}{}", code.0, seg, code.2, params)
    }

    /// Like `check`, but with German explanations for typical HKCCS rejections.
    fn check_transfer(&self) -> CoreResult<()> {
        let errs = self.errors();
        let Some(first) = errs.first() else {
            return Ok(());
        };
        let msg = errs
            .iter()
            .map(|e| explain_transfer_code(e))
            .collect::<Vec<_>>()
            .join(" / ");
        Err(CoreError::Bank {
            code: first.0.clone(),
            message: msg,
        })
    }

    fn check(&self) -> CoreResult<()> {
        let errs = self.errors();
        if let Some(e) = errs.first() {
            return Err(CoreError::Bank {
                code: e.0.clone(),
                message: errs
                    .iter()
                    .map(|e| self.describe(e))
                    .collect::<Vec<_>>()
                    .join(" / "),
            });
        }
        Ok(())
    }
}

pub struct FinTsConnector {
    blz: String,
    url: String,
    client: Option<reqwest::Client>,
    dialog_id: String,
    msg_no: u32,
    st: FinTsState,
    task_reference: Option<String>,
    challenge: Option<Challenge>,
    tan_for_next: Option<String>,
    product_id: String,
    product_version: String,
    /// Accounts from the user parameter data (HIUPD).
    upd: Vec<UpdAccount>,
    /// A SEPA transfer (HKCCS/HKIPZ) is awaiting its TAN.
    transferring: bool,
    /// TAN medium name entered by the user (e.g. Postbank BestSign `SO:Gerät`);
    /// wins over the HKTAB lookup.
    tan_medium_override: String,
    /// The bank answered a statement request with 3997 ("nur teilweise
    /// ausgeführt"): it delivered less than the requested period.
    partial_statements: bool,
    /// The order was handed to the bank: from here on, an unclear reply or a
    /// lost connection means "result unknown", never "not executed".
    order_submitted: bool,
    result: TransferResult,
    /// The order being sent.
    order: Option<PreparedOrder>,
    /// Segment number of the order in the last order message (the name check
    /// segment shifts it), to read the bank's per-segment confirmation.
    order_seg_no: u32,
    /// VOP-ID from HIVPP, sent back with HKVPA.
    vop_id: Option<Vec<u8>>,
    /// Name matched: send HKVPA along with the TAN.
    vop_with_tan: bool,
    /// Name-check result shown to the user, awaiting confirmation.
    vop_pending: Option<PayeeMatch>,
}

/// A transfer order ready to send (segment number set at send time).
#[derive(Clone)]
struct PreparedOrder {
    seg_id: &'static str,
    kti: String,
    descriptor: &'static str,
    xml: String,
    instant: bool,
    recipient_name: String,
    recipient_iban: String,
    /// HKCCM only: control sum in cents and "one booking per payment".
    batch: Option<(i64, bool)>,
}

/// Longest wait between two name-check polls, and in total.
const VOP_POLL_WAIT_MAX: std::time::Duration = std::time::Duration::from_secs(3);
const VOP_POLL_TOTAL_MAX: std::time::Duration = std::time::Duration::from_secs(25);

/// Name-check part of an order message.
enum Vop {
    None,
    /// HKVPP + order + HKTAN: the first name check request.
    Check,
    /// HKVPP only, with the polling ID (and the continuation point from
    /// 3040): asks again while the result is pending. Never carries the
    /// order or HKTAN, so polling cannot create a second order.
    Poll {
        polling_id: Vec<u8>,
        touchdown: Option<String>,
    },
    /// HKVPA with the VOP-ID.
    Execute,
}

/// What a bank reply means for a transfer order.
#[derive(Debug, PartialEq, Eq)]
enum OrderReply {
    /// No errors: accepted (a challenge may follow) or executed.
    Accepted,
    /// Clearly not executed; report the bank's error.
    Rejected,
    /// Instant order clearly not executed; the user may send it as a
    /// regular transfer (new order, new approval).
    InstantDeclined(String),
    /// The order may have been executed.
    Unknown(String),
}

impl FinTsConnector {
    pub fn new(blz: &str) -> Self {
        FinTsConnector {
            blz: blz.to_string(),
            url: String::new(),
            client: None,
            dialog_id: "0".into(),
            msg_no: 1,
            st: FinTsState::default(),
            task_reference: None,
            challenge: None,
            tan_for_next: None,
            product_id: String::new(),
            product_version: String::new(),
            upd: Vec::new(),
            transferring: false,
            tan_medium_override: String::new(),
            partial_statements: false,
            order_submitted: false,
            result: TransferResult::default(),
            order: None,
            order_seg_no: 3,
            vop_id: None,
            vop_with_tan: false,
            vop_pending: None,
        }
    }

    fn now() -> (String, String) {
        let n = chrono::Local::now();
        (
            n.format("%Y%m%d").to_string(),
            n.format("%H%M%S").to_string(),
        )
    }

    fn system_id(&self) -> &str {
        if self.st.system_id.is_empty() {
            "0"
        } else {
            &self.st.system_id
        }
    }

    /// Highest version of `tx` that both the bank (BPD) and this client support.
    fn negotiated(&self, tx: &str) -> Option<u32> {
        let ours = IMPLEMENTED
            .iter()
            .find(|(k, _)| *k == tx)
            .map(|(_, v)| *v)
            .unwrap_or(&[]);
        self.st
            .versions
            .get(tx)
            .and_then(|vs| vs.iter().copied().filter(|v| ours.contains(v)).max())
    }

    /// Like `negotiated`, but falls back to our highest version when the bank
    /// sent no parameters for it (e.g. before the first BPD).
    fn version(&self, tx: &str) -> u32 {
        self.negotiated(tx).unwrap_or_else(|| {
            IMPLEMENTED
                .iter()
                .find(|(k, _)| *k == tx)
                .and_then(|(_, v)| v.iter().max().copied())
                .unwrap_or(1)
        })
    }

    fn bank_supports(&self, tx: &str) -> bool {
        self.negotiated(tx).is_some()
    }

    /// Security profile of HNSHK/HNVSK: version 1 for the one-step method
    /// (security function 999, synchronisation dialog), version 2 for every
    /// two-step TAN method. Strict banks (Consorsbank) reject a mismatch with
    /// "9010 Ungültiger Signaturaufbau".
    fn security_profile(sec_func: &str) -> &'static str {
        if sec_func == "999" {
            "PIN:1"
        } else {
            "PIN:2"
        }
    }

    /// Wraps payload segments (numbered from 3) into a signed, "encrypted"
    /// PIN/TAN message and returns the wire bytes.
    fn build_message(
        &self,
        ctx: &ConnectContext,
        payload: &[Vec<u8>],
        sec_func: &str,
        tan: Option<&str>,
    ) -> Vec<u8> {
        let (date, time) = Self::now();
        let user = escape(&ctx.login_name);
        let ctrl_ref = format!("{}", rand::random::<u32>() % 9_000_000 + 1_000_000);
        let profile = Self::security_profile(sec_func);
        let mut inner: Vec<u8> = Vec::new();
        inner.extend(
            SegmentBuilder::new("HNSHK", 2, 4)
                .raw(profile)
                .raw(sec_func)
                .raw(&ctrl_ref)
                .raw("1")
                .raw("1")
                .raw(&format!("1::{}", escape(self.system_id())))
                .raw("1")
                .raw(&format!("1:{date}:{time}"))
                .raw("1:999:1")
                .raw("6:10:16")
                .raw(&format!("{COUNTRY}:{}:{user}:S:0:0", self.blz))
                .build(),
        );
        for p in payload {
            inner.extend_from_slice(p);
        }
        let n_sha = 3 + payload.len() as u32;
        let pin = escape(ctx.secret.expose());
        let auth = match tan {
            Some(t) => format!("{pin}:{}", escape(t)),
            None => pin,
        };
        inner.extend(
            SegmentBuilder::new("HNSHA", n_sha, 2)
                .raw(&ctrl_ref)
                .raw("")
                .raw(&auth)
                .build(),
        );

        let hnvsk = SegmentBuilder::new("HNVSK", 998, 3)
            .raw(profile)
            .raw("998")
            .raw("1")
            .raw(&format!("1::{}", escape(self.system_id())))
            .raw(&format!("1:{date}:{time}"))
            .raw("2:2:13:@8@00000000:5:1")
            .raw(&format!("{COUNTRY}:{}:{user}:V:0:0", self.blz))
            .raw("0")
            .build();
        let hnvsd = SegmentBuilder::new("HNVSD", 999, 1).binary(&inner).build();
        let hnhbs = SegmentBuilder::new("HNHBS", n_sha + 1, 1)
            .raw(&self.msg_no.to_string())
            .build();

        let build = |size: usize| {
            let mut m = SegmentBuilder::new("HNHBK", 1, 3)
                .raw(&format!("{size:012}"))
                .raw("300")
                .raw(&escape(&self.dialog_id))
                .raw(&self.msg_no.to_string())
                .build();
            m.extend_from_slice(&hnvsk);
            m.extend_from_slice(&hnvsd);
            m.extend_from_slice(&hnhbs);
            m
        };
        let len = build(0).len();
        build(len)
    }

    async fn send(
        &mut self,
        ctx: &ConnectContext,
        payload: Vec<Vec<u8>>,
        sec_func: &str,
        tan: Option<&str>,
    ) -> CoreResult<BankReply> {
        let mut sent = HashMap::new();
        sent.insert(2, "HNSHK".to_string());
        for p in &payload {
            let head = crate::text::decode_bank_bytes(&p[..p.len().min(16)]);
            let mut it = head.split(':');
            if let (Some(id), Some(n)) = (it.next(), it.next().and_then(|n| n.parse::<u32>().ok()))
            {
                sent.insert(n, id.to_string());
            }
        }
        sent.insert(3 + payload.len() as u32, "HNSHA".to_string());
        let msg = self.build_message(ctx, &payload, sec_func, tan);
        super::ensure_secure_fints_url(&self.url)?;
        let client = match &self.client {
            Some(c) => c.clone(),
            None => {
                let c = super::http_client_no_redirect()?;
                self.client = Some(c.clone());
                c
            }
        };
        let body = base64::engine::general_purpose::STANDARD.encode(&msg);
        let resp = client
            .post(&self.url)
            .header("Content-Type", "text/plain")
            .body(body)
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(CoreError::Network {
                message: format!("FinTS server answered HTTP {}", resp.status()),
            });
        }
        let text = super::read_text_limited(resp).await?;
        let cleaned: String = text.chars().filter(|c| !c.is_whitespace()).collect();
        let raw = base64::engine::general_purpose::STANDARD
            .decode(cleaned.as_bytes())
            .map_err(|e| CoreError::Protocol {
                message: format!("base64: {e}"),
            })?;
        let segments = parse_response(&raw)?;
        self.msg_no += 1;
        let mut codes = Vec::new();
        for s in &segments {
            if s.id() == "HIRMG" || s.id() == "HIRMS" {
                for el in s.elements.iter().skip(1) {
                    let t = |i: usize| el.get(i).map(|v| v.text().to_string()).unwrap_or_default();
                    let params = el.iter().skip(3).map(|v| v.text().to_string()).collect();
                    codes.push((t(0), s.reference(), t(2), params));
                }
            }
        }
        if crate::depot_debug::enabled() {
            // Step trace: segment names and return codes only, no texts or data.
            crate::depot_debug::log(&format!(
                "fints msg: sec={} profile={} sent={:?} codes={:?}",
                if sec_func == "999" {
                    "one-step"
                } else {
                    "two-step"
                },
                Self::security_profile(sec_func),
                payload
                    .iter()
                    .map(|p| {
                        // "HKKAZ:3:7" – segment header only
                        let head = crate::text::decode_bank_bytes(&p[..p.len().min(16)]);
                        head.split(['+', '\''])
                            .next()
                            .unwrap_or_default()
                            .to_string()
                    })
                    .collect::<Vec<_>>(),
                codes
                    .iter()
                    .map(|c: &(String, Option<u32>, String, Vec<String>)| match c.1 {
                        Some(n) => format!("{}@{n}", c.0),
                        None => c.0.clone(),
                    })
                    .collect::<Vec<_>>()
            ));
            // Bank's wording for errors and unusual warnings (generic texts, no
            // parameters). Routine codes (no SCA, BPD/UPD hints, TAN list) are skipped.
            for c in codes.iter().filter(|c| {
                c.0.starts_with('9')
                    || (c.0.starts_with('3')
                        && !matches!(c.0.as_str(), "3050" | "3060" | "3076" | "3920"))
            }) {
                crate::depot_debug::log(&format!(
                    "fints {} {}: {} (params: {})",
                    if c.0.starts_with('9') {
                        "error"
                    } else {
                        "warning"
                    },
                    c.0,
                    c.2.chars().take(160).collect::<String>(),
                    c.3.len()
                ));
            }
        }
        if let Some(h) = segments.iter().find(|s| s.id() == "HNHBK") {
            let did = h.get(3, 0);
            if !did.is_empty() && did != "0" {
                self.dialog_id = did.to_string();
            }
        }
        Ok(BankReply {
            segments,
            codes,
            sent,
        })
    }

    fn reset_dialog(&mut self) {
        self.dialog_id = "0".into();
        self.msg_no = 1;
    }

    fn learn_bpd(&mut self, reply: &BankReply) {
        for s in &reply.segments {
            let id = s.id();
            if id.starts_with("HI") && id.ends_with('S') && id.len() == 6 {
                let tx = format!("HK{}", &id[2..5]);
                let v = self.st.versions.entry(tx).or_default();
                if !v.contains(&s.version()) {
                    v.push(s.version());
                }
                if id == "HIKAZS" {
                    // bank parameters only: storage period (days), flags
                    let params: Vec<String> = s
                        .elements
                        .iter()
                        .skip(4)
                        .map(|el| el.iter().map(|v| v.text()).collect::<Vec<_>>().join(":"))
                        .collect();
                    crate::depot_debug::log(&format!(
                        "fints BPD HIKAZS v{} params={}",
                        s.version(),
                        params.join("+")
                    ));
                }
                if id == "HIEKAS" {
                    // bank parameters only (formats, flags) – no customer data
                    let params: Vec<String> = s
                        .elements
                        .iter()
                        .skip(4)
                        .map(|el| el.iter().map(|v| v.text()).collect::<Vec<_>>().join(":"))
                        .collect();
                    crate::depot_debug::log(&format!(
                        "statements: BPD HIEKAS v{} params={}",
                        s.version(),
                        params.join("+")
                    ));
                }
            }
            if id == "HIPINS" {
                // last element: list of (segment, J/N) pairs after 5 PIN fields
                if let Some(el) = s.elements.last() {
                    let texts: Vec<&str> = el.iter().map(|v| v.text()).collect();
                    for pair in texts.windows(2) {
                        if pair[0].starts_with("HK")
                            && pair[0].len() == 5
                            && (pair[1] == "J" || pair[1] == "N")
                        {
                            self.st
                                .tan_required
                                .insert(pair[0].to_string(), pair[1] == "J");
                        }
                    }
                }
            }
        }
        for cazs in reply.all("HICAZS") {
            for el in &cazs.elements {
                for v in el {
                    let t = v.text();
                    if t.contains("camt.052") && !self.st.camt_formats.iter().any(|f| f == t) {
                        self.st.camt_formats.push(t.to_string());
                    }
                }
            }
            // best (newest) format first: …camt.052.001.08 > …001.02
            self.st.camt_formats.sort_by(|a, b| b.cmp(a));
        }
        for (seg, tx) in [
            ("HICCSS", "HKCCS"),
            ("HIIPZS", "HKIPZ"),
            ("HICSES", "HKCSE"),
            ("HICCMS", "HKCCM"),
        ] {
            // Merge across BPD messages (anonymous and authenticated dialog).
            for f in pain_formats(reply, seg) {
                let list = self.st.pain_formats.entry(tx.to_string()).or_default();
                if !list.contains(&f) {
                    list.push(f);
                }
            }
        }
        if let Some(seg) = reply.first("HICCMS") {
            self.st.batch_params = Some(parse_batch_params(seg));
        }
        if let Some(vpps) = reply.first("HIVPPS") {
            let (format, orders) = vop_parameters(vpps);
            self.st.vop_format = format;
            self.st.vop_orders = orders;
        }
        let upds: Vec<UpdAccount> = reply.all("HIUPD").map(parse_upd).collect();
        for a in upds {
            if let Some(existing) = self
                .upd
                .iter_mut()
                .find(|e| e.account_number == a.account_number && e.sub_account == a.sub_account)
            {
                *existing = a;
            } else {
                self.upd.push(a);
            }
        }
        if let Some(sync) = reply.first("HISYN") {
            let id = sync.get(1, 0);
            if !id.is_empty() {
                self.st.system_id = id.to_string();
            }
        }
        // Allowed TAN methods for this user.
        if let Some(c) = reply.code("3920") {
            let allowed: Vec<String> =
                c.3.iter()
                    .filter(|p| !p.is_empty() && p.as_str() != "999")
                    .cloned()
                    .collect();
            let names = self.tan_method_names(reply);
            if !allowed.is_empty()
                && (self.st.sec_func.is_empty() || !allowed.contains(&self.st.sec_func))
            {
                // Prefer app based / decoupled methods.
                let pick = choose_tan_function(&allowed, &names);
                self.st.tan_method_name = names.get(&pick).cloned().unwrap_or_default();
                self.st.sec_func = pick;
            }
        }
        if let (Some(hitab), true) = (reply.first("HITAB"), self.tan_medium_override.is_empty()) {
            for el in hitab.elements.iter().skip(2) {
                let texts: Vec<&str> = el.iter().map(|v| v.text()).collect();
                if texts.get(1) == Some(&"1") {
                    if let Some(name) = texts
                        .iter()
                        .skip(2)
                        .find(|t| t.chars().any(|c| c.is_alphabetic()) && t.len() > 2)
                    {
                        self.st.tan_medium = name.to_string();
                        break;
                    }
                }
            }
        }
    }

    /// code -> human name, from HITANS (v6/v7: code, process, tech id, ZKA name, ZKA version, name …).
    fn tan_method_names(&self, reply: &BankReply) -> HashMap<String, String> {
        let mut out = HashMap::new();
        for s in reply.all("HITANS") {
            if let Some(el) = s.elements.get(4) {
                let t: Vec<&str> = el.iter().map(|v| v.text()).collect();
                for i in 0..t.len().saturating_sub(5) {
                    if t[i].len() == 3
                        && t[i].starts_with('9')
                        && (t[i + 1] == "1" || t[i + 1] == "2")
                    {
                        out.insert(t[i].to_string(), t[i + 5].to_string());
                    }
                }
            }
        }
        out
    }

    fn hkidn(&self, ctx: &ConnectContext, n: u32) -> Vec<u8> {
        SegmentBuilder::new("HKIDN", n, 2)
            .raw(&format!("{COUNTRY}:{}", self.blz))
            .de(&[&ctx.login_name])
            .de(&[self.system_id()])
            .raw("1")
            .build()
    }

    fn hkvvb(&self, n: u32) -> Vec<u8> {
        SegmentBuilder::new("HKVVB", n, 3)
            .raw("0")
            .raw("0")
            .raw("0")
            .de(&[&self.product_id])
            .de(&[&self.product_version])
            .build()
    }

    fn hktan_process4(&self, n: u32, reference_segment: &str) -> Vec<u8> {
        let mut b = SegmentBuilder::new("HKTAN", n, self.version("HKTAN"))
            .raw("4")
            .raw(reference_segment);
        if !self.st.tan_medium.is_empty() {
            for _ in 0..8 {
                b = b.raw("");
            }
            b = b.de(&[&self.st.tan_medium]);
        }
        b.build()
    }

    /// Analyses a reply that may carry a TAN challenge.
    fn challenge_from(&mut self, reply: &BankReply) -> CoreResult<Option<Phase>> {
        let hitan = reply.first("HITAN");
        if let Some(h) = hitan {
            let task = h.get(3, 0);
            if !task.is_empty() && task != "noref" {
                self.task_reference = Some(task.to_string());
            }
        }
        let challenge_text = hitan.map(|h| h.get(4, 0).to_string()).unwrap_or_default();
        let method = if self.st.tan_method_name.is_empty() {
            trf("TAN-Verfahren {0}", &[&self.st.sec_func])
        } else {
            self.st.tan_method_name.clone()
        };
        if reply.has("3955") || reply.has("3956") {
            let c = Challenge {
                kind: ChallengeKind::DecoupledPush,
                title: tr("Bitte in der Banking-App freigeben").into(),
                message: if challenge_text.is_empty() {
                    reply
                        .code("3955")
                        .or(reply.code("3956"))
                        .map(|c| c.2.clone())
                        .unwrap_or_default()
                } else {
                    clean_challenge(&challenge_text)
                },
                method_name: method,
                redirect_url: None,
                image: None,
                expires_in_seconds: Some(300),
                poll_interval_seconds: 3,
            };
            self.challenge = Some(c.clone());
            return Ok(Some(if reply.has("3956") {
                Phase::Pending(c)
            } else {
                Phase::Challenge(c)
            }));
        }
        if reply.has("0030") && self.task_reference.is_some() {
            let image = hitan
                .and_then(|h| h.binary(5))
                .map(|b| b.to_vec())
                .filter(|b| b.len() > 64);
            let c = Challenge {
                kind: if image.is_some() {
                    ChallengeKind::ImageCode
                } else {
                    ChallengeKind::Code
                },
                title: tr("TAN eingeben").into(),
                message: clean_challenge(&challenge_text),
                method_name: method,
                redirect_url: None,
                image: image.map(strip_mime_header),
                expires_in_seconds: Some(300),
                poll_interval_seconds: 0,
            };
            self.challenge = Some(c.clone());
            return Ok(Some(Phase::Challenge(c)));
        }
        Ok(None)
    }

    async fn sync_dialog(&mut self, ctx: &ConnectContext) -> CoreResult<()> {
        self.reset_dialog();
        let payload = vec![
            self.hkidn(ctx, 3),
            self.hkvvb(4),
            SegmentBuilder::new("HKSYN", 5, 3).raw("0").build(),
        ];
        let reply = self.send(ctx, payload, "999", None).await?;
        reply.check()?;
        self.learn_bpd(&reply);
        // Optional: TAN media list (needed by some banks for HKTAN).
        let tab_v = self.version("HKTAB");
        if self.bank_supports("HKTAB") {
            if let Ok(r) = self
                .send(
                    ctx,
                    vec![SegmentBuilder::new("HKTAB", 3, tab_v)
                        .raw("0")
                        .raw("A")
                        .build()],
                    "999",
                    None,
                )
                .await
            {
                self.learn_bpd(&r);
            }
        }
        self.end_dialog(ctx, "999").await;
        if self.st.system_id.is_empty() {
            return Err(CoreError::Protocol {
                message: "bank did not assign a customer system ID (HISYN)".into(),
            });
        }
        Ok(())
    }

    async fn end_dialog(&mut self, ctx: &ConnectContext, sec_func: &str) {
        if self.dialog_id != "0" {
            let seg = SegmentBuilder::new("HKEND", 3, 1)
                .de(&[&self.dialog_id.clone()])
                .build();
            let _ = self.send(ctx, vec![seg], sec_func, None).await;
        }
        self.reset_dialog();
    }

    /// Whether a business segment must be accompanied by HKTAN process 4:
    /// what HIPINS says, plus banks whose HIPINS is wrong. Consorsbank lists
    /// HKKAZ/HKSAL as not TAN-bound but rejects them without HKTAN (9075).
    fn needs_hktan(&self, seg_id: &str) -> bool {
        self.st.tan_required.get(seg_id) == Some(&true)
            || (self.blz == CONSORSBANK_BLZ && matches!(seg_id, "HKKAZ" | "HKSAL"))
    }

    /// Sends one business segment; adds HKTAN process 4 (referencing that
    /// segment) when the bank requires SCA for it (HIPINS), and waits for a
    /// decoupled approval (HKTAN process S polling) if the bank asks for one.
    async fn request(
        &mut self,
        ctx: &ConnectContext,
        seg_id: &str,
        segment: Vec<u8>,
    ) -> CoreResult<BankReply> {
        let sec = self.sec();
        let mut payload = vec![segment];
        if sec != "999" && self.needs_hktan(seg_id) {
            payload.push(self.hktan_process4(4, seg_id));
        }
        let mut reply = self.send(ctx, payload, &sec, None).await?;
        if reply.has("3955") || reply.has("3956") {
            let _ = self.challenge_from(&reply)?;
            let task = self
                .task_reference
                .clone()
                .ok_or_else(|| CoreError::Protocol {
                    message: trf("{0}: Freigabe ohne Auftragsreferenz", &[&seg_id]),
                })?;
            for _ in 0..60 {
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                let seg = SegmentBuilder::new("HKTAN", 3, self.version("HKTAN"))
                    .raw("S")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                let r = self.send(ctx, vec![seg], &sec, None).await?;
                if !r.has("3956") {
                    reply = r;
                    break;
                }
            }
        } else if reply.has("0030") {
            return Err(CoreError::Bank {
                code: "0030".into(),
                message: trf("Die Bank verlangt für {0} eine TAN-Eingabe. Bitte ein Push-/App-Verfahren (z. B. SecureGo plus) verwenden oder „Tage beim ersten Abruf“ auf höchstens 90 setzen.", &[&seg_id]),
            });
        }
        reply.check()?;
        Ok(reply)
    }

    /// Accounts from UPD merged with HKSPA (BIC/IBAN). Returns (account, upd).
    async fn account_list(
        &mut self,
        ctx: &ConnectContext,
        errors: &mut Vec<String>,
    ) -> Vec<(SepaAccount, Option<UpdAccount>)> {
        let mut sepa: Vec<SepaAccount> = Vec::new();
        if self.bank_supports("HKSPA") {
            let v = self.version("HKSPA");
            match self
                .request(ctx, "HKSPA", SegmentBuilder::new("HKSPA", 3, v).build())
                .await
            {
                Ok(reply) => {
                    for hispa in reply.all("HISPA") {
                        for el in hispa.elements.iter().skip(1) {
                            let t = |i: usize| {
                                el.get(i).map(|v| v.text().to_string()).unwrap_or_default()
                            };
                            if !t(1).is_empty() {
                                sepa.push(SepaAccount {
                                    iban: t(1),
                                    bic: t(2),
                                    account_number: t(3),
                                    sub_account: t(4),
                                    blz: t(6),
                                });
                            }
                        }
                    }
                }
                Err(e) => errors.push(trf("Kontenliste (HKSPA) – {0}", &[&e])),
            }
        }
        let mut out: Vec<(SepaAccount, Option<UpdAccount>)> = Vec::new();
        for u in self.upd.clone() {
            // Only accounts of this bank with at least one usable transaction
            let usable = u.allowed.is_empty()
                || ["HKSAL", "HKCAZ", "HKKAZ", "HKWPD"]
                    .iter()
                    .any(|t| u.allowed.contains(*t));
            if !usable {
                continue;
            }
            let s = sepa.iter().find(|s| {
                (!u.iban.is_empty() && s.iban == u.iban)
                    || (s.account_number == u.account_number && !u.account_number.is_empty())
            });
            let acc = SepaAccount {
                iban: s.map(|s| s.iban.clone()).unwrap_or_else(|| u.iban.clone()),
                bic: s.map(|s| s.bic.clone()).unwrap_or_default(),
                account_number: u.account_number.clone(),
                sub_account: u.sub_account.clone(),
                blz: if u.blz.is_empty() {
                    self.blz.clone()
                } else {
                    u.blz.clone()
                },
            };
            out.push((acc, Some(u)));
        }
        for s in sepa {
            if !out.iter().any(|(a, _)| a.iban == s.iban) {
                out.push((s, None));
            }
        }
        out
    }

    async fn balance(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
    ) -> CoreResult<Option<(i64, String, String)>> {
        let v = self.version("HKSAL");
        let acct = if v >= 7 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let r = self
            .request(
                ctx,
                "HKSAL",
                SegmentBuilder::new("HKSAL", 3, v)
                    .raw(&acct)
                    .raw("N")
                    .build(),
            )
            .await?;
        Ok(r.first("HISAL").and_then(|s| {
            // element 4: booked balance  C|D : amount : currency : date
            let c = parse_cents(s.get(4, 1)).ok()?;
            let sign = if s.get(4, 0) == "D" { -1 } else { 1 };
            let cur = if s.get(4, 2).is_empty() {
                "EUR".to_string()
            } else {
                s.get(4, 2).to_string()
            };
            let d = s.get(4, 3);
            let date = fints_date(d).unwrap_or_else(super::today);
            Some((sign * c, cur, date))
        }))
    }

    /// HKWPD: holdings statement of a depot (MT535), all pages.
    async fn holdings(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
    ) -> CoreResult<mt535::Statement> {
        let v = self.version("HKWPD");
        let mut data = Vec::<u8>::new();
        let mut touchdown: Option<String> = None;
        crate::depot_debug::log(&format!(
            "fints HKWPD: bpd HIWPDS versions={:?} (bank_supports={}), sending v{v} with KTV",
            self.st.versions.get("HKWPD"),
            self.bank_supports("HKWPD")
        ));
        for page in 0..20 {
            let r = match self
                .request(ctx, "HKWPD", Self::hkwpd(v, acc, touchdown.as_deref()))
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    crate::depot_debug::log(&format!(
                        "fints HKWPD page {page}: request error (kind of error only): {}",
                        e.to_string().chars().take(4).collect::<String>()
                    ));
                    return Err(e);
                }
            };
            let codes: Vec<String> = r
                .codes
                .iter()
                .map(|c| format!("{}@{}", c.0, c.1.map(|n| n.to_string()).unwrap_or_default()))
                .collect();
            let hiwpd: Vec<String> = r
                .all("HIWPD")
                .map(|s| {
                    format!(
                        "v{} bin_len={:?} elems={}",
                        s.version(),
                        s.binary(1).map(|b| b.len()),
                        s.elements.len()
                    )
                })
                .collect();
            crate::depot_debug::log(&format!(
                "fints HKWPD page {page}: codes={codes:?} HIWPD segments={hiwpd:?}"
            ));
            for s in r.all("HIWPD") {
                if let Some(b) = s.binary(1) {
                    data.extend_from_slice(b);
                    data.extend_from_slice(b"\r\n");
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        Ok(mt535::parse(&crate::text::decode_bank_bytes(&data)))
    }

    /// Depot (KTV), then currency, price quality and max. entries (all
    /// optional, left to the bank) and the touchdown point.
    fn hkwpd(version: u32, acc: &SepaAccount, touchdown: Option<&str>) -> Vec<u8> {
        let mut b = SegmentBuilder::new("HKWPD", 3, version).raw(&Self::ktv(acc));
        if let Some(t) = touchdown {
            b = b.raw("").raw("").raw("").de(&[t]);
        }
        b.build()
    }

    fn hkcaz(
        &self,
        acc: &SepaAccount,
        format: &str,
        from: &str,
        to: &str,
        touchdown: Option<&str>,
    ) -> Vec<u8> {
        let mut b = SegmentBuilder::new("HKCAZ", 3, self.version("HKCAZ"))
            .raw(&Self::kti(acc))
            .de(&[format])
            .raw("N")
            .raw(from)
            .raw(to)
            .raw("");
        if let Some(t) = touchdown {
            b = b.de(&[t]);
        }
        b.build()
    }

    async fn statements_camt(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
    ) -> CoreResult<(Vec<super::RemoteTransaction>, Option<i64>)> {
        let format = self.st.camt_formats.first().cloned().unwrap_or_default();
        let from = ctx.since.replace('-', "");
        let to = super::today().replace('-', "");
        let mut touchdown: Option<String> = None;
        let mut txs = Vec::new();
        let mut closing = None;
        for _page in 0..50 {
            let seg = self.hkcaz(acc, &format, &from, &to, touchdown.as_deref());
            let r = self.request(ctx, "HKCAZ", seg).await?;
            for s in r.all("HICAZ") {
                // element 3: booked camt documents (one or more binaries)
                for v in s.element(3) {
                    if let syntax::Value::Binary(xml) = v {
                        // raw @len@ slice, decoded as the XML's own encoding (UTF-8) – never via the Latin-1 envelope
                        let (t, rep) = camt::parse(&crate::text::decode_xml_bytes(xml), label);
                        txs.extend(t);
                        if rep.closing_balance_cents.is_some() {
                            closing = rep.closing_balance_cents;
                        }
                    }
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        Ok((txs, closing))
    }

    async fn statements_mt940(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
        currency: &str,
    ) -> CoreResult<(Vec<super::RemoteTransaction>, Option<i64>)> {
        let v = self.version("HKKAZ");
        let acct = if v >= 7 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let from = ctx.since.replace('-', "");
        let to = super::today().replace('-', "");
        let mut touchdown: Option<String> = None;
        let mut data = Vec::<u8>::new();
        for _page in 0..50 {
            let mut b = SegmentBuilder::new("HKKAZ", 3, v)
                .raw(&acct)
                .raw("N")
                .raw(&from)
                .raw(&to)
                .raw("");
            if let Some(t) = &touchdown {
                b = b.de(&[t]);
            }
            let r = self.request(ctx, "HKKAZ", b.build()).await?;
            if r.has("3997") {
                self.partial_statements = true;
            }
            for s in r.all("HIKAZ") {
                if let Some(b) = s.binary(1) {
                    data.extend_from_slice(b);
                    data.extend_from_slice(b"\r\n");
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        let (txs, stmt) = mt940::parse(&crate::text::decode_bank_bytes(&data), label, currency);
        Ok((txs, stmt.closing_balance_cents))
    }

    /// HKEKA: electronic statement as PDF (format 3). Optional – any error is ignored by the caller.
    async fn statements_pdf(
        &mut self,
        ctx: &ConnectContext,
        acc: &SepaAccount,
        label: &str,
    ) -> CoreResult<Vec<crate::documents::RemoteDocument>> {
        let v = self.version("HKEKA");
        let acct = if v >= 5 {
            Self::kti(acc)
        } else {
            Self::ktv(acc)
        };
        let mut docs = Vec::new();
        let mut touchdown: Option<String> = None;
        for _page in 0..12 {
            let mut b = SegmentBuilder::new("HKEKA", 3, v)
                .raw(&acct)
                .raw("3")
                .raw("")
                .raw("")
                .raw("");
            if let Some(t) = &touchdown {
                b = b.de(&[t]);
            }
            let r = self.request(ctx, "HKEKA", b.build()).await?;
            for s in r.all("HIEKA") {
                let period = format!("{}–{}", s.get(2, 0), s.get(2, 1));
                for el in &s.elements {
                    for val in el {
                        if let syntax::Value::Binary(pdf) = val {
                            if pdf.starts_with(b"%PDF") {
                                let to = s.get(2, 1);
                                let date = fints_date(to).unwrap_or_else(super::today);
                                docs.push(crate::documents::RemoteDocument {
                                    account_ref: label.to_string(),
                                    booking_external_id: None,
                                    title: trf("Kontoauszug {0}", &[&period]),
                                    doc_type: "kontoauszug".into(),
                                    mime_type: "application/pdf".into(),
                                    file_name: format!("Kontoauszug_{}_{}.pdf", label, date),
                                    source_url: format!("fints:hkeka:{label}:{period}"),
                                    bytes: pdf.clone(),
                                    date,
                                });
                            }
                        }
                    }
                }
            }
            touchdown = r.code("3040").and_then(|c| c.3.first().cloned());
            if touchdown.is_none() {
                break;
            }
        }
        Ok(docs)
    }

    /// Non-sensitive trace whether the bank offers PDF statements (HIEKAS), e.g.
    /// to check banks like ING (GitHub #57). No account data is logged.
    fn log_statement_support(&self, upd_allows: Option<bool>) {
        crate::depot_debug::log(&format!(
            "statements: HIEKAS versions={:?} negotiated={:?} upd_allows={:?} tan_required={:?}",
            self.st.versions.get("HKEKA"),
            self.negotiated("HKEKA"),
            upd_allows,
            self.st.tan_required.get("HKEKA"),
        ));
    }

    fn check_reply(&self, reply: &BankReply) -> CoreResult<()> {
        if self.transferring {
            reply.check_transfer()
        } else {
            reply.check()
        }
    }

    /// Sends HKCCS (regular), HKCSE (scheduled) or HKIPZ (instant) + HKTAN
    /// process 4. An instant order the bank does not offer ends as
    /// `TransferResult::InstantDeclined` without sending anything. There is
    /// never an automatic second order.
    async fn start_transfer(
        &mut self,
        ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<Phase> {
        let instant = job.instant;
        let seg_id: &'static str = if instant {
            "HKIPZ"
        } else if job.execution_date.is_some() {
            "HKCSE"
        } else {
            "HKCCS"
        };
        let not_allowed = || {
            CoreError::Bank {
            code: seg_id.into(),
            message: match seg_id {
                "HKIPZ" => tr("Dieses Konto oder diese Bank erlaubt keine Echtzeitüberweisungen per FinTS (HKIPZ). Bitte in der Banking-App überweisen."),
                "HKCSE" => tr("Dieses Konto oder diese Bank erlaubt keine Terminüberweisungen per FinTS (HKCSE). Bitte in der Banking-App überweisen."),
                _ => tr("Dieses Konto oder diese Bank erlaubt keine SEPA-Überweisungen per FinTS (HKCCS). Bitte in der Banking-App überweisen."),
            }
            .into(),
        }
        };
        if !self.bank_supports(seg_id) {
            if instant {
                return Ok(self.decline_instant(tr(
                    "Die Bank bietet per FinTS keine Echtzeitüberweisung (HKIPZ) an.",
                )));
            }
            return Err(not_allowed());
        }
        let sec = self.sec();
        if sec == "999" {
            return Err(CoreError::Bank {
                code: "HKTAN".into(),
                message: tr("Für Überweisungen ist ein TAN-Verfahren nötig; es wurde keines gefunden. Bitte zuerst eine Synchronisation mit TAN-Verfahren durchführen.").into(),
            });
        }
        let mut errors = Vec::new();
        let accounts = self.account_list(ctx, &mut errors).await;
        let want = sepa::normalize_iban(&job.source_iban);
        let (acc, upd) = accounts
            .into_iter()
            .find(|(a, _)| sepa::normalize_iban(&a.iban) == want)
            .ok_or_else(|| CoreError::NotFound {
                what: trf(
                    "Konto {0} bei der Bank{1}",
                    &[
                        &job.source_iban,
                        &if errors.is_empty() {
                            String::new()
                        } else {
                            format!(" ({})", errors.join(" / "))
                        },
                    ],
                ),
            })?;
        if let Some(u) = &upd {
            if !u.allowed.is_empty() && !u.allowed.contains(seg_id) {
                if instant {
                    return Ok(self.decline_instant(tr(
                        "Für dieses Konto ist die Echtzeitüberweisung per FinTS nicht freigeschaltet.",
                    )));
                }
                return Err(not_allowed());
            }
        }
        let version = match self.pain_version(seg_id) {
            Some(v) => v,
            None => {
                return Ok(self.decline_instant(tr(
                    "Die Bank erwartet für Echtzeitüberweisungen ein Datenformat, das GiroCrab nicht unterstützt.",
                )))
            }
        };
        let (date, time) = Self::now();
        let created = format!(
            "{}-{}-{}T{}:{}:{}",
            &date[..4],
            &date[4..6],
            &date[6..],
            &time[..2],
            &time[2..4],
            &time[4..]
        );
        let exec = job
            .execution_date
            .clone()
            .unwrap_or_else(|| format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..]));
        let msg_id = format!("GC{date}{time}{:08X}", rand::random::<u32>());
        let owner = if job.source_owner.trim().is_empty() {
            "Kontoinhaber"
        } else {
            job.source_owner.trim()
        };
        let xml = sepa::build_pain001(&sepa::Pain001 {
            message_id: &msg_id,
            created: &created,
            execution_date: &exec,
            debtor_name: owner,
            debtor_iban: &acc.iban,
            debtor_bic: &acc.bic,
            creditor_name: &job.recipient_name,
            creditor_iban: &job.recipient_iban,
            creditor_bic: job.recipient_bic.as_deref(),
            amount_cents: job.amount_cents,
            purpose: &job.purpose,
            version,
            end_to_end_id: &job.end_to_end_id,
            instant,
        })?;
        self.order = Some(PreparedOrder {
            seg_id,
            kti: Self::kti(&acc),
            descriptor: version.descriptor(),
            xml,
            instant,
            recipient_name: job.recipient_name.clone(),
            recipient_iban: job.recipient_iban.clone(),
            batch: None,
        });
        self.vop_id = None;
        self.vop_with_tan = false;
        self.vop_pending = None;
        let needs_vop =
            !self.st.vop_format.is_empty() && self.st.vop_orders.iter().any(|o| o == seg_id);
        if !needs_vop {
            let reply = self.send_order(ctx, Vop::None).await?;
            return self.finish_submit(&reply);
        }
        let (reply, polled) = self.check_payee(ctx).await?;
        if let Some(early) = self.reject_or_stop(&reply)? {
            return Ok(early);
        }
        let Some(check) = self.evaluate_payee(&reply) else {
            // Match (or no result reported): on to the approval.
            if polled && self.vop_id.is_some() {
                // The last reply answered a bare HKVPP poll and carries no
                // challenge: authorise with HKVPA + order + HKTAN now.
                self.vop_with_tan = false;
                let reply = self.send_order(ctx, Vop::Execute).await?;
                return self.finish_submit(&reply);
            }
            return self.finish_submit(&reply);
        };
        // Anything but a clean match: nothing more is sent until the user
        // confirms (`confirm_payee`); cancelling ends the dialog instead.
        self.vop_pending = Some(check.result);
        Ok(Phase::ConfirmPayee(check))
    }

    /// Sends HKCCM + HKTAN process 4. No name check for batches: the bank
    /// answers with what it requires.
    async fn start_batch(
        &mut self,
        ctx: &ConnectContext,
        job: &BatchTransferJob,
    ) -> CoreResult<Phase> {
        let seg_id: &'static str = "HKCCM";
        let not_allowed = || {
            CoreError::Bank {
            code: seg_id.into(),
            message: tr("Dieses Konto oder diese Bank erlaubt keine Sammelüberweisungen per FinTS (HKCCM). Bitte in der Banking-App überweisen.").into(),
        }
        };
        let Some(params) = self
            .st
            .batch_params
            .clone()
            .filter(|_| self.bank_supports(seg_id))
        else {
            return Err(not_allowed());
        };
        if params.max_count > 0 && job.payments.len() > params.max_count as usize {
            return Err(CoreError::InvalidInput {
                message: trf(
                    "Die Bank erlaubt höchstens {0} Zahlungen pro Sammelüberweisung.",
                    &[&params.max_count],
                ),
            });
        }
        if !job.batch_booking && !params.single_booking_allowed {
            return Err(CoreError::InvalidInput {
                message: tr("Die Bank bucht Sammelüberweisungen nur als Sammelbuchung.").into(),
            });
        }
        if self.sec() == "999" {
            return Err(CoreError::Bank {
                code: "HKTAN".into(),
                message: tr("Für Überweisungen ist ein TAN-Verfahren nötig; es wurde keines gefunden. Bitte zuerst eine Synchronisation mit TAN-Verfahren durchführen.").into(),
            });
        }
        let mut errors = Vec::new();
        let accounts = self.account_list(ctx, &mut errors).await;
        let want = sepa::normalize_iban(&job.source_iban);
        let (acc, upd) = accounts
            .into_iter()
            .find(|(a, _)| sepa::normalize_iban(&a.iban) == want)
            .ok_or_else(|| CoreError::NotFound {
                what: trf(
                    "Konto {0} bei der Bank{1}",
                    &[&job.source_iban, &String::new()],
                ),
            })?;
        if let Some(u) = &upd {
            if !u.allowed.is_empty() && !u.allowed.contains(seg_id) {
                return Err(not_allowed());
            }
        }
        let version = self.pain_version(seg_id).unwrap_or(sepa::PainVersion::V03);
        let (date, time) = Self::now();
        let created = format!(
            "{}-{}-{}T{}:{}:{}",
            &date[..4],
            &date[4..6],
            &date[6..],
            &time[..2],
            &time[2..4],
            &time[4..]
        );
        let exec = job
            .execution_date
            .clone()
            .unwrap_or_else(|| format!("{}-{}-{}", &date[..4], &date[4..6], &date[6..]));
        let msg_id = format!("GC{date}{time}{:08X}", rand::random::<u32>());
        let owner = if job.source_owner.trim().is_empty() {
            "Kontoinhaber"
        } else {
            job.source_owner.trim()
        };
        let xml = sepa::build_pain001_batch(&sepa::Pain001Batch {
            message_id: &msg_id,
            created: &created,
            execution_date: &exec,
            debtor_name: owner,
            debtor_iban: &acc.iban,
            debtor_bic: &acc.bic,
            payments: &job.payments,
            version,
            batch_booking: job.batch_booking,
        })?;
        let total =
            sepa::batch_total_cents(&job.payments).ok_or_else(|| CoreError::InvalidInput {
                message: tr("Die Summe der Sammelüberweisung ist zu groß.").into(),
            })?;
        self.order = Some(PreparedOrder {
            seg_id,
            kti: Self::kti(&acc),
            descriptor: version.descriptor(),
            xml,
            instant: false,
            recipient_name: String::new(),
            recipient_iban: String::new(),
            batch: Some((total, !job.batch_booking)),
        });
        self.vop_id = None;
        self.vop_with_tan = false;
        self.vop_pending = None;
        let reply = self.send_order(ctx, Vop::None).await?;
        self.finish_submit(&reply)
    }

    /// Instant not possible before anything was sent: nothing to approve.
    fn decline_instant(&mut self, reason: &str) -> Phase {
        self.result = TransferResult::InstantDeclined {
            reason: reason.to_string(),
        };
        Phase::Ready
    }

    /// Segments of one order message: [HKVPP|HKVPA] + order + HKTAN
    /// process 4, or HKVPP alone for a polling request.
    fn order_payload(&mut self, vop: Vop) -> CoreResult<Vec<Vec<u8>>> {
        let order = self.order.clone().ok_or(CoreError::SessionClosed)?;
        let mut n = 3;
        let mut payload = Vec::new();
        match vop {
            Vop::None => {}
            Vop::Check => {
                payload.push(
                    SegmentBuilder::new("HKVPP", n, self.version("HKVPP"))
                        .de(&[&self.st.vop_format])
                        .build(),
                );
                n += 1;
            }
            Vop::Poll {
                polling_id,
                touchdown,
            } => {
                // Polling: HKVPP only (format, polling ID, max. entries,
                // continuation point), no order and no HKTAN.
                let mut b = SegmentBuilder::new("HKVPP", n, self.version("HKVPP"))
                    .de(&[&self.st.vop_format])
                    .binary(&polling_id);
                if let Some(t) = touchdown {
                    b = b.raw("").de(&[&t]);
                }
                return Ok(vec![b.build()]);
            }
            Vop::Execute => {
                payload.push(self.hkvpa(n)?);
                n += 1;
            }
        }
        self.order_seg_no = n;
        let mut seg =
            SegmentBuilder::new(order.seg_id, n, self.version(order.seg_id)).raw(&order.kti);
        if let Some((total, single)) = order.batch {
            // HKCCM: Summenfeld, Einzelbuchung gewünscht (only what the BPD asks for).
            let p = self.st.batch_params.clone().unwrap_or_default();
            seg = if p.sum_required {
                seg.de(&[&sepa::format_amount(total).replace('.', ","), "EUR"])
            } else {
                seg.raw("")
            };
            seg = if p.single_booking_allowed {
                seg.de(&[if single { "J" } else { "N" }])
            } else {
                seg.raw("")
            };
        }
        payload.push(
            seg.de(&[order.descriptor])
                .binary(order.xml.as_bytes())
                .build(),
        );
        payload.push(self.hktan_process4(n + 1, order.seg_id));
        Ok(payload)
    }

    /// Sends one order message. Marks the order as submitted first: once the
    /// bytes may have left, the result can be "unknown".
    async fn send_order(&mut self, ctx: &ConnectContext, vop: Vop) -> CoreResult<BankReply> {
        let payload = self.order_payload(vop)?;
        let sec = self.sec();
        self.order_submitted = true;
        self.send(ctx, payload, &sec, None).await
    }

    fn hkvpa(&self, n: u32) -> CoreResult<Vec<u8>> {
        // No VOP-ID: nothing can be approved (and nothing was sent).
        let id = self
            .vop_id
            .as_deref()
            .ok_or_else(|| CoreError::InvalidInput {
                message: "name check: no VOP-ID from the bank".into(),
            })?;
        Ok(SegmentBuilder::new("HKVPA", n, 1).binary(id).build())
    }

    /// HKVPP + order; asks again (HKVPP only, with the polling ID) while the
    /// result is pending. Waits at most `VOP_POLL_WAIT_MAX` per round and
    /// `VOP_POLL_TOTAL_MAX` overall, so the session lock is never held long.
    /// Returns the last reply and whether polling happened.
    async fn check_payee(&mut self, ctx: &ConnectContext) -> CoreResult<(BankReply, bool)> {
        let mut reply = self.send_order(ctx, Vop::Check).await?;
        let mut polled = false;
        let mut waited = std::time::Duration::ZERO;
        for _ in 0..10 {
            let Some(h) = reply.first("HIVPP") else { break };
            let code = vop_result_code(h);
            let polling = h.binary(3).map(|b| b.to_vec());
            if !reply.errors().is_empty()
                || !(code.is_empty() || code == "PDNG")
                || polling.is_none()
            {
                break;
            }
            let wait = std::time::Duration::from_secs(
                h.get(8, 0)
                    .parse::<u64>()
                    .unwrap_or(2)
                    .clamp(1, VOP_POLL_WAIT_MAX.as_secs()),
            );
            if waited + wait > VOP_POLL_TOTAL_MAX {
                break;
            }
            waited += wait;
            tokio::time::sleep(wait).await;
            let touchdown = reply.code("3040").and_then(|c| c.3.first().cloned());
            polled = true;
            reply = self
                .send_order(
                    ctx,
                    Vop::Poll {
                        polling_id: polling.unwrap_or_default(),
                        touchdown,
                    },
                )
                .await?;
        }
        Ok((reply, polled))
    }

    /// Reads HIVPP. `None` = go on to the approval (match, or the bank did
    /// not report a result); `Some` = the user has to confirm.
    fn evaluate_payee(&mut self, reply: &BankReply) -> Option<PayeeCheck> {
        let h = reply.first("HIVPP")?;
        self.vop_id = h.binary(1).map(|b| b.to_vec()).filter(|b| !b.is_empty());
        let code = vop_result_code(h);
        let order = self.order.as_ref()?;
        let opt = |s: &str, max: usize| Some(clean_bank_text(s, max)).filter(|s| !s.is_empty());
        let result = match code.as_str() {
            "RCVC" => PayeeMatch::Match,
            "RVMC" => PayeeMatch::CloseMatch,
            "RVNM" => PayeeMatch::NoMatch,
            _ => PayeeMatch::NotPossible,
        };
        if result == PayeeMatch::Match && !reply.has("3945") {
            self.vop_with_tan = self.vop_id.is_some();
            return None;
        }
        Some(PayeeCheck {
            result,
            entered_name: order.recipient_name.clone(),
            iban: order.recipient_iban.clone(),
            bank_name: opt(h.get(6, 2), VOP_NAME_MAX),
            reason: opt(h.get(6, 5), VOP_TEXT_MAX).or_else(|| {
                (code.is_empty() || code == "PDNG")
                    .then(|| tr("Die Empfängerbank hat kein Ergebnis geliefert.").to_string())
            }),
            notice: opt(h.get(7, 0), VOP_TEXT_MAX),
        })
    }

    /// Classifies the reply to the order message. `Some(phase)` ends the
    /// transfer (declined / unknown); `None` = accepted, go on. Rejections
    /// are returned as errors.
    fn reject_or_stop(&mut self, reply: &BankReply) -> CoreResult<Option<Phase>> {
        let instant = self.order.as_ref().is_some_and(|o| o.instant);
        match classify_submit_reply(reply, instant, self.order_seg_no) {
            OrderReply::Accepted => Ok(None),
            OrderReply::Rejected => {
                reply.check_transfer()?;
                unreachable!("Rejected implies errors")
            }
            OrderReply::InstantDeclined(reason) => {
                self.result = TransferResult::InstantDeclined { reason };
                Ok(Some(Phase::Ready))
            }
            OrderReply::Unknown(reason) => {
                self.result = TransferResult::Unknown { reason };
                Ok(Some(Phase::Ready))
            }
        }
    }

    /// Reply to an order message that needs no further name check: classify
    /// it, then wait for the approval or finish.
    fn finish_submit(&mut self, reply: &BankReply) -> CoreResult<Phase> {
        if let Some(early) = self.reject_or_stop(reply)? {
            return Ok(early);
        }
        if let Some(p) = self.challenge_from(reply)? {
            return Ok(p);
        }
        let instant = self.order.as_ref().is_some_and(|o| o.instant);
        self.result = TransferResult::Executed { instant };
        Ok(Phase::Ready)
    }

    /// The user confirmed despite the name-check result: HKVPA + order + HKTAN.
    /// Only ever reached from the user's explicit confirmation.
    async fn confirm_payee(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        // A stray/duplicate confirmation must not look like an unknown outcome.
        if self.vop_pending.take().is_none() {
            return Err(CoreError::InvalidInput {
                message: "no name check awaiting confirmation".into(),
            });
        }
        let reply = self.send_order(ctx, Vop::Execute).await?;
        self.finish_submit(&reply)
    }

    /// Reply to an approved TAN / decoupled poll. For a login this checks
    /// the reply; for a transfer it decides executed / rejected / unknown.
    async fn after_approval(
        &mut self,
        _ctx: &ConnectContext,
        reply: BankReply,
    ) -> CoreResult<Phase> {
        if !self.order_submitted {
            self.check_reply(&reply)?;
            return Ok(Phase::Ready);
        }
        let instant = self.order.as_ref().is_some_and(|o| o.instant);
        match classify_approval_reply(&reply, instant) {
            OrderReply::Accepted => {
                self.result = TransferResult::Executed { instant };
            }
            OrderReply::Rejected => {
                reply.check_transfer()?;
                unreachable!("Rejected implies errors")
            }
            OrderReply::InstantDeclined(reason) => {
                self.result = TransferResult::InstantDeclined { reason };
            }
            OrderReply::Unknown(reason) => {
                self.result = TransferResult::Unknown { reason };
            }
        }
        Ok(Phase::Ready)
    }

    /// Authenticated dialog (HKIDN/HKVVB + HKTAN process 4 for SCA).
    async fn open_dialog(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        // Authenticated dialog with strong customer authentication.
        self.reset_dialog();
        let sec = self.sec();
        let mut reply = self.send_dialog_init(ctx, &sec).await?;
        // Some banks reject HKTAN in the dialog init as malformed (9010 without a
        // PIN/TAN/system-id code): retry once one-step and remember it.
        if sec != "999" && init_rejected_as_malformed(&reply) {
            self.reset_dialog();
            let retry = self.send_dialog_init(ctx, "999").await?;
            if retry.check().is_ok() {
                self.st.single_step = true;
                reply = retry;
            }
        }
        self.learn_bpd(&reply);
        if let Err(e) = reply.check() {
            // Stale system ID / TAN method -> force re-sync next time.
            if reply.has("9931") || reply.has("9942") || reply.has("9010") {
                self.st.system_id.clear();
            }
            return Err(e);
        }
        if let Some(p) = self.challenge_from(&reply)? {
            return Ok(p);
        }
        Ok(Phase::Ready)
    }

    async fn send_dialog_init(&mut self, ctx: &ConnectContext, sec: &str) -> CoreResult<BankReply> {
        let mut payload = vec![self.hkidn(ctx, 3), self.hkvvb(4)];
        if sec != "999" {
            payload.push(self.hktan_process4(5, "HKIDN"));
        }
        self.send(ctx, payload, sec, None).await
    }

    /// Whether the transfer document should be `pain.001.001.09` (true) or `.03` (false).
    /// Instant payments (HKIPZ) are always `.09`. Otherwise the BPD descriptors decide:
    /// `.03` if advertised, else `.09` if only that is advertised; nothing advertised
    /// (or only formats we cannot produce) falls back to `.03`.
    fn pain_version(&self, code: &str) -> Option<sepa::PainVersion> {
        let formats = self.st.pain_formats.get(code);
        if code == "HKIPZ" {
            return sepa::PainVersion::pick(formats.map(Vec::as_slice).unwrap_or(&[]));
        }
        let has = |suffix: &str| formats.is_some_and(|l| l.iter().any(|f| f.ends_with(suffix)));
        Some(if !has(".001.03") && has(".001.09") {
            sepa::PainVersion::V09
        } else {
            sepa::PainVersion::V03
        })
    }

    fn sec(&self) -> String {
        if self.st.single_step || self.st.sec_func.is_empty() {
            "999".into()
        } else {
            self.st.sec_func.clone()
        }
    }

    /// KTI: IBAN:BIC, or (without IBAN, e.g. loans) ::Konto:Unterkonto:280:BLZ.
    /// Consorsbank rejects the IBAN:BIC-only form ("9010 Fehler im
    /// Segmentaufbau") and wants all of IBAN:BIC:Konto:Unterkonto:280:BLZ.
    fn kti(acc: &SepaAccount) -> String {
        if acc.blz == CONSORSBANK_BLZ && !acc.iban.is_empty() && !acc.account_number.is_empty() {
            return format!(
                "{}:{}:{}:{}:{COUNTRY}:{}",
                escape(&acc.iban),
                escape(&acc.bic),
                escape(&acc.account_number),
                escape(&acc.sub_account),
                acc.blz
            );
        }
        if acc.iban.is_empty() {
            format!(
                "::{}:{}:{COUNTRY}:{}",
                escape(&acc.account_number),
                escape(&acc.sub_account),
                acc.blz
            )
        } else {
            format!("{}:{}", escape(&acc.iban), escape(&acc.bic))
        }
    }

    fn ktv(acc: &SepaAccount) -> String {
        format!(
            "{}:{}:{COUNTRY}:{}",
            escape(&acc.account_number),
            escape(&acc.sub_account),
            acc.blz
        )
    }
}

/// Stable per-account key (`external_ref`). Loans (Darlehen) have no IBAN and often share
/// one account number, distinguished only by the Unterkontomerkmal – it must be part of
/// the key, otherwise every sub-account collapses into one account with all bookings.
fn account_label(acc: &SepaAccount) -> String {
    if !acc.iban.is_empty() {
        acc.iban.clone()
    } else if acc.sub_account.is_empty() {
        acc.account_number.clone()
    } else {
        format!("{}-{}", acc.account_number, acc.sub_account)
    }
}

/// Dialog init refused with 9010 ("Ungültiger Signaturaufbau") that is not a stale
/// system ID / TAN method (9931/9942).
fn init_rejected_as_malformed(reply: &BankReply) -> bool {
    reply.has("9010") && !reply.has("9931") && !reply.has("9942")
}

/// PIN/TAN/approval/SCA errors: the order was certainly not executed.
fn is_auth_error(code: &str) -> bool {
    code.starts_with("99") || matches!(code, "9075" | "9076" | "9078")
}

/// Message-level codes that say nothing about the order itself.
fn is_generic_error(code: &str) -> bool {
    matches!(code, "9010" | "9050" | "9800")
}

/// Order-specific rejections that unambiguously mean "not executed"
/// (invalid order, limit exceeded, account does not allow it / is blocked).
fn is_clear_rejection(code: &str) -> bool {
    matches!(code, "9210" | "9380" | "9390" | "9391")
}

/// Bank errors in user-facing form ("9380 Der Betrag überschreitet …").
fn reason_text(reply: &BankReply) -> String {
    let errs = reply.errors();
    let specific: Vec<_> = errs.iter().filter(|e| !is_generic_error(&e.0)).collect();
    let shown: Vec<_> = if specific.is_empty() {
        errs.iter().collect()
    } else {
        specific
    };
    shown
        .iter()
        .map(|e| explain_transfer_code(e))
        .collect::<Vec<_>>()
        .join(" / ")
}

/// Reply to the order itself (HKCCS/HKCSE/HKIPZ + HKTAN process 4), i.e.
/// before the user approved anything. Errors here mean the bank refused the
/// order before executing it, unless the reply also confirms the order
/// segment (contradictory: unknown).
fn classify_submit_reply(reply: &BankReply, instant: bool, order_seg: u32) -> OrderReply {
    let errs = reply.errors();
    if errs.is_empty() {
        return OrderReply::Accepted;
    }
    let order_confirmed = reply
        .codes
        .iter()
        .any(|c| c.0.starts_with('0') && c.1 == Some(order_seg));
    if order_confirmed {
        return OrderReply::Unknown(reason_text(reply));
    }
    if !instant || errs.iter().any(|e| is_auth_error(&e.0)) {
        return OrderReply::Rejected;
    }
    // Dialog aborted: without SCA an instant order may already be executed.
    if reply.has("9800") {
        return OrderReply::Unknown(reason_text(reply));
    }
    OrderReply::InstantDeclined(reason_text(reply))
}

/// Reply after the user approved the order (TAN / decoupled poll). Only
/// auth errors and clear order rejections count as "not executed"; generic
/// codes, 9800 (dialog aborted) and anything else mean the instant payment
/// may already have been executed.
fn classify_approval_reply(reply: &BankReply, instant: bool) -> OrderReply {
    let errs = reply.errors();
    if errs.is_empty() {
        return OrderReply::Accepted;
    }
    if errs.iter().any(|e| is_auth_error(&e.0)) {
        return OrderReply::Rejected;
    }
    let specific: Vec<_> = errs.iter().filter(|e| !is_generic_error(&e.0)).collect();
    let clear = !reply.has("9800")
        && !specific.is_empty()
        && specific.iter().all(|e| is_clear_rejection(&e.0));
    match (clear, instant) {
        (true, true) => OrderReply::InstantDeclined(reason_text(reply)),
        (true, false) => OrderReply::Rejected,
        (false, _) => OrderReply::Unknown(reason_text(reply)),
    }
}

/// HIVPPS: (payment status report format, orders that need a name check).
/// Parameter group: max. entries : structured : V/S : batch : count : format : HKxxx …
fn vop_parameters(seg: &Segment) -> (String, Vec<String>) {
    let mut format = String::new();
    let mut orders = Vec::new();
    for el in &seg.elements {
        for v in el {
            let t = v.text();
            if format.is_empty() && t.contains("pain.002") {
                format = t.to_string();
            } else if t.len() == 5
                && t.starts_with("HK")
                && t[2..].chars().all(|c| c.is_ascii_uppercase())
            {
                orders.push(t.to_string());
            }
        }
    }
    (format, orders)
}

/// Max. length of an account holder name (SEPA) and of bank free texts.
const VOP_NAME_MAX: usize = 70;
const VOP_TEXT_MAX: usize = 500;

/// Bank free text for display / the form: control characters dropped,
/// whitespace collapsed, cut to `max` characters.
fn clean_bank_text(s: &str, max: usize) -> String {
    s.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max)
        .collect()
}

/// The worst result among all codes found: a match must never mask a
/// mismatch. Worst first: RVNM, RVMC, RVNA, PDNG, RCVC.
fn worst_vop_code(candidates: &[&str]) -> String {
    ["RVNM", "RVMC", "RVNA", "PDNG", "RCVC"]
        .iter()
        .find(|c| candidates.iter().any(|t| t.contains(*c)))
        .map(|c| c.to_string())
        .unwrap_or_default()
}

/// VOP result code from HIVPP: the single-transaction result (EVPE) and the
/// codes in the payment status report; the worst one wins.
fn vop_result_code(h: &Segment) -> String {
    let evpe = h.get(6, 4).trim().to_string();
    let report = h
        .binary(5)
        .map(crate::text::decode_bank_bytes)
        .unwrap_or_default();
    worst_vop_code(&[&evpe, &report])
}

/// pain.001 descriptors from a BPD parameter segment (HICCSS / HIIPZS / HICSES).
fn pain_formats(reply: &BankReply, seg_id: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for seg in reply.all(seg_id) {
        for el in &seg.elements {
            for v in el {
                let t = v.text();
                if t.starts_with("urn:iso:std:iso:20022:tech:xsd:pain.001")
                    && !t.ends_with(".xsd")
                    && !out.iter().any(|f| f == t)
                {
                    out.push(t.to_string());
                }
            }
        }
    }
    out
}

/// Localised text for a bank return code (HIRMG/HIRMS) during a transfer.
fn explain_transfer_code(c: &(String, Option<u32>, String, Vec<String>)) -> String {
    let hint = match c.0.as_str() {
        "9050" => tr("Die Nachricht enthält Fehler."),
        "9010" => tr("Die Bank hat die Nachricht nicht verarbeitet."),
        "9120" | "9130" | "9140" | "9160" => {
            tr("Ein Pflichtfeld der Überweisung fehlt oder ist ungültig.")
        }
        "9210" => tr("Der Auftrag wurde abgelehnt (Daten ungültig oder nicht erlaubt)."),
        "9340" => tr("Der Auftrag ist ungültig; bitte IBAN, Betrag und Name prüfen."),
        "9380" => tr("Der Betrag überschreitet das Limit des Kontos."),
        "9390" => tr("Das Konto lässt diese Überweisung nicht zu."),
        "9391" => tr("Das Konto ist für Überweisungen gesperrt."),
        "9931" | "9942" => tr("PIN oder Zugangsdaten wurden abgelehnt."),
        "9941" => tr("Die TAN ist ungültig oder abgelaufen."),
        "9955" | "9956" => tr("Die Freigabe wurde abgelehnt oder ist abgelaufen."),
        "9075" => {
            tr("Starke Kundenauthentifizierung ist erforderlich, wurde aber nicht abgeschlossen.")
        }
        _ => "",
    };
    let params = if c.3.is_empty() {
        String::new()
    } else {
        format!(" ({})", c.3.join(", "))
    };
    if hint.is_empty() {
        trf(
            "{0} Die Bank hat die Überweisung abgelehnt: {1}{2}",
            &[&c.0, &c.2, &params],
        )
    } else {
        trf("{0} {1} Bank: {2}{3}", &[&c.0, &hint, &c.2, &params])
    }
}

/// Picks the TAN function from the codes allowed by 3920: app/decoupled
/// methods first (SecureGo plus, pushTAN …), then a fixed preference list,
/// never 999 (one-step).
fn choose_tan_function(allowed: &[String], names: &HashMap<String, String>) -> String {
    let by_name = allowed.iter().find(|a| {
        let n = names.get(*a).map(|s| s.to_lowercase()).unwrap_or_default();
        [
            "decoupled",
            "securego",
            "pushtan",
            "push",
            "app",
            "banking-app",
        ]
        .iter()
        .any(|k| n.contains(k))
    });
    if let Some(a) = by_name {
        return a.clone();
    }
    for pref in [
        "946", "944", "942", "921", "962", "972", "982", "920", "923", "913", "912", "911", "910",
        "900",
    ] {
        if allowed.iter().any(|a| a == pref) {
            return pref.to_string();
        }
    }
    allowed.first().cloned().unwrap_or_else(|| "999".into())
}

fn clean_challenge(s: &str) -> String {
    s.replace("<br>", "\n")
        .replace("<br/>", "\n")
        .replace("<b>", "")
        .replace("</b>", "")
        .trim()
        .to_string()
}

/// photoTAN images come as 2-byte length + MIME type + 2-byte length + data.
fn strip_mime_header(b: Vec<u8>) -> Vec<u8> {
    if b.len() > 4 {
        let l = ((b[0] as usize) << 8) | b[1] as usize;
        if l > 0 && l < 64 && b.len() > l + 4 && b[2..2 + l].starts_with(b"image/") {
            return b[l + 4..].to_vec();
        }
    }
    b
}

#[async_trait]
impl BankConnector for FinTsConnector {
    async fn begin(&mut self, ctx: &ConnectContext) -> CoreResult<Phase> {
        self.url = ctx.setting(&format!("fints.url.{}", self.blz))?.to_string();
        self.product_id = ctx.setting("fints.product_id")?.to_string();
        self.product_version = ctx.setting_or("fints.product_version", "0.1").to_string();
        if ctx.secret.is_empty() {
            return Err(CoreError::Authentication {
                message: tr("PIN ist leer").into(),
            });
        }
        if let Ok(st) = serde_json::from_value::<FinTsState>(ctx.state.clone()) {
            self.st = st;
        }
        self.tan_medium_override = ctx
            .setting_or(&format!("fints.tan_medium.{}", ctx.connection_id), "")
            .trim()
            .to_string();
        if !self.tan_medium_override.is_empty() {
            self.st.tan_medium = self.tan_medium_override.clone();
        }
        if self.st.system_id.is_empty() || self.st.sec_func.is_empty() {
            self.sync_dialog(ctx).await?;
        }
        self.open_dialog(ctx).await
    }

    async fn respond(
        &mut self,
        ctx: &ConnectContext,
        response: ChallengeResponse,
    ) -> CoreResult<Phase> {
        if let ChallengeResponse::ConfirmPayee = response {
            return self.confirm_payee(ctx).await;
        }
        let task = self
            .task_reference
            .clone()
            .ok_or_else(|| CoreError::Protocol {
                message: "no pending TAN task".into(),
            })?;
        let sec = self.sec();
        // Name matched: HKVPA (VOP-ID) goes along with the approval.
        let mut payload = Vec::new();
        // Only with the first step after the name check, not with the
        // following decoupled status polls.
        if std::mem::take(&mut self.vop_with_tan) {
            payload.push(self.hkvpa(3)?);
        }
        let n = 3 + payload.len() as u32;
        match response {
            ChallengeResponse::ConfirmPayee => unreachable!(),
            ChallengeResponse::Poll => {
                let seg = SegmentBuilder::new("HKTAN", n, self.version("HKTAN"))
                    .raw("S")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                payload.push(seg);
                let reply = self.send(ctx, payload, &sec, None).await?;
                if reply.has("3956") && reply.errors().is_empty() {
                    let c = self.challenge.clone().ok_or(CoreError::SessionClosed)?;
                    return Ok(Phase::Pending(c));
                }
                self.after_approval(ctx, reply).await
            }
            ChallengeResponse::Code(tan) => {
                let seg = SegmentBuilder::new("HKTAN", n, self.version("HKTAN"))
                    .raw("2")
                    .raw("")
                    .raw("")
                    .raw("")
                    .de(&[&task])
                    .raw("N")
                    .build();
                self.tan_for_next = None;
                payload.push(seg);
                let reply = self.send(ctx, payload, &sec, Some(tan.expose())).await?;
                self.after_approval(ctx, reply).await
            }
        }
    }

    async fn fetch(&mut self, ctx: &ConnectContext) -> CoreResult<FetchResult> {
        let mut errors: Vec<String> = Vec::new();
        let accounts = self.account_list(ctx, &mut errors).await;
        let mut result = FetchResult::default();
        let mut ok_any = false;
        // Explicit statements fetch (Vault::fetch_account_statements): HKEKA of one account only.
        let auto_statements: Vec<String> = ctx
            .settings
            .get(super::STATEMENTS_AUTO)
            .map(|v| v.expose().split(',').map(str::to_string).collect())
            .unwrap_or_default();
        if let Some(wanted) = ctx.settings.get(super::STATEMENTS_ONLY) {
            let wanted = wanted.expose().to_string();
            let Some((acc, upd)) = accounts.iter().find(|(a, _)| account_label(a) == wanted) else {
                return Err(CoreError::NotFound {
                    what: trf("Konto {0}", &[&wanted]),
                });
            };
            let supported = self.bank_supports("HKEKA")
                && upd
                    .as_ref()
                    .map(|u| u.allowed.is_empty() || u.allowed.contains("HKEKA"))
                    .unwrap_or(true);
            self.log_statement_support(
                upd.as_ref()
                    .map(|u| u.allowed.is_empty() || u.allowed.contains("HKEKA")),
            );
            if !supported {
                return Err(CoreError::Bank {
                    code: "HKEKA".into(),
                    message: tr(
                        "Diese Bank bietet keine elektronischen Kontoauszüge per FinTS an.",
                    )
                    .into(),
                });
            }
            result.documents = self.statements_pdf(ctx, acc, &wanted).await?;
            result.state = Some(serde_json::to_value(&self.st)?);
            return Ok(result);
        }
        for (acc, upd) in &accounts {
            let allowed = |tx: &str| {
                upd.as_ref()
                    .map(|u| u.allowed.is_empty() || u.allowed.contains(tx))
                    .unwrap_or(true)
            };
            let mut kind = upd
                .as_ref()
                .map(|u| kind_from_code(u.kind_code))
                .unwrap_or(AccountKind::Checking);
            let label = account_label(acc);
            // Some banks report depots with a generic Kontoart; trust the product name.
            if kind == AccountKind::Checking
                && (upd
                    .as_ref()
                    .is_some_and(|u| u.product.to_lowercase().contains("depot"))
                    || label.to_lowercase().contains("depot"))
            {
                kind = AccountKind::Brokerage;
            }
            crate::depot_debug::log(&format!(
                "fints account: kind={kind:?} kind_code={:?} is_depot={} upd_found={} hkwpd_allowed={} bank_supports_hkwpd={}",
                upd.as_ref().map(|u| u.kind_code),
                kind == AccountKind::Brokerage,
                upd.is_some(),
                allowed("HKWPD"),
                self.bank_supports("HKWPD")
            ));
            let mut currency = upd
                .as_ref()
                .map(|u| u.currency.clone())
                .filter(|c| !c.is_empty())
                .unwrap_or_else(|| "EUR".into());
            let mut balance: Option<i64> = None;
            let mut balance_date = super::today();

            // --- Balance (HKSAL), only if the account allows it
            if self.bank_supports("HKSAL") && allowed("HKSAL") {
                match self.balance(ctx, acc).await {
                    Ok(Some((b, cur, date))) => {
                        balance = Some(b);
                        currency = cur;
                        balance_date = date;
                        ok_any = true;
                    }
                    Ok(None) => {}
                    Err(e) => errors.push(trf("{0}: Saldo – {1}", &[&label, &e])),
                }
            }

            // --- Depot value (HKWPD / MT535), only for depots that allow it
            // Some banks omit HKWPD from HIUPD although HIWPDS is in the BPD: try it
            // anyway for depots; a 9xxx rejection just lands in the error list.
            if kind == AccountKind::Brokerage && self.bank_supports("HKWPD") {
                match self.holdings(ctx, acc).await {
                    Ok(st) => {
                        crate::depot_debug::log(&format!(
                            "fints holdings parsed: {} positions, value_derivable={}",
                            st.holdings.len(),
                            st.value_cents().is_some()
                        ));
                        // Positions are always kept, even when the total can't be derived.
                        if let Some(c) = st
                            .holdings
                            .iter()
                            .map(|h| h.currency.clone())
                            .find(|c| !c.is_empty())
                        {
                            currency = c;
                        }
                        for h in &st.holdings {
                            result.holdings.push(super::RemoteHolding {
                                account_ref: label.clone(),
                                holding: h.to_model(),
                            });
                        }
                        match st.value_cents() {
                            Some(v) => {
                                balance = Some(v);
                                if let Some(d) = st.latest_date() {
                                    balance_date = d;
                                }
                                ok_any = true;
                            }
                            None => {
                                if !st.holdings.is_empty() {
                                    ok_any = true;
                                }
                                errors.push(trf(
                                    "{0}: Depotbestand (HKWPD) – Wert einzelner Positionen fehlt",
                                    &[&label],
                                ))
                            }
                        }
                    }
                    Err(e) => errors.push(trf("{0}: Depotbestand (HKWPD) – {1}", &[&label, &e])),
                }
            }

            // --- Statements: camt (HKCAZ) first, MT940 (HKKAZ) as fallback. Loans are
            // included only when HIUPD permits it (or lists nothing); every request is
            // its own FinTS message, so a 9050 on one loan is just collected in `errors`.
            let mut txs = Vec::new();
            {
                let can_camt = self.bank_supports("HKCAZ")
                    && allowed("HKCAZ")
                    && !self.st.camt_formats.is_empty();
                let can_mt940 = self.bank_supports("HKKAZ") && allowed("HKKAZ");
                let mut done = false;
                if can_camt {
                    match self.statements_camt(ctx, acc, &label).await {
                        Ok((t, closing)) => {
                            // Loan sub-accounts ("Darlehen") often answer camt with an empty
                            // list; then MT940 is tried before giving up.
                            let empty_loan = kind == AccountKind::Loan && t.is_empty() && can_mt940;
                            txs = t;
                            if balance.is_none() {
                                balance = closing;
                            }
                            done = !empty_loan;
                            ok_any = true;
                        }
                        Err(e) => {
                            errors.push(trf("{0}: Umsätze (HKCAZ/camt.052) – {1}", &[&label, &e]))
                        }
                    }
                }
                if !done && can_mt940 {
                    match self.statements_mt940(ctx, acc, &label, &currency).await {
                        Ok((t, closing)) => {
                            if !t.is_empty() || txs.is_empty() {
                                txs = t;
                            }
                            if balance.is_none() {
                                balance = closing;
                            }
                            ok_any = true;
                            if std::mem::take(&mut self.partial_statements) {
                                errors.push(trf(
                                    "{0}: Die Bank hat nur einen Teil des angeforderten Zeitraums geliefert (Rückmeldung 3997).",
                                    &[&label],
                                ));
                            }
                        }
                        Err(e) => {
                            errors.push(trf("{0}: Umsätze (HKKAZ/MT940) – {1}", &[&label, &e]))
                        }
                    }
                }
            }
            result.transactions.extend(txs);

            // Opt-in (GitHub #57): PDF statements, at most weekly per account. A failure
            // never fails the sync; the explicit fetch reports errors instead.
            if auto_statements.contains(&label) {
                self.log_statement_support(Some(allowed("HKEKA")));
                if allowed("HKEKA") && self.bank_supports("HKEKA") {
                    match self.statements_pdf(ctx, acc, &label).await {
                        Ok(docs) => {
                            crate::depot_debug::log(&format!(
                                "statements: auto fetch ok, {} PDF(s)",
                                docs.len()
                            ));
                            result.documents.extend(docs);
                            result.statements_fetched.push(label.clone());
                        }
                        Err(e) => crate::depot_debug::log(&format!(
                            "statements: auto fetch failed: {}",
                            e.to_string().chars().take(160).collect::<String>()
                        )),
                    }
                }
            }
            let name = upd
                .as_ref()
                .map(|u| u.product.clone())
                .filter(|p| !p.is_empty())
                .unwrap_or_else(|| match kind {
                    AccountKind::Loan => "Darlehen".into(),
                    AccountKind::Savings => "Sparkonto".into(),
                    AccountKind::CreditCard => "Kreditkarte".into(),
                    AccountKind::Brokerage => "Depot".into(),
                    _ => "Girokonto".into(),
                });
            result.accounts.push(RemoteAccount {
                external_ref: label.clone(),
                name,
                owner: upd.as_ref().map(|u| u.owner.clone()).unwrap_or_default(),
                iban: acc.iban.clone(),
                account_number: acc.account_number.clone(),
                currency,
                kind,
                balance_cents: balance.unwrap_or(0),
                balance_date,
            });
        }
        if !ok_any && !errors.is_empty() {
            return Err(CoreError::Bank {
                code: "FinTS".into(),
                message: errors.join(" / "),
            });
        }
        result.state = Some(serde_json::to_value(&self.st)?);
        Ok(result)
    }

    async fn finish(&mut self, ctx: &ConnectContext) {
        let sec = self.sec();
        self.end_dialog(ctx, &sec).await;
    }

    async fn send_transfer(
        &mut self,
        ctx: &ConnectContext,
        job: &TransferJob,
    ) -> CoreResult<Phase> {
        self.transferring = true;
        self.result = TransferResult::default();
        self.order_submitted = false;
        self.order = None;
        let r = self.start_transfer(ctx, job).await;
        if r.is_err() {
            self.transferring = false;
        }
        r
    }

    async fn send_batch_transfer(
        &mut self,
        ctx: &ConnectContext,
        job: &BatchTransferJob,
    ) -> CoreResult<Phase> {
        self.transferring = true;
        self.result = TransferResult::default();
        self.order_submitted = false;
        self.order = None;
        let r = self.start_batch(ctx, job).await;
        if r.is_err() {
            self.transferring = false;
        }
        r
    }

    fn transfer_result(&self) -> TransferResult {
        self.result.clone()
    }

    fn order_submitted(&self) -> bool {
        self.order_submitted
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::secret::SecretString;

    fn test_ctx() -> ConnectContext {
        ConnectContext {
            connection_id: 1,
            login_name: "user:1".into(),
            secret: SecretString::new("12345".into()),
            settings: Default::default(),
            state: serde_json::json!({}),
            since: "2025-01-01".into(),
            since_by_account: Default::default(),
        }
    }

    /// Mock FinTS endpoint: answers the n-th request with `replies[n]` (last one repeats)
    /// and records which segment ids each request contained.
    fn mock_bank(
        replies: Vec<&'static str>,
    ) -> (String, std::sync::Arc<std::sync::Mutex<Vec<Vec<String>>>>) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://127.0.0.1:{}/fints",
            listener.local_addr().unwrap().port()
        );
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen2 = seen.clone();
        std::thread::spawn(move || {
            for (n, stream) in listener.incoming().enumerate() {
                let Ok(mut s) = stream else { break };
                let mut buf = Vec::new();
                let mut chunk = [0u8; 8192];
                let body = loop {
                    let k = s.read(&mut chunk).unwrap_or(0);
                    buf.extend_from_slice(&chunk[..k]);
                    let text = String::from_utf8_lossy(&buf).to_string();
                    if let Some(i) = text.find("\r\n\r\n") {
                        let len = text[..i]
                            .to_ascii_lowercase()
                            .split("content-length:")
                            .nth(1)
                            .and_then(|v| v.lines().next()?.trim().parse::<usize>().ok())
                            .unwrap_or(0);
                        if buf.len() >= i + 4 + len || k == 0 {
                            break text[i + 4..].to_string();
                        }
                    } else if k == 0 {
                        break String::new();
                    }
                };
                let raw = base64::engine::general_purpose::STANDARD
                    .decode(body.trim())
                    .unwrap_or_default();
                let ids = syntax::parse_response(&raw)
                    .map(|v| v.iter().map(|x| x.id().to_string()).collect())
                    .unwrap_or_default();
                seen2.lock().unwrap().push(ids);
                let reply = replies[n.min(replies.len() - 1)];
                let b64 = base64::engine::general_purpose::STANDARD.encode(reply);
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b64}",
                    b64.len()
                );
                let _ = s.write_all(resp.as_bytes());
            }
        });
        (url, seen)
    }

    const REJECT_9010: &str = "HNHBK:1:3+000000000000+300+0+1'HIRMG:2:2+9800::Der Dialog wurde abgebrochen.'HIRMS:3:2:3+9010::Ungültiger Signaturaufbau: Fehler im Segmentaufbau.'";
    const ACCEPT: &str =
        "HNHBK:1:3+000000000000+300+DIALOG1+1'HIRMG:2:2+0010::Nachricht entgegengenommen.'";
    const STALE_SYSTEM_ID: &str = "HNHBK:1:3+000000000000+300+0+1'HIRMG:2:2+9800::abgebrochen.'HIRMS:3:2:3+9931::Anmeldename falsch.'HIRMS:4:2:3+9010::Fehler.'";

    fn two_step_connector(url: &str, state: serde_json::Value) -> FinTsConnector {
        let mut c = FinTsConnector::new("50010517");
        c.url = url.into();
        c.product_id = "TESTPRODUCT".into();
        c.product_version = "0.1".into();
        c.st = serde_json::from_value(state).unwrap();
        c
    }

    fn has_hktan(ids: &[String]) -> bool {
        ids.iter().any(|i| i == "HKTAN")
    }

    #[tokio::test]
    async fn dialog_init_9010_falls_back_to_single_step_and_persists() {
        let (url, seen) = mock_bank(vec![REJECT_9010, ACCEPT]);
        let state = serde_json::json!({"system_id": "123", "sec_func": "946", "tan_method_name": "", "tan_medium": "", "versions": {}, "tan_required": {}});
        let mut c = two_step_connector(&url, state);
        let phase = c.open_dialog(&test_ctx()).await.unwrap();
        assert!(matches!(phase, Phase::Ready));
        {
            let seen = seen.lock().unwrap();
            assert_eq!(seen.len(), 2);
            assert!(has_hktan(&seen[0]), "first try is two-step: {:?}", seen[0]);
            assert!(!has_hktan(&seen[1]), "retry is one-step: {:?}", seen[1]);
        }
        assert!(c.st.single_step);
        let persisted = serde_json::to_value(&c.st).unwrap();
        assert_eq!(persisted["single_step"], true);

        // Next sync starts directly one-step.
        let (url2, seen2) = mock_bank(vec![ACCEPT]);
        let mut c2 = two_step_connector(&url2, persisted);
        assert_eq!(c2.sec(), "999");
        c2.open_dialog(&test_ctx()).await.unwrap();
        let seen2 = seen2.lock().unwrap();
        assert_eq!(seen2.len(), 1);
        assert!(!has_hktan(&seen2[0]), "{:?}", seen2[0]);
    }

    #[tokio::test]
    async fn dialog_init_9010_with_stale_system_id_does_not_fall_back() {
        let (url, seen) = mock_bank(vec![STALE_SYSTEM_ID]);
        let state = serde_json::json!({"system_id": "123", "sec_func": "946", "tan_method_name": "", "tan_medium": "", "versions": {}, "tan_required": {}});
        let mut c = two_step_connector(&url, state);
        assert!(c.open_dialog(&test_ctx()).await.is_err());
        assert_eq!(seen.lock().unwrap().len(), 1);
        assert!(!c.st.single_step);
        assert!(c.st.system_id.is_empty());
    }

    #[tokio::test]
    async fn failed_single_step_retry_is_not_remembered() {
        let (url, seen) = mock_bank(vec![REJECT_9010]);
        let state = serde_json::json!({"system_id": "123", "sec_func": "946", "tan_method_name": "", "tan_medium": "", "versions": {}, "tan_required": {}});
        let mut c = two_step_connector(&url, state);
        assert!(c.open_dialog(&test_ctx()).await.is_err());
        assert_eq!(seen.lock().unwrap().len(), 2);
        assert!(!c.st.single_step);
    }

    #[test]
    fn secure_url_check_rejects_plain_http() {
        assert!(crate::connectors::ensure_secure_fints_url("https://bank.example/fints").is_ok());
        assert!(crate::connectors::ensure_secure_fints_url("http://bank.example/fints").is_err());
        assert!(crate::connectors::ensure_secure_fints_url("ftp://bank.example").is_err());
        assert!(crate::connectors::ensure_secure_fints_url("").is_err());
    }

    #[tokio::test]
    async fn send_rejects_http_url() {
        let mut c = FinTsConnector::new("52090000");
        c.url = "http://bank.example/fints".into();
        let r = c.send(&test_ctx(), vec![], "999", None).await;
        assert!(matches!(r, Err(CoreError::Protocol { .. })));
    }

    #[tokio::test]
    async fn send_does_not_follow_redirects() {
        use std::io::{Read, Write};
        for code in [301, 302, 307, 308] {
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
            let h2 = hits.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut s) = stream else { break };
                    h2.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let mut buf = [0u8; 8192];
                    let _ = s.read(&mut buf);
                    let resp = format!(
                        "HTTP/1.1 {code} Moved\r\nLocation: http://127.0.0.1:{port}/other\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    );
                    let _ = s.write_all(resp.as_bytes());
                }
            });
            let mut c = FinTsConnector::new("52090000");
            c.url = format!("http://127.0.0.1:{port}/fints");
            let r = c.send(&test_ctx(), vec![], "999", None).await;
            assert!(
                matches!(r, Err(CoreError::Network { .. })),
                "code {code}: {r:?}"
            );
            assert_eq!(
                hits.load(std::sync::atomic::Ordering::SeqCst),
                1,
                "code {code}"
            );
        }
    }

    #[test]
    fn message_has_correct_length_and_structure() {
        let mut c = FinTsConnector::new("52090000");
        c.product_id = "TESTPRODUCT".into();
        c.product_version = "0.1".into();
        let ctx = ConnectContext {
            connection_id: 1,
            login_name: "user:1".into(),
            secret: SecretString::new("12345".into()),
            settings: Default::default(),
            state: serde_json::json!({}),
            since: "2025-01-01".into(),
            since_by_account: Default::default(),
        };
        let payload = vec![c.hkidn(&ctx, 3), c.hkvvb(4), c.hktan_process4(5, "HKIDN")];
        let msg = c.build_message(&ctx, &payload, "946", None);
        let header_len: usize = std::str::from_utf8(&msg[10..22]).unwrap().parse().unwrap();
        assert_eq!(header_len, msg.len());
        let segs = syntax::parse_response(&msg).unwrap();
        let ids: Vec<&str> = segs.iter().map(|s| s.id()).collect();
        assert_eq!(
            ids,
            vec!["HNHBK", "HNVSK", "HNSHK", "HKIDN", "HKVVB", "HKTAN", "HNSHA", "HNHBS"]
        );
        assert_eq!(segs[3].get(2, 0), "user:1", "login is escaped and restored");
        assert_eq!(segs[6].get(3, 0), "12345");
        assert_eq!(segs[7].number(), 7);
        // Two-step method: security profile version 2 in HNVSK and HNSHK.
        assert_eq!((segs[1].get(1, 0), segs[1].get(1, 1)), ("PIN", "2"));
        assert_eq!((segs[2].get(1, 0), segs[2].get(1, 1)), ("PIN", "2"));

        // One-step (999, synchronisation dialog): profile version 1. Consorsbank
        // answers PIN:2 here with "9010 Ungültiger Signaturaufbau".
        let sync = vec![c.hkidn(&ctx, 3), c.hkvvb(4)];
        let msg = c.build_message(&ctx, &sync, "999", None);
        let segs = syntax::parse_response(&msg).unwrap();
        assert_eq!((segs[1].id(), segs[1].get(1, 1)), ("HNVSK", "1"));
        assert_eq!((segs[2].id(), segs[2].get(1, 1)), ("HNSHK", "1"));
        assert_eq!(segs[2].get(2, 0), "999");
    }

    #[test]
    fn consorsbank_statements_always_carry_hktan() {
        let mut c = FinTsConnector::new("76030080");
        c.st.tan_required.insert("HKKAZ".into(), false);
        assert!(c.needs_hktan("HKKAZ") && c.needs_hktan("HKSAL"));
        assert!(!c.needs_hktan("HKSPA"));
        // Other banks: HIPINS decides.
        let mut c = FinTsConnector::new("52090000");
        c.st.tan_required.insert("HKKAZ".into(), false);
        c.st.tan_required.insert("HKSAL".into(), true);
        assert!(!c.needs_hktan("HKKAZ") && c.needs_hktan("HKSAL"));
    }

    fn reply(raw: &[u8]) -> BankReply {
        let segments = syntax::parse_response(raw).unwrap();
        let mut codes = Vec::new();
        for s in &segments {
            if s.id() == "HIRMG" || s.id() == "HIRMS" {
                for el in s.elements.iter().skip(1) {
                    let t = |i: usize| el.get(i).map(|v| v.text().to_string()).unwrap_or_default();
                    codes.push((
                        t(0),
                        s.reference(),
                        t(2),
                        el.iter().skip(3).map(|v| v.text().to_string()).collect(),
                    ));
                }
            }
        }
        BankReply {
            segments,
            codes,
            sent: HashMap::from([(3, "HKKAZ".to_string())]),
        }
    }

    #[test]
    fn negotiates_versions_from_bpd() {
        let mut c = FinTsConnector::new("52090000");
        let r = reply(b"HISALS:5:5:3+1+1+0'HISALS:6:7:3+1+1+0'HISALS:7:8:3+1+1+0'HICAZS:8:1:3+1+1+0+450:N:N:urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.02:urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.08'HITANS:9:6:3+1+1+0+J:N:0:946:2:SECUREGO:Decoupled::SecureGo plus:6:1:x'HITANS:10:7:3+1+1+0+J:N:0'HIKAZS:11:7:3+1+1+0+90:N:N'HIRMS:12:2:3+3920::Zugelassene Zwei-Schritt-Verfahren:942:946'");
        c.learn_bpd(&r);
        assert_eq!(c.version("HKSAL"), 8);
        assert_eq!(c.version("HKCAZ"), 1);
        assert_eq!(c.version("HKTAN"), 7);
        assert_eq!(c.version("HKKAZ"), 7);
        assert!(!c.bank_supports("HKSPA"));
        assert_eq!(
            c.st.camt_formats[0],
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08"
        );
        assert_eq!(
            c.st.sec_func, "946",
            "decoupled SecureGo plus preferred over 942"
        );
        assert_eq!(c.st.tan_method_name, "SecureGo plus");
    }

    #[test]
    fn parses_upd_with_allowed_transactions_and_loans() {
        let r = reply(b"HIUPD:5:6:3+0012345601::280:52090000+DE44520900000012345601+KUNDE+1+EUR+Muster+Alex+Girokonto++HKSAL:1+HKCAZ:1+HKKAZ:1'HIUPD:6:6:3+0098765400::280:52090000++KUNDE+40+EUR+Muster+Alex+Baudarlehen++HKSAL:1'");
        let upds: Vec<UpdAccount> = r.all("HIUPD").map(parse_upd).collect();
        assert_eq!(upds.len(), 2);
        assert_eq!(upds[0].iban, "DE44520900000012345601");
        assert!(upds[0].allowed.contains("HKCAZ"));
        assert_eq!(kind_from_code(upds[1].kind_code), AccountKind::Loan);
        assert!(
            upds[1].allowed.contains("HKSAL") && !upds[1].allowed.contains("HKCAZ"),
            "loan: balance only"
        );
        let kti = FinTsConnector::kti(&SepaAccount {
            iban: String::new(),
            bic: String::new(),
            account_number: "0098765400".into(),
            sub_account: String::new(),
            blz: "52090000".into(),
        });
        assert_eq!(kti, "::0098765400::280:52090000");
        // IBAN known: IBAN:BIC – except Consorsbank, which wants the full form.
        let acc = |blz: &str| SepaAccount {
            iban: "DE00".into(),
            bic: "BICXDEXX".into(),
            account_number: "0123456789".into(),
            sub_account: String::new(),
            blz: blz.into(),
        };
        assert_eq!(FinTsConnector::kti(&acc("52090000")), "DE00:BICXDEXX");
        assert_eq!(
            FinTsConnector::kti(&acc("76030080")),
            "DE00:BICXDEXX:0123456789::280:76030080"
        );
    }

    #[test]
    fn error_names_offending_segment() {
        let r = reply(b"HIRMG:2:2+9050::Die Nachricht enth\xe4lt Fehler.'HIRMS:3:2:3+9010::Auftragsart wird nicht unterst\xfctzt.'");
        let err = r.check().unwrap_err().to_string();
        assert!(err.contains("9050 [Nachricht]"), "{err}");
        assert!(err.contains("9010 [HKKAZ #3]"), "{err}");
    }

    #[test]
    fn submit_reply_declines_instant_only_when_order_was_refused() {
        // Order refused before any approval -> instant declined, with the
        // specific code rather than the generic 9050.
        let r = reply(b"HIRMG:2:2+9050::Die Nachricht enth\xe4lt Fehler.'HIRMS:3:2:3+9210::Empf\xe4ngerbank nimmt nicht an SEPA Instant teil.'");
        let OrderReply::InstantDeclined(why) = classify_submit_reply(&r, true, 3) else {
            panic!()
        };
        assert!(why.starts_with("9210 "), "{why}");
        assert!(!why.contains("9050"), "{why}");
        // Same reply for a regular order -> plain error.
        assert_eq!(classify_submit_reply(&r, false, 3), OrderReply::Rejected);
        // Accepted, TAN required.
        let r = reply(b"HIRMG:2:2+0010::Nachricht entgegengenommen.'HIRMS:3:2:3+0030::Auftrag empfangen - TAN erforderlich.'");
        assert_eq!(classify_submit_reply(&r, true, 3), OrderReply::Accepted);
        // Wrong PIN -> not executed, no instant decline either.
        let r = reply(b"HIRMG:2:2+9942::PIN falsch.'");
        assert_eq!(classify_submit_reply(&r, true, 3), OrderReply::Rejected);
        // Dialog abort on an instant order: may have been executed.
        let r = reply(b"HIRMG:2:2+9800::Dialog abgebrochen.'");
        assert!(matches!(
            classify_submit_reply(&r, true, 3),
            OrderReply::Unknown(_)
        ));
        // Contradictory: order segment confirmed but errors present -> unknown.
        let r =
            reply(b"HIRMG:2:2+9800::Dialog abgebrochen.'HIRMS:3:2:3+0020::Auftrag ausgef\xfchrt.'");
        assert!(matches!(
            classify_submit_reply(&r, true, 3),
            OrderReply::Unknown(_)
        ));
    }

    #[test]
    fn submit_reply_reads_the_order_segment_behind_the_name_check() {
        // With HKVPP in front, the order is segment 4: its confirmation plus
        // an error elsewhere is contradictory (unknown), not a plain decline.
        let r =
            reply(b"HIRMG:2:2+9800::Dialog abgebrochen.'HIRMS:4:2:4+0020::Auftrag ausgef\xfchrt.'");
        assert!(matches!(
            classify_submit_reply(&r, true, 4),
            OrderReply::Unknown(_)
        ));
        // A success code for the name-check segment (3) says nothing about the order.
        let r =
            reply(b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+0020::ok.'HIRMS:4:2:4+9210::Abgelehnt.'");
        assert!(matches!(
            classify_submit_reply(&r, true, 4),
            OrderReply::InstantDeclined(_)
        ));
    }

    #[test]
    fn approval_reply_never_treats_ambiguous_codes_as_not_executed() {
        // Executed.
        let r = reply(b"HIRMG:2:2+0010::Nachricht entgegengenommen.'HIRMS:3:2:3+0020::Auftrag ausgef\xfchrt.'");
        assert_eq!(classify_approval_reply(&r, true), OrderReply::Accepted);
        // Generic codes, dialog abort, unknown order codes, transient errors:
        // the instant payment may have been executed -> unknown, both for
        // instant and regular orders.
        for raw in [
            &b"HIRMG:2:2+9050::Die Nachricht enth\xe4lt Fehler.'"[..],
            &b"HIRMG:2:2+9010::Verarbeitung nicht m\xf6glich.'"[..],
            &b"HIRMG:2:2+9800::Dialog abgebrochen.'"[..],
            &b"HIRMG:2:2+9800::Dialog abgebrochen.'HIRMS:3:2:3+9210::Auftrag abgelehnt.'"[..],
            &b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+9110::Verarbeitung abgebrochen.'"[..],
            &b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+9210::Abgelehnt.'HIRMS:4:2:4+9160::Unbekannt.'"
                [..],
        ] {
            for instant in [true, false] {
                let got = classify_approval_reply(&reply(raw), instant);
                assert!(
                    matches!(got, OrderReply::Unknown(_)),
                    "{:?} -> {got:?}",
                    String::from_utf8_lossy(raw)
                );
            }
        }
        // Clear order-specific rejection (9210, limit 9380) without 9800:
        // instant -> declined (user may resend as regular), regular -> error.
        for raw in [
            &b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+9210::Empf\xe4ngerbank nicht erreichbar.'"[..],
            &b"HIRMG:2:2+3060::Warnungen.'HIRMS:3:2:3+9380::Betrag \xfcbersteigt Limit.'"[..],
        ] {
            let r = reply(raw);
            assert!(matches!(
                classify_approval_reply(&r, true),
                OrderReply::InstantDeclined(_)
            ));
            assert_eq!(classify_approval_reply(&r, false), OrderReply::Rejected);
        }
        // Declined in the app, wrong TAN -> not executed.
        for raw in [
            &b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+9955::Auftrag abgelehnt.'"[..],
            &b"HIRMG:2:2+9050::Fehler.'HIRMS:3:2:3+9941::TAN ung\xfcltig.'"[..],
        ] {
            assert_eq!(
                classify_approval_reply(&reply(raw), true),
                OrderReply::Rejected
            );
        }
    }

    #[test]
    fn reads_instant_formats_and_negotiates_hkipz() {
        // HIIPZS as sent by Consorsbank (purpose codes empty) and comdirect.
        let raw = b"HIIPZS:11:1:3+1+1+0+:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.03'";
        let r = reply(raw);
        assert_eq!(
            pain_formats(&r, "HIIPZS"),
            vec![
                sepa::PAIN_09_DESCRIPTOR.to_string(),
                sepa::PAIN_DESCRIPTOR.to_string()
            ]
        );
        let raw = b"HIIPZS:20:1:3+999+1+0+BENE,BONU:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09.xsd'";
        assert_eq!(
            pain_formats(&reply(raw), "HIIPZS"),
            vec![sepa::PAIN_09_DESCRIPTOR.to_string()]
        );

        let mut c = FinTsConnector::new("76030080");
        c.learn_bpd(&reply(raw));
        assert!(c.bank_supports("HKIPZ"));
        assert_eq!(c.version("HKIPZ"), 1);
        assert_eq!(
            c.st.pain_formats["HKIPZ"],
            vec![sepa::PAIN_09_DESCRIPTOR.to_string()]
        );
        // A second BPD message adds formats instead of replacing them.
        c.learn_bpd(&reply(
            b"HIIPZS:20:1:3+999+1+0+:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.03'",
        ));
        assert_eq!(
            c.st.pain_formats["HKIPZ"],
            vec![
                sepa::PAIN_09_DESCRIPTOR.to_string(),
                sepa::PAIN_DESCRIPTOR.to_string()
            ]
        );
    }

    fn order_for(c: &mut FinTsConnector) {
        c.order = Some(PreparedOrder {
            seg_id: "HKCCS",
            kti: String::new(),
            descriptor: sepa::PAIN_DESCRIPTOR,
            xml: String::new(),
            instant: false,
            recipient_name: "Erika Musterfrau".into(),
            recipient_iban: "DE89370400440532013000".into(),
            batch: None,
        });
    }

    #[test]
    fn reads_vop_parameters_from_bpd() {
        // HIVPPS as sent by comdirect.
        let raw =
            b"HIVPPS:7:1:3+1+1+0+20:J:S:N:N:sepade.pain.002.001.10.xsd:HKIPZ:HKCUI:HKCCS:HKCDE'";
        let mut c = FinTsConnector::new("20041111");
        c.learn_bpd(&reply(raw));
        assert_eq!(c.st.vop_format, "sepade.pain.002.001.10.xsd");
        assert_eq!(c.st.vop_orders, vec!["HKIPZ", "HKCUI", "HKCCS", "HKCDE"]);
        // Consorsbank sends no HIVPPS: no name check.
        let c = FinTsConnector::new("76030080");
        assert!(c.st.vop_format.is_empty());
    }

    #[test]
    fn reads_batch_parameters_and_builds_hkccm() {
        let raw =
            b"HICCMS:12:1:3+1+1+0+500:J:J:urn?:iso?:std?:iso?:20022?:tech?:xsd?:pain.001.001.09'";
        let mut c = FinTsConnector::new("20041111");
        c.learn_bpd(&reply(raw));
        assert_eq!(
            c.st.batch_params,
            Some(BatchParams {
                max_count: 500,
                sum_required: true,
                single_booking_allowed: true
            })
        );
        assert_eq!(
            c.st.pain_formats["HKCCM"],
            vec![sepa::PAIN_09_DESCRIPTOR.to_string()]
        );
        order_for(&mut c);
        if let Some(o) = c.order.as_mut() {
            o.seg_id = "HKCCM";
            o.batch = Some((123_450, true));
        }
        let text =
            String::from_utf8_lossy(&c.order_payload(Vop::None).unwrap().concat()).to_string();
        assert!(text.contains("HKCCM:3:"), "{text}");
        assert!(text.contains("+1234,50:EUR+J+"), "{text}");
        // Without the BPD flags neither optional field is sent.
        c.st.batch_params = Some(BatchParams::default());
        let text =
            String::from_utf8_lossy(&c.order_payload(Vop::None).unwrap().concat()).to_string();
        assert!(!text.contains("EUR+"), "{text}");
    }

    #[test]
    fn polling_sends_only_hkvpp_without_order_or_hktan() {
        let mut c = FinTsConnector::new("20041111");
        order_for(&mut c);
        c.st.vop_format = "urn:iso:std:iso:20022:tech:xsd:pain.002.001.14".into();
        let text = |p: Vec<Vec<u8>>| String::from_utf8_lossy(&p.concat()).to_string();
        let first = text(c.order_payload(Vop::Check).unwrap());
        assert!(first.contains("HKVPP") && first.contains("HKCCS") && first.contains("HKTAN"));
        let poll = text(
            c.order_payload(Vop::Poll {
                polling_id: b"POLL-1".to_vec(),
                touchdown: Some("TD1".into()),
            })
            .unwrap(),
        );
        assert!(poll.contains("HKVPP") && poll.contains("@6@POLL-1") && poll.contains("TD1"));
        for seg in ["HKCCS", "HKIPZ", "HKCSE", "HKTAN"] {
            assert!(!poll.contains(seg), "{seg} in {poll}");
        }
    }

    #[test]
    fn worst_vop_result_wins_and_bank_texts_are_cleaned() {
        assert_eq!(worst_vop_code(&["RCVC", "... RVNM ..."]), "RVNM");
        assert_eq!(worst_vop_code(&["", "RCVC RVMC"]), "RVMC");
        assert_eq!(worst_vop_code(&["RCVC", "PDNG"]), "PDNG");
        assert_eq!(worst_vop_code(&["RCVC"]), "RCVC");
        assert_eq!(worst_vop_code(&["", ""]), "");
        let dirty = format!("Max\u{0}\n  Muster\u{7}{}", "x".repeat(100));
        let clean = clean_bank_text(&dirty, VOP_NAME_MAX);
        assert_eq!(clean.chars().count(), VOP_NAME_MAX);
        assert!(clean.starts_with("Max Muster") && !clean.chars().any(|c| c.is_control()));
    }

    #[test]
    fn evaluates_vop_results() {
        // Close match: bank reports the holder's name and a notice.
        let r = reply(b"HIRMG:2:2+3060::Hinweise.'HIRMS:3:2:4+3945::Freigabe ohne VOP-Best\xe4tigung nicht m\xf6glich.'HIVPP:5:1:3+@8@VOPID123+++++DE89370400440532013000::Erika Mustermann::RVMC+Trotzdem freigeben??'");
        let mut c = FinTsConnector::new("20041111");
        order_for(&mut c);
        let check = c.evaluate_payee(&r).unwrap();
        assert_eq!(check.result, PayeeMatch::CloseMatch);
        assert_eq!(check.bank_name.as_deref(), Some("Erika Mustermann"));
        assert_eq!(check.entered_name, "Erika Musterfrau");
        assert_eq!(check.notice.as_deref(), Some("Trotzdem freigeben?"));
        assert_eq!(c.vop_id.as_deref(), Some(&b"VOPID123"[..]));
        assert!(!c.vop_with_tan);
        assert_eq!(c.hkvpa(3).unwrap(), b"HKVPA:3:1+@8@VOPID123'".to_vec());

        // Match without 3945: go on to the approval, HKVPA with the TAN.
        let r =
            reply(b"HIRMG:2:2+0010::OK.'HIVPP:5:1:3+@4@ABCD+++++DE89370400440532013000::::RCVC'");
        let mut c = FinTsConnector::new("20041111");
        order_for(&mut c);
        assert!(c.evaluate_payee(&r).is_none());
        assert!(c.vop_with_tan);

        // Pending (polling ID, no result) is reported as "not possible".
        let r = reply(b"HIVPP:6:1:3+++@36@6b1a5ec1-9af5-4398-b0da-6526cbf210dd+++++2'");
        let h = r.first("HIVPP").unwrap();
        assert_eq!(vop_result_code(h), "");
        assert_eq!(h.binary(3).map(|b| b.len()), Some(36));
        assert_eq!(h.get(8, 0), "2");
        let mut c = FinTsConnector::new("20041111");
        order_for(&mut c);
        assert_eq!(
            c.evaluate_payee(&r).unwrap().result,
            PayeeMatch::NotPossible
        );

        // No HIVPP at all: continue without a check.
        let mut c = FinTsConnector::new("20041111");
        order_for(&mut c);
        assert!(c.evaluate_payee(&reply(b"HIRMG:2:2+0010::OK.'")).is_none());
    }

    #[test]
    fn builds_hkcaz_with_escaped_camt_urn() {
        let mut c = FinTsConnector::new("52090000");
        c.st.versions.insert("HKCAZ".into(), vec![1]);
        let acc = SepaAccount {
            iban: "DE44520900000012345601".into(),
            bic: "GENODE51KS1".into(),
            account_number: String::new(),
            sub_account: String::new(),
            blz: "52090000".into(),
        };
        let seg = c.hkcaz(
            &acc,
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08",
            "20260801",
            "20261109",
            None,
        );
        let text = String::from_utf8(seg.clone()).unwrap();
        assert!(text.starts_with("HKCAZ:3:1+DE44520900000012345601:GENODE51KS1+urn?:iso?:std?:iso?:20022?:tech?:xsd?:camt.052.001.08+N+20260801+20261109'"), "{text}");
        let parsed = syntax::parse(&seg).unwrap();
        assert_eq!(
            parsed[0].get(2, 0),
            "urn:iso:std:iso:20022:tech:xsd:camt.052.001.08"
        );
    }

    #[test]
    fn builds_hkwpd_for_depot_with_touchdown() {
        let acc = SepaAccount {
            iban: String::new(),
            bic: String::new(),
            account_number: "1234567".into(),
            sub_account: String::new(),
            blz: "12030000".into(),
        };
        assert_eq!(
            FinTsConnector::hkwpd(6, &acc, None),
            b"HKWPD:3:6+1234567::280:12030000'".to_vec()
        );
        assert_eq!(
            FinTsConnector::hkwpd(5, &acc, Some("P:2")),
            b"HKWPD:3:5+1234567::280:12030000++++P?:2'".to_vec()
        );
    }

    #[test]
    fn hktan_uses_negotiated_version() {
        let mut c = FinTsConnector::new("52090000");
        c.st.versions.insert("HKTAN".into(), vec![6]);
        let seg = String::from_utf8(c.hktan_process4(5, "HKIDN")).unwrap();
        assert!(seg.starts_with("HKTAN:5:6+4+HKIDN"), "{seg}");
    }

    #[test]
    fn loan_sub_accounts_get_distinct_labels() {
        let mk = |sub: &str| SepaAccount {
            iban: String::new(),
            bic: String::new(),
            account_number: "0098765400".into(),
            sub_account: sub.into(),
            blz: "52090000".into(),
        };
        assert_ne!(account_label(&mk("01")), account_label(&mk("02")));
        assert_eq!(account_label(&mk("")), "0098765400");
    }
}

#[cfg(test)]
mod date_slice_tests {
    #[test]
    fn fints_date_needs_eight_ascii_digits() {
        assert_eq!(super::fints_date("20261107").as_deref(), Some("2026-11-07"));
        assert_eq!(super::fints_date("202ä1107"), None); // 8 bytes, not 8 digits
        assert_eq!(super::fints_date("2026110"), None);
        assert_eq!(super::fints_date(""), None);
    }
}
