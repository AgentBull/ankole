//! Bounded inspection view of a workbook for Agents (`office.inspect`).

use gridcraft_core::{CellRef, RangeRef, Value};
use gridcraft_model::{Sheet, Visibility};
use serde::{Deserialize, Serialize};

use crate::Error;
use crate::doc::{SpreadsheetDoc, sheet_by_id};
use crate::ids::SheetId;
use crate::view::{SheetInfo, cell_input_at, display_text, sheets};

/// Maximum cells returned in one `inspect` reply so large workbooks stay bounded.
const MAX_INSPECT_CELLS: u64 = 2_000;
/// Default rows inspected when the caller omits `range`.
const DEFAULT_MAX_ROWS: u32 = 50;
/// Default columns inspected when the caller omits `range`.
const DEFAULT_MAX_COLS: u32 = 26;

#[derive(Debug, Default, Deserialize)]
struct InspectParams {
    #[serde(default)]
    sheet_id: Option<SheetId>,
    #[serde(default)]
    sheet: Option<String>,
    #[serde(default)]
    range: Option<String>,
}

#[derive(Debug, Serialize)]
struct InspectReply {
    format: &'static str,
    title: String,
    sheets: Vec<SheetInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    inspected_sheet: Option<InspectedSheet>,
}

#[derive(Debug, Serialize)]
struct InspectedSheet {
    sheet_id: SheetId,
    name: String,
    range: String,
    truncated: bool,
    cells: Vec<InspectedCell>,
    merges: Vec<String>,
    tables: Vec<InspectedTable>,
}

#[derive(Debug, Serialize)]
struct InspectedCell {
    cell: String,
    row: u32,
    col: u32,
    text: String,
    input: String,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<String>,
}

#[derive(Debug, Serialize)]
struct InspectedTable {
    name: String,
    range: String,
}

/// Inspects a workbook's sheets and a bounded range of cells on one sheet.
///
/// # Errors
///
/// Returns [`Error::Invalid`] when `params_json` is not valid JSON, names a missing sheet,
/// or provides an invalid or oversized A1 range.
pub fn inspect(doc: &SpreadsheetDoc, params_json: &str) -> Result<serde_json::Value, Error> {
    let params: InspectParams = if params_json.trim().is_empty() {
        InspectParams::default()
    } else {
        serde_json::from_str(params_json)
            .map_err(|err| Error::invalid(format!("invalid inspect parameters: {err}")))?
    };

    let wb = doc.workbook();
    let sheet_list = sheets(doc);
    let target = select_sheet(doc, &params)?;

    let inspected_sheet = match target {
        None => None,
        Some(sheet) => Some(inspect_sheet(doc, sheet, params.range.as_deref())?),
    };

    serde_json::to_value(InspectReply {
        format: "spreadsheet",
        title: wb.props.title.clone(),
        sheets: sheet_list,
        inspected_sheet,
    })
    .map_err(|err| Error::Write(err.to_string()))
}

fn select_sheet<'a>(
    doc: &'a SpreadsheetDoc,
    params: &InspectParams,
) -> Result<Option<&'a Sheet>, Error> {
    let wb = doc.workbook();
    if let Some(id) = params.sheet_id {
        return sheet_by_id(wb, id).map(Some);
    }
    if let Some(name) = params.sheet.as_deref() {
        return wb
            .sheets
            .iter()
            .find(|s| s.name.eq_ignore_ascii_case(name))
            .map(|v| &**v)
            .map(Some)
            .ok_or_else(|| Error::invalid(format!("sheet `{name}` does not exist")));
    }
    Ok(wb
        .sheets
        .iter()
        .find(|s| s.visibility == Visibility::Visible)
        .or_else(|| wb.sheets.first())
        .map(|v| &**v))
}

fn inspect_sheet(
    doc: &SpreadsheetDoc,
    sheet: &Sheet,
    requested_range: Option<&str>,
) -> Result<InspectedSheet, Error> {
    let wb = doc.workbook();
    let (bounds, mut truncated) = match requested_range {
        Some(raw) => {
            let parsed = RangeRef::parse(raw)
                .or_else(|| CellRef::parse(raw).map(RangeRef::cell))
                .ok_or_else(|| Error::invalid(format!("invalid cell range `{raw}`")))?;
            let count = (u64::from(parsed.end.row - parsed.start.row) + 1)
                * (u64::from(parsed.end.col - parsed.start.col) + 1);
            if count > MAX_INSPECT_CELLS {
                return Err(Error::invalid(format!(
                    "range `{raw}` spans {count} cells, exceeding the {MAX_INSPECT_CELLS}-cell limit"
                )));
            }
            (parsed, false)
        }
        None => match sheet.used_range() {
            None => (RangeRef::new(CellRef::new(0, 0), CellRef::new(0, 0)), false),
            Some(used) => {
                let end_row = used
                    .end
                    .row
                    .min(used.start.row.saturating_add(DEFAULT_MAX_ROWS - 1));
                let end_col = used
                    .end
                    .col
                    .min(used.start.col.saturating_add(DEFAULT_MAX_COLS - 1));
                let clipped = end_row < used.end.row || end_col < used.end.col;
                (
                    RangeRef::new(used.start, CellRef::new(end_row, end_col)),
                    clipped,
                )
            }
        },
    };

    let mut cells = Vec::new();
    for row in bounds.start.row..=bounds.end.row {
        for col in bounds.start.col..=bounds.end.col {
            if cells.len() as u64 >= MAX_INSPECT_CELLS {
                truncated = true;
                break;
            }
            let at = CellRef::new(row, col);
            let val = sheet.value(at);
            let note = sheet.comments.get(&at).map(|c| c.text.clone());
            let has_formula = sheet.cell(at).is_some_and(|c| c.formula.is_some());
            if matches!(val, Value::Empty) && !has_formula && note.is_none() {
                continue;
            }
            let kind = match val {
                Value::Empty => "empty",
                Value::Number(_) => "number",
                Value::Text(_) => "text",
                Value::Bool(_) => "bool",
                Value::Error(_) => "error",
                Value::Array(_) => "array",
            };
            cells.push(InspectedCell {
                cell: at.a1(),
                row,
                col,
                text: display_text(wb, sheet, at),
                input: cell_input_at(wb, sheet, at),
                kind,
                note,
            });
        }
    }

    let merges = sheet
        .merges
        .iter()
        .filter(|m| m.intersects(&bounds))
        .map(RangeRef::a1)
        .collect();
    let tables = sheet
        .tables
        .iter()
        .filter(|t| t.range.intersects(&bounds))
        .map(|t| InspectedTable {
            name: t.name.clone(),
            range: t.range.a1(),
        })
        .collect();

    Ok(InspectedSheet {
        sheet_id: SheetId(sheet.file_id),
        name: sheet.name.clone(),
        range: bounds.a1(),
        truncated,
        cells,
        merges,
        tables,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{apply, create_blank};

    #[test]
    fn inspects_sheet_summary_and_cells() {
        let (doc, _) = create_blank("Budget").unwrap();
        let applied = apply(
            &doc,
            r#"{"type":"cell.set","sheet_id":1,"cell":"B2","input":"=10+5"}"#,
            "[]",
        )
        .unwrap();

        let value = inspect(&applied.doc, r#"{"range":"A1:C3"}"#).unwrap();
        assert_eq!(value["format"], "spreadsheet");
        assert_eq!(value["sheets"][0]["sheet_id"], 1);
        let cells = value["inspected_sheet"]["cells"].as_array().unwrap();
        assert_eq!(cells.len(), 1);
        assert_eq!(cells[0]["cell"], "B2");
        assert_eq!(cells[0]["text"], "15");
        assert_eq!(cells[0]["input"], "=10+5");
    }
}
