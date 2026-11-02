//! Search text and outline metadata derived from a workbook, and what saving its source file drops.
//!
//! Both outputs are rebuildable caches: the control plane stores them beside the authoritative
//! `.xlsx` and regenerates them from it whenever needed.

use std::io::Read;

use gridcraft_core::Value;
use gridcraft_model::{Visibility, Workbook};
use serde::Serialize;

use crate::doc::SpreadsheetDoc;

/// Longest search text kept for one workbook, in bytes. Large numeric tables would otherwise grow
/// the search index without adding useful terms.
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
}

/// One sheet in tab order. `rows` and `cols` count up to the last stored cell.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SheetSummary {
    /// The sheet's stable id.
    pub sheet_id: u32,
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
                sheet_id: sheet.file_id,
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
    }
}

/// Sheet names, then each sheet's constant text cells row by row (tab-separated within a row),
/// then its comments, truncated to [`PLAIN_TEXT_LIMIT`]. Formula results are left out because they
/// repeat text that the sheet already holds.
pub(crate) fn plain_text(wb: &Workbook) -> String {
    let mut out = String::new();
    'sheets: for sheet in &wb.sheets {
        push_line(&mut out, &sheet.name);
        let mut row = None;
        for (cell_ref, cell) in sheet.cells.iter() {
            let (None, Value::Text(text)) = (&cell.formula, &cell.value) else {
                continue;
            };
            if text.trim().is_empty() {
                continue;
            }
            if row == Some(cell_ref.row) {
                out.push('\t');
            } else {
                if row.is_some() {
                    out.push('\n');
                }
                row = Some(cell_ref.row);
            }
            out.push_str(text);
            if out.len() > PLAIN_TEXT_LIMIT {
                break 'sheets;
            }
        }
        if row.is_some() {
            out.push('\n');
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
    truncate(out)
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
    use gridcraft_core::{CellRef, Value};
    use gridcraft_model::{Comment, Sheet, Workbook};

    use super::{PLAIN_TEXT_LIMIT, SourceReport, plain_text};

    #[test]
    fn plain_text_lists_names_text_cells_and_comments() {
        let mut wb = Workbook::new();
        let mut sheet = Sheet::new("华东区");
        sheet.set_value(CellRef::new(0, 0), Value::text("地区"));
        sheet.set_value(CellRef::new(0, 1), Value::text("收入"));
        sheet.set_value(CellRef::new(1, 0), Value::text("上海"));
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
        wb.sheets = vec![std::sync::Arc::new(sheet)];
        assert_eq!(plain_text(&wb), "华东区\n地区\t收入\n上海\n核对\n");
    }

    #[test]
    fn plain_text_stops_at_the_limit_on_a_char_boundary() {
        let mut wb = Workbook::new();
        let mut sheet = Sheet::new("S");
        for row in 0..60_000 {
            sheet.set_value(CellRef::new(row, 0), Value::text("中文内容"));
        }
        wb.sheets = vec![std::sync::Arc::new(sheet)];
        let text = plain_text(&wb);
        assert!(text.len() <= PLAIN_TEXT_LIMIT && text.len() > PLAIN_TEXT_LIMIT - 4);
    }

    #[test]
    fn only_warnings_about_lost_content_flag_unsupported_objects() {
        let kept = SourceReport::new(
            b"",
            vec!["macros (VBA project) were kept but not executed".into()],
        );
        assert!(!kept.has_unsupported_objects);
        let lost = SourceReport::new(
            b"",
            vec!["grouped shapes are not supported and were skipped (x, object 1)".into()],
        );
        assert!(lost.has_unsupported_objects);
    }
}
