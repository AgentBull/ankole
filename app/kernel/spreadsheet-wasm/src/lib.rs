//! WebAssembly bindings that run Ankole spreadsheet documents in a browser Web Worker.
//!
//! The worker opens the same `.xlsx` bytes and replays the same committed operations as the
//! control plane, so both sides compute the same workbook. Every behavior lives in
//! `ankole_spreadsheet`; this crate only converts arguments and results. Structured results are
//! JSON text, which the worker parses once and posts to the page.
#![forbid(unsafe_code)]
#![warn(
    missing_docs,
    unreachable_pub,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::must_use_candidate,
    clippy::missing_errors_doc
)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        reason = "a failing test should stop at the broken expectation"
    )
)]

use ankole_spreadsheet::SpreadsheetDoc;
use wasm_bindgen::JsError;
use wasm_bindgen::prelude::wasm_bindgen;

/// One spreadsheet document held by the worker.
#[wasm_bindgen]
pub struct Spreadsheet {
    doc: SpreadsheetDoc,
}

#[wasm_bindgen]
impl Spreadsheet {
    /// Reads `.xlsx` bytes and replays the committed operations that are not yet compacted into
    /// them, given as a JSON array in revision order.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<Spreadsheet, JsError> {
        Ok(Spreadsheet {
            doc: ankole_spreadsheet::open(bytes, tail_ops_json)
                .map_err(|error| js_error(&error))?,
        })
    }

    /// Creates a workbook with one empty sheet whose `sheet_id` is 1.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn create_blank(title: &str) -> Result<Spreadsheet, JsError> {
        let (doc, _) = ankole_spreadsheet::create_blank(title).map_err(|error| js_error(&error))?;
        Ok(Spreadsheet { doc })
    }

    /// A second document that starts equal to this one. Documents are copy-on-write, so the fork
    /// shares every sheet with this one until either side applies an operation.
    #[must_use]
    pub fn fork(&self) -> Spreadsheet {
        Spreadsheet {
            doc: self.doc.clone(),
        }
    }

    /// Executes one canonical operation locally, without rebasing, and returns
    /// `{"op": …, "structural_edit": … | null}` as JSON: the operation as the control plane would
    /// commit it on the same document.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn apply(&mut self, op_json: &str) -> Result<String, JsError> {
        self.apply_rebased(op_json, "[]")
    }

    /// Rebases one operation over `prior_ops_json`, the JSON array of operations committed after
    /// the revision the operation was based on, executes it, and returns the same JSON as
    /// [`Spreadsheet::apply`]. When the rebase would have to guess, the error message is exactly
    /// the conflict's wire name, such as `target_deleted`, so the caller can tell a conflict from
    /// an invalid operation.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn apply_rebased(
        &mut self,
        op_json: &str,
        prior_ops_json: &str,
    ) -> Result<String, JsError> {
        let applied = ankole_spreadsheet::apply(&self.doc, op_json, prior_ops_json)
            .map_err(|error| JsError::new(&apply_error_message(error)))?;
        let result =
            serde_json::json!({ "op": applied.op, "structural_edit": applied.structural_edit });
        self.doc = applied.doc;
        Ok(result.to_string())
    }

    /// The cells, styles, merged areas, spills, and line sizes of the zero-based rectangle from
    /// `(r0, c0)` to `(r1, c1)`, as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn viewport(
        &self,
        sheet_id: u32,
        r0: u32,
        c0: u32,
        r1: u32,
        c1: u32,
    ) -> Result<String, JsError> {
        json(
            &ankole_spreadsheet::viewport(&self.doc, sheet_id, r0, c0, r1, c1)
                .map_err(|error| js_error(&error))?,
        )
    }

    /// The sheet tabs in order, as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn sheets(&self) -> Result<String, JsError> {
        json(&ankole_spreadsheet::sheets(&self.doc))
    }

    /// The text a cell editor starts from for the A1 cell `cell`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn cell_input(&self, sheet_id: u32, cell: &str) -> Result<String, JsError> {
        ankole_spreadsheet::cell_input(&self.doc, sheet_id, cell).map_err(|error| js_error(&error))
    }

    /// The document as `.xlsx` bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn export_xlsx(&self) -> Result<Vec<u8>, JsError> {
        Ok(ankole_spreadsheet::export_xlsx(&self.doc)
            .map_err(|error| js_error(&error))?
            .xlsx)
    }

    /// The count, sum, average, minimum, and maximum of the A1 range `range`, as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn selection_stats(&self, sheet_id: u32, range: &str) -> Result<String, JsError> {
        json(
            &ankole_spreadsheet::selection_stats(&self.doc, sheet_id, range)
                .map_err(|error| js_error(&error))?,
        )
    }

    /// The cells of the A1 range `range` with their inputs, values, and formats, as the JSON a
    /// later [`paste_op`] takes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn copy_block(&self, sheet_id: u32, range: &str) -> Result<String, JsError> {
        json(
            &ankole_spreadsheet::copy_block(&self.doc, sheet_id, range)
                .map_err(|error| js_error(&error))?,
        )
    }

    /// The floating pictures of one sheet, as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn images(&self, sheet_id: u32) -> Result<String, JsError> {
        json(&ankole_spreadsheet::images(&self.doc, sheet_id).map_err(|error| js_error(&error))?)
    }

    /// The encoded bytes of the floating picture `image_id`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn image_data(&self, sheet_id: u32, image_id: u32) -> Result<Vec<u8>, JsError> {
        ankole_spreadsheet::image_data(&self.doc, sheet_id, image_id)
            .map_err(|error| js_error(&error))
    }

    /// The encoded bytes of the picture in the A1 cell `cell`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` with the kernel's message when the kernel refuses the input.
    pub fn cell_picture(&self, sheet_id: u32, cell: &str) -> Result<Vec<u8>, JsError> {
        Ok(ankole_spreadsheet::cell_picture(&self.doc, sheet_id, cell)
            .map_err(|error| js_error(&error))?
            .bytes)
    }
}

/// Every function a formula can call, sorted by name, as JSON.
///
/// # Errors
///
/// Throws a `JsError` with the kernel's message when the kernel refuses the input.
#[wasm_bindgen]
pub fn functions() -> Result<String, JsError> {
    json(&ankole_spreadsheet::functions())
}

/// The `range.paste` operation, as JSON, that pastes the block JSON of
/// [`Spreadsheet::copy_block`] with its top-left cell on the A1 cell `cell`. `mode` is `all`,
/// `values`, `formulas`, or `formats`.
///
/// # Errors
///
/// Throws a `JsError` with the kernel's message when the kernel refuses the input.
#[wasm_bindgen]
pub fn paste_op(
    block_json: &str,
    sheet_id: u32,
    cell: &str,
    mode: &str,
) -> Result<String, JsError> {
    let block: ankole_spreadsheet::ClipboardBlock = serde_json::from_str(block_json)
        .map_err(|error| JsError::new(&format!("invalid copied block: {error}")))?;
    let mode: ankole_spreadsheet::PasteMode = serde_json::from_value(serde_json::Value::from(mode))
        .map_err(|error| JsError::new(&format!("invalid paste mode: {error}")))?;
    json(
        &ankole_spreadsheet::paste_op(&block, sheet_id, cell, mode)
            .map_err(|error| js_error(&error))?,
    )
}

/// A conflict reports only its wire name; every other refusal reports its message.
fn apply_error_message(error: ankole_spreadsheet::ApplyError) -> String {
    match error {
        ankole_spreadsheet::ApplyError::Conflict(conflict) => conflict.as_str().to_string(),
        ankole_spreadsheet::ApplyError::Error(error) => error.to_string(),
    }
}

fn js_error(error: &ankole_spreadsheet::Error) -> JsError {
    JsError::new(&error.to_string())
}

fn json(value: &impl serde::Serialize) -> Result<String, JsError> {
    serde_json::to_string(value).map_err(|error| JsError::new(&error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::{Spreadsheet, apply_error_message};

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

    #[test]
    fn a_fork_rebases_pending_edits_without_touching_its_source()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut confirmed = Spreadsheet::create_blank("Fork").map_err(|_| "create_blank")?;
        confirmed
            .apply(r#"{"type":"cell.set","sheet_id":1,"cell":"A1","input":"12"}"#)
            .map_err(|_| "apply")?;
        let mut local = confirmed.fork();
        local
            .apply(r#"{"type":"cell.set","sheet_id":1,"cell":"A2","input":"=A1*2"}"#)
            .map_err(|_| "apply")?;
        assert_eq!(confirmed.cell_input(1, "A2").map_err(|_| "cell_input")?, "");

        // Another editor inserted a row above, so the pending edit moves down with its reference.
        let insert = r#"[{"type":"line.insert","sheet_id":1,"axis":"rows","at":0,"count":1}]"#;
        confirmed
            .apply(r#"{"type":"line.insert","sheet_id":1,"axis":"rows","at":0,"count":1}"#)
            .map_err(|_| "insert")?;
        let mut rebuilt = confirmed.fork();
        let rebased: serde_json::Value = serde_json::from_str(
            &rebuilt
                .apply_rebased(
                    r#"{"type":"cell.set","sheet_id":1,"cell":"A2","input":"=A1*2"}"#,
                    insert,
                )
                .map_err(|_| "apply_rebased")?,
        )?;
        assert_eq!(rebased["op"]["cell"], "A3");
        assert_eq!(rebased["op"]["input"], "=A2*2");
        let viewport: serde_json::Value =
            serde_json::from_str(&rebuilt.viewport(1, 2, 0, 2, 0).map_err(|_| "viewport")?)?;
        assert_eq!(viewport["cells"][0]["text"], "24");
        assert_eq!(confirmed.cell_input(1, "A3").map_err(|_| "cell_input")?, "");
        Ok(())
    }

    #[test]
    fn a_conflict_reports_its_wire_name() -> Result<(), Box<dyn std::error::Error>> {
        let (doc, _) = ankole_spreadsheet::create_blank("Conflict")?;
        let deleted = ankole_spreadsheet::apply(
            &doc,
            r#"{"type":"line.delete","sheet_id":1,"axis":"rows","at":4,"count":1}"#,
            "[]",
        )
        .map_err(|_| "delete")?;
        let error = ankole_spreadsheet::apply(
            &deleted.doc,
            r#"{"type":"cell.set","sheet_id":1,"cell":"A5","input":"1"}"#,
            r#"[{"type":"line.delete","sheet_id":1,"axis":"rows","at":4,"count":1}]"#,
        )
        .err()
        .ok_or("the edit of a deleted row must conflict")?;
        assert_eq!(apply_error_message(error), "target_deleted");
        let invalid = ankole_spreadsheet::apply(&doc, r#"{"type":"cell.set"}"#, "[]")
            .err()
            .ok_or("an incomplete operation must fail")?;
        assert!(apply_error_message(invalid).starts_with("invalid operation"));
        Ok(())
    }
}
