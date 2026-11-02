//! Format snapshots: what undo needs to put the formats of a range back.
//!
//! A snapshot names every cell of the range that holds a format of its own and, for whole rows
//! or columns, every line that holds a line format, each with its full format. `range.restore_formats`
//! puts them back and takes away the formats added since. Formats travel as format patches, so a
//! pattern or gradient fill comes back as its foreground colour and a diagonal border is not kept.

use gridcraft_core::RangeRef;
use serde::Serialize;

use crate::Error;
use crate::clipboard::{MAX_CLIPBOARD_CELLS, full_format};
use crate::doc::{SpreadsheetDoc, sheet_by_id};
use crate::ids::SheetId;
use crate::ops::{CellFormat, LineFormat};

/// The formats of a range, as `range.restore_formats` takes them.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct FormatSnapshot {
    /// The line formats of whole rows or columns.
    pub lines: Vec<LineFormat>,
    /// The cells that hold a format of their own.
    pub cells: Vec<CellFormat>,
}

/// Reads the formats of the A1 range `range`, so that undo can put them back.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet, an invalid range, or a range whose stored
/// cells exceed [`MAX_CLIPBOARD_CELLS`].
pub fn format_snapshot(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    range: &str,
) -> Result<FormatSnapshot, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let range = RangeRef::parse(range)
        .filter(|range| range.end.is_valid())
        .ok_or_else(|| Error::invalid(format!("invalid range reference `{range}`")))?;
    let mut lines = Vec::new();
    let (full_rows, full_cols) = (range.is_full_rows(), range.is_full_cols());
    if full_rows || full_cols {
        // The axis that range.format uses: rows unless the range is the whole sheet.
        let rows = full_rows && !full_cols;
        let (infos, first, last) = if rows {
            (&sheet.rows, range.start.row, range.end.row)
        } else {
            (&sheet.cols, range.start.col, range.end.col)
        };
        for (line, info) in infos.range(first..=last) {
            if let Some(style) = info.style {
                lines.push(LineFormat {
                    offset: line - first,
                    format: full_format(wb, wb.styles.get(style)),
                });
            }
        }
    }
    let mut cells = Vec::new();
    for (at, cell) in sheet.cells.iter_range(range) {
        if cells.len() as u64 >= MAX_CLIPBOARD_CELLS {
            return Err(Error::invalid(format!(
                "a format snapshot holds at most {MAX_CLIPBOARD_CELLS} cells"
            )));
        }
        cells.push(CellFormat {
            row: at.row - range.start.row,
            col: at.col - range.start.col,
            format: full_format(wb, wb.styles.get(cell.style)),
        });
    }
    Ok(FormatSnapshot { lines, cells })
}
