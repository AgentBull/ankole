//! Every canonical operation executed against real GridCraft workbooks.

use ankole_spreadsheet::{ApplyError, Error};
use gridcraft_core::{CellError, Value};
use gridcraft_model::{Color, FilterCriterion, HAlign, PatternType};
use serde_json::json;

use crate::support::{apply, apply_all, blank, cell, formula, number, text, value, workbook_sheet};

fn rejects(doc: &ankole_spreadsheet::SpreadsheetDoc, op: serde_json::Value) -> String {
    match ankole_spreadsheet::apply(doc, &op.to_string(), "[]") {
        Err(ApplyError::Error(Error::Invalid(message))) => message,
        other => panic!("{op} was not rejected as invalid: {other:?}"),
    }
}

fn set(sheet_id: u32, at: &str, input: &str) -> serde_json::Value {
    json!({"type": "cell.set", "sheet_id": sheet_id, "cell": at, "input": input})
}

#[test]
fn cell_set_types_values_formulas_and_formats() {
    let doc = apply_all(
        &blank(),
        &[
            set(1, "A1", "120"),
            set(1, "A2", "30"),
            set(1, "A3", "=SUM(A1:A2)"),
            set(1, "B1", "50%"),
            set(1, "B2", "2026-03-04"),
            set(1, "B3", "'00123"),
        ],
    );
    assert_eq!(number(&doc, 1, "A3"), 150.0);
    assert_eq!(formula(&doc, 1, "A3").as_deref(), Some("=SUM(A1:A2)"));
    assert_eq!(number(&doc, 1, "B1"), 0.5);
    let styles = &doc.workbook().styles;
    let style_of = |a1: &str| {
        styles
            .get(
                workbook_sheet(&doc, 1)
                    .cell(cell(a1))
                    .map(|c| c.style)
                    .unwrap_or_default(),
            )
            .num_fmt
            .as_str()
            .to_string()
    };
    assert_eq!(style_of("B1"), "0%");
    assert!(
        style_of("B2").contains('y'),
        "a typed date gets a date format"
    );
    assert_eq!(text(&doc, 1, "B3"), "00123");

    let edited = apply(&doc, set(1, "A1", "200")).doc;
    assert_eq!(number(&edited, 1, "A3"), 230.0, "dependents recalculate");
    let cleared = apply(&edited, set(1, "A2", "")).doc;
    assert_eq!(number(&cleared, 1, "A3"), 200.0);

    let array = apply(&doc, json!({"type": "cell.set", "sheet_id": 1, "cell": "C1", "input": "=A1:A2*2", "array": true})).doc;
    assert!(
        workbook_sheet(&array, 1)
            .cell(cell("C1"))
            .and_then(|c| c.formula.as_ref())
            .is_some_and(|f| f.array.is_some())
    );

    assert!(rejects(&doc, set(1, "A4", "=ROUND(1,2,3)")).contains("ROUND"));
    assert!(rejects(&doc, set(9, "A1", "1")).contains("sheet_id 9"));
    assert!(
        rejects(
            &doc,
            json!({"type": "cell.set", "sheet_id": 1, "cell": "A1", "input": "1", "array": true})
        )
        .contains("array")
    );
}

#[test]
fn copy_on_write_leaves_the_input_document_unchanged() {
    let base = apply(&blank(), set(1, "A1", "1")).doc;
    let next = apply(&base, set(1, "A1", "2")).doc;
    assert_eq!(number(&base, 1, "A1"), 1.0);
    assert_eq!(number(&next, 1, "A1"), 2.0);
}

#[test]
fn range_set_values_writes_a_block_of_the_same_shape() {
    let styled = apply(
        &blank(),
        json!({"type": "range.format", "sheet_id": 1, "range": "B1", "patch": {"bold": true}}),
    )
    .doc;
    let doc = apply(
        &apply(&styled, set(1, "B1", "old")).doc,
        json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:C2", "values": [[1, null, "x"], [true, "=A1+1", "007"]]}),
    )
    .doc;
    assert_eq!(number(&doc, 1, "A1"), 1.0);
    assert_eq!(
        value(&doc, 1, "B1"),
        Value::Empty,
        "null clears the content"
    );
    assert!(
        doc.workbook()
            .styles
            .get(workbook_sheet(&doc, 1).style_id(cell("B1")))
            .font
            .bold,
        "and keeps the format"
    );
    assert_eq!(value(&doc, 1, "A2"), Value::Bool(true));
    assert_eq!(number(&doc, 1, "B2"), 2.0);
    assert_eq!(
        number(&doc, 1, "C2"),
        7.0,
        "strings are typed input by default"
    );
    let raw = apply(&blank(), json!({"type": "range.set_values", "sheet_id": 1, "range": "A1", "values": [["007"]], "parse": false})).doc;
    assert_eq!(text(&raw, 1, "A1"), "007");
    assert!(
        rejects(
            &blank(),
            json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:B1", "values": [[1]]})
        )
        .contains("1 rows of 2")
    );
}

#[test]
fn range_clear_removes_what_its_mode_names() {
    let doc = apply_all(
        &blank(),
        &[
            set(1, "A1", "1"),
            json!({"type": "range.format", "sheet_id": 1, "range": "A1", "patch": {"bold": true}}),
            json!({"type": "comment.set", "sheet_id": 1, "cell": "A1", "text": "note"}),
        ],
    );
    let clear = |mode: &str| {
        apply(
            &doc,
            json!({"type": "range.clear", "sheet_id": 1, "range": "A1:B2", "mode": mode}),
        )
        .doc
    };
    let bold = |doc: &ankole_spreadsheet::SpreadsheetDoc| {
        doc.workbook()
            .styles
            .get(workbook_sheet(doc, 1).style_id(cell("A1")))
            .font
            .bold
    };
    let contents = clear("contents");
    assert_eq!(value(&contents, 1, "A1"), Value::Empty);
    assert!(bold(&contents));
    let formats = clear("formats");
    assert_eq!(number(&formats, 1, "A1"), 1.0);
    assert!(!bold(&formats));
    assert!(workbook_sheet(&clear("comments"), 1).comments.is_empty());
    let all = clear("all");
    assert!(
        workbook_sheet(&all, 1).cells.is_empty() && workbook_sheet(&all, 1).comments.is_empty()
    );
}

#[test]
fn range_format_patches_cells_and_whole_columns() {
    let doc = apply(
        &apply(&blank(), set(1, "B2", "5")).doc,
        json!({"type": "range.format", "sheet_id": 1, "range": "A1:B2", "patch": {
            "bold": true, "font_color": "#FF0000", "fill_color": "#00FF00", "h_align": "center",
            "num_fmt": "0.00", "borders": {"bottom": {"style": "thin"}}
        }}),
    )
    .doc;
    let style = doc
        .workbook()
        .styles
        .get(workbook_sheet(&doc, 1).style_id(cell("B2")));
    assert!(style.font.bold);
    assert_eq!(style.font.color, Color::Rgb(0xFF0000));
    assert_eq!(
        (style.fill.pattern, style.fill.fg),
        (PatternType::Solid, Color::Rgb(0x00FF00))
    );
    assert_eq!(style.align.h, HAlign::Center);
    assert_eq!(style.num_fmt.as_str(), "0.00");
    assert!(!style.borders.bottom.is_none());
    let unfilled = apply(&doc, json!({"type": "range.format", "sheet_id": 1, "range": "B2", "patch": {"fill_color": null}})).doc;
    assert_eq!(
        unfilled
            .workbook()
            .styles
            .get(workbook_sheet(&unfilled, 1).style_id(cell("B2")))
            .fill
            .pattern,
        PatternType::None
    );

    let column = apply(
        &doc,
        json!({"type": "range.format", "sheet_id": 1, "range": "C:C", "patch": {"italic": true}}),
    )
    .doc;
    let sheet = workbook_sheet(&column, 1);
    assert!(
        sheet
            .cols
            .get(&2)
            .and_then(|info| info.style)
            .is_some_and(|style| column.workbook().styles.get(style).font.italic)
    );
    assert!(
        sheet.cells.len() <= 4,
        "a whole-column format stores a line style, not a million cells"
    );
    assert!(
        rejects(
            &doc,
            json!({"type": "range.format", "sheet_id": 1, "range": "A1", "patch": {"font_size": 0}})
        )
        .contains("font_size")
    );
}

#[test]
fn merging_keeps_the_top_left_value_and_unmerging_removes_the_area() {
    let doc = apply_all(
        &blank(),
        &[
            set(1, "A1", "keep"),
            set(1, "B1", "drop"),
            set(1, "C1", "=B1"),
        ],
    );
    let merged = apply(
        &doc,
        json!({"type": "range.merge", "sheet_id": 1, "range": "A1:B2"}),
    )
    .doc;
    let sheet = workbook_sheet(&merged, 1);
    assert_eq!(sheet.merges.len(), 1);
    assert_eq!(text(&merged, 1, "A1"), "keep");
    assert_eq!(value(&merged, 1, "B1"), Value::Empty);
    assert_eq!(
        number(&merged, 1, "C1"),
        0.0,
        "formulas reading the cleared cell recalculate"
    );
    let across = apply(
        &doc,
        json!({"type": "range.merge", "sheet_id": 1, "range": "A3:C4", "across": true}),
    )
    .doc;
    assert_eq!(workbook_sheet(&across, 1).merges.len(), 2);
    let unmerged = apply(
        &merged,
        json!({"type": "range.unmerge", "sheet_id": 1, "range": "B2"}),
    )
    .doc;
    assert!(workbook_sheet(&unmerged, 1).merges.is_empty());
    assert!(
        rejects(
            &doc,
            json!({"type": "range.merge", "sheet_id": 1, "range": "A1"})
        )
        .contains("two cells")
    );
}

#[test]
fn lines_resize_hide_and_freeze() {
    let doc = apply_all(
        &blank(),
        &[
            json!({"type": "line.resize", "sheet_id": 1, "axis": "cols", "start": 0, "end": 1, "size_px": 120}),
            json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 4, "end": 4, "size_px": "hidden"}),
            json!({"type": "sheet.freeze", "sheet_id": 1, "rows": 1, "cols": 2}),
        ],
    );
    let sheet = workbook_sheet(&doc, 1);
    assert_eq!(sheet.col_width(1), 120.0);
    assert!(sheet.is_row_hidden(4));
    assert_eq!(sheet.freeze, Some((1, 2)));
    let shown = apply_all(
        &doc,
        &[
            json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 4, "end": 4, "size_px": "unhide"}),
            json!({"type": "line.resize", "sheet_id": 1, "axis": "cols", "start": 0, "end": 1, "size_px": "auto"}),
            json!({"type": "sheet.freeze", "sheet_id": 1, "rows": 0, "cols": 0}),
        ],
    );
    let sheet = workbook_sheet(&shown, 1);
    assert!(!sheet.is_row_hidden(4) && sheet.cols.is_empty() && sheet.freeze.is_none());
    assert!(rejects(&doc, json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 0, "end": 0, "size_px": 5000})).contains("size_px"));
}

#[test]
fn inserting_and_deleting_lines_moves_cells_and_rewrites_formulas() {
    let doc = apply_all(
        &blank(),
        &[
            set(1, "B1", "1"),
            set(1, "B2", "2"),
            set(1, "B5", "5"),
            set(1, "C5", "=SUM(B1:B5)"),
            json!({"type": "range.merge", "sheet_id": 1, "range": "D4:E5"}),
            json!({"type": "sheet.insert", "name": "Other"}),
        ],
    );
    let other = crate::support::sheet_id(&doc, "Other");
    let doc = apply(&doc, set(other, "A1", "=Sheet1!B5*2")).doc;
    let inserted = apply(
        &doc,
        json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": 2, "count": 3}),
    )
    .doc;
    assert_eq!(formula(&inserted, 1, "C8").as_deref(), Some("=SUM(B1:B8)"));
    assert_eq!(number(&inserted, 1, "B8"), 5.0);
    assert_eq!(
        formula(&inserted, other, "A1").as_deref(),
        Some("=Sheet1!B8*2"),
        "references on other sheets follow"
    );
    assert_eq!(
        workbook_sheet(&inserted, 1).merges,
        vec![gridcraft_core::RangeRef::new(cell("D7"), cell("E8"))]
    );
    assert_eq!(number(&inserted, other, "A1"), 10.0);

    let deleted = apply(
        &inserted,
        json!({"type": "line.delete", "sheet_id": 1, "axis": "rows", "at": 1, "count": 1}),
    )
    .doc;
    assert_eq!(formula(&deleted, 1, "C7").as_deref(), Some("=SUM(B1:B7)"));
    assert_eq!(number(&deleted, 1, "C7"), 6.0);
    let referenced = apply(
        &inserted,
        json!({"type": "line.delete", "sheet_id": 1, "axis": "rows", "at": 7, "count": 1}),
    )
    .doc;
    assert_eq!(
        value(&referenced, other, "A1"),
        Value::Error(CellError::Ref),
        "references to deleted cells become #REF!"
    );
    let columns = apply(
        &doc,
        json!({"type": "line.insert", "sheet_id": 1, "axis": "cols", "at": 0, "count": 1}),
    )
    .doc;
    assert_eq!(formula(&columns, 1, "D5").as_deref(), Some("=SUM(C1:C5)"));
    assert!(rejects(&doc, json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": 1_048_575, "count": 2})).contains("fit"));
}

#[test]
fn inserting_and_deleting_cells_shifts_only_the_covered_lines() {
    let doc = apply_all(
        &blank(),
        &[set(1, "A1", "1"), set(1, "B1", "2"), set(1, "D1", "=A1+B1")],
    );
    let down = apply(
        &doc,
        json!({"type": "cells.insert", "sheet_id": 1, "range": "A1", "shift": "down"}),
    )
    .doc;
    assert_eq!(number(&down, 1, "A2"), 1.0);
    assert_eq!(number(&down, 1, "B1"), 2.0);
    assert_eq!(formula(&down, 1, "D1").as_deref(), Some("=A2+B1"));
    let left = apply(
        &doc,
        json!({"type": "cells.delete", "sheet_id": 1, "range": "A1", "shift": "left"}),
    )
    .doc;
    assert_eq!(number(&left, 1, "A1"), 2.0);
    assert_eq!(formula(&left, 1, "C1").as_deref(), Some("=#REF!+A1"));
    assert!(
        rejects(
            &doc,
            json!({"type": "cells.insert", "sheet_id": 1, "range": "A1", "shift": "up"})
        )
        .contains("down or right")
    );
}

#[test]
fn moving_a_block_carries_its_cells_and_redirects_references() {
    let doc = apply_all(
        &blank(),
        &[
            set(1, "A1", "3"),
            set(1, "A2", "=A1*2"),
            set(1, "C1", "=A2"),
            json!({"type": "comment.set", "sheet_id": 1, "cell": "A1", "text": "moved note"}),
            json!({"type": "sheet.insert", "name": "Archive"}),
        ],
    );
    let moved = apply(&doc, json!({"type": "range.move", "sheet_id": 1, "from": "A1:A2", "to_sheet_id": 1, "to_cell": "E5"})).doc;
    assert_eq!(value(&moved, 1, "A1"), Value::Empty);
    assert_eq!(formula(&moved, 1, "E6").as_deref(), Some("=E5*2"));
    assert_eq!(formula(&moved, 1, "C1").as_deref(), Some("=E6"));
    assert!(workbook_sheet(&moved, 1).comments.contains_key(&cell("E5")));
    let archive = crate::support::sheet_id(&doc, "Archive");
    let away = apply(&doc, json!({"type": "range.move", "sheet_id": 1, "from": "A1:A2", "to_sheet_id": archive, "to_cell": "B2"})).doc;
    assert_eq!(
        formula(&away, archive, "B3").as_deref(),
        Some("=Archive!B2*2")
    );
    assert_eq!(formula(&away, 1, "C1").as_deref(), Some("=Archive!B3"));
    assert_eq!(number(&away, 1, "C1"), 6.0);
}

#[test]
fn sheets_insert_rename_reorder_color_and_delete() {
    let inserted = apply(&blank(), json!({"type": "sheet.insert"}));
    assert_eq!(
        serde_json::to_value(&inserted.op).ok(),
        Some(json!({"type": "sheet.insert", "sheet_id": 2, "name": "Sheet2", "index": 1}))
    );
    let doc = apply_all(
        &inserted.doc,
        &[set(2, "A1", "7"), set(1, "A1", "=Sheet2!A1")],
    );
    let renamed = apply(
        &doc,
        json!({"type": "sheet.rename", "sheet_id": 2, "name": "华东区"}),
    );
    assert_eq!(
        serde_json::to_value(&renamed.op).ok(),
        Some(
            json!({"type": "sheet.rename", "sheet_id": 2, "name": "华东区", "old_name": "Sheet2"})
        )
    );
    assert_eq!(
        formula(&renamed.doc, 1, "A1").as_deref(),
        Some("=华东区!A1")
    );
    let reordered = apply(
        &renamed.doc,
        json!({"type": "sheet.reorder", "sheet_id": 2, "index": 0}),
    )
    .doc;
    assert_eq!(
        reordered
            .workbook()
            .sheets
            .iter()
            .map(|s| s.file_id)
            .collect::<Vec<_>>(),
        vec![2, 1]
    );
    let colored = apply(
        &reordered,
        json!({"type": "sheet.tab_color", "sheet_id": 2, "color": "#336699"}),
    )
    .doc;
    assert_eq!(
        workbook_sheet(&colored, 2).tab_color,
        Some(Color::Rgb(0x336699))
    );
    let deleted = apply(&colored, json!({"type": "sheet.delete", "sheet_id": 2}));
    assert_eq!(
        serde_json::to_value(&deleted.op).ok(),
        Some(json!({"type": "sheet.delete", "sheet_id": 2, "name": "华东区"}))
    );
    assert_eq!(value(&deleted.doc, 1, "A1"), Value::Error(CellError::Ref));
    assert!(
        rejects(&deleted.doc, json!({"type": "sheet.delete", "sheet_id": 1}))
            .contains("at least one visible")
    );
    assert!(rejects(&doc, json!({"type": "sheet.insert", "name": "sheet2"})).contains("taken"));
    assert!(rejects(&doc, json!({"type": "sheet.insert", "sheet_id": 1})).contains("in use"));
}

#[test]
fn sorting_moves_whole_rows_below_the_header() {
    let doc = apply(
        &blank(),
        json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:B4", "values": [["名称", "数量"], ["b", 2], ["c", 3], ["a", 1]]}),
    )
    .doc;
    let doc = apply(&doc, set(1, "C2", "=B2*10")).doc;
    let sorted = apply(&doc, json!({"type": "range.sort", "sheet_id": 1, "range": "A1:C4", "keys": [{"col": "B", "descending": true}], "header": true})).doc;
    assert_eq!(text(&sorted, 1, "A1"), "名称");
    assert_eq!(
        [
            text(&sorted, 1, "A2"),
            text(&sorted, 1, "A3"),
            text(&sorted, 1, "A4")
        ],
        ["c", "b", "a"]
    );
    assert_eq!(
        formula(&sorted, 1, "C3").as_deref(),
        Some("=B3*10"),
        "a formula moves with its row like a copy"
    );
    assert_eq!(number(&sorted, 1, "C3"), 20.0);
    assert!(
        rejects(
            &doc,
            json!({"type": "range.sort", "sheet_id": 1, "range": "A1:B4", "keys": [{"col": "D"}]})
        )
        .contains("inside the range")
    );
}

#[test]
fn filters_hide_failing_rows_and_removal_shows_them() {
    let doc = apply(
        &blank(),
        json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:A5", "values": [["地区"], ["上海"], ["北京"], ["上海"], [null]]}),
    )
    .doc;
    let filtered = apply(&doc, json!({"type": "filter.set", "sheet_id": 1, "range": "A1:A5", "columns": [{"col": "A", "values": ["上海"]}]})).doc;
    let sheet = workbook_sheet(&filtered, 1);
    assert_eq!(
        (1..5)
            .map(|row| sheet.is_row_hidden(row))
            .collect::<Vec<_>>(),
        vec![false, true, false, true]
    );
    assert!(matches!(
        sheet.autofilter.as_ref().and_then(|f| f.criteria.first()),
        Some((0, FilterCriterion::Values { .. }))
    ));
    let removed = apply(
        &filtered,
        json!({"type": "filter.set", "sheet_id": 1, "range": null}),
    )
    .doc;
    let sheet = workbook_sheet(&removed, 1);
    assert!(sheet.autofilter.is_none() && (1..5).all(|row| !sheet.is_row_hidden(row)));
}

#[test]
fn validations_replace_the_rule_of_their_range() {
    let rule = json!({"kind": "list", "formula1": "是,否"});
    let doc = apply(
        &blank(),
        json!({"type": "validation.set", "sheet_id": 1, "range": "A1:A10", "rule": rule}),
    )
    .doc;
    let validation = workbook_sheet(&doc, 1)
        .validations
        .first()
        .cloned()
        .expect("a validation");
    assert_eq!(validation.f1, "\"是,否\"");
    let narrowed = apply(
        &doc,
        json!({"type": "validation.set", "sheet_id": 1, "range": "A3:A4", "rule": null}),
    )
    .doc;
    let ranges = &workbook_sheet(&narrowed, 1)
        .validations
        .first()
        .expect("the rest of the rule")
        .ranges;
    assert_eq!(ranges.iter().map(|r| r.count()).sum::<u64>(), 8);
    let bounded = json!({"type": "validation.set", "sheet_id": 1, "range": "B1", "rule": {"kind": "whole", "operator": "between", "formula1": "1", "formula2": "=A1*2"}});
    assert_eq!(
        workbook_sheet(&apply(&doc, bounded).doc, 1)
            .validations
            .len(),
        2
    );
    assert!(rejects(&doc, json!({"type": "validation.set", "sheet_id": 1, "range": "B1", "rule": {"kind": "whole", "formula1": "many"}})).contains("many"));
}

#[test]
fn notes_are_set_and_removed() {
    let doc = apply(&blank(), json!({"type": "comment.set", "sheet_id": 1, "cell": "B2", "text": "核对金额", "author": "张三"})).doc;
    let note = workbook_sheet(&doc, 1)
        .comments
        .get(&cell("B2"))
        .cloned()
        .expect("a note");
    assert_eq!(
        (note.author.as_str(), note.text.as_str()),
        ("张三", "核对金额")
    );
    let removed = apply(
        &doc,
        json!({"type": "comment.set", "sheet_id": 1, "cell": "B2", "text": null}),
    )
    .doc;
    assert!(workbook_sheet(&removed, 1).comments.is_empty());
}

#[test]
fn tables_are_created_with_header_columns_and_converted_back() {
    let doc = apply(&blank(), json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:C2", "values": [["区域", null, "区域"], ["x", 1, 2]]})).doc;
    let created = apply(
        &doc,
        json!({"type": "table.toggle", "sheet_id": 1, "range": "A1:C2", "enabled": true}),
    );
    assert_eq!(
        serde_json::to_value(&created.op)
            .ok()
            .and_then(|op| op.get("name").cloned()),
        Some(json!("Table1"))
    );
    let table = workbook_sheet(&created.doc, 1)
        .tables
        .first()
        .cloned()
        .expect("a table");
    assert_eq!(
        table
            .columns
            .iter()
            .map(|c| c.name.as_str())
            .collect::<Vec<_>>(),
        vec!["区域", "Column2", "区域2"]
    );
    assert_eq!(text(&created.doc, 1, "B1"), "Column2");
    let doc = apply(&created.doc, set(1, "E1", "=SUM(Table1[Column2])")).doc;
    assert_eq!(number(&doc, 1, "E1"), 1.0);
    assert!(
        rejects(
            &doc,
            json!({"type": "table.toggle", "sheet_id": 1, "range": "B1:D3", "enabled": true})
        )
        .contains("overlap")
    );
    let removed = apply(
        &doc,
        json!({"type": "table.toggle", "sheet_id": 1, "range": "B2", "enabled": false}),
    );
    assert!(workbook_sheet(&removed.doc, 1).tables.is_empty());
    assert_eq!(value(&removed.doc, 1, "E1"), Value::Error(CellError::Ref));
}

#[test]
fn replaying_committed_operations_reproduces_the_same_file() {
    let (base, exported) = ankole_spreadsheet::create_blank("Replay").expect("blank workbook");
    let ops = [
        set(1, "A1", "10"),
        json!({"type": "sheet.insert", "name": "明细"}),
        set(1, "A2", "=A1*3"),
        json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": 0, "count": 2}),
        json!({"type": "range.format", "sheet_id": 1, "range": "A3:A4", "patch": {"num_fmt": "#,##0.00"}}),
        json!({"type": "range.sort", "sheet_id": 1, "range": "A3:A4", "keys": [{"col": "A", "descending": true}]}),
    ];
    let mut live = base;
    let mut committed = Vec::new();
    for op in ops {
        let applied = apply(&live, op);
        committed.push(serde_json::to_value(&applied.op).expect("committed op"));
        live = applied.doc;
    }
    let replayed = ankole_spreadsheet::open(
        &exported.xlsx,
        &serde_json::Value::Array(committed).to_string(),
    )
    .expect("replay");
    let bytes = |doc| ankole_spreadsheet::export_xlsx(doc).expect("export").xlsx;
    assert_eq!(bytes(&live), bytes(&replayed));
    // Sorting moves `=A3*3` up one row like a copy, so it reads the blank A2 afterwards.
    assert_eq!(
        (
            formula(&replayed, 1, "A3").as_deref(),
            number(&replayed, 1, "A4")
        ),
        (Some("=A2*3"), 10.0)
    );
}

#[test]
fn blank_workbooks_export_search_text_and_metadata() {
    let (doc, exported) = ankole_spreadsheet::create_blank("预算").expect("blank workbook");
    assert_eq!(
        exported
            .metadata
            .sheets
            .first()
            .map(|s| (s.sheet_id, s.name.as_str())),
        Some((1, "Sheet1"))
    );
    assert!(exported.xlsx.len() < 16 * 1024);
    let doc = apply(&doc, set(1, "A1", "季度预算")).doc;
    let exported = ankole_spreadsheet::export_xlsx(&doc).expect("export");
    assert_eq!(exported.plain_text, "Sheet1\n季度预算\n");
    assert_eq!(
        serde_json::to_value(&exported.metadata).ok(),
        Some(json!({
            "sheets": [{"sheet_id": 1, "name": "Sheet1", "rows": 1, "cols": 1, "hidden": false}],
            "warnings": [],
            "has_unsupported_objects": false
        }))
    );
}
