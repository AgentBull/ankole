//! Search text and outline metadata derived from a workbook, and what saving its source file drops.
//!
//! Both outputs are rebuildable caches: the control plane stores them beside the authoritative
//! `.xlsx` and regenerates them from it whenever needed.

use std::collections::BTreeMap;
use std::io::Read;

use gridcraft_core::{CellRef, RangeRef};
use gridcraft_model::{Sheet, Visibility, Workbook};
use serde::Serialize;

use crate::doc::SpreadsheetDoc;
use crate::ids::SheetId;
use crate::view::display_text;

/// Longest text kept for one workbook, in bytes. The control plane stores, indexes, and chunks
/// this text, so the limit bounds that work however large the workbook's tables are.
pub const PLAIN_TEXT_LIMIT: usize = 512 * 1024;

/// GridCraft reports these warnings for content it does not show but writes back unchanged, so
/// they do not mean that saving loses anything. Every other read warning reports something that
/// was skipped, simplified, or dropped.
const KEPT_ON_SAVE: &[&str] = &[
    "they are kept for saving",
    "were kept; they are not followed or refreshed",
    "were kept but not executed",
];

/// Content types of parts that GridCraft neither models nor passes through, which saving drops
/// without a read warning: slicers, timelines, the Power Pivot data model, and named sheet views.
const DROPPED_CONTENT_TYPES: &[&str] = &[
    "application/vnd.ms-excel.slicer+xml",
    "application/vnd.ms-excel.slicerCache+xml",
    "application/vnd.ms-excel.timeline+xml",
    "application/vnd.ms-excel.timelineCache+xml",
    "application/vnd.openxmlformats-officedocument.model+data",
    "application/vnd.ms-excel.namedsheetviews+xml",
];

/// The largest `[Content_Types].xml` read while looking for dropped parts.
const CONTENT_TYPES_LIMIT: u64 = 16 * 1024 * 1024;

/// What reading the source file reported. Opening a document keeps it, so every later export of
/// that document still warns about what the first save dropped.
#[derive(Debug, Default)]
pub(crate) struct SourceReport {
    pub warnings: Vec<String>,
    pub has_unsupported_objects: bool,
}

impl SourceReport {
    pub(crate) fn new(bytes: &[u8], warnings: Vec<String>) -> Self {
        let lossy = warnings
            .iter()
            .any(|warning| !KEPT_ON_SAVE.iter().any(|kept| warning.contains(kept)));
        Self {
            has_unsupported_objects: lossy || has_dropped_parts(bytes),
            warnings,
        }
    }
}

fn has_dropped_parts(bytes: &[u8]) -> bool {
    let Ok(mut archive) = zip::ZipArchive::new(std::io::Cursor::new(bytes)) else {
        return false;
    };
    let Ok(part) = archive.by_name("[Content_Types].xml") else {
        return false;
    };
    let mut content_types = String::new();
    if part
        .take(CONTENT_TYPES_LIMIT)
        .read_to_string(&mut content_types)
        .is_err()
    {
        return false;
    }
    DROPPED_CONTENT_TYPES
        .iter()
        .any(|content_type| content_types.contains(content_type))
}

/// The workbook outline the control plane caches for page metadata and the editor's first paint.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Metadata {
    /// The sheets in tab order.
    pub sheets: Vec<SheetSummary>,
    /// What reading the source file reported about the parts it could not keep.
    pub warnings: Vec<String>,
    /// Whether saving drops objects of the source file, such as slicers.
    pub has_unsupported_objects: bool,
    /// Whether the workbook's text is longer than [`PLAIN_TEXT_LIMIT`] and was cut there.
    pub truncated: bool,
}

/// One sheet in tab order. `rows` and `cols` count up to the last stored cell.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SheetSummary {
    /// The sheet's stable id.
    pub sheet_id: SheetId,
    /// The tab's name.
    pub name: String,
    /// Rows up to the last stored cell.
    pub rows: u32,
    /// Columns up to the last stored cell.
    pub cols: u32,
    /// Whether the tab is hidden.
    pub hidden: bool,
}

pub(crate) fn metadata(doc: &SpreadsheetDoc) -> Metadata {
    let sheets = doc
        .workbook()
        .sheets
        .iter()
        .map(|sheet| {
            let used = sheet.used_range();
            SheetSummary {
                sheet_id: SheetId(sheet.file_id),
                name: sheet.name.clone(),
                rows: used.map_or(0, |range| range.end.row + 1),
                cols: used.map_or(0, |range| range.end.col + 1),
                hidden: sheet.visibility != Visibility::Visible,
            }
        })
        .collect();
    let source = doc.source();
    Metadata {
        sheets,
        warnings: source.warnings.clone(),
        has_unsupported_objects: source.has_unsupported_objects,
        // shortcut: the flag costs a second pass over the workbook's text on open and on export;
        // derive the text and the outline in one call if that pass shows up in a profile.
        truncated: bounded_text(doc.workbook()).1,
    }
}

/// The workbook as text, one sheet after another, cut at [`PLAIN_TEXT_LIMIT`].
///
/// Each sheet starts with a `[Sheet: <name>]` line. Every row that shows something follows as
/// `R<row>\t<cell>\t<cell>...`: `<row>` is the 1-based row number, the cells run from column A,
/// a blank cell is an empty string between two tabs, and the blank cells after the last shown
/// one are dropped. A cell reads as the grid shows it, so numbers, dates, and formula results
/// carry their number format, and a tab or line break inside a cell becomes a space. A cell that
/// holds a picture is blank. A merged range taller than one row repeats its top-left text in its
/// first column on every later row that shows something, so each row carries the label it sits
/// under. The sheet's comments and their replies follow its rows as plain lines.
pub(crate) fn plain_text(wb: &Workbook) -> String {
    bounded_text(wb).0
}

/// [`plain_text`], and whether the limit cut it.
fn bounded_text(wb: &Workbook) -> (String, bool) {
    let mut out = String::new();
    for sheet in &wb.sheets {
        out.push_str(&format!("[Sheet: {}]\n", one_line(&sheet.name)));
        push_rows(&mut out, wb, sheet);
        if out.len() > PLAIN_TEXT_LIMIT {
            break;
        }
        for comment in sheet.comments.values() {
            push_line(&mut out, &comment.text);
            for (_, reply) in &comment.replies {
                push_line(&mut out, reply);
            }
        }
        if out.len() > PLAIN_TEXT_LIMIT {
            break;
        }
    }
    let truncated = out.len() > PLAIN_TEXT_LIMIT;
    (truncate(out), truncated)
}

/// Appends the rows of `sheet` that show something and stops once `out` passes the limit.
fn push_rows(out: &mut String, wb: &Workbook, sheet: &Sheet) {
    // The merged ranges that repeat a label, in the order the walk below reaches their rows.
    let mut merges: Vec<(RangeRef, String)> = sheet
        .merges
        .iter()
        .filter(|range| range.end.row > range.start.row)
        .map(|range| (*range, cell_text(wb, sheet, range.start)))
        .filter(|(_, text)| !text.is_empty())
        .collect();
    merges.sort_by_key(|(range, _)| range.start.row);
    let mut later = merges.iter().peekable();
    let mut open: Vec<&(RangeRef, String)> = Vec::new();

    let mut cells = sheet.cells.iter().peekable();
    while let Some(&(CellRef { row, .. }, _)) = cells.peek() {
        let mut shown = BTreeMap::new();
        while let Some((at, _)) = cells.next_if(|(at, _)| at.row == row) {
            let text = cell_text(wb, sheet, at);
            if !text.is_empty() {
                shown.insert(at.col, text);
            }
        }
        if shown.is_empty() {
            continue;
        }
        while let Some(merge) = later.next_if(|(range, _)| range.start.row < row) {
            open.push(merge);
        }
        open.retain(|(range, _)| range.end.row >= row);
        for (range, text) in &open {
            shown.entry(range.start.col).or_insert_with(|| text.clone());
        }

        out.push_str(&format!("R{}", row + 1));
        let mut next_col = 0;
        for (col, text) in &shown {
            out.extend(std::iter::repeat_n('\t', (col - next_col + 1) as usize));
            out.push_str(text);
            next_col = col + 1;
        }
        out.push('\n');
        if out.len() > PLAIN_TEXT_LIMIT {
            return;
        }
    }
}

/// What the grid shows in a stored cell, on one line; nothing for a cell that holds a picture.
fn cell_text(wb: &Workbook, sheet: &Sheet, at: CellRef) -> String {
    let Some(cell) = sheet.cells.get(at) else {
        return String::new();
    };
    let formula = cell.formula.as_deref();
    if (cell.value.is_empty() && formula.is_none())
        || sheet.cell_pictures.contains_key(&at)
        || formula.is_some_and(|formula| is_image_formula(&formula.text))
    {
        return String::new();
    }
    one_line(&display_text(wb, sheet, at))
}

/// Whether the formula, written with or without `=`, places a picture in its cell: WPS writes
/// `DISPIMG`, and Excel writes `IMAGE`, which files spell `_xlfn.IMAGE`.
fn is_image_formula(formula: &str) -> bool {
    let starts_with = |text: &str, prefix: &str| {
        text.get(..prefix.len())
            .is_some_and(|head| head.eq_ignore_ascii_case(prefix))
    };
    let call = formula.trim_start().trim_start_matches('=');
    let call = if starts_with(call, "_xlfn.") {
        &call[6..]
    } else {
        call
    };
    starts_with(call, "DISPIMG(") || starts_with(call, "IMAGE(")
}

fn one_line(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ").trim().to_owned()
}

fn push_line(out: &mut String, text: &str) {
    if !text.trim().is_empty() {
        out.push_str(text);
        out.push('\n');
    }
}

fn truncate(mut text: String) -> String {
    if text.len() > PLAIN_TEXT_LIMIT {
        let mut end = PLAIN_TEXT_LIMIT;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
    text
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use gridcraft_core::{CellRef, RangeRef, Value};
    use gridcraft_model::{Cell, Comment, Formula, NumFmt, Sheet, Style, Workbook};

    use super::{PLAIN_TEXT_LIMIT, bounded_text, plain_text};

    fn workbook(sheet: Sheet) -> Workbook {
        let mut wb = Workbook::new();
        wb.sheets = vec![Arc::new(sheet)];
        wb
    }

    #[test]
    fn plain_text_marks_the_sheet_numbers_its_rows_and_lists_comments() {
        let mut sheet = Sheet::new("华东区");
        sheet.set_value(CellRef::new(0, 0), Value::text("地区"));
        sheet.set_value(CellRef::new(0, 1), Value::text("收入"));
        sheet.set_value(CellRef::new(1, 0), Value::text("上海\n浦东"));
        sheet.set_value(CellRef::new(1, 1), Value::number(12.0));
        sheet.comments.insert(
            CellRef::new(1, 0),
            Comment {
                author: "a".into(),
                text: "核对".into(),
                replies: vec![],
                threaded: false,
                resolved: false,
                visible: false,
                dates: vec![],
                note_box: None,
            },
        );
        assert_eq!(
            bounded_text(&workbook(sheet)),
            (
                "[Sheet: 华东区]\nR1\t地区\t收入\nR2\t上海 浦东\t12\n核对\n".to_owned(),
                false
            )
        );
    }

    #[test]
    fn plain_text_shows_cells_as_the_grid_does_and_keeps_their_columns() {
        let mut wb = Workbook::new();
        let mut styled = |code: &str| {
            wb.styles.intern(Style {
                num_fmt: NumFmt::new(code),
                ..Style::default()
            })
        };
        let (amount, percent, date) = (styled("#,##0.00"), styled("0.0%"), styled("yyyy-mm-dd"));
        let mut sheet = Sheet::new("S");
        let mut set = |row, col, value, formula: Option<&str>, style| {
            let formula = formula.map(|text| Arc::new(Formula::new(text)));
            sheet.set_cell(
                CellRef::new(row, col),
                Cell {
                    value,
                    formula,
                    style,
                },
            );
        };
        set(0, 0, Value::number(1234.5), None, amount);
        set(0, 2, Value::number(0.125), None, percent);
        set(0, 4, Value::number(45292.0), None, date);
        set(2, 1, Value::number(3.0), Some("=1+2"), amount);
        set(2, 2, Value::Bool(true), None, amount);
        // Row 2 and the tail of row 3 hold pictures only.
        let dispimg = "=DISPIMG(\"ID_1\",1)";
        set(1, 0, Value::text(dispimg), Some(dispimg), amount);
        set(2, 3, Value::text("x"), Some("_xlfn.image(\"u\")"), amount);
        set(2, 4, Value::text("x"), Some("=IMAGE(\"u\")"), amount);
        wb.sheets = vec![Arc::new(sheet)];
        assert_eq!(
            plain_text(&wb),
            "[Sheet: S]\nR1\t1,234.50\t\t12.5%\t\t2024-01-01\nR3\t\t3.00\tTRUE\n"
        );
    }

    #[test]
    fn plain_text_repeats_a_tall_merge_down_its_first_column_only() {
        let mut sheet = Sheet::new("S");
        let mut text = |row, col, value: &str| {
            sheet.set_value(CellRef::new(row, col), Value::text(value));
        };
        // A1:B3 labels rows 1-3, and row 3 shows nothing else.
        text(0, 0, "华东");
        text(0, 2, "上海");
        text(1, 2, "杭州");
        // A5:C5 is one row tall.
        text(4, 0, "合计");
        text(5, 3, "9");
        sheet.merges = vec![
            RangeRef::new(CellRef::new(0, 0), CellRef::new(2, 1)),
            RangeRef::new(CellRef::new(4, 0), CellRef::new(4, 2)),
        ];
        assert_eq!(
            plain_text(&workbook(sheet)),
            "[Sheet: S]\nR1\t华东\t\t上海\nR2\t华东\t\t杭州\nR5\t合计\nR6\t\t\t\t9\n"
        );
    }

    #[test]
    fn plain_text_stops_at_the_limit_on_a_char_boundary() {
        let mut sheet = Sheet::new("S");
        for row in 0..60_000 {
            sheet.set_value(CellRef::new(row, 0), Value::text("中文内容"));
        }
        let (text, truncated) = bounded_text(&workbook(sheet));
        assert!(text.len() <= PLAIN_TEXT_LIMIT && text.len() > PLAIN_TEXT_LIMIT - 4);
        assert!(truncated);
    }
}
