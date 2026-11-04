//! The rebase matrix: an operation authored at an older revision, applied after the operations
//! committed since then.

use ankole_spreadsheet::{ApplyError, Conflict, SpreadsheetDoc};
use serde_json::{Value as Json, json};

use crate::support::{apply, apply_all, blank, formula, number, sheet_id, text};

/// Commits `prior` on `base` and then applies `incoming` as authored against `base`. Returns the
/// committed incoming operation and the resulting document.
fn concurrent(
    base: &SpreadsheetDoc,
    prior: &[Json],
    incoming: Json,
) -> Result<(Json, SpreadsheetDoc), ApplyError> {
    let mut doc = base.clone();
    let mut committed = Vec::new();
    for op in prior {
        let applied = apply(&doc, op.clone());
        committed.push(serde_json::to_value(&applied.op).expect("committed op"));
        doc = applied.doc;
    }
    let applied = ankole_spreadsheet::apply(
        &doc,
        &incoming.to_string(),
        &Json::Array(committed).to_string(),
    )?;
    Ok((
        serde_json::to_value(&applied.op).expect("committed op"),
        applied.doc,
    ))
}

fn conflict(base: &SpreadsheetDoc, prior: &[Json], incoming: Json) -> Conflict {
    match concurrent(base, prior, incoming.clone()) {
        Err(ApplyError::Conflict(conflict)) => conflict,
        other => panic!("{incoming} did not conflict: {:?}", other.map(|(op, _)| op)),
    }
}

fn set(sheet_id: u32, at: &str, input: &str) -> Json {
    json!({"type": "cell.set", "sheet_id": sheet_id, "cell": at, "input": input})
}

fn insert_rows(at: u32, count: u32) -> Json {
    json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": at, "count": count})
}

fn delete_rows(at: u32, count: u32) -> Json {
    json!({"type": "line.delete", "sheet_id": 1, "axis": "rows", "at": at, "count": count})
}

fn numbers() -> SpreadsheetDoc {
    apply_all(
        &blank(),
        &(1..=5)
            .map(|row| set(1, &format!("B{row}"), &row.to_string()))
            .collect::<Vec<_>>(),
    )
}

#[test]
fn a_cell_edit_follows_inserted_rows_and_its_formula_is_rewritten() {
    // The plan's example: InsertRows(at 2, count 3) commits while `C5 = SUM(B1:B5)` is in flight.
    let (op, doc) = concurrent(
        &numbers(),
        &[insert_rows(2, 3)],
        set(1, "C5", "=SUM(B1:B5)"),
    )
    .expect("rebased");
    assert_eq!(op, set(1, "C8", "=SUM(B1:B8)"));
    assert_eq!(number(&doc, 1, "C8"), 15.0);
}

#[test]
fn edits_on_other_sheets_or_unrelated_cells_pass_unchanged_and_the_last_write_wins() {
    let base = apply(&numbers(), json!({"type": "sheet.insert", "name": "Other"})).doc;
    let other = sheet_id(&base, "Other");
    let (op, _) = concurrent(&base, &[insert_rows(0, 2)], set(other, "A1", "x")).expect("rebased");
    assert_eq!(op, set(other, "A1", "x"));
    let (op, doc) =
        concurrent(&base, &[set(1, "D1", "first")], set(1, "D1", "second")).expect("rebased");
    assert_eq!(op, set(1, "D1", "second"));
    assert_eq!(text(&doc, 1, "D1"), "second");
}

#[test]
fn a_target_inside_deleted_rows_is_rejected() {
    assert_eq!(
        conflict(&numbers(), &[delete_rows(1, 3)], set(1, "C3", "1")),
        Conflict::TargetDeleted
    );
    let (op, _) =
        concurrent(&numbers(), &[delete_rows(1, 3)], set(1, "C5", "=B5")).expect("rebased");
    assert_eq!(op, set(1, "C2", "=B2"));
    let (op, _) = concurrent(
        &numbers(),
        &[delete_rows(1, 1)],
        json!({"type": "range.format", "sheet_id": 1, "range": "A1:A4", "patch": {"bold": true}}),
    )
    .expect("a range shrinks around deleted rows");
    assert_eq!(op.get("range"), Some(&json!("A1:A3")));
}

#[test]
fn line_edits_on_the_same_axis_shift_or_conflict() {
    let base = numbers();
    let (op, _) = concurrent(&base, &[insert_rows(1, 2)], delete_rows(3, 1)).expect("rebased");
    assert_eq!(op, delete_rows(5, 1));
    let (op, _) = concurrent(&base, &[insert_rows(2, 1)], insert_rows(2, 1)).expect("rebased");
    assert_eq!(
        op,
        insert_rows(3, 1),
        "a later insert at the same point lands after the earlier one"
    );
    let (op, _) = concurrent(&base, &[delete_rows(0, 1)], delete_rows(3, 2)).expect("rebased");
    assert_eq!(op, delete_rows(2, 2));
    assert_eq!(
        conflict(&base, &[delete_rows(1, 3)], delete_rows(2, 3)),
        Conflict::OverlappingStructuralEdit
    );
    assert_eq!(
        conflict(&base, &[insert_rows(2, 1)], delete_rows(1, 3)),
        Conflict::OverlappingStructuralEdit
    );
    assert_eq!(
        conflict(&base, &[delete_rows(1, 3)], insert_rows(2, 1)),
        Conflict::OverlappingStructuralEdit
    );
    let columns =
        json!({"type": "line.insert", "sheet_id": 1, "axis": "cols", "at": 0, "count": 1});
    let (op, _) = concurrent(&base, &[columns], delete_rows(3, 1)).expect("other axis");
    assert_eq!(op, delete_rows(3, 1));
    let resize = json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 2, "end": 3, "size_px": 30});
    let (op, _) = concurrent(&base, &[insert_rows(0, 2)], resize).expect("rebased");
    assert_eq!(
        (op.get("start"), op.get("end")),
        (Some(&json!(4)), Some(&json!(5)))
    );
}

#[test]
fn a_block_of_values_split_by_a_structural_edit_is_rejected() {
    let block = json!({"type": "range.set_values", "sheet_id": 1, "range": "D2:D3", "values": [[1], ["=B2"]]});
    let (op, _) = concurrent(&numbers(), &[insert_rows(0, 1)], block.clone())
        .expect("a block above the edit moves");
    assert_eq!(
        op,
        json!({"type": "range.set_values", "sheet_id": 1, "range": "D3:D4", "values": [[1], ["=B3"]]})
    );
    assert_eq!(
        conflict(&numbers(), &[insert_rows(2, 1)], block),
        Conflict::OverlappingStructuralEdit
    );
}

#[test]
fn renamed_and_deleted_sheets_rewrite_or_reject_concurrent_operations() {
    let base = apply(&numbers(), json!({"type": "sheet.insert", "name": "Data"})).doc;
    let data = sheet_id(&base, "Data");
    let rename = json!({"type": "sheet.rename", "sheet_id": data, "name": "华东区"});
    let (op, doc) = concurrent(
        &base,
        &[rename.clone(), set(data, "A1", "4")],
        set(1, "E1", "=Data!A1*2"),
    )
    .expect("rebased");
    assert_eq!(op, set(1, "E1", "=华东区!A1*2"));
    assert_eq!(number(&doc, 1, "E1"), 8.0);
    // Renamed, then rows inserted on it: the formula uses the old name and the old coordinates.
    let shift =
        json!({"type": "line.insert", "sheet_id": data, "axis": "rows", "at": 0, "count": 1});
    let (op, _) = concurrent(&base, &[rename, shift], set(1, "E1", "=Data!A1")).expect("rebased");
    assert_eq!(op, set(1, "E1", "=华东区!A2"));

    let delete = json!({"type": "sheet.delete", "sheet_id": data});
    assert_eq!(
        conflict(&base, std::slice::from_ref(&delete), set(data, "A1", "1")),
        Conflict::SheetDeleted
    );
    let to_deleted = json!({"type": "range.move", "sheet_id": 1, "from": "B1", "to_sheet_id": data, "to_cell": "A1"});
    assert_eq!(
        conflict(&base, std::slice::from_ref(&delete), to_deleted),
        Conflict::SheetDeleted
    );
    let (op, _) = concurrent(&base, &[delete], set(1, "E1", "=Data!A1")).expect("rebased");
    assert_eq!(op, set(1, "E1", "=#REF!"));
}

#[test]
fn a_concurrent_sort_or_merge_rejects_operations_that_touch_its_range() {
    let sort = json!({"type": "range.sort", "sheet_id": 1, "range": "B1:B5", "keys": [{"col": "B", "descending": true}]});
    let merge = json!({"type": "range.merge", "sheet_id": 1, "range": "D1:E2"});
    assert_eq!(
        conflict(&numbers(), std::slice::from_ref(&sort), set(1, "B2", "9")),
        Conflict::ConcurrentSortOrMerge
    );
    assert_eq!(
        conflict(&numbers(), std::slice::from_ref(&sort), insert_rows(3, 1)),
        Conflict::ConcurrentSortOrMerge
    );
    assert_eq!(
        conflict(&numbers(), std::slice::from_ref(&merge), set(1, "E2", "x")),
        Conflict::ConcurrentSortOrMerge
    );
    let (op, _) =
        concurrent(&numbers(), &[sort, merge], set(1, "F9", "x")).expect("outside both ranges");
    assert_eq!(op, set(1, "F9", "x"));
}

#[test]
fn moved_blocks_carry_targets_they_contain() {
    let base = apply(&numbers(), json!({"type": "sheet.insert", "name": "Other"})).doc;
    let other = sheet_id(&base, "Other");
    let within = json!({"type": "range.move", "sheet_id": 1, "from": "B1:B5", "to_sheet_id": 1, "to_cell": "H1"});
    let (op, _) =
        concurrent(&base, std::slice::from_ref(&within), set(1, "B2", "=B1+1")).expect("rebased");
    assert_eq!(op, set(1, "H2", "=H1+1"));
    let partly =
        json!({"type": "range.format", "sheet_id": 1, "range": "A1:B2", "patch": {"bold": true}});
    assert_eq!(
        conflict(&base, &[within], partly),
        Conflict::OverlappingStructuralEdit
    );
    let away = json!({"type": "range.move", "sheet_id": 1, "from": "B1:B5", "to_sheet_id": other, "to_cell": "A1"});
    assert_eq!(
        conflict(&base, std::slice::from_ref(&away), set(1, "B2", "1")),
        Conflict::OverlappingStructuralEdit
    );
    let (op, _) = concurrent(&base, &[away], set(1, "C1", "=B3"))
        .expect("a reference to the moved block follows it");
    assert_eq!(op, set(1, "C1", "=Other!A3"));
}

#[test]
fn inserted_cells_shift_targets_only_in_their_columns() {
    let shift = json!({"type": "cells.insert", "sheet_id": 1, "range": "B1:B2", "shift": "down"});
    let (op, _) =
        concurrent(&numbers(), std::slice::from_ref(&shift), set(1, "B4", "x")).expect("rebased");
    assert_eq!(op, set(1, "B6", "x"));
    let (op, _) = concurrent(
        &numbers(),
        std::slice::from_ref(&shift),
        set(1, "C4", "=B4"),
    )
    .expect("rebased");
    assert_eq!(op, set(1, "C4", "=B6"));
    let (_, doc) = concurrent(&numbers(), &[shift], set(1, "C4", "=B4")).expect("rebased");
    assert_eq!(formula(&doc, 1, "C4").as_deref(), Some("=B6"));
}

#[test]
fn prior_operations_must_be_committed() {
    let base = apply(&numbers(), json!({"type": "sheet.insert", "name": "Data"})).doc;
    let renamed = apply(
        &base,
        json!({"type": "sheet.rename", "sheet_id": 2, "name": "New"}),
    )
    .doc;
    let uncommitted = json!([{"type": "sheet.rename", "sheet_id": 2, "name": "New"}]).to_string();
    let result = ankole_spreadsheet::apply(&renamed, &set(1, "A1", "1").to_string(), &uncommitted);
    assert!(matches!(result, Err(ApplyError::Error(_))));
}
