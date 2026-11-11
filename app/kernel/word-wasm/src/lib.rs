//! WebAssembly bindings that run Ankole Word documents in a browser Web Worker.

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

use ankole_word::editor::Editor;
use ankole_word::{ApplyError, Error};
use wasm_bindgen::JsError;
use wasm_bindgen::prelude::wasm_bindgen;

/// Collaborative Word document editor and read-only page previewer held by a browser Web Worker.
#[wasm_bindgen]
pub struct WordEditor {
    inner: Editor,
}

#[wasm_bindgen]
impl WordEditor {
    /// Creates a blank `.docx` Word document editor with the given metadata title.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when the kernel cannot initialize the blank document.
    pub fn create_blank(title: &str) -> Result<WordEditor, JsError> {
        Ok(Self {
            inner: Editor::create_blank(title).map_err(|e| js_error(&e))?,
        })
    }

    /// Creates a blank macro-enabled `.docm` Word document editor with the given metadata title.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when the kernel cannot initialize the blank document.
    pub fn create_blank_docm(title: &str) -> Result<WordEditor, JsError> {
        Ok(Self {
            inner: Editor::create_blank_docm(title).map_err(|e| js_error(&e))?,
        })
    }

    /// Opens `.docx` or `.docm` bytes, restores an optional compaction identity checkpoint, and
    /// replays the uncompacted JSON array `tail_ops_json`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when the package, checkpoint, or uncompacted operations are invalid or
    /// newer than supported.
    pub fn open(
        bytes: &[u8],
        tail_ops_json: &str,
        checkpoint_json: Option<String>,
    ) -> Result<WordEditor, JsError> {
        Ok(Self {
            inner: Editor::open_with_checkpoint(bytes, tail_ops_json, checkpoint_json.as_deref())
                .map_err(|e| JsError::new(&apply_error_message(e)))?,
        })
    }

    /// Lays out the document, caches the layout, and returns page geometry
    /// `[{"index", "width_pt", "height_pt"}, ...]` as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn pages_info(&mut self) -> Result<String, JsError> {
        self.inner.pages_info().map_err(|e| js_error(&e))
    }

    /// Rasterizes `page_index` at `scale` pixels per point into straight RGBA8 bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds or `scale` is invalid.
    pub fn render_page_rgba(&mut self, page_index: usize, scale: f32) -> Result<Vec<u8>, JsError> {
        self.inner
            .render_page_rgba(page_index, scale)
            .map_err(|e| js_error(&e))
    }

    /// Returns `[width_px, height_px]` for `page_index` rendered at `scale` pixels per point.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds or `scale` is invalid.
    pub fn page_pixel_size(&mut self, page_index: usize, scale: f32) -> Result<Vec<u32>, JsError> {
        self.inner
            .page_pixel_size(page_index, scale)
            .map_err(|e| js_error(&e))
    }

    /// Rasterizes `page_index` at `scale` pixels per point and encodes it as PNG bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds, `scale` is invalid, or PNG encoding
    /// fails.
    pub fn render_page_png(&mut self, page_index: usize, scale: f32) -> Result<Vec<u8>, JsError> {
        self.inner
            .render_page_png(page_index, scale)
            .map_err(|e| js_error(&e))
    }

    /// Returns JSON describing the active caret, selection rectangles, Presence coordinates, and
    /// active formatting flags.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn caret_and_selection(&mut self) -> Result<String, JsError> {
        self.inner.caret_and_selection().map_err(|e| js_error(&e))
    }

    /// Returns page bounding rectangles `[{"page", "x", "y", "w", "h"}, ...]` for `block_index`
    /// in `story_json` so collaborators' soft-locked blocks can be outlined.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `story_json` is invalid.
    pub fn block_rects(&mut self, story_json: &str, block_index: usize) -> Result<String, JsError> {
        self.inner
            .block_rects(story_json, block_index)
            .map_err(|e| js_error(&e))
    }

    /// Resolves a collaborator's Presence selection JSON into page highlight rectangles.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `selection_json` is malformed.
    pub fn presence_selection_rects(&mut self, selection_json: &str) -> Result<String, JsError> {
        self.inner
            .presence_selection_rects(selection_json)
            .map_err(|e| js_error(&e))
    }

    /// Handles a pointer down gesture at `(x_pt, y_pt)` on `page_index`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_down(
        &mut self,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
        clicks: u32,
        shift: bool,
        alt: bool,
    ) -> Result<String, JsError> {
        self.inner
            .pointer_down(page_index, x_pt, y_pt, clicks, shift, alt)
            .map_err(|e| js_error(&e))
    }

    /// Updates an active pointer gesture at `(x_pt, y_pt)` on `page_index`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_move(
        &mut self,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
    ) -> Result<String, JsError> {
        self.inner
            .pointer_move(page_index, x_pt, y_pt)
            .map_err(|e| js_error(&e))
    }

    /// Finishes an active pointer gesture at `(x_pt, y_pt)` on `page_index`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_up(
        &mut self,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
    ) -> Result<String, JsError> {
        self.inner
            .pointer_up(page_index, x_pt, y_pt)
            .map_err(|e| js_error(&e))
    }

    /// Dispatches a keyboard shortcut, navigation key, or character key event.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when command execution or JSON serialization fails.
    pub fn key_event(
        &mut self,
        key: &str,
        ctrl_or_meta: bool,
        shift: bool,
        alt: bool,
    ) -> Result<String, JsError> {
        self.inner
            .key_event(key, ctrl_or_meta, shift, alt)
            .map_err(|e| js_error(&e))
    }

    /// Inserts plain text at the current selection outside IME composition.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when the insertion is refused by the active selection.
    pub fn insert_text(&mut self, text: &str) -> Result<String, JsError> {
        self.inner.insert_text(text).map_err(|e| js_error(&e))
    }

    /// Updates active IME preedit text and relative cursor offsets.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when updating the preedit range fails.
    pub fn ime_preedit(
        &mut self,
        text: &str,
        cursor_start: usize,
        cursor_end: usize,
    ) -> Result<String, JsError> {
        self.inner
            .ime_preedit(text, cursor_start, cursor_end)
            .map_err(|e| js_error(&e))
    }

    /// Commits an active IME composition with `text`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when inserting the committed text fails.
    pub fn ime_commit(&mut self, text: &str) -> Result<String, JsError> {
        self.inner.ime_commit(text).map_err(|e| js_error(&e))
    }

    /// Cancels an active IME composition and restores the pre-composition document state.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn ime_cancel(&mut self) -> Result<String, JsError> {
        self.inner.ime_cancel().map_err(|e| js_error(&e))
    }

    /// Returns `true` while an IME composition session is active.
    #[must_use]
    pub fn is_composing(&self) -> bool {
        self.inner.is_composing()
    }

    /// Runs a safe WordCraft command by ID with JSON parameters.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when the command is blocked, `params_json` is malformed, or execution
    /// fails.
    pub fn execute_command(
        &mut self,
        command_id: &str,
        params_json: &str,
    ) -> Result<String, JsError> {
        self.inner
            .execute_command(command_id, params_json)
            .map_err(|e| js_error(&e))
    }

    /// Returns `true` when the active session document differs from `optimistic_base` (and no IME
    /// composition is active).
    #[must_use]
    pub fn has_local_changes(&self) -> bool {
        self.inner.has_local_changes()
    }

    /// Derives a canonical `ChangeSet` JSON string from `optimistic_base` to the session document
    /// and advances `optimistic_base`. Never commits while [`Self::is_composing`] is `true`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when deriving or serializing the change set fails.
    pub fn commit_local_step(&mut self) -> Result<Option<String>, JsError> {
        self.inner.commit_local_step().map_err(|e| js_error(&e))
    }

    /// Advances `confirmed` by `confirmed_ops_json`, rebases `pending_ops_json` and any active
    /// local draft, updates `Session::set_document`, shifts the caret block index, and returns
    /// JSON `{"dropped_pending", "draft_conflict", "conflict_reason", "active_block"}`.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when operation JSON is malformed or carries an unsupported future
    /// `model_version`.
    pub fn apply_remote(
        &mut self,
        confirmed_ops_json: &str,
        pending_ops_json: &str,
    ) -> Result<String, JsError> {
        self.inner
            .apply_remote(confirmed_ops_json, pending_ops_json)
            .map_err(|e| JsError::new(&apply_error_message(e)))
    }

    /// Discards unconfirmed local edits and resets the session document to `confirmed`.
    pub fn reset_to_confirmed(&mut self) {
        self.inner.reset_to_confirmed();
    }

    /// Undoes the latest personal block snapshot and returns any resulting `blocks.splice`
    /// `ChangeSet` JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when deriving or serializing the undo change set fails.
    pub fn undo(&mut self) -> Result<Option<String>, JsError> {
        self.inner.undo().map_err(|e| js_error(&e))
    }

    /// Redoes the latest undone personal block snapshot and returns any resulting `blocks.splice`
    /// `ChangeSet` JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when deriving or serializing the redo change set fails.
    pub fn redo(&mut self) -> Result<Option<String>, JsError> {
        self.inner.redo().map_err(|e| js_error(&e))
    }

    /// Searches all stories of the document for `query`, returning match positions, snippets, and
    /// page highlight rectangles as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn find(&mut self, query: &str, match_case: bool) -> Result<String, JsError> {
        self.inner.find(query, match_case).map_err(|e| js_error(&e))
    }

    /// Returns the plain text of the active selection.
    #[must_use]
    pub fn selected_text(&self) -> String {
        self.inner.selected_text()
    }

    /// Returns HTML markup for the active selection.
    #[must_use]
    pub fn selected_html(&self) -> String {
        self.inner.selected_html()
    }

    /// Lists safe WordCraft commands matching `query` as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn commands(&self, query: &str) -> Result<String, JsError> {
        self.inner.commands(query).map_err(|e| js_error(&e))
    }

    /// Exports the current document as `.docx` or `.docm` bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when OOXML serialization fails.
    pub fn export_docx(&self) -> Result<Vec<u8>, JsError> {
        self.inner.export_docx().map_err(|e| js_error(&e))
    }

    /// Exports the current document as PDF bytes.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when PDF export fails.
    pub fn export_pdf(&self) -> Result<Vec<u8>, JsError> {
        self.inner.export_pdf().map_err(|e| js_error(&e))
    }

    /// Returns diagnostic entries for pictures that could not be loaded on open, as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn missing_pictures(&self) -> Result<String, JsError> {
        self.inner.missing_pictures().map_err(|e| js_error(&e))
    }

    /// Loads any fonts embedded in the opened document into the Worker's font database and returns
    /// the number of loaded font faces.
    #[must_use]
    pub fn load_embedded_fonts(&self) -> usize {
        self.inner.load_embedded_fonts()
    }

    /// Adds a dynamically fetched site font blob to the Worker's font database and returns the
    /// number of loaded font faces.
    #[must_use]
    pub fn add_font(bytes: &[u8]) -> usize {
        Editor::add_font(bytes)
    }

    /// Returns font family substitutions recorded during layout as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn substituted_fonts(&mut self) -> Result<String, JsError> {
        self.inner.substituted_fonts().map_err(|e| js_error(&e))
    }

    /// Returns canonical site fallback font families needed for uncovered CJK glyphs as JSON.
    ///
    /// # Errors
    ///
    /// Throws a `JsError` when JSON serialization fails.
    pub fn missing_glyph_fonts(&self) -> Result<String, JsError> {
        self.inner.missing_glyph_fonts().map_err(|e| js_error(&e))
    }
}

fn apply_error_message(error: ApplyError) -> String {
    match error {
        ApplyError::Conflict(conflict) => conflict.as_str().to_string(),
        ApplyError::FutureVersion { .. } | ApplyError::Error(_) => error.to_string(),
    }
}

fn js_error(error: &Error) -> JsError {
    JsError::new(&error.to_string())
}

#[cfg(test)]
mod tests {
    use super::{WordEditor, apply_error_message};
    use ankole_word::{ApplyError, Conflict};

    // Host builds cannot construct a `JsError`, so these tests verify the Worker wrapper over
    // valid flows and verify `apply_error_message` directly.
    #[test]
    fn worker_editor_round_trips_typing_render_and_collaboration()
    -> Result<(), Box<dyn std::error::Error>> {
        let mut editor = WordEditor::create_blank("Worker Spec").map_err(|_| "create_blank")?;
        let pages: serde_json::Value =
            serde_json::from_str(&editor.pages_info().map_err(|_| "pages_info")?)?;
        assert_eq!(pages.as_array().map(Vec::len), Some(1));

        editor
            .insert_text("Hello collaborative Word")
            .map_err(|_| "insert_text")?;
        assert!(editor.has_local_changes());

        let op_json = editor
            .commit_local_step()
            .map_err(|_| "commit")?
            .ok_or("expected local change set")?;
        assert!(!editor.has_local_changes());

        let size = editor
            .page_pixel_size(0, 1.0)
            .map_err(|_| "page_pixel_size")?;
        let rgba = editor
            .render_page_rgba(0, 1.0)
            .map_err(|_| "render_page_rgba")?;
        assert_eq!(rgba.len(), (size[0] as usize) * (size[1] as usize) * 4);

        let matches: serde_json::Value =
            serde_json::from_str(&editor.find("collaborative", true).map_err(|_| "find")?)?;
        assert_eq!(matches.as_array().map(Vec::len), Some(1));

        let docx = editor.export_docx().map_err(|_| "export_docx")?;
        let mut peer = WordEditor::create_blank("Worker Spec").map_err(|_| "peer")?;
        let remote_summary: serde_json::Value = serde_json::from_str(
            &peer
                .apply_remote(&format!("[{op_json}]"), "[]")
                .map_err(|_| "apply_remote")?,
        )?;
        assert_eq!(remote_summary["dropped_pending"], 0);
        assert_eq!(remote_summary["draft_conflict"], false);

        let reopened = WordEditor::open(&docx, "[]", None).map_err(|_| "open")?;
        assert_eq!(reopened.load_embedded_fonts(), 0);
        Ok(())
    }

    #[test]
    fn conflict_maps_to_wire_code() {
        assert_eq!(
            apply_error_message(ApplyError::Conflict(Conflict::BlockChanged)),
            "block_changed"
        );
        assert_eq!(
            apply_error_message(ApplyError::Conflict(Conflict::UnbalancedMarkers)),
            "unbalanced_markers"
        );
    }
}
