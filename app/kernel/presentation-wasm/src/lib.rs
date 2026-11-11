//! WebAssembly bindings that run Ankole Presentation Pages (`.pptx`) in a browser Web Worker.
//!
//! Both collaborative edit mode and read-only attachment preview mode run [`PresentationEditor`]
//! inside a dedicated Worker, sharing the exact wire format, conflict rules, and renderer as the
//! control-plane kernel crate.
#![forbid(unsafe_code)]
#![warn(
    missing_docs,
    unreachable_pub,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::must_use_candidate,
    clippy::missing_errors_doc
)]
#![cfg_attr(
    test,
    allow(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing,
        reason = "a failing test should stop at the broken expectation"
    )
)]

use ankole_presentation::{ApplyError, EditorState, Error};
use wasm_bindgen::JsError;
use wasm_bindgen::prelude::wasm_bindgen;

/// Stateful presentation editor and previewer owned by a browser Web Worker.
#[wasm_bindgen]
pub struct PresentationEditor {
    inner: EditorState,
}

#[wasm_bindgen]
impl PresentationEditor {
    /// Creates a clean 1-slide blank presentation editor with `title`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if initialization fails.
    pub fn create_blank(title: &str) -> Result<PresentationEditor, JsError> {
        let inner = EditorState::create_blank(title).map_err(js_error)?;
        Ok(Self { inner })
    }

    /// Opens `.pptx` bytes, applies an optional compaction identity checkpoint, and replays
    /// committed `tail_ops_json` in revision order.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if `bytes` or `checkpoint_json` cannot be decoded, an operation is
    /// invalid, or an operation carries a newer `model_version` than this build supports.
    pub fn open(
        bytes: &[u8],
        tail_ops_json: &str,
        checkpoint_json: Option<String>,
    ) -> Result<PresentationEditor, JsError> {
        let inner =
            EditorState::open_with_checkpoint(bytes, tail_ops_json, checkpoint_json.as_deref())
                .map_err(apply_js_error)?;
        Ok(Self { inner })
    }

    /// Returns slide list metadata across the presentation as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if serialization fails.
    pub fn slides_info(&self) -> Result<String, JsError> {
        self.inner.slides_info().map_err(js_error)
    }

    /// Returns the zero-based index of the active slide.
    #[must_use]
    pub fn active_slide(&self) -> usize {
        self.inner.active_slide()
    }

    /// Sets the active slide by zero-based `slide_index` and returns updated selection info JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `slide_index` is out of bounds.
    pub fn set_active_slide(&mut self, slide_index: usize) -> Result<String, JsError> {
        self.inner.set_active_slide(slide_index).map_err(js_error)
    }

    /// Returns the current slide selection, shape selection, text caret/range, notes, editing
    /// state, and Undo/Redo availability as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if serialization fails.
    pub fn selection_info(&self) -> Result<String, JsError> {
        self.inner.selection_info().map_err(js_error)
    }

    /// Rasterizes `slide_index` at `scale` into straight RGBA8 bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `slide_index` or `scale` is invalid.
    pub fn render_slide_rgba(&self, slide_index: usize, scale: f32) -> Result<Vec<u8>, JsError> {
        self.inner
            .render_slide_rgba(slide_index, scale)
            .map_err(js_error)
    }

    /// Returns `[width, height]` in pixels for slides rendered at `scale`.
    #[must_use]
    pub fn slide_pixel_size(&self, scale: f32) -> Vec<u32> {
        self.inner.slide_pixel_size(scale)
    }

    /// Rasterizes `slide_index` at `scale` into encoded PNG bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `slide_index` or `scale` is invalid or PNG encoding fails.
    pub fn render_slide_png(&self, slide_index: usize, scale: f32) -> Result<Vec<u8>, JsError> {
        self.inner
            .render_slide_png(slide_index, scale)
            .map_err(js_error)
    }

    /// Executes a safe DeckCraft command with JSON parameters on the local session.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if the command is blocked, `params_json` is invalid, or execution fails.
    pub fn execute_command(
        &mut self,
        command_id: &str,
        params_json: &str,
    ) -> Result<String, JsError> {
        self.inner
            .execute_command(command_id, params_json)
            .map_err(js_error)
    }

    /// Feeds a pointer event in slide coordinates (points) to the session's active tool.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if `event_json` is malformed or tool execution fails.
    pub fn pointer_event(&mut self, event_json: &str) -> Result<String, JsError> {
        self.inner.pointer_event(event_json).map_err(js_error)
    }

    /// Feeds a keyboard press with modifier flags to the session.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if `mods_json` is malformed or key handling fails.
    pub fn key_event(&mut self, key: &str, mods_json: &str) -> Result<String, JsError> {
        self.inner.key_event(key, mods_json).map_err(js_error)
    }

    /// Updates the speaker notes text of `slide_id`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if `slide_id` does not exist.
    pub fn set_slide_notes(&mut self, slide_id: u32, notes: &str) -> Result<(), JsError> {
        self.inner
            .set_slide_notes(slide_id, notes)
            .map_err(js_error)
    }

    /// Reports whether uncommitted local draft changes exist relative to `optimistic_base`.
    #[must_use]
    pub fn has_local_changes(&self) -> bool {
        self.inner.has_local_changes()
    }

    /// Derives a canonical `ChangeSet` JSON string from `optimistic_base` to the current session
    /// document and advances `optimistic_base`, returning `None` when nothing changed.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if the derived operation violates wire or picture limits.
    pub fn commit_local_step(&mut self) -> Result<Option<String>, JsError> {
        self.inner.commit_local_step().map_err(js_error)
    }

    /// Advances `confirmed` by `confirmed_ops_json` and rebases `pending_ops_json` plus any
    /// uncommitted local draft onto `confirmed`, returning rebase status JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if the operation lists cannot be parsed or carry a future `model_version`.
    pub fn apply_remote(
        &mut self,
        confirmed_ops_json: &str,
        pending_ops_json: &str,
    ) -> Result<String, JsError> {
        self.inner
            .apply_remote(confirmed_ops_json, pending_ops_json)
            .map_err(apply_js_error)
    }

    /// Discards pending and draft local edits, restoring the session to `confirmed`.
    pub fn reset_to_confirmed(&mut self) {
        self.inner.reset_to_confirmed();
    }

    /// Undoes the last personal single-slide edit and returns the derived `slide.put` `ChangeSet`
    /// JSON, or `None` when the Undo stack is empty.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if change set derivation fails.
    pub fn undo(&mut self) -> Result<Option<String>, JsError> {
        self.inner.undo().map_err(js_error)
    }

    /// Redoes the last undone personal single-slide edit and returns the derived `slide.put`
    /// `ChangeSet` JSON, or `None` when the Redo stack is empty.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if change set derivation fails.
    pub fn redo(&mut self) -> Result<Option<String>, JsError> {
        self.inner.redo().map_err(js_error)
    }

    /// Searches all slide shapes and speaker notes for `query`, returning matches as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if JSON serialization fails.
    pub fn find(&self, query: &str, match_case: bool) -> Result<String, JsError> {
        self.inner.find(query, match_case).map_err(js_error)
    }

    /// Returns plain text of the active text selection, selected table cells, or selected shapes.
    #[must_use]
    pub fn selected_text(&self) -> String {
        self.inner.selected_text()
    }

    /// Lists safe editor commands matching `query` as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if JSON serialization fails.
    pub fn commands(&self, query: &str) -> Result<String, JsError> {
        self.inner.commands(query).map_err(js_error)
    }

    /// Exports the current presentation as `.pptx` bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if `.pptx` serialization fails.
    pub fn export_pptx(&self) -> Result<Vec<u8>, JsError> {
        self.inner.export_pptx().map_err(js_error)
    }

    /// Exports the current presentation as PDF bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if PDF serialization fails.
    pub fn export_pdf(&self) -> Result<Vec<u8>, JsError> {
        self.inner.export_pdf().map_err(js_error)
    }

    /// Decodes and registers embedded presentation fonts in this Worker's `FontDb`, returning the
    /// number of font faces loaded.
    #[must_use]
    pub fn load_embedded_fonts(&self) -> usize {
        self.inner.load_embedded_fonts()
    }

    /// Adds a raw font blob to this Worker's `FontDb`, returning the number of font faces loaded.
    #[must_use]
    pub fn add_font(bytes: &[u8]) -> usize {
        EditorState::add_font(bytes)
    }

    /// Returns missing font families and their substituted faces as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if JSON serialization fails.
    pub fn substituted_fonts(&self) -> Result<String, JsError> {
        self.inner.substituted_fonts().map_err(js_error)
    }

    /// Returns canonical site fallback font families needed for uncovered CJK characters as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if JSON serialization fails.
    pub fn missing_glyph_fonts(&self) -> Result<String, JsError> {
        self.inner.missing_glyph_fonts().map_err(js_error)
    }

    /// Returns import warnings reported when the presentation was opened as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` if JSON serialization fails.
    pub fn warnings(&self) -> Result<String, JsError> {
        self.inner.warnings().map_err(js_error)
    }
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "used directly with Result::map_err across the wasm boundary"
)]
fn js_error(err: Error) -> JsError {
    JsError::new(&err.to_string())
}

#[allow(
    clippy::needless_pass_by_value,
    reason = "used directly with Result::map_err across the wasm boundary"
)]
fn apply_js_error(err: ApplyError) -> JsError {
    let message = match err {
        ApplyError::Conflict(conflict) => conflict.as_str().to_string(),
        ApplyError::FutureVersion { found, supported } => format!(
            "future_model_version: operation model_version {found} exceeds supported version {supported}"
        ),
        ApplyError::Error(inner) => inner.to_string(),
    };
    JsError::new(&message)
}

#[cfg(test)]
mod tests {
    use super::PresentationEditor;

    #[test]
    fn wasm_wrapper_delegates_editor_lifecycle() {
        let editor = PresentationEditor::create_blank("WASM Deck")
            .unwrap_or_else(|_| panic!("create_blank failed"));
        assert_eq!(editor.active_slide(), 0);
        assert!(!editor.has_local_changes());
        let cmds = editor
            .commands("slide.new")
            .unwrap_or_else(|_| panic!("commands failed"));
        assert!(cmds.contains("slide.new"));
        let bytes = editor
            .export_pptx()
            .unwrap_or_else(|_| panic!("export_pptx failed"));
        let reopened =
            PresentationEditor::open(&bytes, "[]", None).unwrap_or_else(|_| panic!("open failed"));
        assert_eq!(reopened.active_slide(), 0);
        assert_eq!(PresentationEditor::add_font(&[]), 0);
    }
}
