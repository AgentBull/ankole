//! WebAssembly bindings that run Ankole spreadsheet documents in a browser Web Worker.
//!
//! The worker opens the same `.xlsx` bytes and replays the same committed operations as the
//! control plane, so both sides compute the same workbook. Every behavior lives in
//! `ankole_spreadsheet`; this crate only converts arguments and results. Structured results are
//! JSON text, which the worker parses once and posts to the page.
#![forbid(unsafe_code)]

use ankole_spreadsheet::SpreadsheetDoc;
use wasm_bindgen::prelude::*;

/// One spreadsheet document held by the worker.
#[wasm_bindgen]
pub struct Spreadsheet {
    doc: SpreadsheetDoc,
}

#[wasm_bindgen]
impl Spreadsheet {
    /// Reads `.xlsx` bytes and replays the committed operations that are not yet compacted into
    /// them, given as a JSON array in revision order.
    pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<Spreadsheet, JsError> {
        Ok(Spreadsheet {
            doc: ankole_spreadsheet::open(bytes, tail_ops_json).map_err(js_error)?,
        })
    }

    /// Creates a workbook with one empty sheet whose `sheet_id` is 1.
    pub fn create_blank(title: &str) -> Result<Spreadsheet, JsError> {
        let (doc, _) = ankole_spreadsheet::create_blank(title).map_err(js_error)?;
        Ok(Spreadsheet { doc })
    }

    /// Executes one canonical operation locally, without rebasing, and returns
    /// `{"op": …, "structural_edit": … | null}` as JSON: the operation as the control plane would
    /// commit it on the same document.
    pub fn apply(&mut self, op_json: &str) -> Result<String, JsError> {
        let applied =
            ankole_spreadsheet::apply(&self.doc, op_json, "[]").map_err(|error| match error {
                ankole_spreadsheet::ApplyError::Conflict(conflict) => {
                    JsError::new(conflict.as_str())
                }
                ankole_spreadsheet::ApplyError::Error(error) => js_error(error),
            })?;
        let result =
            serde_json::json!({ "op": applied.op, "structural_edit": applied.structural_edit });
        self.doc = applied.doc;
        Ok(result.to_string())
    }

    /// The cells, styles, merged areas, spills, and line sizes of the zero-based rectangle from
    /// `(r0, c0)` to `(r1, c1)`, as JSON.
    pub fn viewport(
        &self,
        sheet_id: u32,
        r0: u32,
        c0: u32,
        r1: u32,
        c1: u32,
    ) -> Result<String, JsError> {
        json(&ankole_spreadsheet::viewport(&self.doc, sheet_id, r0, c0, r1, c1).map_err(js_error)?)
    }

    /// The sheet tabs in order, as JSON.
    pub fn sheets(&self) -> Result<String, JsError> {
        json(&ankole_spreadsheet::sheets(&self.doc))
    }

    /// The text a cell editor starts from for the A1 cell `cell`.
    pub fn cell_input(&self, sheet_id: u32, cell: &str) -> Result<String, JsError> {
        ankole_spreadsheet::cell_input(&self.doc, sheet_id, cell).map_err(js_error)
    }

    /// The document as `.xlsx` bytes.
    pub fn export_xlsx(&self) -> Result<Vec<u8>, JsError> {
        Ok(ankole_spreadsheet::export_xlsx(&self.doc)
            .map_err(js_error)?
            .xlsx)
    }
}

fn js_error(error: ankole_spreadsheet::Error) -> JsError {
    JsError::new(&error.to_string())
}

fn json(value: &impl serde::Serialize) -> Result<String, JsError> {
    serde_json::to_string(value).map_err(|error| JsError::new(&error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::Spreadsheet;

    // Host builds cannot construct a `JsError`, so these tests cover the success paths only.
    #[test]
    fn the_worker_api_returns_json_the_page_can_paint() -> Result<(), Box<dyn std::error::Error>> {
        let mut sheet = Spreadsheet::create_blank("Worker").map_err(|_| "create_blank")?;
        let applied: serde_json::Value = serde_json::from_str(
            &sheet
                .apply(r#"{"type":"cell.set","sheet_id":1,"cell":"B2","input":"1234.5"}"#)
                .map_err(|_| "apply")?,
        )?;
        assert_eq!(applied["structural_edit"], serde_json::Value::Null);
        sheet.apply(r##"{"type":"range.format","sheet_id":1,"range":"B2","patch":{"num_fmt":"#,##0.00","bold":true}}"##).map_err(|_| "format")?;
        let viewport: serde_json::Value =
            serde_json::from_str(&sheet.viewport(1, 0, 0, 9, 9).map_err(|_| "viewport")?)?;
        assert_eq!(viewport["cells"][0]["text"], "1,234.50");
        assert_eq!(
            viewport["styles"][viewport["cells"][0]["style"].as_u64().unwrap_or(0) as usize]["bold"],
            true
        );
        let sheets: serde_json::Value =
            serde_json::from_str(&sheet.sheets().map_err(|_| "sheets")?)?;
        assert_eq!(sheets[0]["sheet_id"], 1);
        assert_eq!(
            sheet.cell_input(1, "B2").map_err(|_| "cell_input")?,
            "1234.5"
        );
        let reopened = Spreadsheet::open(&sheet.export_xlsx().map_err(|_| "export")?, "[]")
            .map_err(|_| "open")?;
        assert_eq!(
            reopened.cell_input(1, "B2").map_err(|_| "cell_input")?,
            "1234.5"
        );
        Ok(())
    }
}
