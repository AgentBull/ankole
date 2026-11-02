//! Editing tools of the spreadsheet editor: the fill handle, pasting, selection statistics, and
//! the function list.

use ankole_spreadsheet::{ApplyError, CellArea, Error, ImageId, SelectionStats, SheetId};
use serde_json::json;

use crate::support::{apply, apply_all, blank, cell, formula, number, text, workbook_sheet};

fn set(at: &str, input: &str) -> serde_json::Value {
    json!({"type": "cell.set", "sheet_id": 1, "cell": at, "input": input})
}

fn fill(range: &str, to: &str) -> serde_json::Value {
    json!({"type": "range.fill", "sheet_id": 1, "range": range, "to": to})
}

#[test]
fn filling_down_continues_numbers_dates_numbered_text_and_named_lists() {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "1"),
            set("A2", "3"),
            set("B1", "7"),
            set("C1", "2026-03-30"),
            set("D1", "第1组"),
            set("E1", "No.008"),
            set("F1", "星期六"),
            set("G1", "Mar"),
            set("G2", "May"),
            set("H1", "0.1"),
            set("H2", "0.2"),
        ],
    );
    let filled = apply_all(
        &doc,
        &[
            fill("A1:A2", "A1:A5"),
            fill("B1:F1", "B1:F4"),
            fill("G1:H2", "G1:H4"),
        ],
    );
    assert_eq!(number(&filled, 1, "A5"), 9.0, "1, 3 continues by 2");
    assert_eq!(
        number(&filled, 1, "B4"),
        10.0,
        "a lone number counts up by one"
    );
    assert_eq!(number(&filled, 1, "C3") - number(&doc, 1, "C1"), 2.0);
    let date_format = |a1: &str| {
        let sheet = workbook_sheet(&filled, 1);
        let style = sheet.cell(cell(a1)).map(|c| c.style).unwrap_or_default();
        filled
            .workbook()
            .styles
            .get(style)
            .num_fmt
            .as_str()
            .to_string()
    };
    assert_eq!(
        date_format("C3"),
        date_format("C1"),
        "the date format repeats"
    );
    assert_eq!(text(&filled, 1, "D3"), "第3组");
    assert_eq!(text(&filled, 1, "E4"), "No.011", "zero padding is kept");
    assert_eq!(text(&filled, 1, "F2"), "星期日");
    assert_eq!(text(&filled, 1, "F3"), "星期一", "a list wraps around");
    assert_eq!(
        text(&filled, 1, "G4"),
        "Sep",
        "Mar, May steps by two months"
    );
    assert_eq!(
        number(&filled, 1, "H4"),
        0.4,
        "binary noise is rounded away"
    );
}

#[test]
fn filling_copies_formulas_with_relative_references_and_repeats_mixed_sources() {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "10"),
            set("A2", "20"),
            set("A3", "30"),
            set("B1", "=A1*2"),
            set("C1", "=$A$1+A1"),
            set("D1", "苹果"),
            set("D2", "5"),
        ],
    );
    let filled = apply_all(&doc, &[fill("B1:C1", "B1:C3"), fill("D1:D2", "D1:D6")]);
    assert_eq!(formula(&filled, 1, "B3").as_deref(), Some("=A3*2"));
    assert_eq!(number(&filled, 1, "B3"), 60.0);
    assert_eq!(formula(&filled, 1, "C2").as_deref(), Some("=$A$1+A2"));
    assert_eq!(text(&filled, 1, "D5"), "苹果", "a mixed source repeats");
    assert_eq!(number(&filled, 1, "D6"), 5.0);

    let copied = apply(
        &doc,
        json!({"type": "range.fill", "sheet_id": 1, "range": "A1:A2", "to": "A1:A4", "mode": "copy"}),
    )
    .doc;
    assert_eq!(
        number(&copied, 1, "A3"),
        10.0,
        "copy mode repeats the numbers"
    );
    assert_eq!(number(&copied, 1, "A4"), 20.0);
}

#[test]
fn filling_up_and_left_counts_backwards() {
    let doc = apply_all(
        &blank(),
        &[set("C5", "5"), set("C6", "6"), set("E1", "Item 3")],
    );
    let filled = apply_all(&doc, &[fill("C5:C6", "C2:C6"), fill("E1", "B1:E1")]);
    assert_eq!(number(&filled, 1, "C2"), 2.0);
    assert_eq!(text(&filled, 1, "B1"), "Item 0");
}

#[test]
fn a_fill_must_extend_its_source_past_one_edge() {
    let doc = apply(&blank(), set("A1", "1")).doc;
    for to in ["B2:C3", "A1:B2", "B1:B3"] {
        let result = ankole_spreadsheet::apply(&doc, &fill("A1", to).to_string(), "[]");
        assert!(
            matches!(result, Err(ApplyError::Error(Error::Invalid(ref message))) if message.contains("range.fill")),
            "{to}: {result:?}"
        );
    }
    let unchanged = apply(&doc, fill("A1", "A1"));
    assert_eq!(number(&unchanged.doc, 1, "A1"), 1.0);
}

#[test]
fn selection_statistics_count_values_and_summarize_numbers() -> Result<(), Error> {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "4"),
            set("A2", "6"),
            set("A3", "说明"),
            set("A4", "=A1+A2"),
            set("B1", "TRUE"),
        ],
    );
    let stats = ankole_spreadsheet::selection_stats(&doc, SheetId(1), "A:B")?;
    assert_eq!(
        stats,
        SelectionStats {
            count: 5,
            numbers: 3,
            sum: 20.0,
            average: Some(20.0 / 3.0),
            min: Some(4.0),
            max: Some(10.0),
        }
    );
    let empty = ankole_spreadsheet::selection_stats(&doc, SheetId(1), "D1:D9")?;
    assert_eq!(empty, SelectionStats::default());
    assert!(ankole_spreadsheet::selection_stats(&doc, SheetId(1), "not a range").is_err());
    Ok(())
}

/// A 1×1 PNG.
const PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

fn picture() -> serde_json::Value {
    json!({"mime": "image/png", "data": PNG, "alt": "Logo"})
}

fn anchor(at: &str) -> serde_json::Value {
    json!({"cell": at, "dx": 4, "dy": 2, "width": 120, "height": 80})
}

fn op_json(op: &ankole_spreadsheet::Op) -> serde_json::Value {
    serde_json::to_value(op).unwrap_or_default()
}

fn png_bytes() -> Vec<u8> {
    base64_simd::STANDARD
        .decode_to_vec(PNG.as_bytes())
        .unwrap_or_default()
}

#[test]
fn floating_pictures_are_inserted_moved_saved_and_deleted() -> Result<(), Error> {
    let doc = apply(
        &blank(),
        json!({"type": "image.insert", "sheet_id": 1, "image_id": 7001, "anchor": anchor("B3"), "picture": picture()}),
    );
    assert_eq!(op_json(&doc.op)["image_id"], 7001);
    let auto = apply(
        &doc.doc,
        json!({"type": "image.insert", "sheet_id": 1, "anchor": anchor("D1"), "picture": picture()}),
    );
    assert_eq!(
        op_json(&auto.op)["image_id"],
        7002,
        "an absent id takes the next object id"
    );
    let moved = apply(
        &auto.doc,
        json!({"type": "image.update", "sheet_id": 1, "image_id": 7001, "anchor": {"cell": "C5", "width": 60, "height": 40}}),
    )
    .doc;
    let images = ankole_spreadsheet::images(&moved, SheetId(1))?;
    assert_eq!(images.len(), 2);
    assert_eq!(
        (images[0].cell.as_str(), images[0].width, images[0].dx),
        ("C5", 60.0, 0.0)
    );
    assert_eq!(images[0].alt, "Logo");
    assert_eq!(
        ankole_spreadsheet::image_data(&moved, SheetId(1), ImageId(7001))?,
        png_bytes()
    );

    // A row inserted above moves the picture down with its cell.
    let shifted = apply(
        &moved,
        json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": 0, "count": 2}),
    )
    .doc;
    assert_eq!(
        ankole_spreadsheet::images(&shifted, SheetId(1))?[0].cell,
        "C7"
    );

    let reopened =
        ankole_spreadsheet::open(&ankole_spreadsheet::export_xlsx(&shifted)?.xlsx, "[]")?;
    let saved = ankole_spreadsheet::images(&reopened, SheetId(1))?;
    assert_eq!(saved.len(), 2, "the file keeps both pictures");
    assert_eq!(saved[0].cell, "C7");
    assert_eq!(saved[0].digest, images[0].digest);

    let deleted = apply(
        &shifted,
        json!({"type": "image.delete", "sheet_id": 1, "image_id": 7002}),
    )
    .doc;
    assert_eq!(ankole_spreadsheet::images(&deleted, SheetId(1))?.len(), 1);
    Ok(())
}

#[test]
fn cell_pictures_replace_content_and_convert_to_floating_pictures() -> Result<(), Error> {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "5"),
            set("A2", "=A1*2"),
            json!({"type": "cell.picture", "sheet_id": 1, "cell": "A1", "picture": picture()}),
        ],
    );
    assert_eq!(
        ankole_spreadsheet::cell_picture(&doc, SheetId(1), "A1")?,
        ankole_spreadsheet::CellPictureData {
            bytes: png_bytes(),
            mime: "image/png".to_string()
        }
    );
    assert_eq!(
        number(&doc, 1, "A2"),
        0.0,
        "the picture replaced the number"
    );
    let view = ankole_spreadsheet::viewport(
        &doc,
        SheetId(1),
        CellArea {
            first_row: 0,
            first_col: 0,
            last_row: 1,
            last_col: 0,
        },
    )?;
    assert!(view.cells[0].picture.is_some());

    let reopened = ankole_spreadsheet::open(&ankole_spreadsheet::export_xlsx(&doc)?.xlsx, "[]")?;
    assert!(ankole_spreadsheet::cell_picture(&reopened, SheetId(1), "A1").is_ok());

    let lifted = apply(
        &doc,
        json!({"type": "image.from_cell", "sheet_id": 1, "cell": "A1", "image_id": 9, "anchor": anchor("A1")}),
    )
    .doc;
    assert!(ankole_spreadsheet::cell_picture(&lifted, SheetId(1), "A1").is_err());
    assert_eq!(
        ankole_spreadsheet::images(&lifted, SheetId(1))?[0].image_id,
        ImageId(9)
    );
    let placed = apply(
        &lifted,
        json!({"type": "image.to_cell", "sheet_id": 1, "image_id": 9, "cell": "B4"}),
    )
    .doc;
    assert!(ankole_spreadsheet::images(&placed, SheetId(1))?.is_empty());
    assert!(ankole_spreadsheet::cell_picture(&placed, SheetId(1), "B4").is_ok());

    let typed = apply(&placed, set("B4", "替换")).doc;
    assert!(
        ankole_spreadsheet::cell_picture(&typed, SheetId(1), "B4").is_err(),
        "typing replaces the picture"
    );
    assert_eq!(text(&typed, 1, "B4"), "替换");
    Ok(())
}

#[test]
fn pictures_must_be_valid_and_ids_unique() {
    let doc = apply(
        &blank(),
        json!({"type": "image.insert", "sheet_id": 1, "image_id": 3, "anchor": anchor("A1"), "picture": picture()}),
    )
    .doc;
    let rejected =
        |op: serde_json::Value| match ankole_spreadsheet::apply(&doc, &op.to_string(), "[]") {
            Err(ApplyError::Error(Error::Invalid(message))) => message,
            other => panic!("{op} was accepted: {other:?}"),
        };
    let jpeg_label = json!({"mime": "image/jpeg", "data": PNG});
    assert!(rejected(json!({"type": "image.insert", "sheet_id": 1, "anchor": anchor("A1"), "picture": jpeg_label})).contains("image/jpeg"));
    assert!(rejected(json!({"type": "image.insert", "sheet_id": 1, "image_id": 3, "anchor": anchor("A1"), "picture": picture()})).contains("in use"));
    assert!(rejected(json!({"type": "image.update", "sheet_id": 1, "image_id": 3, "anchor": {"cell": "A1", "width": 0, "height": 5}})).contains("size"));
    assert!(
        rejected(json!({"type": "image.delete", "sheet_id": 1, "image_id": 4}))
            .contains("image_id 4")
    );
    let huge = base64_simd::STANDARD.encode_to_string(
        [
            b"\x89PNG\r\n\x1a\n".as_slice(),
            &vec![0; ankole_spreadsheet::MAX_PICTURE_BYTES],
        ]
        .concat(),
    );
    assert!(rejected(json!({"type": "cell.picture", "sheet_id": 1, "cell": "A1", "picture": {"mime": "image/png", "data": huge}})).contains("bytes"));
    assert!(rejected(json!({"type": "image.insert", "sheet_id": 1, "anchor": anchor("A1"), "picture": {"mime": "image/png", "data": "not base64!"}})).contains("base64"));
}

#[test]
fn a_picture_inserted_concurrently_with_a_row_insert_follows_its_cell() {
    let doc = blank();
    let insert = json!({"type": "line.insert", "sheet_id": 1, "axis": "rows", "at": 1, "count": 3});
    let committed = apply(&doc, insert.clone()).doc;
    let image = json!({"type": "image.insert", "sheet_id": 1, "image_id": 11, "anchor": anchor("B5"), "picture": picture()});
    let rebased =
        ankole_spreadsheet::apply(&committed, &image.to_string(), &json!([insert]).to_string());
    let Ok(rebased) = rebased else {
        panic!("the picture must rebase: {rebased:?}");
    };
    assert_eq!(op_json(&rebased.op)["anchor"]["cell"], "B8");
}

#[test]
fn copied_blocks_paste_formulas_values_and_formats() -> Result<(), Error> {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "2"),
            set("A2", "3"),
            set("B1", "=A1*10"),
            set("B2", "=$A$1+A2"),
            json!({"type": "range.format", "sheet_id": 1, "range": "B1", "patch": {"bold": true, "fill_color": "#FFEE00", "num_fmt": "0.0"}}),
            json!({"type": "range.format", "sheet_id": 1, "range": "D4", "patch": {"italic": true}}),
        ],
    );
    let block = ankole_spreadsheet::copy_block(&doc, SheetId(1), "A1:B2")?;
    assert_eq!(block.origin, "A1");
    assert_eq!(block.rows[0][1].input, "=A1*10");
    assert_eq!(block.rows[0][1].value, "20");
    assert_eq!(block.rows[0][1].text, "20.0");

    let all =
        ankole_spreadsheet::paste_op(&block, SheetId(1), "C3", ankole_spreadsheet::PasteMode::All)?;
    let pasted = apply(&doc, serde_json::to_value(&all).unwrap_or_default()).doc;
    assert_eq!(formula(&pasted, 1, "D3").as_deref(), Some("=C3*10"));
    assert_eq!(formula(&pasted, 1, "D4").as_deref(), Some("=$A$1+C4"));
    assert_eq!(number(&pasted, 1, "D4"), 5.0);
    let style = |doc: &ankole_spreadsheet::SpreadsheetDoc, a1: &str| {
        let sheet = workbook_sheet(doc, 1);
        doc.workbook().styles.get(sheet.style_id(cell(a1))).clone()
    };
    assert!(style(&pasted, "D3").font.bold);
    assert_eq!(style(&pasted, "D3").num_fmt.as_str(), "0.0");
    assert!(
        !style(&pasted, "D4").font.italic,
        "a full paste replaces the old format"
    );

    let values = ankole_spreadsheet::paste_op(
        &block,
        SheetId(1),
        "C3",
        ankole_spreadsheet::PasteMode::Values,
    )?;
    let pasted = apply(&doc, serde_json::to_value(&values).unwrap_or_default()).doc;
    assert_eq!(formula(&pasted, 1, "D3"), None);
    assert_eq!(number(&pasted, 1, "D3"), 20.0);
    assert!(
        style(&pasted, "D4").font.italic,
        "pasting values keeps the destination format"
    );

    let formats = ankole_spreadsheet::paste_op(
        &block,
        SheetId(1),
        "C3",
        ankole_spreadsheet::PasteMode::Formats,
    )?;
    let pasted = apply(
        &apply(&doc, set("D3", "keep")).doc,
        serde_json::to_value(&formats).unwrap_or_default(),
    )
    .doc;
    assert_eq!(text(&pasted, 1, "D3"), "keep");
    assert!(style(&pasted, "D3").font.bold);
    Ok(())
}

#[test]
fn fills_can_skip_formats_or_copy_only_formats() {
    let doc = apply_all(
        &blank(),
        &[
            set("A1", "1"),
            set("A2", "2"),
            json!({"type": "range.format", "sheet_id": 1, "range": "A1:A2", "patch": {"bold": true}}),
            set("A3", "keep"),
            json!({"type": "range.format", "sheet_id": 1, "range": "A4", "patch": {"italic": true}}),
        ],
    );
    let font = |doc: &ankole_spreadsheet::SpreadsheetDoc, a1: &str| {
        let sheet = workbook_sheet(doc, 1);
        doc.workbook()
            .styles
            .get(sheet.style_id(cell(a1)))
            .font
            .clone()
    };
    let values = apply(
        &doc,
        json!({"type": "range.fill", "sheet_id": 1, "range": "A1:A2", "to": "A1:A4", "mode": "values"}),
    )
    .doc;
    assert_eq!(number(&values, 1, "A4"), 4.0);
    assert!(
        !font(&values, "A4").bold && font(&values, "A4").italic,
        "the filled cell keeps its format"
    );
    let formats = apply(
        &doc,
        json!({"type": "range.fill", "sheet_id": 1, "range": "A1:A2", "to": "A1:A4", "mode": "formats"}),
    )
    .doc;
    assert_eq!(text(&formats, 1, "A3"), "keep");
    assert!(font(&formats, "A3").bold && font(&formats, "A4").bold);
}

fn format(range: &str, patch: serde_json::Value) -> serde_json::Value {
    json!({"type": "range.format", "sheet_id": 1, "range": range, "patch": patch})
}

fn row_size(doc: &ankole_spreadsheet::SpreadsheetDoc, row: u32) -> Option<f32> {
    workbook_sheet(doc, 1)
        .rows
        .get(&row)
        .and_then(|info| info.size)
}

#[test]
fn rows_grow_with_large_fonts_and_wrapped_text_unless_their_height_was_set() {
    let doc = apply_all(
        &blank(),
        &[set("A1", "dasd啊"), format("A1", json!({"font_size": 24}))],
    );
    let grown = row_size(&doc, 0).unwrap_or_default();
    assert!(grown > 40.0, "a 24 pt font needs a taller row, got {grown}");
    let back = apply(&doc, format("A1", json!({"font_size": 11}))).doc;
    assert_eq!(
        row_size(&back, 0),
        None,
        "the row returns to the default height"
    );

    let wrapped = apply_all(
        &blank(),
        &[
            set(
                "B2",
                "一段很长很长的说明文字，会在这一列里折成好几行显示出来",
            ),
            format("B2", json!({"wrap": true})),
        ],
    );
    assert!(row_size(&wrapped, 1).unwrap_or_default() > 40.0);
    let cleared = apply(
        &wrapped,
        json!({"type": "range.clear", "sheet_id": 1, "range": "B2", "mode": "contents"}),
    )
    .doc;
    assert_eq!(row_size(&cleared, 1), None);

    let fixed = apply_all(
        &blank(),
        &[
            json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 2, "end": 2, "size_px": 18}),
            set("A3", "固定"),
            format("A3", json!({"font_size": 36})),
        ],
    );
    assert_eq!(
        row_size(&fixed, 2),
        Some(18.0),
        "a height the author set stays"
    );
    let automatic = apply(
        &fixed,
        json!({"type": "line.resize", "sheet_id": 1, "axis": "rows", "start": 2, "end": 2, "size_px": "auto"}),
    )
    .doc;
    assert!(
        row_size(&automatic, 2).unwrap_or_default() > 50.0,
        "auto fits the content again"
    );
}

#[test]
fn a_format_snapshot_restores_cell_line_and_blank_cell_formats() -> Result<(), Error> {
    let doc = apply_all(
        &blank(),
        &[
            set("B2", "保留"),
            format("B2", json!({"italic": true, "indent": 2, "rotation": 45})),
            json!({"type": "cell.picture", "sheet_id": 1, "cell": "C3", "picture": picture()}),
            format("2:2", json!({"fill_color": "#FFEE00"})),
        ],
    );
    let style = |doc: &ankole_spreadsheet::SpreadsheetDoc, a1: &str| {
        let sheet = workbook_sheet(doc, 1);
        doc.workbook().styles.get(sheet.style_id(cell(a1))).clone()
    };
    let before = ["B2", "C3", "D4", "A2"].map(|a1| style(&doc, a1));
    let stored = workbook_sheet(&doc, 1).cells.iter().count();

    let snapshot = ankole_spreadsheet::format_snapshot(&doc, SheetId(1), "B2:D4")?;
    let formatted = apply(
        &doc,
        format("B2:D4", json!({"bold": true, "fill_color": "#FF0000"})),
    )
    .doc;
    assert!(style(&formatted, "D4").font.bold);
    let restored = apply(
        &formatted,
        json!({"type": "range.restore_formats", "sheet_id": 1, "range": "B2:D4", "lines": snapshot.lines, "cells": snapshot.cells}),
    )
    .doc;
    assert_eq!(
        ["B2", "C3", "D4", "A2"].map(|a1| style(&restored, a1)),
        before
    );
    assert_eq!(text(&restored, 1, "B2"), "保留");
    assert!(
        ankole_spreadsheet::cell_picture(&restored, SheetId(1), "C3").is_ok(),
        "the picture stays"
    );
    assert_eq!(
        workbook_sheet(&restored, 1).cells.iter().count(),
        stored,
        "blank cells the format added are gone again"
    );

    let lines = ankole_spreadsheet::format_snapshot(&doc, SheetId(1), "1:3")?;
    assert_eq!(lines.lines.len(), 1, "row 2 holds a line format");
    let reformatted = apply(&doc, format("1:3", json!({"font_color": "#0000FF"}))).doc;
    let undone = apply(
        &reformatted,
        json!({"type": "range.restore_formats", "sheet_id": 1, "range": "1:3", "lines": lines.lines, "cells": lines.cells}),
    )
    .doc;
    assert_eq!(style(&undone, "A2"), before[3]);
    assert!(
        workbook_sheet(&undone, 1)
            .rows
            .get(&0)
            .and_then(|info| info.style)
            .is_none()
    );
    assert!(
        workbook_sheet(&undone, 1)
            .rows
            .get(&2)
            .and_then(|info| info.style)
            .is_none()
    );
    Ok(())
}
