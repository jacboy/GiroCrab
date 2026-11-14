//! CSV import for batch transfers (Sammelüberweisung, #240): name, IBAN,
//! amount, purpose per line. The import never fails as a whole: every line
//! becomes a row, faulty ones carry their errors so the sheet can show and fix
//! them. Nothing is sent from here.

use crate::connectors::fints::sepa::{normalize_iban, validate_iban};
use crate::i18n::{tr, trf};
use crate::money::parse_cents;

const MAX_NAME: usize = 70;
const MAX_PURPOSE: usize = 140;

/// One line of the file.
#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BatchCsvRow {
    /// 1-based line in the file where the row starts.
    pub line: u32,
    pub name: String,
    /// Normalised IBAN without spaces (as typed when invalid).
    pub iban: String,
    pub bic: String,
    /// The amount as written in the file.
    pub amount_text: String,
    /// 0 when the amount is missing or invalid.
    pub amount_cents: i64,
    pub purpose: String,
    /// Empty = the row is fine.
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BatchCsvImport {
    pub rows: Vec<BatchCsvRow>,
    /// Problems with the file as a whole (missing column, no rows).
    pub problems: Vec<String>,
    /// `;`, `,` or a tab.
    pub delimiter: String,
    pub had_header: bool,
}

#[derive(Clone, Copy, Default)]
struct Columns {
    name: Option<usize>,
    iban: Option<usize>,
    bic: Option<usize>,
    amount: Option<usize>,
    purpose: Option<usize>,
}

/// Parses `text` (UTF-8, optional BOM). Columns come from a header line when
/// there is one, else the order is name, IBAN, amount, purpose.
#[uniffi::export]
pub fn parse_batch_csv(text: String) -> BatchCsvImport {
    let text = text.trim_start_matches('\u{feff}');
    let delim = detect_delimiter(text);
    let records = split_records(text, delim);
    let mut problems = Vec::new();
    let mut iter = records.into_iter().filter(|(_, f)| !is_blank(f)).peekable();

    let mut cols = Columns {
        name: Some(0),
        iban: Some(1),
        bic: None,
        amount: Some(2),
        purpose: Some(3),
    };
    let mut had_header = false;
    if let Some((_, first)) = iter.peek() {
        if let Some(c) = header_columns(first) {
            had_header = true;
            for (missing, label) in [
                (c.name.is_none(), "Name"),
                (c.iban.is_none(), "IBAN"),
                (c.amount.is_none(), "Betrag"),
            ] {
                if missing {
                    problems.push(trf("In der Kopfzeile fehlt die Spalte „{0}“.", &[&label]));
                }
            }
            cols = c;
            iter.next();
        }
    }
    let rows: Vec<BatchCsvRow> = if problems.is_empty() {
        iter.map(|(line, f)| to_row(line, &f, cols)).collect()
    } else {
        Vec::new()
    };
    if rows.is_empty() && problems.is_empty() {
        problems.push(tr("Die Datei enthält keine Zahlungen.").to_string());
    }
    BatchCsvImport {
        rows,
        problems,
        delimiter: delim.to_string(),
        had_header,
    }
}

fn is_blank(fields: &[String]) -> bool {
    fields.iter().all(|f| f.trim().is_empty())
}

/// The delimiter with the most occurrences in the first non-empty line
/// (outside quotes); `;` when nothing decides.
fn detect_delimiter(text: &str) -> char {
    let mut counts = [(';', 0usize), (',', 0), ('\t', 0)];
    let mut quoted = false;
    for c in text.chars() {
        if c == '"' {
            quoted = !quoted;
        } else if !quoted && (c == '\n' || c == '\r') {
            if counts.iter().any(|(_, n)| *n > 0) {
                break;
            }
        } else if !quoted {
            if let Some(slot) = counts.iter_mut().find(|(d, _)| *d == c) {
                slot.1 += 1;
            }
        }
    }
    counts
        .iter()
        .max_by_key(|(d, n)| (*n, *d == ';'))
        .filter(|(_, n)| *n > 0)
        .map(|(d, _)| *d)
        .unwrap_or(';')
}

/// Splits into records of fields: quotes group, `""` is a quote, a quoted
/// field may contain delimiters and line breaks. Keeps the start line.
fn split_records(text: &str, delim: char) -> Vec<(u32, Vec<String>)> {
    let mut out = Vec::new();
    let mut fields: Vec<String> = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut line = 1u32;
    let mut start = 1u32;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            c if c == delim && !quoted => fields.push(std::mem::take(&mut field)),
            '\r' if !quoted => {}
            '\n' if !quoted => {
                fields.push(std::mem::take(&mut field));
                out.push((start, std::mem::take(&mut fields)));
                line += 1;
                start = line;
            }
            c => {
                if c == '\n' {
                    line += 1;
                }
                field.push(c);
            }
        }
    }
    if !field.is_empty() || !fields.is_empty() {
        fields.push(field);
        out.push((start, fields));
    }
    out
}

/// A header line names at least one known column.
fn header_columns(first: &[String]) -> Option<Columns> {
    let mut cols = Columns::default();
    let mut known = false;
    for (i, cell) in first.iter().enumerate() {
        let key = cell.trim().to_lowercase();
        let slot = match key.as_str() {
            "name" | "empfänger" | "empfaenger" | "zahlungsempfänger" | "begünstigter"
            | "beguenstigter" | "recipient" | "payee" => &mut cols.name,
            "iban" => &mut cols.iban,
            "bic" => &mut cols.bic,
            "betrag" | "amount" | "summe" => &mut cols.amount,
            "zweck" | "verwendungszweck" | "purpose" | "reference" | "verwendung" => {
                &mut cols.purpose
            }
            _ => continue,
        };
        if slot.is_none() {
            *slot = Some(i);
            known = true;
        }
    }
    known.then_some(cols)
}

fn to_row(line: u32, f: &[String], cols: Columns) -> BatchCsvRow {
    let get = |i: Option<usize>| {
        i.and_then(|i| f.get(i))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    };
    let name = get(cols.name);
    let iban_raw = get(cols.iban);
    let amount_text = get(cols.amount);
    let purpose = get(cols.purpose);
    let mut errors = Vec::new();
    if f.len() < 3 && cols.iban == Some(1) {
        errors.push(tr("Zu wenige Spalten (erwartet: Name, IBAN, Betrag, Zweck).").to_string());
    }
    if name.is_empty() {
        errors.push(tr("Der Empfängername fehlt.").to_string());
    } else if name.chars().count() > MAX_NAME {
        errors.push(tr("Der Name ist länger als 70 Zeichen.").to_string());
    }
    let valid_iban = validate_iban(&iban_raw);
    if !valid_iban {
        errors.push(tr("Die Empfänger-IBAN ist ungültig.").to_string());
    }
    let amount_cents = match parse_cents(&amount_text) {
        Ok(c) if c > 0 => c,
        _ => {
            errors.push(tr("Der Betrag ist ungültig oder fehlt.").to_string());
            0
        }
    };
    if purpose.chars().count() > MAX_PURPOSE {
        errors.push(tr("Der Verwendungszweck ist länger als 140 Zeichen.").to_string());
    }
    BatchCsvRow {
        line,
        name,
        iban: if valid_iban {
            normalize_iban(&iban_raw)
        } else {
            iban_raw
        },
        bic: get(cols.bic),
        amount_text,
        amount_cents,
        purpose,
        errors,
    }
}

#[cfg(test)]
mod tests;
