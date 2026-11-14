use super::*;

const GOOD: &str = "DE89370400440532013000";

fn parse(s: &str) -> BatchCsvImport {
    parse_batch_csv(s.to_string())
}

#[test]
fn german_semicolon_file_with_header_and_bom() {
    let csv = format!(
        "\u{feff}Name;IBAN;Betrag;Verwendungszweck\r\nAnna Müller;DE89 3704 0044 0532 0130 00;60,00;Beitrag 2026\r\nBen Koch;{GOOD};1.234,50;\"Spende; Sommerfest\"\r\n"
    );
    let r = parse(&csv);
    assert!(r.had_header);
    assert_eq!(r.delimiter, ";");
    assert!(r.problems.is_empty());
    assert_eq!(r.rows.len(), 2);
    assert_eq!(r.rows[0].iban, GOOD);
    assert_eq!(r.rows[0].amount_cents, 6_000);
    assert_eq!(r.rows[0].line, 2);
    assert_eq!(r.rows[1].amount_cents, 123_450);
    assert_eq!(r.rows[1].purpose, "Spende; Sommerfest");
    assert!(r.rows.iter().all(|x| x.errors.is_empty()));
}

#[test]
fn comma_file_without_header_uses_the_default_order() {
    let r = parse(&format!("Anna,{GOOD},\"60.50\",Beitrag\nBen,{GOOD},30,\n"));
    assert!(!r.had_header);
    assert_eq!(r.delimiter, ",");
    assert_eq!(r.rows.len(), 2);
    assert_eq!(r.rows[0].amount_cents, 6_050);
    assert_eq!(r.rows[1].amount_cents, 3_000);
    assert_eq!(r.rows[1].purpose, "");
}

#[test]
fn header_names_decide_the_column_order() {
    let r = parse(&format!(
        "Betrag;Zweck;BIC;IBAN;Empfänger\n12,00;Miete;COBADEFFXXX;{GOOD};Vermieter\n"
    ));
    assert!(r.had_header);
    let row = &r.rows[0];
    assert_eq!(row.name, "Vermieter");
    assert_eq!(row.bic, "COBADEFFXXX");
    assert_eq!(row.amount_cents, 1_200);
    assert_eq!(row.purpose, "Miete");
}

#[test]
fn faulty_rows_stay_and_carry_their_errors() {
    let r = parse(&format!(
        "Name;IBAN;Betrag;Zweck\nA;{GOOD};10,00;x\n;DE89370400440532013001;;\nB;{GOOD};-5;x\n"
    ));
    assert_eq!(r.rows.len(), 3);
    assert!(r.rows[0].errors.is_empty());
    assert_eq!(r.rows[1].errors.len(), 3); // name, IBAN, amount
    assert_eq!(r.rows[1].amount_cents, 0);
    assert_eq!(r.rows[2].errors.len(), 1); // negative amount
    assert_eq!(r.rows[2].line, 4);
}

#[test]
fn limits_for_name_and_purpose() {
    let long_name = "N".repeat(71);
    let long_purpose = "Z".repeat(141);
    let r = parse(&format!("{long_name};{GOOD};1,00;{long_purpose}\n"));
    assert_eq!(r.rows[0].errors.len(), 2);
}

#[test]
fn quoted_fields_with_quotes_and_line_breaks() {
    let r = parse(&format!(
        "Name;IBAN;Betrag;Zweck\n\"Meier \"\"Junior\"\"\";{GOOD};5,00;\"zwei\nZeilen\"\nC;{GOOD};7,00;y\n"
    ));
    assert_eq!(r.rows.len(), 2);
    assert_eq!(r.rows[0].name, "Meier \"Junior\"");
    assert_eq!(r.rows[0].purpose, "zwei\nZeilen");
    assert_eq!(r.rows[1].line, 4); // the line break inside the quotes is counted
}

#[test]
fn blank_lines_are_skipped_and_missing_columns_reported() {
    let r = parse(&format!("\n\nA;{GOOD};1,00\n\n"));
    assert_eq!(r.rows.len(), 1);
    assert_eq!(r.rows[0].line, 3);

    let r = parse("Name;Betrag\nA;1,00\n");
    assert!(r.rows.is_empty());
    assert_eq!(r.problems.len(), 1); // IBAN column missing

    let r = parse("   \n\n");
    assert!(r.rows.is_empty());
    assert_eq!(r.problems.len(), 1);

    let r = parse("A;B\n");
    assert_eq!(r.rows.len(), 1);
    assert!(!r.rows[0].errors.is_empty());
}

#[test]
fn tab_separated_file() {
    let r = parse(&format!("Name\tIBAN\tBetrag\tZweck\nA\t{GOOD}\t2,50\tz\n"));
    assert_eq!(r.delimiter, "\t");
    assert_eq!(r.rows[0].amount_cents, 250);
}
