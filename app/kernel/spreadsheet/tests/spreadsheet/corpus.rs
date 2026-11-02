//! The golden corpus: three business workbooks with one reproducible edit each. Together they
//! carry every feature category that a save keeps: tables, a chart, a PivotTable, notes and
//! threaded comments, data validation, conditional formats, merges, frozen panes, tab colors, a
//! defined name, and formulas that read another sheet.
//!
//! `roundtrip_cases.json` names a cell to change, the dependent cell and its value before and
//! after, the value that restores the input, and three totals that must hold again afterwards.
//! `样本清单.csv` lists the features each file carries. Upgrading GridCraft must keep these tests
//! green.

use std::collections::BTreeMap;

use gridcraft_core::Value;
use serde::Deserialize;
use serde_json::{Value as Json, json};

use crate::support::{
    TestResult, apply, corpus_dir, corpus_file, package_parts, rewrite_package, sheet_id,
};

#[derive(Deserialize)]
struct Case {
    file: String,
    sheet: String,
    cell: String,
    before: Json,
    input: Json,
    expected: Expected,
    restore_value: Json,
    baseline_totals: Vec<Total>,
}

#[derive(Deserialize)]
struct Expected {
    cell: String,
    before: Json,
    after: Json,
}

#[derive(Deserialize)]
struct Total {
    cell: String,
    label: String,
    expected: Json,
}

fn cases() -> Vec<Case> {
    let json =
        std::fs::read(corpus_dir().join("roundtrip_cases.json")).expect("roundtrip_cases.json");
    serde_json::from_slice(&json).expect("valid cases")
}

/// What a person types to enter the case's value.
fn typed(value: &Json) -> String {
    match value {
        Json::String(text) => text.clone(),
        Json::Number(number) => number.as_i64().map_or_else(
            || number.as_f64().map(|n| n.to_string()).unwrap_or_default(),
            |n| n.to_string(),
        ),
        other => other.to_string(),
    }
}

/// Amounts compare within 0.00001 and ratios (below 1) within 0.0000001, as the corpus README
/// specifies; text compares exactly.
fn check(what: &str, actual: &Value, expected: &Json) -> Result<(), String> {
    let matches = match (actual, expected) {
        (Value::Number(actual), Json::Number(expected)) => {
            let expected = expected.as_f64().unwrap_or(f64::NAN);
            (actual - expected).abs() <= if expected.abs() < 1.0 { 1e-7 } else { 1e-5 }
        }
        (Value::Empty, Json::Number(expected)) => expected.as_f64() == Some(0.0),
        (Value::Text(actual), Json::String(expected)) => actual.as_ref() == expected,
        _ => false,
    };
    if matches {
        Ok(())
    } else {
        Err(format!("{what}: expected {expected}, found {actual:?}"))
    }
}

fn sheet_value(wb: &gridcraft_model::Workbook, sheet: &str, a1: &str) -> Value {
    let cell = gridcraft_core::CellRef::parse(a1).unwrap_or_default();
    wb.sheets
        .iter()
        .find(|s| s.name == sheet)
        .map(|s| s.value(cell))
        .unwrap_or(Value::Empty)
}

fn run_case(case: &Case) -> Result<(), String> {
    let bytes = corpus_file(&case.file);
    let doc = ankole_spreadsheet::open(&bytes, "[]").map_err(|error| error.to_string())?;
    let id = sheet_id(&doc, &case.sheet);
    let wb = doc.workbook();
    check(
        "input before",
        &sheet_value(wb, &case.sheet, &case.cell),
        &case.before,
    )?;
    check(
        "dependent before",
        &sheet_value(wb, &case.sheet, &case.expected.cell),
        &case.expected.before,
    )?;

    let set = |doc, input: &Json| {
        apply(
            doc,
            json!({"type": "cell.set", "sheet_id": id, "cell": case.cell, "input": typed(input)}),
        )
        .doc
    };
    let edited = set(&doc, &case.input);
    check(
        "dependent after",
        &sheet_value(edited.workbook(), &case.sheet, &case.expected.cell),
        &case.expected.after,
    )?;

    // Reading the export back without recalculating shows what the file itself stores.
    let exported = ankole_spreadsheet::export_xlsx(&edited).map_err(|error| error.to_string())?;
    let (stored, _) =
        gridcraft_xlsx::read_xlsx(&exported.xlsx).map_err(|error| error.to_string())?;
    check(
        "stored input",
        &sheet_value(&stored, &case.sheet, &case.cell),
        &case.input,
    )?;
    check(
        "stored cached dependent",
        &sheet_value(&stored, &case.sheet, &case.expected.cell),
        &case.expected.after,
    )?;
    let ids = |wb: &gridcraft_model::Workbook| {
        wb.sheets
            .iter()
            .map(|s| (s.name.clone(), s.file_id))
            .collect::<Vec<_>>()
    };
    if ids(&stored) != ids(edited.workbook()) {
        return Err(format!(
            "sheet ids changed: {:?} -> {:?}",
            ids(edited.workbook()),
            ids(&stored)
        ));
    }

    let restored = set(&edited, &case.restore_value);
    check(
        "restored dependent",
        &sheet_value(restored.workbook(), &case.sheet, &case.expected.cell),
        &case.expected.before,
    )?;
    for total in &case.baseline_totals {
        let (sheet, a1) = total
            .cell
            .split_once('!')
            .ok_or("total cell without a sheet")?;
        check(
            &total.label,
            &sheet_value(restored.workbook(), sheet, a1),
            &total.expected,
        )?;
    }
    Ok(())
}

#[test]
fn every_corpus_case_edits_recalculates_stores_and_restores() {
    let failures: Vec<String> = cases()
        .iter()
        .filter_map(|case| {
            run_case(case)
                .err()
                .map(|error| format!("{}: {error}", case.file))
        })
        .collect();
    assert!(failures.is_empty(), "{failures:#?}");
}

/// Element names in an XML text, without namespace prefixes, in document order.
fn element_names(xml: &str) -> impl Iterator<Item = &str> {
    xml.split('<')
        .skip(1)
        .filter(|tag| !tag.starts_with(['/', '?', '!']))
        .map(|tag| {
            let name = tag
                .split(|c: char| c.is_whitespace() || c == '>' || c == '/')
                .next()
                .unwrap_or_default();
            name.rsplit(':').next().unwrap_or(name)
        })
}

/// Feature counts taken from the package XML, independent of GridCraft's model. Parts are
/// recognized by their root element because writers name and prefix them differently.
fn package_features(bytes: &[u8]) -> BTreeMap<&'static str, usize> {
    let mut counts: BTreeMap<&'static str, usize> = BTreeMap::new();
    for (name, data) in package_parts(bytes) {
        if !name.ends_with(".xml") {
            continue;
        }
        let xml = String::from_utf8_lossy(&data);
        let mut names = element_names(&xml);
        let root = names.next().unwrap_or_default();
        let mut add =
            |feature: &'static str, count: usize| *counts.entry(feature).or_default() += count;
        match root {
            "table" => add("tables", 1),
            "chartSpace" => add("charts", 1),
            "pivotTableDefinition" => add("pivot_tables", 1),
            "pivotCacheDefinition" => add("pivot_caches", 1),
            "pivotCacheRecords" => add("pivot_records", names.filter(|n| *n == "r").count()),
            "styleSheet" => {
                for element in names {
                    match element {
                        "numFmt" => add("number_formats", 1),
                        "font" => add("fonts", 1),
                        "fill" => add("fills", 1),
                        "border" => add("borders", 1),
                        "dxf" => add("differential_formats", 1),
                        _ => {}
                    }
                }
            }
            "comments" => add("notes", names.filter(|n| *n == "comment").count()),
            "ThreadedComments" => add(
                "threaded_comments",
                names.filter(|n| *n == "threadedComment").count(),
            ),
            "workbook" => add(
                "defined_names",
                names.filter(|n| *n == "definedName").count(),
            ),
            "worksheet" => {
                for element in names {
                    match element {
                        "dataValidation" => add("validations", 1),
                        "conditionalFormatting" => add("conditional_formats", 1),
                        "cfRule" => add("conditional_rules", 1),
                        "col" => add("column_widths", 1),
                        "tabColor" => add("tab_colors", 1),
                        "hyperlink" => add("hyperlinks", 1),
                        "f" => add("formulas", 1),
                        "mergeCell" => add("merges", 1),
                        _ => {}
                    }
                }
                add("frozen_panes", xml.matches("state=\"frozen\"").count());
            }
            _ => {}
        }
    }
    counts
}

/// One row of `样本清单.csv`: the feature counts the corpus generator recorded.
struct Manifest {
    file: String,
    merges: usize,
    charts: usize,
    pivot_tables: usize,
    notes: usize,
    validations: usize,
}

fn manifest() -> Vec<Manifest> {
    let csv = std::fs::read_to_string(corpus_dir().join("样本清单.csv")).expect("样本清单.csv");
    csv.trim_start_matches('\u{feff}')
        .lines()
        .skip(1)
        .map(|line| {
            let fields: Vec<&str> = line.split(',').collect();
            let count = |i: usize| {
                fields
                    .get(i)
                    .and_then(|field| field.parse().ok())
                    .unwrap_or_else(|| panic!("column {i} of {line}"))
            };
            Manifest {
                file: fields.get(1).map(|f| f.to_string()).unwrap_or_default(),
                merges: count(9),
                charts: count(10),
                pivot_tables: count(11),
                notes: count(12),
                validations: count(14),
            }
        })
        .collect()
}

/// Package features GridCraft writes back one for one.
const KEPT_FEATURES: &[&str] = &[
    "tables",
    "charts",
    "pivot_tables",
    "pivot_caches",
    "pivot_records",
    "notes",
    "threaded_comments",
    "validations",
    "conditional_rules",
    "merges",
    "frozen_panes",
    "defined_names",
    "formulas",
    "tab_colors",
    "hyperlinks",
    "fonts",
    "fills",
    "borders",
    "differential_formats",
];

fn compare_models(
    source: &gridcraft_model::Workbook,
    written: &gridcraft_model::Workbook,
) -> Result<(), String> {
    let layout = |wb: &gridcraft_model::Workbook| {
        wb.sheets
            .iter()
            .map(|s| {
                (
                    s.name.clone(),
                    s.file_id,
                    s.freeze,
                    s.merges.clone(),
                    s.tab_color,
                )
            })
            .collect::<Vec<_>>()
    };
    if layout(source) != layout(written) {
        return Err(format!(
            "sheet layout changed: {:?} -> {:?}",
            layout(source),
            layout(written)
        ));
    }
    for (a, b) in source.sheets.iter().zip(&written.sheets) {
        let lines = |infos: &std::collections::BTreeMap<u32, gridcraft_model::LineInfo>| {
            infos
                .iter()
                .map(|(i, l)| (*i, l.size.map(|s| (s * 100.0).round()), l.hidden))
                .collect::<Vec<_>>()
        };
        if lines(&a.cols) != lines(&b.cols) || lines(&a.rows) != lines(&b.rows) {
            return Err(format!("{}: line sizes changed", a.name));
        }
        if a.comments != b.comments
            || a.validations != b.validations
            || a.hyperlinks != b.hyperlinks
        {
            return Err(format!("{}: notes, validations, or links changed", a.name));
        }
        let tables = |s: &gridcraft_model::Sheet| {
            s.tables
                .iter()
                .map(|t| {
                    (
                        t.name.clone(),
                        t.range,
                        t.columns.iter().map(|c| c.name.clone()).collect::<Vec<_>>(),
                    )
                })
                .collect::<Vec<_>>()
        };
        if tables(a) != tables(b) {
            return Err(format!("{}: tables changed", a.name));
        }
        // Series references compare in canonical form: the writer drops quotes a sheet name does not need.
        let canonical = |text: &str| {
            gridcraft_formula::parse(text)
                .map_or_else(|_| text.to_string(), |expr| gridcraft_formula::print(&expr))
        };
        let series = |s: &gridcraft_model::Sheet| {
            let refs = |c: &gridcraft_model::Chart| {
                c.series
                    .iter()
                    .map(|x| (canonical(&x.values), x.categories.as_deref().map(canonical)))
                    .collect::<Vec<_>>()
            };
            s.charts
                .iter()
                .map(|c| (c.kind, c.title.clone(), refs(c)))
                .collect::<Vec<_>>()
        };
        if series(a) != series(b) || a.pivots.len() != b.pivots.len() {
            return Err(format!("{}: charts or PivotTables changed", a.name));
        }
        for (at, cell) in a.cells.iter() {
            let other = b
                .cell(at)
                .ok_or_else(|| format!("{}!{} disappeared", a.name, at.a1()))?;
            let formula = |c: &gridcraft_model::Cell| c.formula.as_ref().map(|f| f.text.clone());
            if formula(cell) != formula(other)
                || source.styles.get(cell.style) != written.styles.get(other.style)
            {
                return Err(format!("{}!{}: formula or style changed", a.name, at.a1()));
            }
            let same_value = match (&cell.value, &other.value) {
                (Value::Number(x), Value::Number(y)) => (x - y).abs() <= 1e-7 * x.abs().max(1.0),
                // A file may omit the cached value of a formula that returns ""; GridCraft stores it.
                (Value::Empty, Value::Text(text)) => cell.formula.is_some() && text.is_empty(),
                (x, y) => x == y,
            };
            if !same_value {
                return Err(format!(
                    "{}!{}: {:?} became {:?}",
                    a.name,
                    at.a1(),
                    cell.value,
                    other.value
                ));
            }
        }
        if a.cells.len() != b.cells.len() {
            return Err(format!(
                "{}: {} cells became {}",
                a.name,
                a.cells.len(),
                b.cells.len()
            ));
        }
    }
    Ok(())
}

fn check_features(file: &str, expected: Option<&Manifest>) -> Result<(), String> {
    let bytes = corpus_file(file);
    let (source, report) = gridcraft_xlsx::read_xlsx(&bytes).map_err(|error| error.to_string())?;
    if !report.warnings.is_empty() {
        return Err(format!("read warnings: {:?}", report.warnings));
    }
    let doc = ankole_spreadsheet::open(&bytes, "[]").map_err(|error| error.to_string())?;
    let exported = ankole_spreadsheet::export_xlsx(&doc).map_err(|error| error.to_string())?;
    if exported.metadata.has_unsupported_objects {
        return Err("flagged unsupported objects".into());
    }
    let (before, after) = (package_features(&bytes), package_features(&exported.xlsx));
    let count =
        |counts: &BTreeMap<&str, usize>, feature: &str| counts.get(feature).copied().unwrap_or(0);
    if let Some(expected) = expected {
        let listed = [
            ("merges", expected.merges),
            ("charts", expected.charts),
            ("pivot_tables", expected.pivot_tables),
            ("notes", expected.notes),
            ("validations", expected.validations),
        ];
        for (feature, listed) in listed {
            if count(&before, feature) != listed {
                return Err(format!(
                    "the census counts {} {feature}, the manifest lists {listed}",
                    count(&before, feature)
                ));
            }
        }
    }
    for feature in KEPT_FEATURES {
        if count(&before, feature) != count(&after, feature) {
            return Err(format!(
                "{feature}: {} became {}",
                count(&before, feature),
                count(&after, feature)
            ));
        }
    }
    // GridCraft writes one <conditionalFormatting> per rule; the rules themselves are kept above.
    if count(&after, "conditional_formats") < count(&before, "conditional_formats") {
        return Err("conditional formats were dropped".into());
    }
    let (written, _) =
        gridcraft_xlsx::read_xlsx(&exported.xlsx).map_err(|error| error.to_string())?;
    compare_models(&source, &written)
}

/// Every corpus file keeps its modelled content through a save. Charts and PivotTables are written
/// from GridCraft's model, so only their modelled parts are compared: chart kind, title, and series
/// references, and the number of PivotTables.
#[test]
fn every_corpus_feature_survives_a_save() {
    let manifest = manifest();
    assert_eq!(manifest.len(), 3);
    let failures: Vec<String> = manifest
        .iter()
        .filter_map(|row| {
            check_features(&row.file, Some(row))
                .err()
                .map(|error| format!("{}: {error}", row.file))
        })
        .collect();
    assert!(failures.is_empty(), "{failures:#?}");
}

const CUSTOM_PROPERTIES: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="审批状态"><vt:lpwstr>已审批</vt:lpwstr></property></Properties>"#;
const CUSTOM_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?><b:Sources xmlns:b="http://schemas.openxmlformats.org/officeDocument/2006/bibliography" SelectedStyle="\APA.XSL"/>"#;
const CUSTOM_XML_PROPS: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="no"?><ds:datastoreItem ds:itemID="{11111111-2222-3333-4444-555555555555}" xmlns:ds="http://schemas.openxmlformats.org/officeDocument/2006/customXml"><ds:schemaRefs><ds:schemaRef ds:uri="http://schemas.openxmlformats.org/officeDocument/2006/bibliography"/></ds:schemaRefs></ds:datastoreItem>"#;
const CUSTOM_XML_RELS: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXmlProps" Target="itemProps1.xml"/></Relationships>"#;

/// File 24 with custom document properties and a custom XML part, which GridCraft does not model
/// but keeps, and with its first sheet renumbered to `sheetId` 7.
fn with_kept_parts(extra_content_types: &str, extra_parts: &[(&str, &str)]) -> Vec<u8> {
    let content_types = format!(
        "<Override PartName=\"/docProps/custom.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.custom-properties+xml\" />\
         <Override PartName=\"/customXml/item1.xml\" ContentType=\"application/xml\" />\
         <Override PartName=\"/customXml/itemProps1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.customXmlProperties+xml\" />{extra_content_types}</Types>"
    );
    let edit = |name: &str, data: Vec<u8>| {
        let text = String::from_utf8(data).expect("XML part");
        let text = match name {
            "[Content_Types].xml" => text.replace("</Types>", &content_types),
            "_rels/.rels" => text.replace(
                "</Relationships>",
                "<Relationship Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/custom-properties\" Target=\"docProps/custom.xml\" Id=\"rIdCustom\" /></Relationships>",
            ),
            "xl/_rels/workbook.xml.rels" => text.replace(
                "</Relationships>",
                "<Relationship Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml\" Target=\"../customXml/item1.xml\" Id=\"rIdCustomXml\" /></Relationships>",
            ),
            "xl/workbook.xml" => text.replace("sheetId=\"1\"", "sheetId=\"7\""),
            _ => text,
        };
        text.into_bytes()
    };
    let mut added = vec![
        ("docProps/custom.xml", CUSTOM_PROPERTIES.as_bytes()),
        ("customXml/item1.xml", CUSTOM_XML.as_bytes()),
        ("customXml/itemProps1.xml", CUSTOM_XML_PROPS.as_bytes()),
        ("customXml/_rels/item1.xml.rels", CUSTOM_XML_RELS.as_bytes()),
    ];
    added.extend(
        extra_parts
            .iter()
            .map(|(name, data)| (*name, data.as_bytes())),
    );
    rewrite_package(&corpus_file("24_多币种结算.xlsx"), edit, &added)
}

#[test]
fn kept_parts_and_sheet_ids_survive_structural_edits_and_saves() -> TestResult {
    let doc = ankole_spreadsheet::open(&with_kept_parts("", &[]), "[]")?;
    assert_eq!(
        doc.workbook()
            .sheets
            .iter()
            .map(|s| s.file_id)
            .collect::<Vec<_>>(),
        vec![7, 2]
    );
    let doc = apply(
        &doc,
        json!({"type": "line.insert", "sheet_id": 7, "axis": "rows", "at": 7, "count": 2}),
    )
    .doc;
    let doc = apply(&doc, json!({"type": "sheet.insert", "name": "附表"})).doc;
    let first = ankole_spreadsheet::export_xlsx(&doc)?;
    let second = ankole_spreadsheet::export_xlsx(&ankole_spreadsheet::open(&first.xlsx, "[]")?)?;
    for exported in [&first, &second] {
        let parts = package_parts(&exported.xlsx);
        assert_eq!(
            parts.get("docProps/custom.xml").map(Vec::as_slice),
            Some(CUSTOM_PROPERTIES.as_bytes())
        );
        assert_eq!(
            parts.get("customXml/item1.xml").map(Vec::as_slice),
            Some(CUSTOM_XML.as_bytes())
        );
        let ids: Vec<(String, u32)> = exported
            .metadata
            .sheets
            .iter()
            .map(|s| (s.name.clone(), s.sheet_id.0))
            .collect();
        assert_eq!(
            ids,
            vec![
                ("结算台账".to_string(), 7),
                ("汇率假设".to_string(), 2),
                ("附表".to_string(), 8)
            ]
        );
        assert!(
            !exported.metadata.has_unsupported_objects && exported.metadata.warnings.is_empty()
        );
    }
    assert_eq!(
        first.xlsx, second.xlsx,
        "a second save of the same content is byte-identical"
    );
    Ok(())
}

#[test]
fn parts_that_saving_drops_flag_unsupported_objects() -> TestResult {
    let slicer = r#"<?xml version="1.0" encoding="UTF-8"?><slicers xmlns="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main"/>"#;
    let override_type = "<Override PartName=\"/xl/slicers/slicer1.xml\" ContentType=\"application/vnd.ms-excel.slicer+xml\" />";
    let doc = ankole_spreadsheet::open(
        &with_kept_parts(override_type, &[("xl/slicers/slicer1.xml", slicer)]),
        "[]",
    )?;
    let exported = ankole_spreadsheet::export_xlsx(&doc)?;
    assert!(exported.metadata.has_unsupported_objects);
    assert!(!package_parts(&exported.xlsx).contains_key("xl/slicers/slicer1.xml"));
    Ok(())
}

const MACRO_WORKBOOK: &str = "application/vnd.ms-excel.sheet.macroEnabled.main+xml";
const VBA_PROJECT: &str = "http://schemas.microsoft.com/office/2006/relationships/vbaProject";
const MACROS_KEPT: &str = "macros (VBA project) were kept but not executed";

/// File 24 as a macro-enabled workbook. Ankole never reads or runs the VBA project, so arbitrary
/// binary bytes stand in for one and must come back unchanged, with GridCraft's notice that the
/// macros were kept but not executed.
fn with_vba_project(project: &[u8]) -> Vec<u8> {
    let edit = |name: &str, data: Vec<u8>| {
        let text = String::from_utf8(data).expect("XML part");
        let text = match name {
            "[Content_Types].xml" => text
                .replace(
                    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
                    MACRO_WORKBOOK,
                )
                .replace(
                    "</Types>",
                    "<Default Extension=\"bin\" ContentType=\"application/vnd.ms-office.vbaProject\" /></Types>",
                ),
            "xl/_rels/workbook.xml.rels" => text.replace(
                "</Relationships>",
                &format!(
                    "<Relationship Type=\"{VBA_PROJECT}\" Target=\"vbaProject.bin\" Id=\"rIdVba\" /></Relationships>"
                ),
            ),
            _ => text,
        };
        text.into_bytes()
    };
    rewrite_package(
        &corpus_file("24_多币种结算.xlsx"),
        edit,
        &[("xl/vbaProject.bin", project)],
    )
}

#[test]
fn a_macro_enabled_workbook_keeps_its_vba_project_through_edits_and_saves() -> TestResult {
    let project: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
    let doc = ankole_spreadsheet::open(&with_vba_project(&project), "[]")?;
    let sheet = sheet_id(&doc, "结算台账");
    let doc = apply(
        &doc,
        json!({"type": "cell.set", "sheet_id": sheet, "cell": "B3", "input": "宏工作簿"}),
    )
    .doc;
    let doc = apply(
        &doc,
        json!({"type": "line.insert", "sheet_id": sheet, "axis": "rows", "at": 7, "count": 1}),
    )
    .doc;
    let first = ankole_spreadsheet::export_xlsx(&doc)?;
    let second = ankole_spreadsheet::export_xlsx(&ankole_spreadsheet::open(&first.xlsx, "[]")?)?;
    for exported in [&first, &second] {
        let parts = package_parts(&exported.xlsx);
        assert_eq!(
            parts.get("xl/vbaProject.bin").map(Vec::as_slice),
            Some(project.as_slice())
        );
        let content_types = String::from_utf8(parts["[Content_Types].xml"].clone())?;
        assert!(content_types.contains(MACRO_WORKBOOK), "{content_types}");
        let relationships = String::from_utf8(parts["xl/_rels/workbook.xml.rels"].clone())?;
        assert!(relationships.contains(VBA_PROJECT), "{relationships}");
        assert!(!exported.metadata.has_unsupported_objects);
        assert_eq!(exported.metadata.warnings, [MACROS_KEPT]);
    }
    Ok(())
}
