//! Demo mode: five fictional German accounts and exactly 50 invented bookings
//! (`--demo-seed` / `GIROCRAB_DEMO_SEED=1`). Deterministic and relative to
//! today so screenshots are reproducible. Nothing in here is real data.

use chrono::{Datelike, Duration, Local, NaiveDate};
use rusqlite::{params, Connection};

use crate::connectors::{descriptor, group_for};
use crate::error::CoreResult;
use crate::models::{AccountKind, ConnectorKind};
use crate::vault::Vault;

/// Minimal single-page PDF with one line of text (valid enough for PDFKit).
fn demo_pdf(line: &str) -> Vec<u8> {
    let stream = format!("BT /F1 18 Tf 72 720 Td ({line}) Tj ET");
    let objs = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>".to_string(),
        format!("<< /Length {} >>\nstream\n{stream}\nendstream", stream.len()),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
    ];
    let mut out = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend(format!("{} 0 obj\n{o}\nendobj\n", i + 1).into_bytes());
    }
    let xref = out.len();
    out.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).into_bytes());
    for off in offsets {
        out.extend(format!("{off:010} 00000 n \n").into_bytes());
    }
    out.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n",
            objs.len() + 1
        )
        .into_bytes(),
    );
    out
}

/// Three unlinked PostBox documents so the documents view has rows in demo mode.
fn demo_documents(conn: &Connection, today: NaiveDate, account_id: i64) -> CoreResult<()> {
    let _ = today;
    let docs = [
        (
            "BioMarkt Sonnenberg – Kassenbeleg",
            "beleg",
            "biomarkt_kassenbeleg.pdf",
            "BioMarkt Sonnenberg - Kassenbeleg - 47,85 EUR",
            "2026-11-04",
        ),
        (
            "Stadtwerke Energie – Stromabschlag",
            "abrechnung",
            "stadtwerke_stromabschlag.pdf",
            "Stadtwerke Energie - Stromabschlag - 78,00 EUR",
            "2026-11-01",
        ),
        (
            "ConnectMobile – Monatsrechnung",
            "abrechnung",
            "connectmobile_monatsrechnung.pdf",
            "ConnectMobile - Monatsrechnung - 19,99 EUR",
            "2026-10-28",
        ),
    ];
    for (i, (title, ty, file, text, date)) in docs.into_iter().enumerate() {
        crate::documents::insert_doc(
            conn,
            None,
            Some(account_id),
            title,
            ty,
            "application/pdf",
            file,
            &demo_pdf(text),
            &format!("demo-doc-{i}"),
            date,
        )?;
    }
    Ok(())
}

/// Login name that switches a bank connection to the simulated demo bank
/// (Apple App Review, guideline 2.1(a)): case-insensitive `demo`, PIN `12345`,
/// any 4- or 6-digit TAN. No network access and no FinTS product ID needed.
pub const MAGIC_DEMO_LOGIN: &str = "demo";
pub const MAGIC_DEMO_PIN: &str = "12345";

pub fn is_magic_demo_login(login: &str) -> bool {
    login.trim().eq_ignore_ascii_case(MAGIC_DEMO_LOGIN)
}

pub struct DemoAccountSpec {
    pub connector: ConnectorKind,
    pub external_ref: &'static str,
    pub name: &'static str,
    pub kind: AccountKind,
    pub iban: &'static str,
    /// Account number (loans: referenced in the Giro's instalment bookings).
    pub account_number: &'static str,
    /// Today's balance in cents.
    pub opening_cents: i64,
    /// Overrides the institute name in the sidebar.
    pub bank_name: &'static str,
    /// Loan: original amount (drives the repayment progress bar).
    pub principal_cents: Option<i64>,
}

pub const DEMO_ACCOUNTS: &[DemoAccountSpec] = &[
    DemoAccountSpec {
        connector: ConnectorKind::VolksbankKasselGoettingen,
        external_ref: "demo-giro",
        name: "Musterbank Girokonto",
        kind: AccountKind::Checking,
        iban: "DE89370400440532013000",
        account_number: "0532013000",
        opening_cents: 4_280_50,
        bank_name: "Musterbank",
        principal_cents: None,
    },
    DemoAccountSpec {
        connector: ConnectorKind::VolksbankKasselGoettingen,
        external_ref: "demo-tagesgeld",
        name: "Tagesgeld Plus",
        kind: AccountKind::Savings,
        iban: "DE75512108001245126199",
        account_number: "1245126199",
        opening_cents: 15_000_00,
        bank_name: "Musterbank",
        principal_cents: None,
    },
    DemoAccountSpec {
        connector: ConnectorKind::TradeRepublic,
        external_ref: "demo-depot",
        name: "Welt-Depot ETF",
        kind: AccountKind::Brokerage,
        iban: "",
        account_number: "",
        opening_cents: 28_450_00,
        bank_name: "Musterbank",
        principal_cents: None,
    },
    DemoAccountSpec {
        connector: ConnectorKind::AmericanExpress,
        external_ref: "demo-visa",
        name: "Visa Gold Kreditkarte",
        kind: AccountKind::CreditCard,
        iban: "",
        account_number: "",
        opening_cents: -642_80,
        bank_name: "Musterbank",
        principal_cents: None,
    },
    DemoAccountSpec {
        connector: ConnectorKind::VolksbankKasselGoettingen,
        external_ref: "demo-darlehen",
        name: "Immobilien-Darlehen",
        kind: AccountKind::Loan,
        iban: "",
        account_number: "4009988",
        opening_cents: -182_500_00,
        bank_name: "Musterbank",
        principal_cents: Some(250_000_00),
    },
];

type Tree<'a> = &'a [(
    &'static str,
    &'static str,
    &'static str,
    &'a [(&'static str, &'static str)],
)];

fn categories(conn: &Connection) -> CoreResult<std::collections::HashMap<&'static str, i64>> {
    let tree: Tree = &[
        (
            "Einnahmen",
            "arrow.down.circle.fill",
            "#2E9D6A",
            &[
                ("Gehalt", "briefcase.fill"),
                ("Zinsen & Dividenden", "percent"),
                ("Erstattungen", "arrow.uturn.backward.circle"),
                ("Sonstige Einnahmen", "plus.circle"),
            ],
        ),
        (
            "Wohnen & Energie",
            "house.fill",
            "#B7782F",
            &[
                ("Miete", "building.2.fill"),
                ("Energie", "bolt.fill"),
                ("Internet & Telefon", "wifi"),
                ("Haushalt", "sofa.fill"),
            ],
        ),
        (
            "Lebensmittel",
            "cart.fill",
            "#B5474F",
            &[
                ("Supermarkt", "cart"),
                ("Bäcker & Metzger", "fork.knife.circle"),
                ("Lebensmittelrettung", "leaf.fill"),
                ("Restaurants & Cafés", "fork.knife"),
                ("Lieferdienste", "takeoutbag.and.cup.and.straw.fill"),
            ],
        ),
        (
            "Mobilität",
            "car.fill",
            "#3A6FB0",
            &[
                ("ÖPNV & Bahn", "tram.fill"),
                ("Tanken", "fuelpump.fill"),
                ("Fahrrad", "bicycle"),
                ("Reisen", "airplane"),
            ],
        ),
        (
            "Einkaufen",
            "bag.fill",
            "#7D5BA6",
            &[
                ("Online-Shopping", "shippingbox.fill"),
                ("Elektronik", "desktopcomputer"),
                ("Drogerie", "cross.vial.fill"),
            ],
        ),
        (
            "Freizeit",
            "sparkles",
            "#2F8F9D",
            &[
                ("Streaming & Musik", "play.tv.fill"),
                ("Sport & Fitness", "figure.run"),
                ("Spiele", "gamecontroller.fill"),
            ],
        ),
        (
            "Versicherungen",
            "shield.lefthalf.filled",
            "#4B5D73",
            &[
                ("Krankenversicherung", "cross.case.fill"),
                ("Haftpflicht & Hausrat", "shield.fill"),
                ("Mitgliedschaften", "person.badge.shield.checkmark.fill"),
            ],
        ),
        (
            "Gebühren & Bargeld",
            "eurosign.circle.fill",
            "#7A808A",
            &[
                ("Bankgebühren", "building.columns"),
                ("Bargeld", "banknote"),
            ],
        ),
        (
            "Kredite & Darlehen",
            "house.circle.fill",
            "#6B7280",
            &[("Darlehensraten", "house")],
        ),
        (
            "Sparen & Investieren",
            "chart.line.uptrend.xyaxis.circle.fill",
            "#1F7A5C",
            &[
                ("ETF-Sparpläne", "chart.line.uptrend.xyaxis"),
                ("Krypto", "bitcoinsign.circle"),
                ("Aktien", "chart.bar.fill"),
                ("Saveback & Round up", "gift.fill"),
            ],
        ),
        (
            "Umbuchungen",
            "arrow.left.arrow.right.circle.fill",
            "#9AA0A6",
            &[
                ("Kreditkartenabrechnung", "creditcard.fill"),
                ("Tagesgeld", "banknote.fill"),
                ("Eigene Konten", "arrow.left.arrow.right"),
            ],
        ),
    ];
    let mut map = std::collections::HashMap::new();
    for (i, (name, sym, color, kids)) in tree.iter().enumerate() {
        conn.execute(
            "INSERT INTO categories(parent_id, name, sf_symbol, color_hex, sort_order) VALUES (NULL, ?1, ?2, ?3, ?4)",
            params![name, sym, color, i as i32],
        )?;
        let pid = conn.last_insert_rowid();
        map.insert(*name, pid);
        for (j, (kid, ksym)) in kids.iter().enumerate() {
            conn.execute(
                "INSERT INTO categories(parent_id, name, sf_symbol, color_hex, sort_order) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![pid, kid, ksym, color, j as i32],
            )?;
            map.insert(*kid, conn.last_insert_rowid());
        }
    }
    conn.execute(
        "UPDATE categories SET budget_cents = 60000 WHERE name = 'Supermarkt'",
        [],
    )?;
    conn.execute(
        "UPDATE categories SET budget_cents = 15000 WHERE name = 'Restaurants & Cafés'",
        [],
    )?;
    Ok(map)
}

fn rules(conn: &Connection, cat: &std::collections::HashMap<&'static str, i64>) -> CoreResult<()> {
    // (name, category, field, kind, pattern, min, max)
    let rules: &[(&str, &str, &str, &str, &str, Option<i64>, Option<i64>)] = &[
        (
            "Saveback & Round up",
            "Saveback & Round up",
            "any",
            "keyword",
            "Saveback|Round up",
            None,
            None,
        ),
        (
            "Gehalt",
            "Gehalt",
            "any",
            "keyword",
            "Gehalt|Lohn",
            Some(1),
            None,
        ),
        (
            "Zinsen & Dividenden",
            "Zinsen & Dividenden",
            "any",
            "regex",
            r"\b(Zinsen|Dividende|Ertrag)\b",
            Some(1),
            None,
        ),
        (
            "Erstattungen",
            "Erstattungen",
            "any",
            "keyword",
            "Erstattung|Rückerstattung|Gutschrift Retoure",
            Some(1),
            None,
        ),
        (
            "Tagesgeld",
            "Tagesgeld",
            "purpose",
            "keyword",
            "Tagesgeld",
            None,
            None,
        ),
        (
            "Kreditkarte",
            "Kreditkartenabrechnung",
            "any",
            "keyword",
            "Kreditkartenabrechnung|Zahlung erhalten",
            None,
            None,
        ),
        (
            "Eigene Konten",
            "Eigene Konten",
            "any",
            "keyword",
            "Einzahlung|Aufladung|Eigenes Konto|Bankeinzug",
            None,
            None,
        ),
        (
            "ETF-Sparpläne",
            "ETF-Sparpläne",
            "counterparty",
            "regex",
            r"(?i)(MSCI|STOXX|FTSE|AI & Big Data|S&P 500)",
            None,
            Some(0),
        ),
        (
            "Krypto",
            "Krypto",
            "counterparty",
            "keyword",
            "Bitcoin|Ethereum",
            None,
            Some(0),
        ),
        (
            "Aktien-Sparplan",
            "Aktien",
            "counterparty",
            "keyword",
            "Bayer",
            None,
            Some(0),
        ),
        (
            "Darlehen",
            "Darlehensraten",
            "any",
            "keyword",
            "Darlehensrate|Tilgung",
            None,
            None,
        ),
        (
            "Supermärkte",
            "Supermarkt",
            "counterparty",
            "keyword",
            "REWE|EDEKA|ALDI|LIDL|Alnatura|Kaufland|Penny|Netto",
            None,
            Some(0),
        ),
        (
            "Bäcker & Metzger",
            "Bäcker & Metzger",
            "counterparty",
            "keyword",
            "Vinzenz Murr|Metzgerei|Bäckerei",
            None,
            Some(0),
        ),
        (
            "Lebensmittelrettung",
            "Lebensmittelrettung",
            "counterparty",
            "keyword",
            "Too Good To Go",
            None,
            Some(0),
        ),
        (
            "Restaurants",
            "Restaurants & Cafés",
            "any",
            "keyword",
            "Restaurant|Café|Pizzeria|Trattoria",
            None,
            Some(0),
        ),
        (
            "Lieferdienste",
            "Lieferdienste",
            "any",
            "keyword",
            "Lieferando|Wolt",
            None,
            Some(0),
        ),
        (
            "Energie",
            "Energie",
            "counterparty",
            "keyword",
            "EnBW Energie|Stadtwerke",
            None,
            Some(0),
        ),
        (
            "Telefon & Internet",
            "Internet & Telefon",
            "counterparty",
            "keyword",
            "Telekom|Vodafone|congstar",
            None,
            Some(0),
        ),
        (
            "Bahn & ÖPNV",
            "ÖPNV & Bahn",
            "any",
            "regex",
            r"(?i)^DB\s+(Fernverkehr|Vertrieb)|NVV|Deutschlandticket",
            None,
            Some(0),
        ),
        (
            "Tanken & Laden",
            "Tanken",
            "counterparty",
            "keyword",
            "Aral|Shell|Esso|EnBW|IONITY|Tesla",
            None,
            Some(0),
        ),
        (
            "Baumarkt & Möbel",
            "Haushalt",
            "counterparty",
            "keyword",
            "HORNBACH|OBI|BAUHAUS|IKEA|toom",
            None,
            Some(0),
        ),
        (
            "Fahrrad",
            "Fahrrad",
            "counterparty",
            "keyword",
            "Fixbike",
            None,
            Some(0),
        ),
        (
            "Reisen",
            "Reisen",
            "any",
            "keyword",
            "Hotel|Lufthansa|Booking.com|Airbnb|Sixt",
            None,
            Some(0),
        ),
        (
            "Online-Shops",
            "Online-Shopping",
            "any",
            "keyword",
            "Amazon|AMZN|Zalando|eBay",
            None,
            Some(0),
        ),
        (
            "Elektronik",
            "Elektronik",
            "counterparty",
            "keyword",
            "MediaMarkt|Cyberport|Apple Distribution",
            None,
            Some(0),
        ),
        (
            "Drogerie",
            "Drogerie",
            "counterparty",
            "keyword",
            "dm-drogerie|Rossmann|Apotheke",
            None,
            Some(0),
        ),
        (
            "Streaming",
            "Streaming & Musik",
            "any",
            "keyword",
            "Spotify|Netflix|APPLE.COM|Disney",
            None,
            Some(0),
        ),
        (
            "Fitness",
            "Sport & Fitness",
            "counterparty",
            "keyword",
            "FitX|Kletterhalle",
            None,
            Some(0),
        ),
        (
            "Spiele",
            "Spiele",
            "any",
            "keyword",
            "Steam|Nintendo",
            None,
            Some(0),
        ),
        (
            "Krankenversicherung",
            "Krankenversicherung",
            "purpose",
            "keyword",
            "Krankenversicherung",
            None,
            Some(0),
        ),
        (
            "Haftpflicht",
            "Haftpflicht & Hausrat",
            "purpose",
            "regex",
            r"(Haftpflicht|Hausrat)",
            None,
            Some(0),
        ),
        (
            "Miete",
            "Miete",
            "counterparty",
            "keyword",
            "Hausverwaltung",
            None,
            Some(0),
        ),
        (
            "Rundfunkbeitrag",
            "Haushalt",
            "counterparty",
            "keyword",
            "Beitragsservice",
            None,
            Some(0),
        ),
        (
            "Mitgliedschaften",
            "Mitgliedschaften",
            "counterparty",
            "keyword",
            "ADAC",
            None,
            Some(0),
        ),
        (
            "Kontoführung",
            "Bankgebühren",
            "any",
            "keyword",
            "Kontoführung|Entgelt",
            None,
            Some(0),
        ),
        (
            "Geldautomat",
            "Bargeld",
            "booking_text",
            "keyword",
            "Bargeldauszahlung|Geldautomat",
            None,
            None,
        ),
    ];
    for (i, (name, c, field, kind, pattern, min, max)) in rules.iter().enumerate() {
        conn.execute(
            "INSERT INTO rules(name, category_id, field, match_kind, pattern, min_amount_cents, max_amount_cents, priority, enabled)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)",
            params![name, cat[c], field, kind, pattern, min, max, (i as i32 + 1) * 10],
        )?;
    }
    Ok(())
}

/// (account index, days ago, cents, counterparty, purpose, booking text) – exactly 52 invented bookings
/// (the last two are the car-loan rates of the manual demo loan).
const BOOKINGS: &[(usize, i64, i64, &str, &str, &str)] = &[
    (
        0,
        52,
        365000,
        "TechNova GmbH",
        "Gehalt September",
        "LOHN/GEHALT",
    ),
    (
        0,
        22,
        365000,
        "TechNova GmbH",
        "Gehalt Oktober",
        "LOHN/GEHALT",
    ),
    (
        0,
        38,
        41230,
        "Finanzamt Musterstadt",
        "Einkommensteuer Erstattung",
        "GUTSCHRIFT",
    ),
    (
        0,
        55,
        -115000,
        "Hausverwaltung Nord GmbH",
        "Miete und Nebenkosten Oktober",
        "DAUERAUFTRAG",
    ),
    (
        0,
        25,
        -115000,
        "Hausverwaltung Nord GmbH",
        "Miete und Nebenkosten November",
        "DAUERAUFTRAG",
    ),
    (
        0,
        50,
        -9500,
        "EnBW Energie Baden-Württemberg AG",
        "Abschlag Strom",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        20,
        -9500,
        "EnBW Energie Baden-Württemberg AG",
        "Abschlag Strom",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        30,
        -4495,
        "Telekom Deutschland GmbH",
        "Festnetz und Internet",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        45,
        -1836,
        "ARD ZDF Deutschlandradio Beitragsservice",
        "Rundfunkbeitrag Quartal",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        56,
        -95000,
        "Darlehensrate Zins & Tilgung Kto 4009988",
        "Darlehensrate Zins & Tilgung Kto 4009988",
        "LASTSCHRIFT",
    ),
    (
        0,
        26,
        -95000,
        "Darlehensrate Zins & Tilgung Kto 4009988",
        "Darlehensrate Zins & Tilgung Kto 4009988",
        "LASTSCHRIFT",
    ),
    (
        0,
        53,
        -50000,
        "iShares Core MSCI World ETF",
        "Sparplan",
        "SPARPLAN",
    ),
    (
        0,
        23,
        -50000,
        "iShares Core MSCI World ETF",
        "Sparplan",
        "SPARPLAN",
    ),
    (
        0,
        24,
        -25000,
        "Vanguard FTSE All-World ETF",
        "Sparplan",
        "SPARPLAN",
    ),
    (
        0,
        54,
        -30000,
        "Tagesgeld Übertrag",
        "Tagesgeld Übertrag",
        "UMBUCHUNG",
    ),
    (
        0,
        2,
        -4782,
        "REWE Markt GmbH",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        17,
        -6315,
        "REWE Markt GmbH",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        41,
        -3840,
        "REWE Markt GmbH",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        6,
        -2977,
        "Lidl Dienstleistung GmbH",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        33,
        -5108,
        "Lidl Dienstleistung GmbH",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        11,
        -7264,
        "EDEKA Center",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        9,
        -2345,
        "dm-drogerie markt",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        36,
        -3190,
        "dm-drogerie markt",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        15,
        -1429,
        "Rossmann",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        4,
        -680,
        "Bäckerei Konditorei König",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        28,
        -3456,
        "Alnatura Bio-Supermarkt",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        13,
        -1875,
        "Apotheke am Markt",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        51,
        -4900,
        "DB Vertrieb GmbH",
        "Deutschlandticket November",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        21,
        -4900,
        "DB Vertrieb GmbH",
        "Deutschlandticket Dezember",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        40,
        -7490,
        "DB Vertrieb GmbH",
        "ICE Ticket Kassel-Hamburg",
        "KARTENZAHLUNG",
    ),
    (
        0,
        8,
        -6843,
        "Shell Station",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        34,
        -7210,
        "Aral AG",
        "Kartenzahlung girocard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        19,
        -2136,
        "EnBW mobility+ Ladestrom",
        "Ladevorgang",
        "LASTSCHRIFT",
    ),
    (
        3,
        43,
        -18900,
        "Sixt GmbH & Co. Autovermietung",
        "Mietwagen Wochenende",
        "KARTENZAHLUNG",
    ),
    (
        3,
        3,
        -3999,
        "Amazon.de",
        "Bestellung 302-1234567-8901234",
        "KARTENZAHLUNG",
    ),
    (
        3,
        18,
        -2490,
        "Amazon.de",
        "Bestellung 302-2345678-9012345",
        "KARTENZAHLUNG",
    ),
    (
        3,
        37,
        -6149,
        "Amazon.de",
        "Bestellung 302-3456789-0123456",
        "KARTENZAHLUNG",
    ),
    (
        3,
        10,
        -299,
        "Apple Distribution International",
        "iCloud+ Speicher",
        "KARTENZAHLUNG",
    ),
    (
        3,
        42,
        -1299,
        "Apple Distribution International",
        "Apple Music",
        "KARTENZAHLUNG",
    ),
    (
        3,
        29,
        -12900,
        "IKEA Deutschland GmbH",
        "Kartenzahlung Regal",
        "KARTENZAHLUNG",
    ),
    (
        3,
        14,
        -1099,
        "Spotify AB",
        "Spotify Premium",
        "KARTENZAHLUNG",
    ),
    (
        3,
        16,
        -1399,
        "Netflix International B.V.",
        "Netflix Standard",
        "KARTENZAHLUNG",
    ),
    (
        0,
        48,
        -2780,
        "Allianz Versicherungs-AG",
        "Hausrat Beitrag",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        31,
        6500,
        "Techniker Krankenkasse",
        "Bonusprogramm Erstattung",
        "GUTSCHRIFT",
    ),
    (
        0,
        46,
        -5400,
        "ADAC e.V.",
        "Mitgliedsbeitrag",
        "FOLGELASTSCHRIFT",
    ),
    (
        0,
        5,
        -3500,
        "Max Mustermann",
        "Danke für das Auslegen",
        "ÜBERWEISUNG",
    ),
    (0, 12, 2000, "Laura Schneider", "Kinokarten", "GUTSCHRIFT"),
    (
        0,
        27,
        -6000,
        "Lukas Weber",
        "Geburtstagsgeschenk Anteil",
        "ÜBERWEISUNG",
    ),
    (
        0,
        35,
        4250,
        "Hannah Berger",
        "Restaurant Anteil",
        "GUTSCHRIFT",
    ),
    (0, 1, -1500, "Tim Hoffmann", "Konzertticket", "ÜBERWEISUNG"),
    (
        0,
        54,
        -28900,
        "Autobank AG",
        "Rate Kreditvertrag 7731045 Autokredit",
        "LASTSCHRIFT",
    ),
    (
        0,
        24,
        -28900,
        "Autobank AG",
        "Rate Kreditvertrag 7731045 Autokredit",
        "LASTSCHRIFT",
    ),
];

struct Tx {
    account: &'static str,
    date: NaiveDate,
    cents: i64,
    counterparty: String,
    purpose: String,
    booking_text: String,
}

fn generate(today: NaiveDate) -> Vec<Tx> {
    BOOKINGS
        .iter()
        .map(|(acc, ago, cents, cp, purpose, bt)| Tx {
            account: DEMO_ACCOUNTS[*acc].external_ref,
            date: today - Duration::days(*ago),
            cents: *cents,
            counterparty: cp.to_string(),
            purpose: purpose.to_string(),
            booking_text: bt.to_string(),
        })
        .collect()
}

#[uniffi::export]
impl Vault {
    /// For a brand-new personal vault: the German category tree and the
    /// starter rules (no accounts, no bookings). Returns the number of
    /// categories created; no-op if categories exist or ever existed (deleted
    /// starter categories must not come back and spread to other devices).
    pub fn seed_starter_categories(&self) -> Result<u32, crate::error::CoreError> {
        let db = self.db()?;
        // includes soft-deleted rows
        let n: i64 = db.query_row("SELECT count(*) FROM categories", [], |r| r.get(0))?;
        if n > 0 {
            return Ok(0);
        }
        let tx = db.unchecked_transaction()?;
        let cats = categories(&tx)?;
        rules(&tx, &cats)?;
        crate::sync_merge::fill_missing_uuids(&tx)?;
        tx.commit()?;
        Ok(cats.len() as u32)
    }

    /// Number of accounts (0 = nothing synced yet).
    pub fn account_count(&self) -> Result<u32, crate::error::CoreError> {
        let db = self.db()?;
        Ok(db.query_row(
            "SELECT count(*) FROM accounts WHERE deleted_ms IS NULL",
            [],
            |r| r.get::<_, i64>(0),
        )? as u32)
    }

    /// Whether the vault ever held an account. Counts every row, so a vault
    /// whose accounts are all deleted still syncs once deletions keep rows.
    pub fn has_account_history(&self) -> Result<bool, crate::error::CoreError> {
        let db = self.db()?;
        Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM accounts)", [], |r| r.get(0))?)
    }

    /// Fills an empty vault with fictitious demo data for all 7 banks
    /// (accounts incl. loans, ~6 months of bookings, categories, rules).
    /// Returns the number of bookings created. No-op if data exists.
    pub fn seed_demo_data(&self) -> Result<u32, crate::error::CoreError> {
        if !self.is_empty()? {
            return Ok(0);
        }
        let db = self.db()?;
        let tx = db.unchecked_transaction()?;
        let cats = categories(&tx)?;
        rules(&tx, &cats)?;
        crate::sync_merge::fill_missing_uuids(&tx)?;
        let mut conn_ids = std::collections::HashMap::new();
        let logins = [
            (ConnectorKind::VolksbankKasselGoettingen, "demo-musterbank"),
            (ConnectorKind::TradeRepublic, "demo-depot"),
            (ConnectorKind::AmericanExpress, "demo-visa"),
        ];
        for (kind, login) in logins {
            let d = descriptor(kind);
            tx.execute(
                "INSERT INTO bank_connections(connector, display_name, login_name, bank_code, sf_symbol, last_sync_unix)
                 VALUES (?1, ?2, ?3, ?4, ?5, strftime('%s','now') - 3600)",
                params![kind.as_str(), d.name, login, d.bank_code, d.sf_symbol],
            )?;
            conn_ids.insert(kind, tx.last_insert_rowid());
        }
        // A few fetch-log rows so the Abruf-Protokoll window is not empty in the demo (#238).
        {
            let now_ms = chrono::Utc::now().timestamp_millis();
            let hour = 3_600_000_i64;
            let rows: [(ConnectorKind, &str, i64, &str, &str, &str, i64); 6] = [
                (
                    ConnectorKind::VolksbankKasselGoettingen,
                    "demo-musterbank",
                    1,
                    "manual",
                    "ok",
                    "",
                    12,
                ),
                (
                    ConnectorKind::TradeRepublic,
                    "demo-depot",
                    3,
                    "automatic",
                    "ok",
                    "",
                    0,
                ),
                (
                    ConnectorKind::AmericanExpress,
                    "demo-visa",
                    6,
                    "manual",
                    "error",
                    "Zeitüberschreitung beim Verbindungsaufbau zur Bank.",
                    0,
                ),
                (
                    ConnectorKind::VolksbankKasselGoettingen,
                    "demo-musterbank",
                    27,
                    "automatic",
                    "cancelled",
                    "Automatischer Abruf übersprungen: Die Bank verlangt eine neue Freigabe.",
                    0,
                ),
                (
                    ConnectorKind::TradeRepublic,
                    "demo-depot",
                    50,
                    "manual",
                    "error",
                    "Anmeldung abgelehnt (HTTP 401). Bitte Zugangsdaten prüfen.",
                    0,
                ),
                (
                    ConnectorKind::VolksbankKasselGoettingen,
                    "demo-musterbank",
                    74,
                    "manual",
                    "ok",
                    "",
                    31,
                ),
            ];
            for (kind, _, hours_ago, source, outcome, message, imported) in rows {
                let d = descriptor(kind);
                tx.execute(
                    "INSERT INTO sync_log(ts_ms, connection_id, connection_name, source, outcome, message, imported)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    params![now_ms - hours_ago * hour, conn_ids[&kind], d.name, source, outcome, message, imported],
                )?;
            }
        }
        let today = Local::now().date_naive();
        let txs = generate(today);
        for g in [
            "Giro & Tagesgeld",
            "Kreditkarten",
            "Depots & ETFs",
            "Darlehen & Kredite",
        ] {
            let (_, sym, order) = [
                AccountKind::Checking,
                AccountKind::CreditCard,
                AccountKind::Brokerage,
                AccountKind::Loan,
            ]
            .into_iter()
            .map(group_for)
            .find(|x| x.0 == g)
            .unwrap();
            Vault::ensure_group(&tx, g, sym, order)?;
        }
        let mut acc_ids = std::collections::HashMap::new();
        for (i, spec) in DEMO_ACCOUNTS.iter().enumerate() {
            let (group, sym, order) = group_for(spec.kind);
            let gid = Vault::ensure_group(&tx, group, sym, order)?;
            let balance = spec.opening_cents;
            let bank = if spec.bank_name.is_empty() {
                descriptor(spec.connector).name
            } else {
                spec.bank_name.to_string()
            };
            tx.execute(
                "INSERT INTO accounts(connection_id, group_id, external_ref, name, bank_name, owner, iban, account_number, currency, kind,
                                      balance_cents, balance_date, sf_symbol, sort_order, initial_balance_cents)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'Erika Mustermann', ?6, ?7, 'EUR', ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    conn_ids[&spec.connector],
                    gid,
                    spec.external_ref,
                    spec.name,
                    bank,
                    spec.iban,
                    spec.account_number,
                    spec.kind.as_str(),
                    balance,
                    today.format("%Y-%m-%d").to_string(),
                    spec.kind.sf_symbol(),
                    i as i32,
                    spec.principal_cents
                ],
            )?;
            acc_ids.insert(spec.external_ref, tx.last_insert_rowid());
        }
        // Scheduled transfers for the "Geplant" page (#240): fictional, relative to today.
        for (n, (days, name, iban, cents, purpose)) in [
            (
                6,
                "Hausverwaltung Nord",
                "DE02120300000000202051",
                85_000,
                "Miete Dezember",
            ),
            (
                12,
                "Stadtwerke München",
                "DE89370400440532013000",
                8_500,
                "Abschlag Strom Kd-Nr 482910",
            ),
            (
                23,
                "Finanzamt Musterstadt",
                "DE75512108001245126199",
                62_000,
                "Einkommensteuer Vorauszahlung Q4",
            ),
            (
                41,
                "Anna Becker",
                "DE44500105175407324931",
                15_000,
                "Anteil Weihnachtsgeschenk",
            ),
        ]
        .into_iter()
        .enumerate()
        {
            tx.execute(
                "INSERT INTO planned_transfers(account_id, end_to_end_id, execution_date, recipient_name,
                        recipient_iban, amount_cents, purpose, created_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)",
                params![
                    acc_ids["demo-giro"],
                    format!("DEMOPLAN{n}"),
                    (today + chrono::Duration::days(days)).format("%Y-%m-%d").to_string(),
                    name,
                    iban,
                    cents,
                    purpose
                ],
            )?;
        }
        // Depot positions: the two savings plans, summing to the depot balance
        // (28.450,00 EUR), so the "Positionen" card is not empty in the demo.
        for (isin, wkn, name, quantity, current, purchase) in [
            (
                "IE00B4L5Y983",
                "A0RPWH",
                "iShares Core MSCI World UCITS ETF",
                160.0_f64,
                104_25_i64,
                92_40_i64,
            ),
            (
                "IE00BK5BQT80",
                "A2PKXG",
                "Vanguard FTSE All-World UCITS ETF",
                110.0,
                107_00,
                98_10,
            ),
        ] {
            tx.execute(
                "INSERT INTO holdings(account_id, isin, wkn, name, quantity, current_price_cents, purchase_price_cents, value_cents)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    acc_ids["demo-depot"],
                    isin,
                    wkn,
                    name,
                    quantity,
                    current,
                    purchase,
                    (quantity * current as f64).round() as i64
                ],
            )?;
        }
        // manual loan without a bank account (#36): Stand two months ago, rates from the Giro
        // (linked by `apply_rules_inner` below)
        let car = crate::loans::create_in(
            &tx,
            &crate::loans::LoanSetup {
                name: "Autokredit".into(),
                original_cents: Some(15_000_00),
                anchor_date: (today - Duration::days(60)).format("%Y-%m-%d").to_string(),
                anchor_balance_cents: 9_400_00,
                interest_rate_ppm: Some(49_900),
                match_expr: "Autobank".into(),
            },
        )?;
        acc_ids.insert("demo-autokredit", car);
        // Sachwerte (#87): gold and a car; gold prices come from the API
        let sachwerte = crate::assets::seed_demo(&tx, today)?;
        acc_ids.insert("demo-sachwerte", sachwerte);
        // user groups for the "Nach Gruppe" sidebar view
        for (name, sym, refs) in [
            (
                "Alltag",
                "person",
                &["demo-giro", "demo-visa", "demo-autokredit"][..],
            ),
            (
                "Sparen & Vorsorge",
                "chart.pie",
                &["demo-tagesgeld", "demo-depot", "demo-sachwerte"][..],
            ),
            ("Haus", "house", &["demo-darlehen"][..]),
        ] {
            let (uuid, _) = crate::user_groups::find_or_create(&tx, crate::i18n::tr(name), sym)?;
            for r in refs {
                crate::user_groups::assign(&tx, acc_ids[r], Some(&uuid), 0)?;
            }
        }
        let mut n = 0u32;
        {
            let mut ins = tx.prepare(
                "INSERT INTO transactions(account_id, external_id, booking_date, value_date, amount_cents, currency, counterparty,
                                          counterparty_iban, purpose, booking_text, checked)
                 VALUES (?1, ?2, ?3, ?3, ?4, 'EUR', ?5, ?6, ?7, ?8, ?9)",
            )?;
            for (i, t) in txs.iter().enumerate() {
                let date = t.date.format("%Y-%m-%d").to_string();
                let checked = (today - t.date).num_days() > 10;
                ins.execute(params![
                    acc_ids[t.account],
                    format!("demo-{i}"),
                    date,
                    t.cents,
                    t.counterparty,
                    "",
                    t.purpose,
                    t.booking_text,
                    checked as i64
                ])?;
                n += 1;
            }
        }
        // Startsaldo (#212): the card reports no balance; it is computed from the
        // bookings, starting with the statement balance at the start of the
        // month three months ago, calibrated to today's balance of the spec.
        let visa = acc_ids["demo-visa"];
        tx.execute(
            "UPDATE accounts SET balance_derived = 1 WHERE id = ?1",
            [visa],
        )?;
        let since = (today - Duration::days(90)).with_day(1).unwrap_or(today);
        crate::opening_balance::store(&tx, visa, Some(0), &since.format("%Y-%m-%d").to_string())?;
        let card = DEMO_ACCOUNTS
            .iter()
            .find(|s| s.external_ref == "demo-visa")
            .map_or(0, |s| s.opening_cents);
        crate::opening_balance::calibrate_in(&tx, visa, card)?;
        Vault::apply_rules_inner(&tx, true)?;
        demo_documents(&tx, today, acc_ids["demo-giro"])?;
        tx.commit()?;
        Ok(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::merchants::FlowKind;
    use crate::models::BookingFilter;

    #[test]
    fn direction_filter_splits_income_and_expenses() {
        use crate::models::BookingDirection;
        let dir_dir = crate::test_support::TempDir::new("girocrab-test");
        let dir = dir_dir.join("v.db");
        let v = Vault::open(dir.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let page = |direction| {
            v.list_transactions(BookingFilter {
                direction,
                ..Default::default()
            })
            .unwrap()
        };
        let (all, income, expense) = (
            page(BookingDirection::All),
            page(BookingDirection::Income),
            page(BookingDirection::Expense),
        );
        assert!(income.total_count > 0 && expense.total_count > 0);
        assert!(income.transactions.iter().all(|t| t.amount_cents > 0));
        assert!(expense.transactions.iter().all(|t| t.amount_cents < 0));
        // zero-amount bookings belong to neither side
        let zero = all
            .transactions
            .iter()
            .filter(|t| t.amount_cents == 0)
            .count() as u32;
        assert_eq!(
            income.total_count + expense.total_count + zero,
            all.total_count
        );
        // page totals follow the filter
        assert_eq!(income.income_cents, all.income_cents);
        assert_eq!(income.expense_cents, 0);
        assert_eq!(expense.expense_cents, all.expense_cents);
        assert_eq!(expense.income_cents, 0);
        // the CSV export uses the same filter
        let csv = v
            .export_bookings_csv(BookingFilter {
                direction: BookingDirection::Income,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(csv.lines().count() as u32, income.total_count + 1);
    }

    #[test]
    fn demo_depot_has_positions_matching_its_balance() {
        let dir_dir = crate::test_support::TempDir::new("girocrab-test");
        let dir = dir_dir.join("v.db");
        let v = Vault::open(dir.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let depot = v
            .list_accounts()
            .unwrap()
            .into_iter()
            .find(|a| a.name == "Welt-Depot ETF")
            .unwrap();
        let holdings = v.list_holdings(depot.id).unwrap();
        assert_eq!(holdings.len(), 2);
        let sum: i64 = holdings.iter().map(|h| h.value_cents).sum();
        assert_eq!(sum, depot.balance_cents);
    }

    #[test]
    fn demo_seed_has_seven_accounts_and_exactly_fifty_two_bookings() {
        let dir_dir = crate::test_support::TempDir::new("girocrab-test");
        let dir = dir_dir.join("v.db");
        let v = Vault::open(dir.to_string_lossy().to_string(), vec![7u8; 32]).unwrap();
        assert_eq!(v.seed_demo_data().unwrap(), 52);
        assert_eq!(v.account_count().unwrap(), 7);
        let car = v.list_manual_loans().unwrap();
        assert_eq!(car.len(), 1);
        assert_eq!(car[0].status.payment_count, 2);
        assert!(car[0].status.remaining_cents < 9_400_00 - 2 * 250_00);
        let accounts = v.list_accounts().unwrap();
        let loan = accounts
            .iter()
            .find(|a| a.name == "Immobilien-Darlehen")
            .unwrap();
        assert_eq!(loan.balance_cents, -182_500_00);
        assert_eq!(loan.initial_balance_cents, Some(250_000_00));
        let giro = accounts
            .iter()
            .find(|a| a.name == "Musterbank Girokonto")
            .unwrap();
        assert_eq!(giro.balance_cents, 4_280_50);
        assert!(!giro.balance_derived);
        // #212: the card's balance is computed from a Startsaldo plus bookings
        let visa = accounts
            .iter()
            .find(|a| a.name == "Visa Gold Kreditkarte")
            .unwrap();
        assert!(visa.balance_derived);
        assert_eq!(visa.balance_cents, -642_80);
        assert!(visa.opening_balance_date.ends_with("-01"));
        assert!(visa.opening_balance_cents.is_some());
        // Loan view also shows the Giro's instalments (linked via the account number).
        let page = v
            .list_transactions(BookingFilter {
                account_ids: vec![loan.id],
                limit: 100,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(page.total_count, 2);
        let cats = v.list_categories(None, None).unwrap();
        assert!(cats
            .iter()
            .any(|c| c.name == "Supermarkt" && c.transaction_count > 0));
        let page = v
            .list_transactions(BookingFilter {
                search: Some("Lidl".into()),
                limit: 50,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(page.total_count, 2);
        assert!(page
            .transactions
            .iter()
            .all(|t| t.category_name == "Supermarkt" && t.flow == FlowKind::Consumption));
        // Private persons get a monogram, never a logo.
        let p = v
            .list_transactions(BookingFilter {
                search: Some("Laura Schneider".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(p.transactions[0].merchant.monogram, "LS");
        // A fresh personal vault gets categories + rules, but no bookings.
        let p2_dir = crate::test_support::TempDir::new("girocrab-test-own");
        let p2 = p2_dir.join("v.db");
        let own = Vault::open(p2.to_string_lossy().to_string(), vec![9u8; 32]).unwrap();
        assert!(own.seed_starter_categories().unwrap() > 30);
        assert_eq!(own.seed_starter_categories().unwrap(), 0);
        assert_eq!(own.account_count().unwrap(), 0);
        assert!(!own.has_account_history().unwrap());
        assert!(v.has_account_history().unwrap());
        let _ = std::fs::remove_file(&p2);
        // wrong key is rejected
        drop(v);
        let wrong = Vault::open(dir.to_string_lossy().to_string(), vec![8u8; 32]);
        assert!(matches!(wrong, Err(crate::error::CoreError::WrongKey)));
        let _ = std::fs::remove_file(&dir);
    }

    #[test]
    fn default_names_are_shown_in_english_but_stored_in_german() {
        use crate::i18n::{with_language, Lang};
        let dir_dir = crate::test_support::TempDir::new("girocrab-i18n");
        let dir = dir_dir.join("v.db");
        let v = Vault::open(dir.to_string_lossy().to_string(), vec![5u8; 32]).unwrap();
        v.seed_demo_data().unwrap();
        let groups_en = with_language(Lang::En, || v.list_account_groups().unwrap());
        assert!(groups_en.iter().any(|g| g.name == "Checking & savings"));
        assert!(groups_en.iter().any(|g| g.name == "Loans"));
        let de = v.list_categories(None, None).unwrap();
        let en = with_language(Lang::En, || v.list_categories(None, None).unwrap());
        // Every starter category has an English name.
        for (d, e) in de.iter().zip(&en) {
            assert_eq!(d.id, e.id);
            assert_ne!(d.name, e.name, "{} is not translated", d.name);
        }
        let sm = en.iter().find(|c| c.name == "Supermarket").unwrap();
        assert_eq!(sm.path, "Food › Supermarket");
        // Classification still sees the stored German names.
        let filter = || BookingFilter {
            limit: 100,
            ..Default::default()
        };
        let page_de = v.list_transactions(filter()).unwrap();
        let page_en = with_language(Lang::En, || v.list_transactions(filter()).unwrap());
        let flows = |p: &crate::models::BookingPage| {
            p.transactions.iter().map(|t| t.flow).collect::<Vec<_>>()
        };
        assert_eq!(flows(&page_de), flows(&page_en));
        assert!(page_en.transactions.iter().any(|t| t.category_path
            == "Saving & investing › ETF savings plans"
            && t.flow == FlowKind::Investment));
        // Saving the unchanged English display name keeps the German default;
        // a real rename is stored as written.
        let sm_de = de.iter().find(|c| c.name == "Supermarkt").unwrap();
        with_language(Lang::En, || {
            v.update_category(
                sm_de.id,
                "Supermarket".into(),
                sm_de.parent_id,
                sm_de.sf_symbol.clone(),
                sm_de.color_hex.clone(),
            )
            .unwrap()
        });
        let after = v.list_categories(None, None).unwrap();
        assert!(after
            .iter()
            .any(|c| c.id == sm_de.id && c.name == "Supermarkt"));
        with_language(Lang::En, || {
            v.update_category(
                sm_de.id,
                "Groceries".into(),
                sm_de.parent_id,
                sm_de.sf_symbol.clone(),
                sm_de.color_hex.clone(),
            )
            .unwrap()
        });
        let after = v.list_categories(None, None).unwrap();
        assert!(after
            .iter()
            .any(|c| c.id == sm_de.id && c.name == "Groceries"));
        // Settings: `group` stays a stable id, `group_title` is localised.
        let s = with_language(Lang::En, || v.list_settings().unwrap());
        let days = s.iter().find(|e| e.key == "sync.days_back").unwrap();
        assert_eq!(days.group, "Allgemein");
        assert_eq!(days.group_title, "General");
        assert_eq!(days.label, "Days on first sync");
        drop(v);
        let _ = std::fs::remove_file(&dir);
    }
}
