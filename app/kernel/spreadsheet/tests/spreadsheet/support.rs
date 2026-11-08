//! Helpers shared by the spreadsheet integration tests.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::PathBuf;

use ankole_spreadsheet::{Applied, SpreadsheetDoc};
use gridcraft_core::{CellRef, Value};
use serde_json::Value as Json;

pub type TestResult = Result<(), Box<dyn std::error::Error>>;

pub fn corpus_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../test/fixtures/spreadsheet/corpus")
}

pub fn corpus_file(name: &str) -> Vec<u8> {
    std::fs::read(corpus_dir().join(name))
        .unwrap_or_else(|error| panic!("corpus file {name}: {error}"))
}

/// A blank workbook with one sheet, `sheet_id` 1.
pub fn blank() -> SpreadsheetDoc {
    ankole_spreadsheet::create_blank("Test")
        .expect("blank workbook")
        .0
}

/// Applies an operation with no concurrent commits.
pub fn apply(doc: &SpreadsheetDoc, op: Json) -> Applied {
    ankole_spreadsheet::apply(doc, &op.to_string(), "[]")
        .unwrap_or_else(|error| panic!("{op}: {error:?}"))
}

/// Applies a chain of operations and returns the final document.
pub fn apply_all(doc: &SpreadsheetDoc, ops: &[Json]) -> SpreadsheetDoc {
    ops.iter()
        .fold(doc.clone(), |doc, op| apply(&doc, op.clone()).doc)
}

pub fn sheet_id(doc: &SpreadsheetDoc, name: &str) -> u32 {
    doc.workbook()
        .sheets
        .iter()
        .find(|sheet| sheet.name == name)
        .map(|sheet| sheet.file_id)
        .unwrap_or_else(|| panic!("no sheet {name}"))
}

fn sheet(doc: &SpreadsheetDoc, sheet_id: u32) -> &gridcraft_model::Sheet {
    doc.workbook()
        .sheets
        .iter()
        .find(|sheet| sheet.file_id == sheet_id)
        .unwrap_or_else(|| panic!("no sheet_id {sheet_id}"))
}

pub fn cell(a1: &str) -> CellRef {
    CellRef::parse(a1).unwrap_or_else(|| panic!("bad cell {a1}"))
}

pub fn value(doc: &SpreadsheetDoc, sheet_id: u32, a1: &str) -> Value {
    sheet(doc, sheet_id).value(cell(a1))
}

pub fn number(doc: &SpreadsheetDoc, sheet_id: u32, a1: &str) -> f64 {
    match value(doc, sheet_id, a1) {
        Value::Number(n) => n,
        other => panic!("{a1} holds {other:?}, not a number"),
    }
}

pub fn text(doc: &SpreadsheetDoc, sheet_id: u32, a1: &str) -> String {
    match value(doc, sheet_id, a1) {
        Value::Text(text) => text.to_string(),
        other => panic!("{a1} holds {other:?}, not text"),
    }
}

/// The formula text of a cell, with its leading `=`.
pub fn formula(doc: &SpreadsheetDoc, sheet_id: u32, a1: &str) -> Option<String> {
    sheet(doc, sheet_id)
        .cell(cell(a1))
        .and_then(|cell| cell.formula.as_ref())
        .map(|formula| format!("={}", formula.text))
}

pub fn workbook_sheet(doc: &SpreadsheetDoc, sheet_id: u32) -> &gridcraft_model::Sheet {
    sheet(doc, sheet_id)
}

/// Decompressed parts of an `.xlsx` package by name.
pub fn package_parts(bytes: &[u8]) -> BTreeMap<String, Vec<u8>> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(bytes)).expect("zip package");
    let mut parts = BTreeMap::new();
    for index in 0..archive.len() {
        let mut part = archive.by_index(index).expect("zip entry");
        let mut data = Vec::new();
        part.read_to_end(&mut data).expect("zip entry data");
        parts.insert(part.name().expect("zip entry name").into_owned(), data);
    }
    parts
}

/// Rebuilds a package with `edit` applied to each part and `added` parts appended.
pub fn rewrite_package(
    bytes: &[u8],
    edit: impl Fn(&str, Vec<u8>) -> Vec<u8>,
    added: &[(&str, &[u8])],
) -> Vec<u8> {
    use std::io::Write;
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default();
    let parts = package_parts(bytes)
        .into_iter()
        .map(|(name, data)| (name.clone(), edit(&name, data)));
    for (name, data) in parts.chain(
        added
            .iter()
            .map(|(name, data)| (name.to_string(), data.to_vec())),
    ) {
        writer.start_file(name, options).expect("zip entry");
        writer.write_all(&data).expect("zip data");
    }
    writer.finish().expect("zip package").into_inner()
}
