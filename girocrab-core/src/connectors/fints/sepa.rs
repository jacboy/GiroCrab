//! SEPA credit transfer helpers: IBAN / BIC validation (ISO 13616 Mod-97,
//! ISO 9362) and a `pain.001` generator (`.001.03` / `.001.09`) for single
//! transfers, optionally flagged as SEPA Instant (`LclInstrm` = `INST`).

use crate::error::{CoreError, CoreResult};
use crate::i18n::tr;

pub const PAIN_DESCRIPTOR: &str = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.03";
pub const PAIN_09_DESCRIPTOR: &str = "urn:iso:std:iso:20022:tech:xsd:pain.001.001.09";

/// pain.001 schema version. `.09` is what most banks expect for SEPA Instant
/// (HKIPZ); `.03` is the long-standing format for regular transfers (HKCCS).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PainVersion {
    V03,
    V09,
}

impl PainVersion {
    pub fn descriptor(self) -> &'static str {
        match self {
            PainVersion::V03 => PAIN_DESCRIPTOR,
            PainVersion::V09 => PAIN_09_DESCRIPTOR,
        }
    }

    /// Picks the version for a list of descriptors a bank advertises in its
    /// BPD (e.g. HIIPZS). Prefers `.09`; an empty list (unknown) also means `.09`.
    pub fn pick(advertised: &[String]) -> Option<Self> {
        let has = |d: &str| advertised.iter().any(|a| a == d);
        if advertised.is_empty() || has(PAIN_09_DESCRIPTOR) {
            Some(PainVersion::V09)
        } else if has(PAIN_DESCRIPTOR) {
            Some(PainVersion::V03)
        } else {
            None
        }
    }
}

/// IBAN length per country (SEPA area + common neighbours).
const IBAN_LENGTHS: &[(&str, usize)] = &[
    ("AD", 24),
    ("AT", 20),
    ("BE", 16),
    ("BG", 22),
    ("CH", 21),
    ("CY", 28),
    ("CZ", 24),
    ("DE", 22),
    ("DK", 18),
    ("EE", 20),
    ("ES", 24),
    ("FI", 18),
    ("FR", 27),
    ("GB", 22),
    ("GI", 23),
    ("GR", 27),
    ("HR", 21),
    ("HU", 28),
    ("IE", 22),
    ("IS", 26),
    ("IT", 27),
    ("LI", 21),
    ("LT", 20),
    ("LU", 20),
    ("LV", 21),
    ("MC", 27),
    ("MT", 31),
    ("NL", 18),
    ("NO", 15),
    ("PL", 28),
    ("PT", 25),
    ("RO", 24),
    ("SE", 24),
    ("SI", 19),
    ("SK", 24),
    ("SM", 27),
    ("VA", 22),
];

/// IBAN length of `country` (two upper-case letters), if known.
pub fn iban_length(country: &str) -> Option<usize> {
    IBAN_LENGTHS
        .iter()
        .find(|(c, _)| *c == country)
        .map(|(_, len)| *len)
}

/// Removes whitespace and upper-cases.
pub fn normalize_iban(iban: &str) -> String {
    iban.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase()
}

/// Strict IBAN check: characters, country prefix, length, Mod-97 checksum.
pub fn validate_iban(iban: &str) -> bool {
    let s = normalize_iban(iban);
    if s.len() < 15 || s.len() > 34 || !s.chars().all(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let b = s.as_bytes();
    if !(b[0].is_ascii_uppercase()
        && b[1].is_ascii_uppercase()
        && b[2].is_ascii_digit()
        && b[3].is_ascii_digit())
    {
        return false;
    }
    if iban_length(&s[..2]) != Some(s.len()) {
        return false;
    }
    // Move the first four characters to the end, letters -> 10..35.
    let mut rem: u32 = 0;
    for c in s[4..].chars().chain(s[..4].chars()) {
        let v = c.to_digit(36).unwrap_or(0);
        rem = if v >= 10 {
            (rem * 100 + v) % 97
        } else {
            (rem * 10 + v) % 97
        };
    }
    rem == 1
}

/// BIC: 8 or 11 characters (4 letters bank, 2 letters country, 2 alnum
/// location, optional 3 alnum branch).
pub fn validate_bic(bic: &str) -> bool {
    let s: String = bic
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_uppercase();
    if s.len() != 8 && s.len() != 11 {
        return false;
    }
    let b = s.as_bytes();
    b[..6].iter().all(|c| c.is_ascii_uppercase())
        && b[6..].iter().all(|c| c.is_ascii_alphanumeric())
}

pub fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if c.is_control() => out.push(' '),
            c => out.push(c),
        }
    }
    out
}

/// Reduces text to the DK SEPA character set (`a-z A-Z 0-9 / - ? : ( ) . , ' + space`):
/// umlauts/ß are transliterated, common accents lose their diacritic, anything
/// else becomes a space.
pub fn sanitize_sepa_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            'ä' => out.push_str("ae"),
            'ö' => out.push_str("oe"),
            'ü' => out.push_str("ue"),
            'Ä' => out.push_str("Ae"),
            'Ö' => out.push_str("Oe"),
            'Ü' => out.push_str("Ue"),
            'ß' | 'ẞ' => out.push_str("ss"),
            'à' | 'á' | 'â' | 'ã' | 'å' => out.push('a'),
            'À' | 'Á' | 'Â' | 'Ã' | 'Å' => out.push('A'),
            'è' | 'é' | 'ê' | 'ë' => out.push('e'),
            'È' | 'É' | 'Ê' | 'Ë' => out.push('E'),
            'ì' | 'í' | 'î' | 'ï' => out.push('i'),
            'Ì' | 'Í' | 'Î' | 'Ï' => out.push('I'),
            'ò' | 'ó' | 'ô' | 'õ' | 'ø' => out.push('o'),
            'Ò' | 'Ó' | 'Ô' | 'Õ' | 'Ø' => out.push('O'),
            'ù' | 'ú' | 'û' => out.push('u'),
            'Ù' | 'Ú' | 'Û' => out.push('U'),
            'ç' => out.push('c'),
            'Ç' => out.push('C'),
            'ñ' => out.push('n'),
            'Ñ' => out.push('N'),
            'æ' => out.push_str("ae"),
            'Æ' => out.push_str("Ae"),
            c if c.is_ascii_alphanumeric() || "/-?:().,'+ ".contains(c) => out.push(c),
            _ => out.push(' '),
        }
    }
    out
}

fn clip(s: &str, max: usize) -> String {
    sanitize_sepa_text(s)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max)
        .collect()
}

/// `1234` -> "12.34"
pub fn format_amount(cents: i64) -> String {
    format!("{}.{:02}", cents / 100, cents % 100)
}

pub struct Pain001<'a> {
    pub message_id: &'a str,
    /// ISO date-time, e.g. 2026-11-09T10:15:00
    pub created: &'a str,
    /// ISO date (YYYY-MM-DD)
    pub execution_date: &'a str,
    pub debtor_name: &'a str,
    pub debtor_iban: &'a str,
    pub debtor_bic: &'a str,
    pub creditor_name: &'a str,
    pub creditor_iban: &'a str,
    pub creditor_bic: Option<&'a str>,
    pub amount_cents: i64,
    pub purpose: &'a str,
    pub version: PainVersion,
    /// EndToEndId (stable per transfer; `NOTPROVIDED` when empty).
    pub end_to_end_id: &'a str,
    /// SEPA Instant Credit Transfer (`<LclInstrm><Cd>INST</Cd></LclInstrm>`).
    pub instant: bool,
}

/// Builds a single-transfer `pain.001` document (UTF-8).
pub fn build_pain001(p: &Pain001) -> CoreResult<String> {
    if p.amount_cents <= 0 {
        return Err(CoreError::InvalidInput {
            message: tr("Der Betrag muss größer als 0 sein.").into(),
        });
    }
    if !validate_iban(p.creditor_iban) {
        return Err(CoreError::InvalidInput {
            message: tr("Die Empfänger-IBAN ist ungültig.").into(),
        });
    }
    if p.creditor_name.trim().is_empty() {
        return Err(CoreError::InvalidInput {
            message: tr("Der Empfängername fehlt.").into(),
        });
    }
    let amount = format_amount(p.amount_cents);
    let msg_id = xml_escape(&clip(p.message_id, 35));
    let debtor = xml_escape(&clip(p.debtor_name, 70));
    let creditor = xml_escape(&clip(p.creditor_name, 70));
    let purpose = xml_escape(&clip(p.purpose, 140));
    let d_iban = normalize_iban(p.debtor_iban);
    let c_iban = normalize_iban(p.creditor_iban);
    // pain.001.001.09 renamed <BIC> to <BICFI> and wraps the execution date.
    let bic_tag = match p.version {
        PainVersion::V03 => "BIC",
        PainVersion::V09 => "BICFI",
    };
    let d_agent = if validate_bic(p.debtor_bic) {
        format!("<{bic_tag}>{}</{bic_tag}>", normalize_iban(p.debtor_bic))
    } else {
        "<Othr><Id>NOTPROVIDED</Id></Othr>".to_string()
    };
    let c_agent = match p.creditor_bic.filter(|b| validate_bic(b)) {
        Some(b) => format!(
            "<CdtrAgt><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></CdtrAgt>",
            normalize_iban(b)
        ),
        None => String::new(),
    };
    let rmt = if purpose.is_empty() {
        String::new()
    } else {
        format!("<RmtInf><Ustrd>{purpose}</Ustrd></RmtInf>")
    };
    let exec = xml_escape(p.execution_date);
    let exec = match p.version {
        PainVersion::V03 => exec,
        PainVersion::V09 => format!("<Dt>{exec}</Dt>"),
    };
    let local_instrument = if p.instant {
        "<LclInstrm><Cd>INST</Cd></LclInstrm>"
    } else {
        ""
    };
    let ns = p.version.descriptor();
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<Document xmlns=\"{ns}\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
<CstmrCdtTrfInitn>\
<GrpHdr><MsgId>{msg_id}</MsgId><CreDtTm>{created}</CreDtTm><NbOfTxs>1</NbOfTxs><CtrlSum>{amount}</CtrlSum>\
<InitgPty><Nm>{debtor}</Nm></InitgPty></GrpHdr>\
<PmtInf><PmtInfId>{msg_id}</PmtInfId><PmtMtd>TRF</PmtMtd><BtchBookg>false</BtchBookg><NbOfTxs>1</NbOfTxs><CtrlSum>{amount}</CtrlSum>\
<PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl>{local_instrument}</PmtTpInf><ReqdExctnDt>{exec}</ReqdExctnDt>\
<Dbtr><Nm>{debtor}</Nm></Dbtr><DbtrAcct><Id><IBAN>{d_iban}</IBAN></Id></DbtrAcct>\
<DbtrAgt><FinInstnId>{d_agent}</FinInstnId></DbtrAgt><ChrgBr>SLEV</ChrgBr>\
<CdtTrfTxInf><PmtId><EndToEndId>{e2e}</EndToEndId></PmtId>\
<Amt><InstdAmt Ccy=\"EUR\">{amount}</InstdAmt></Amt>{c_agent}\
<Cdtr><Nm>{creditor}</Nm></Cdtr><CdtrAcct><Id><IBAN>{c_iban}</IBAN></Id></CdtrAcct>{rmt}\
</CdtTrfTxInf></PmtInf></CstmrCdtTrfInitn></Document>",
        created = xml_escape(p.created),
        e2e = if p.end_to_end_id.trim().is_empty() {
            "NOTPROVIDED".to_string()
        } else {
            xml_escape(&clip(p.end_to_end_id, 35))
        },
    ))
}

/// One payment of a batch transfer (Sammelüberweisung).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchPayment {
    pub name: String,
    pub iban: String,
    pub bic: Option<String>,
    pub amount_cents: i64,
    pub purpose: String,
    /// EndToEndId, unique per payment (`NOTPROVIDED` when empty).
    pub end_to_end_id: String,
}

pub struct Pain001Batch<'a> {
    pub message_id: &'a str,
    /// ISO date-time, e.g. 2026-11-09T10:15:00
    pub created: &'a str,
    /// ISO date (YYYY-MM-DD), one for the whole batch.
    pub execution_date: &'a str,
    pub debtor_name: &'a str,
    pub debtor_iban: &'a str,
    pub debtor_bic: &'a str,
    pub payments: &'a [BatchPayment],
    pub version: PainVersion,
    /// `true` = the bank books the batch as one entry (`BtchBookg` true),
    /// `false` = one booking per payment.
    pub batch_booking: bool,
}

/// Sum of all payments in cents; `None` on overflow.
pub fn batch_total_cents(payments: &[BatchPayment]) -> Option<i64> {
    payments
        .iter()
        .try_fold(0i64, |acc, p| acc.checked_add(p.amount_cents))
}

/// Checks one payment; the message names the 1-based position.
pub fn validate_batch_payment(position: usize, p: &BatchPayment) -> CoreResult<()> {
    let fail = |msg: &str| CoreError::InvalidInput {
        message: crate::i18n::trf("Zahlung {0}: {1}", &[&position, &msg]),
    };
    if p.name.trim().is_empty() {
        return Err(fail(tr("Der Empfängername fehlt.")));
    }
    if !validate_iban(&p.iban) {
        return Err(fail(tr("Die Empfänger-IBAN ist ungültig.")));
    }
    if p.amount_cents <= 0 {
        return Err(fail(tr("Der Betrag muss größer als 0 sein.")));
    }
    Ok(())
}

/// Builds a batch `pain.001` document (UTF-8): one `PmtInf` with one
/// `CdtTrfTxInf` per payment, `NbOfTxs` and `CtrlSum` in header and block.
pub fn build_pain001_batch(p: &Pain001Batch) -> CoreResult<String> {
    if p.payments.is_empty() {
        return Err(CoreError::InvalidInput {
            message: tr("Die Sammelüberweisung enthält keine Zahlung.").into(),
        });
    }
    for (i, pay) in p.payments.iter().enumerate() {
        validate_batch_payment(i + 1, pay)?;
    }
    let total = batch_total_cents(p.payments).ok_or_else(|| CoreError::InvalidInput {
        message: tr("Die Summe der Sammelüberweisung ist zu groß.").into(),
    })?;
    let sum = format_amount(total);
    let count = p.payments.len();
    let msg_id = xml_escape(&clip(p.message_id, 35));
    let debtor = xml_escape(&clip(p.debtor_name, 70));
    let d_iban = normalize_iban(p.debtor_iban);
    let bic_tag = match p.version {
        PainVersion::V03 => "BIC",
        PainVersion::V09 => "BICFI",
    };
    let d_agent = if validate_bic(p.debtor_bic) {
        format!("<{bic_tag}>{}</{bic_tag}>", normalize_iban(p.debtor_bic))
    } else {
        "<Othr><Id>NOTPROVIDED</Id></Othr>".to_string()
    };
    let exec = xml_escape(p.execution_date);
    let exec = match p.version {
        PainVersion::V03 => exec,
        PainVersion::V09 => format!("<Dt>{exec}</Dt>"),
    };
    let mut txs = String::new();
    for pay in p.payments {
        let amount = format_amount(pay.amount_cents);
        let c_agent = match pay.bic.as_deref().filter(|b| validate_bic(b)) {
            Some(b) => format!(
                "<CdtrAgt><FinInstnId><{bic_tag}>{}</{bic_tag}></FinInstnId></CdtrAgt>",
                normalize_iban(b)
            ),
            None => String::new(),
        };
        let purpose = xml_escape(&clip(&pay.purpose, 140));
        let rmt = if purpose.is_empty() {
            String::new()
        } else {
            format!("<RmtInf><Ustrd>{purpose}</Ustrd></RmtInf>")
        };
        let e2e = if pay.end_to_end_id.trim().is_empty() {
            "NOTPROVIDED".to_string()
        } else {
            xml_escape(&clip(&pay.end_to_end_id, 35))
        };
        txs.push_str(&format!(
            "<CdtTrfTxInf><PmtId><EndToEndId>{e2e}</EndToEndId></PmtId>\
<Amt><InstdAmt Ccy=\"EUR\">{amount}</InstdAmt></Amt>{c_agent}\
<Cdtr><Nm>{}</Nm></Cdtr><CdtrAcct><Id><IBAN>{}</IBAN></Id></CdtrAcct>{rmt}</CdtTrfTxInf>",
            xml_escape(&clip(&pay.name, 70)),
            normalize_iban(&pay.iban),
        ));
    }
    let ns = p.version.descriptor();
    Ok(format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
<Document xmlns=\"{ns}\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">\
<CstmrCdtTrfInitn>\
<GrpHdr><MsgId>{msg_id}</MsgId><CreDtTm>{created}</CreDtTm><NbOfTxs>{count}</NbOfTxs><CtrlSum>{sum}</CtrlSum>\
<InitgPty><Nm>{debtor}</Nm></InitgPty></GrpHdr>\
<PmtInf><PmtInfId>{msg_id}</PmtInfId><PmtMtd>TRF</PmtMtd><BtchBookg>{batch}</BtchBookg><NbOfTxs>{count}</NbOfTxs><CtrlSum>{sum}</CtrlSum>\
<PmtTpInf><SvcLvl><Cd>SEPA</Cd></SvcLvl></PmtTpInf><ReqdExctnDt>{exec}</ReqdExctnDt>\
<Dbtr><Nm>{debtor}</Nm></Dbtr><DbtrAcct><Id><IBAN>{d_iban}</IBAN></Id></DbtrAcct>\
<DbtrAgt><FinInstnId>{d_agent}</FinInstnId></DbtrAgt><ChrgBr>SLEV</ChrgBr>\
{txs}</PmtInf></CstmrCdtTrfInitn></Document>",
        created = xml_escape(p.created),
        batch = p.batch_booking,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_ibans() {
        assert!(validate_iban("DE89370400440532013000"));
        assert!(validate_iban("DE89 3704 0044 0532 0130 00"));
        assert!(validate_iban("  de89370400440532013000 "));
        assert!(validate_iban("GB82 WEST 1234 5698 7654 32"));
        assert!(validate_iban("AT611904300234573201"));
    }

    #[test]
    fn invalid_ibans() {
        assert!(!validate_iban("DE89370400440532013001")); // checksum
        assert!(!validate_iban("DE8937040044053201300")); // too short for DE
        assert!(!validate_iban("XX89370400440532013000")); // unknown country
        assert!(!validate_iban("DE89-3704-0044-0532-0130-00")); // bad characters
        assert!(!validate_iban(""));
        assert!(!validate_iban("1234"));
    }

    #[test]
    fn bic_validation() {
        assert!(validate_bic("COBADEFFXXX"));
        assert!(validate_bic("genodef1ks2"));
        assert!(validate_bic("GENODEF1"));
        assert!(!validate_bic("GENODE"));
        assert!(!validate_bic("1234DEFF"));
    }

    fn sample<'a>(name: &'a str, purpose: &'a str) -> Pain001<'a> {
        Pain001 {
            message_id: "GC-1",
            created: "2026-11-09T10:00:00",
            execution_date: "2026-11-09",
            debtor_name: "Erika Mustermann",
            debtor_iban: "DE02120300000000202051",
            debtor_bic: "BYLADEM1001",
            creditor_name: name,
            creditor_iban: "DE89 3704 0044 0532 0130 00",
            creditor_bic: None,
            amount_cents: 12_345,
            purpose,
            version: PainVersion::V03,
            end_to_end_id: "",
            instant: false,
        }
    }

    #[test]
    fn pain001_scheduled_date_and_instant_variant() {
        let mut p = sample("A", "x");
        p.execution_date = "2027-01-15";
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("<ReqdExctnDt>2027-01-15</ReqdExctnDt>"));
        assert!(!xml.contains("INST"));
        p.version = PainVersion::V09;
        p.instant = true;
        p.creditor_bic = Some("COBADEFFXXX");
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("pain.001.001.09"));
        assert!(xml.contains("<LclInstrm><Cd>INST</Cd></LclInstrm>"));
        assert!(xml.contains("<ReqdExctnDt><Dt>2027-01-15</Dt></ReqdExctnDt>"));
        assert!(xml.contains("<BICFI>BYLADEM1001</BICFI>"));
        assert!(xml.contains("<CdtrAgt><FinInstnId><BICFI>COBADEFFXXX</BICFI>"));
    }

    #[test]
    fn instant_pain_09_uses_inst_bicfi_and_wrapped_date() {
        let mut p = sample("Max Muster", "Miete");
        p.version = PainVersion::V09;
        p.instant = true;
        p.creditor_bic = Some("COBADEFFXXX");
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("xmlns=\"urn:iso:std:iso:20022:tech:xsd:pain.001.001.09\""));
        assert!(xml.contains("<SvcLvl><Cd>SEPA</Cd></SvcLvl><LclInstrm><Cd>INST</Cd></LclInstrm>"));
        assert!(xml.contains("<ReqdExctnDt><Dt>2026-11-09</Dt></ReqdExctnDt>"));
        assert!(xml.contains("<BICFI>BYLADEM1001</BICFI>"));
        assert!(xml.contains("<BICFI>COBADEFFXXX</BICFI>"));
        assert!(!xml.contains("<BIC>"));
    }

    #[test]
    fn regular_pain_03_is_unchanged() {
        let xml = build_pain001(&sample("Max Muster", "Miete")).unwrap();
        assert!(xml.contains("<EndToEndId>NOTPROVIDED</EndToEndId>"));
        let mut p = sample("Max Muster", "Miete");
        p.end_to_end_id = "GC0123456789ABCDEF";
        let xml2 = build_pain001(&p).unwrap();
        assert!(xml2.contains("<EndToEndId>GC0123456789ABCDEF</EndToEndId>"));
        assert!(xml.contains("pain.001.001.03"));
        assert!(xml.contains("<ReqdExctnDt>2026-11-09</ReqdExctnDt>"));
        assert!(xml.contains("<BIC>BYLADEM1001</BIC>"));
        assert!(!xml.contains("INST"));
    }

    #[test]
    fn picks_pain_version_from_bpd() {
        let s = |v: &[&str]| v.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        assert_eq!(PainVersion::pick(&[]), Some(PainVersion::V09));
        assert_eq!(
            PainVersion::pick(&s(&[PAIN_DESCRIPTOR, PAIN_09_DESCRIPTOR])),
            Some(PainVersion::V09)
        );
        assert_eq!(
            PainVersion::pick(&s(&[PAIN_DESCRIPTOR])),
            Some(PainVersion::V03)
        );
        assert_eq!(
            PainVersion::pick(&s(&["urn:iso:std:iso:20022:tech:xsd:pain.001.003.01"])),
            None
        );
    }

    #[test]
    fn pain001_basics_and_sepa_charset() {
        let xml = build_pain001(&sample("Müller & Söhne <GmbH>", "Rechnung äöüß \"7\"")).unwrap();
        assert!(xml.contains("<Cdtr><Nm>Mueller Soehne GmbH</Nm></Cdtr>"));
        assert!(xml.contains("<Ustrd>Rechnung aeoeuess 7</Ustrd>"));
        assert!(xml.contains("<InstdAmt Ccy=\"EUR\">123.45</InstdAmt>"));
        assert!(xml.contains("<CtrlSum>123.45</CtrlSum>"));
        assert!(xml.contains("<IBAN>DE89370400440532013000</IBAN>"));
        assert!(xml.contains("<BIC>BYLADEM1001</BIC>"));
        assert!(xml.contains("pain.001.001.03"));
        assert!(!xml.contains("CdtrAgt"));
        assert!(xml.is_ascii());
    }

    #[test]
    fn sanitizes_to_dk_charset() {
        assert_eq!(sanitize_sepa_text("Müller"), "Mueller");
        assert_eq!(sanitize_sepa_text("ÄÖÜ äöü ß"), "AeOeUe aeoeue ss");
        assert_eq!(sanitize_sepa_text("René €5 & Co*"), "Rene  5   Co ");
        assert_eq!(
            sanitize_sepa_text("A/B-C?D:E(F).G,H'I+J"),
            "A/B-C?D:E(F).G,H'I+J"
        );
    }

    #[test]
    fn xml_escaping_stays_intact() {
        assert_eq!(xml_escape("a&b<c>\"d'"), "a&amp;b&lt;c&gt;&quot;d&apos;");
        let xml = build_pain001(&sample("O'Brien", "x")).unwrap();
        assert!(xml.contains("<Nm>O&apos;Brien</Nm>"));
    }

    #[test]
    fn pain001_limits_and_rejects() {
        let long = "x".repeat(300);
        let xml = build_pain001(&sample("A", &long)).unwrap();
        let ustrd = xml
            .split("<Ustrd>")
            .nth(1)
            .unwrap()
            .split("</Ustrd>")
            .next()
            .unwrap();
        assert_eq!(ustrd.chars().count(), 140);
        let mut p = sample("A", "x");
        p.amount_cents = 0;
        assert!(build_pain001(&p).is_err());
        let mut p = sample("A", "x");
        p.creditor_iban = "DE00000000000000000000";
        assert!(build_pain001(&p).is_err());
        assert_eq!(format_amount(5), "0.05");
    }

    #[test]
    fn pain001_creditor_bic_and_control_chars() {
        let mut p = sample("Max\nMuster", "a\tb");
        p.creditor_bic = Some("COBADEFFXXX");
        let xml = build_pain001(&p).unwrap();
        assert!(xml.contains("<CdtrAgt><FinInstnId><BIC>COBADEFFXXX</BIC>"));
        assert!(xml.contains("<Nm>Max Muster</Nm>"));
        assert!(xml.contains("<Ustrd>a b</Ustrd>"));
    }

    fn pay(name: &str, iban: &str, cents: i64, e2e: &str) -> BatchPayment {
        BatchPayment {
            name: name.into(),
            iban: iban.into(),
            bic: None,
            amount_cents: cents,
            purpose: "Beitrag".into(),
            end_to_end_id: e2e.into(),
        }
    }

    fn batch<'a>(payments: &'a [BatchPayment], booking: bool) -> Pain001Batch<'a> {
        Pain001Batch {
            message_id: "GC-B1",
            created: "2026-11-09T10:00:00",
            execution_date: "2026-11-09",
            debtor_name: "Verein e.V.",
            debtor_iban: "DE02120300000000202051",
            debtor_bic: "BYLADEM1001",
            payments,
            version: PainVersion::V03,
            batch_booking: booking,
        }
    }

    #[test]
    fn batch_has_count_sum_and_one_block_per_payment() {
        let pays = [
            pay("Anna Müller", "DE89370400440532013000", 6_000, "E1"),
            pay("Ben & Co", "DE02120300000000202051", 3_050, "E2"),
            pay("Cem", "DE75512108001245126199", 1, "E3"),
        ];
        let xml = build_pain001_batch(&batch(&pays, true)).unwrap();
        assert_eq!(xml.matches("<CdtTrfTxInf>").count(), 3);
        assert_eq!(xml.matches("<NbOfTxs>3</NbOfTxs>").count(), 2); // header + block
        assert_eq!(xml.matches("<CtrlSum>90.51</CtrlSum>").count(), 2);
        assert_eq!(xml.matches("<PmtInf>").count(), 1);
        assert!(xml.contains("<BtchBookg>true</BtchBookg>"));
        assert!(xml.contains("<Nm>Anna Mueller</Nm>")); // SEPA character set
        assert!(xml.contains("<Nm>Ben  Co</Nm>") || xml.contains("<Nm>Ben Co</Nm>"));
        assert!(xml.contains("<EndToEndId>E2</EndToEndId>"));
        assert!(!xml.contains("INST"));
    }

    #[test]
    fn batch_booking_flag_follows_the_choice() {
        let pays = [pay("A", "DE89370400440532013000", 100, "")];
        let single = build_pain001_batch(&batch(&pays, false)).unwrap();
        assert!(single.contains("<BtchBookg>false</BtchBookg>"));
        assert!(single.contains("<EndToEndId>NOTPROVIDED</EndToEndId>"));
    }

    #[test]
    fn batch_09_wraps_date_and_uses_bicfi() {
        let mut pays = [pay("A", "DE89370400440532013000", 100, "E1")];
        pays[0].bic = Some("COBADEFFXXX".into());
        let mut b = batch(&pays, true);
        b.version = PainVersion::V09;
        let xml = build_pain001_batch(&b).unwrap();
        assert!(xml.contains("<ReqdExctnDt><Dt>2026-11-09</Dt></ReqdExctnDt>"));
        assert!(xml.contains("<CdtrAgt><FinInstnId><BICFI>COBADEFFXXX</BICFI>"));
    }

    #[test]
    fn batch_rejects_empty_and_names_the_bad_position() {
        assert!(build_pain001_batch(&batch(&[], true)).is_err());
        let pays = [
            pay("A", "DE89370400440532013000", 100, "E1"),
            pay("B", "DE89370400440532013001", 100, "E2"), // checksum
        ];
        let err = build_pain001_batch(&batch(&pays, true))
            .unwrap_err()
            .to_string();
        assert!(err.contains('2'), "{err}");
        let pays = [pay("A", "DE89370400440532013000", 0, "E1")];
        assert!(build_pain001_batch(&batch(&pays, true)).is_err());
        let pays = [pay("  ", "DE89370400440532013000", 5, "E1")];
        assert!(build_pain001_batch(&batch(&pays, true)).is_err());
    }

    #[test]
    fn batch_total_overflow_is_an_error() {
        let pays = [
            pay("A", "DE89370400440532013000", i64::MAX, "E1"),
            pay("B", "DE89370400440532013000", 1, "E2"),
        ];
        assert_eq!(batch_total_cents(&pays), None);
        assert!(build_pain001_batch(&batch(&pays, true)).is_err());
    }
}
