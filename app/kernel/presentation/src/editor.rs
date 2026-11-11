//! Interactive presentation editor state backing the browser WebAssembly Worker.

use std::collections::{HashSet, VecDeque};
use std::sync::Arc;

use deckcraft_engine::cmd::text::{body_of, text_frame};
use deckcraft_engine::keys::{key_token, shortcut_matches};
use deckcraft_engine::tools::{Mods, PointerEvent, PointerKind, ToolKind};
use deckcraft_engine::{DocState, Session, TextSel, command_specs};
use deckcraft_fonts::FontDb;
use deckcraft_geom::Point;
use deckcraft_model::text::TextBody;
use deckcraft_model::{MediaId, Presentation, ShapeKind, Slide, SlideId};
use deckcraft_text::Pos;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::commands::{commands, is_blocked_command};
use crate::derive::derive;
use crate::inspect::{find, shape_plain_text};
use crate::ops::{
    ChangeSet, Edit, apply_changeset_to_presentation, parse_changeset_list, validate_changeset,
};
use crate::rebase::apply_parsed;
use crate::{
    ApplyError, Error, MAX_OP_BYTES, MAX_PICTURE_BYTES, PresentationDoc, ensure_isolated_fonts,
    export_pdf, export_pptx, open_with_checkpoint, render_slide_png, render_slide_rgba,
    slide_pixel_dimensions,
};

const MAX_UNDO_SNAPSHOTS: usize = 100;

#[derive(Clone, Debug)]
struct SlideSnapshot {
    slide_id: SlideId,
    slide: Arc<Slide>,
}

/// Interactive presentation editor holding confirmed server state, queued optimistic state,
/// live DeckCraft [`Session`] state, and a personal per-slide Undo/Redo snapshot stack.
pub struct EditorState {
    confirmed: PresentationDoc,
    optimistic_base: PresentationDoc,
    session: Session,
    local_unacked_ops: VecDeque<ChangeSet>,
    undo_stack: Vec<SlideSnapshot>,
    redo_stack: Vec<SlideSnapshot>,
    pointer_pre_doc: Option<Arc<Presentation>>,
    typing_coalesced_slide: Option<SlideId>,
}

impl std::fmt::Debug for EditorState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EditorState")
            .field("active_slide", &self.active_slide())
            .field("undo_depth", &self.undo_stack.len())
            .field("redo_depth", &self.redo_stack.len())
            .finish_non_exhaustive()
    }
}

impl EditorState {
    fn from_doc(doc: PresentationDoc) -> Self {
        ensure_isolated_fonts();
        let mut session = Session::new();
        let pres = doc.presentation().clone();
        let title = pres.props.title.clone();
        let mut st = DocState::new(pres, None, title);
        if let Some(first) = st.doc.slides.first() {
            st.selection.slides = vec![first.id];
        }
        session.add_document(st);
        Self {
            confirmed: doc.clone(),
            optimistic_base: doc,
            session,
            local_unacked_ops: VecDeque::new(),
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            pointer_pre_doc: None,
            typing_coalesced_slide: None,
        }
    }

    /// Creates an interactive editor initialized with a blank 1-slide presentation.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if building the blank `.pptx` model fails.
    pub fn create_blank(title: &str) -> Result<Self, Error> {
        let (doc, _) = PresentationDoc::blank_with_bytes(title)?;
        Ok(Self::from_doc(doc))
    }

    /// Opens `.pptx` bytes and replays committed `tail_ops_json` into an interactive editor.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if `bytes` cannot be read or any operation in `tail_ops_json` is
    /// invalid or from a newer model version.
    pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<Self, ApplyError> {
        Self::open_with_checkpoint(bytes, tail_ops_json, None)
    }

    /// Opens `.pptx` bytes, applies an optional compaction identity checkpoint, and replays
    /// committed `tail_ops_json` into an interactive editor.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if `bytes` or `checkpoint_json` cannot be read or any operation in
    /// `tail_ops_json` is invalid or from a newer model version.
    pub fn open_with_checkpoint(
        bytes: &[u8],
        tail_ops_json: &str,
        checkpoint_json: Option<&str>,
    ) -> Result<Self, ApplyError> {
        let doc = open_with_checkpoint(bytes, tail_ops_json, checkpoint_json)?;
        Ok(Self::from_doc(doc))
    }

    fn current_doc(&self) -> PresentationDoc {
        match self.session.active() {
            Some(st) => PresentationDoc::from_parts(
                Arc::clone(&st.doc),
                Arc::clone(self.confirmed.warnings_arc()),
            ),
            None => self.optimistic_base.clone(),
        }
    }

    /// Serializes metadata for every slide in the active presentation as JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn slides_info(&self) -> Result<String, Error> {
        let doc = self.current_doc();
        let slides: Vec<Value> = doc
            .presentation()
            .slides
            .iter()
            .enumerate()
            .map(|(index, slide)| {
                json!({
                    "index": index,
                    "slide_id": slide.id.0,
                    "title": slide.title(),
                    "name": slide.name,
                    "layout_id": slide.layout.0,
                    "hidden": slide.hidden,
                    "notes": slide.notes.text(),
                    "comments_count": slide.comments.len(),
                    "shapes_count": slide.shapes.len(),
                })
            })
            .collect();
        serde_json::to_string(&slides).map_err(|err| Error::Write(err.to_string()))
    }

    /// Zero-based index of the currently active slide.
    #[must_use]
    pub fn active_slide(&self) -> usize {
        self.session.active().map_or(0, |st| st.selection.slide)
    }

    /// Switches the active slide to `slide_index` and returns updated selection info JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `slide_index` is out of bounds.
    pub fn set_active_slide(&mut self, slide_index: usize) -> Result<String, Error> {
        self.session.settle_composition();
        self.pointer_pre_doc = None;
        self.typing_coalesced_slide = None;

        let st = self
            .session
            .active_mut()
            .ok_or_else(|| Error::Invalid("no active presentation".into()))?;
        let slide_id = st
            .doc
            .slides
            .get(slide_index)
            .map(|s| s.id)
            .ok_or_else(|| {
                Error::Invalid(format!(
                    "slide index {slide_index} out of bounds (len {})",
                    st.doc.slides.len()
                ))
            })?;
        st.interaction = None;
        st.selection.slide = slide_index;
        st.selection.slides = vec![slide_id];
        st.selection.shapes.clear();
        st.selection.text = None;
        st.selection.cells = None;
        st.revision = st.revision.wrapping_add(1);

        self.selection_info()
    }

    /// Returns active slide, selected shapes, text caret/range, speaker notes, editing flag, and
    /// Undo/Redo availability as JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn selection_info(&self) -> Result<String, Error> {
        let Some(st) = self.session.active() else {
            return Err(Error::Invalid("no active presentation".into()));
        };
        let slide = st.current_slide();
        let slide_id = slide.map(|s| s.id.0);
        let notes = slide.map(|s| s.notes.text()).unwrap_or_default();
        let shapes: Vec<u32> = st.selection.shapes.iter().map(|id| id.0).collect();
        let text_sel = st.selection.text.as_ref().map(|t| {
            json!({
                "shape_id": t.shape.0,
                "anchor": [t.anchor.0, t.anchor.1],
                "caret": [t.caret.0, t.caret.1],
                "cell": t.cell.map(|(r, c)| [r, c]),
                "notes": t.notes,
            })
        });
        let text_quads: Vec<[[f64; 2]; 4]> = st
            .selection
            .text
            .as_ref()
            .filter(|text| !text.notes && text.anchor != text.caret)
            .and_then(|text| {
                let (layout, transform) = text_frame(st, text)?;
                let (start, end) = text.ordered();
                let pos = |(para, ch)| Pos { para, ch };
                Some(
                    layout
                        .selection_rects(pos(start), pos(end))
                        .into_iter()
                        .map(|r| {
                            [
                                Point::new(r.x0, r.y0),
                                Point::new(r.x1, r.y0),
                                Point::new(r.x1, r.y1),
                                Point::new(r.x0, r.y1),
                            ]
                            .map(|point| {
                                let point = transform * point;
                                [point.x, point.y]
                            })
                        })
                        .collect(),
                )
            })
            .unwrap_or_default();
        let editing = st.selection.text.is_some()
            || st.interaction.is_some()
            || st.composition.is_some()
            || self.has_local_changes();

        let payload = json!({
            "slide_id": slide_id,
            "slide_index": st.selection.slide,
            "editing": editing,
            "shapes": shapes,
            "text_sel": text_sel,
            "text_quads": text_quads,
            "notes": notes,
            "can_undo": !self.undo_stack.is_empty(),
            "can_redo": !self.redo_stack.is_empty(),
        });
        serde_json::to_string(&payload).map_err(|err| Error::Write(err.to_string()))
    }

    /// Renders `slide_index` at `scale` to straight RGBA8 pixel bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if `slide_index` or `scale` is invalid.
    pub fn render_slide_rgba(&self, slide_index: usize, scale: f32) -> Result<Vec<u8>, Error> {
        let (_, _, rgba) = render_slide_rgba(&self.current_doc(), slide_index, scale)?;
        Ok(rgba)
    }

    /// Returns `[width_px, height_px]` for slides rendered at `scale`.
    #[must_use]
    pub fn slide_pixel_size(&self, scale: f32) -> Vec<u32> {
        match slide_pixel_dimensions(self.current_doc().presentation(), scale) {
            Ok((w, h)) => vec![w, h],
            Err(_) => vec![0, 0],
        }
    }

    /// Renders `slide_index` at `scale` to encoded PNG bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if `slide_index` or `scale` is invalid or PNG encoding fails.
    pub fn render_slide_png(&self, slide_index: usize, scale: f32) -> Result<Vec<u8>, Error> {
        render_slide_png(&self.current_doc(), slide_index, scale)
    }

    /// Executes a safe DeckCraft command on the local session and records a personal Undo step.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `command_id` is blocked, `params_json` is malformed, the
    /// command fails, or newly added media exceeds [`MAX_PICTURE_BYTES`].
    pub fn execute_command(
        &mut self,
        command_id: &str,
        params_json: &str,
    ) -> Result<String, Error> {
        let trimmed = command_id.trim();
        if is_blocked_command(trimmed) || matches!(trimmed, "edit.undo" | "edit.redo") {
            return Err(Error::Invalid(format!(
                "command `{trimmed}` is not permitted; use dedicated editor methods where applicable"
            )));
        }
        let params: Value = if params_json.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(params_json)
                .map_err(|err| Error::Invalid(format!("invalid command params JSON: {err}")))?
        };

        self.typing_coalesced_slide = None;
        let (before_pres, before_sel) = self.snapshot_session_state()?;
        let existing_media: HashSet<MediaId> = before_pres.media.iter().map(|m| m.id).collect();

        let out = self
            .session
            .execute(trimmed, &params)
            .map_err(|err| Error::Invalid(err.to_string()))?;

        if let Err(err) = self.enforce_media_limit(&before_pres, &existing_media) {
            self.restore_session_state(before_pres, before_sel);
            return Err(err);
        }

        if let Some(after_pres) = self.session.active().map(|st| Arc::clone(&st.doc)) {
            self.record_undo_from_diff(&before_pres, &after_pres);
        }

        serde_json::to_string(&out).map_err(|err| Error::Write(err.to_string()))
    }

    /// Dispatches a pointer gesture event in slide coordinates (points) to the session tool.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `event_json` is malformed or tool execution fails.
    pub fn pointer_event(&mut self, event_json: &str) -> Result<String, Error> {
        let parsed = parse_pointer_input(event_json)?;
        if let Some(tool) = parsed.tool {
            self.session.set_tool(tool);
        }
        if matches!(parsed.event.kind, PointerKind::Down) {
            self.typing_coalesced_slide = None;
            self.pointer_pre_doc = self.session.active().map(|st| Arc::clone(&st.doc));
        }
        let single_gesture_before = if matches!(
            parsed.event.kind,
            PointerKind::DoubleClick | PointerKind::TripleClick | PointerKind::ContextClick
        ) {
            self.typing_coalesced_slide = None;
            self.session.active().map(|st| Arc::clone(&st.doc))
        } else {
            None
        };

        let out = self
            .session
            .pointer(parsed.event)
            .map_err(|err| Error::Invalid(err.to_string()))?;

        if matches!(parsed.event.kind, PointerKind::Up)
            && let Some(before) = self.pointer_pre_doc.take()
            && let Some(after) = self.session.active().map(|st| Arc::clone(&st.doc))
        {
            self.record_undo_from_diff(&before, &after);
        } else if let Some(before) = single_gesture_before
            && let Some(after) = self.session.active().map(|st| Arc::clone(&st.doc))
        {
            self.record_undo_from_diff(&before, &after);
        }

        serde_json::to_string(&out).map_err(|err| Error::Write(err.to_string()))
    }

    /// Dispatches a keyboard event to the session, coalescing consecutive typing Undo snapshots on
    /// the same slide.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `mods_json` is malformed or key execution fails.
    pub fn key_event(&mut self, key: &str, mods_json: &str) -> Result<String, Error> {
        let mods = parse_mods(mods_json)?;
        if shortcut_is_blocked(key, mods) {
            return Ok(json!({"handled": false}).to_string());
        }

        let before = self
            .session
            .active()
            .map(|st| (Arc::clone(&st.doc), st.selection.text.is_some()))
            .ok_or_else(|| Error::Invalid("no active presentation".into()))?;

        let mut out = self
            .session
            .key(key, mods)
            .map_err(|err| Error::Invalid(err.to_string()))?;

        let handled = out.get("handled").and_then(Value::as_bool).unwrap_or(false);
        let is_plain_char = !mods.cmd
            && !mods.alt
            && key.chars().count() == 1
            && !key.chars().any(char::is_control);

        if !handled && before.1 && is_plain_char {
            let r = self
                .session
                .execute("text.insert", &json!({ "text": key }))
                .map_err(|err| Error::Invalid(err.to_string()))?;
            out = json!({
                "handled": true,
                "command": "text.insert",
                "result": r,
            });
        }

        if let Some(after) = self.session.active().map(|st| Arc::clone(&st.doc))
            && !Arc::ptr_eq(&before.0, &after)
        {
            if before.1 && is_plain_char {
                if let Some(changed_slide) = single_changed_slide(&before.0, &after) {
                    if self.typing_coalesced_slide != Some(changed_slide.slide_id) {
                        self.push_undo_snapshot(changed_slide.slide_id, changed_slide.slide);
                        self.typing_coalesced_slide = Some(changed_slide.slide_id);
                    }
                } else {
                    self.typing_coalesced_slide = None;
                    self.record_undo_from_diff(&before.0, &after);
                }
            } else {
                self.typing_coalesced_slide = None;
                self.record_undo_from_diff(&before.0, &after);
            }
        }

        serde_json::to_string(&out).map_err(|err| Error::Write(err.to_string()))
    }

    /// Replaces the speaker notes plain text of `slide_id` and records a personal Undo snapshot.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `slide_id` does not exist in the presentation.
    pub fn set_slide_notes(&mut self, slide_id: u32, notes: &str) -> Result<(), Error> {
        self.session.settle_composition();
        self.typing_coalesced_slide = None;

        let st = self
            .session
            .active_mut()
            .ok_or_else(|| Error::Invalid("no active presentation".into()))?;
        let target = SlideId(slide_id);
        let pos = st
            .doc
            .slides
            .iter()
            .position(|s| s.id == target)
            .ok_or_else(|| Error::Invalid(format!("slide {slide_id} does not exist")))?;

        let prior_slide = st
            .doc
            .slides
            .get(pos)
            .cloned()
            .ok_or_else(|| Error::Invalid(format!("slide {slide_id} does not exist")))?;
        if prior_slide.notes.text() == notes.replace("\r\n", "\n").replace('\r', "\n") {
            return Ok(());
        }

        let mut next_pres = (*st.doc).clone();
        if let Some(slot) = next_pres.slides.get_mut(pos) {
            Arc::make_mut(slot).notes = TextBody::from_text(notes);
        }
        next_pres.fix_next_id();
        st.doc = Arc::new(next_pres);
        st.revision = st.revision.wrapping_add(1);

        self.push_undo_snapshot(target, prior_slide);
        Ok(())
    }

    /// Reports whether the session holds uncommitted local edits relative to `optimistic_base`.
    #[must_use]
    pub fn has_local_changes(&self) -> bool {
        let cur = self.current_doc();
        derive(&self.optimistic_base, &cur).ok().flatten().is_some()
    }

    /// Derives a canonical [`ChangeSet`] JSON string from `optimistic_base` to the current session
    /// state and advances `optimistic_base`, returning `Ok(None)` when nothing changed.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if the derived operation violates wire or media size limits.
    pub fn commit_local_step(&mut self) -> Result<Option<String>, Error> {
        self.session.end_composition();
        self.typing_coalesced_slide = None;

        let cur = self.current_doc();
        let Some(cs) = derive(&self.optimistic_base, &cur)? else {
            return Ok(None);
        };
        validate_changeset(&cs, true).map_err(apply_error_to_error)?;
        let encoded = serde_json::to_string(&cs).map_err(|err| Error::Write(err.to_string()))?;
        if encoded.len() > MAX_OP_BYTES {
            return Err(Error::Invalid(format!(
                "derived operation size {} exceeds maximum {} bytes",
                encoded.len(),
                MAX_OP_BYTES
            )));
        }

        let applied =
            apply_parsed(&self.optimistic_base, cs, &[], None).map_err(apply_error_to_error)?;
        self.optimistic_base = applied.doc;
        self.local_unacked_ops.push_back(applied.op);
        if let Some(st) = self.session.active_mut() {
            st.doc = Arc::clone(self.optimistic_base.presentation_arc());
        }
        Ok(Some(encoded))
    }

    /// Advances `confirmed` by `confirmed_ops_json`, rebases `pending_ops_json` and any
    /// uncommitted local draft onto `confirmed`, updates the session while preserving valid
    /// selection state, and returns `{dropped_pending, draft_conflict, conflict_reason, active_slide_id}`.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if `confirmed_ops_json` or `pending_ops_json` is malformed or comes
    /// from a newer `model_version`.
    pub fn apply_remote(
        &mut self,
        confirmed_ops_json: &str,
        pending_ops_json: &str,
    ) -> Result<String, ApplyError> {
        self.session.settle_composition();
        self.pointer_pre_doc = None;
        self.typing_coalesced_slide = None;

        let confirmed_ops = parse_changeset_list(confirmed_ops_json)?;
        let pending_ops = parse_changeset_list(pending_ops_json)?;

        let cur_doc = self.current_doc();
        let local_draft = derive(&self.optimistic_base, &cur_doc)?;

        // Determine how many locally committed steps were acknowledged vs foreign remote ops.
        let acked_budget = self
            .local_unacked_ops
            .len()
            .saturating_sub(pending_ops.len());
        let mut acked_used = 0usize;
        let mut foreign_ops = Vec::new();
        for op in &confirmed_ops {
            let is_own_ack = acked_used < acked_budget
                && self
                    .local_unacked_ops
                    .front()
                    .is_some_and(|front| changesets_match_modulo_authors(front, op));
            if is_own_ack {
                let _ = self.local_unacked_ops.pop_front();
                acked_used += 1;
            } else {
                foreign_ops.push(op.clone());
            }
        }

        // Advance `self.confirmed` through all newly confirmed server operations.
        let mut next_confirmed_pres = self.confirmed.presentation().clone();
        for op in &confirmed_ops {
            next_confirmed_pres = apply_changeset_to_presentation(&next_confirmed_pres, op)?;
        }
        let next_confirmed = PresentationDoc::from_parts(
            Arc::new(next_confirmed_pres),
            Arc::clone(self.confirmed.warnings_arc()),
        );
        self.confirmed = next_confirmed.clone();

        // Update personal Undo/Redo stacks in response to foreign remote operations.
        self.prune_undo_for_foreign_ops(&foreign_ops);

        // Rebase queued pending operations over `foreign_ops` on top of `self.confirmed`.
        let mut rebased_base = next_confirmed;
        let mut surviving_pending = VecDeque::new();
        let mut pending_results = Vec::with_capacity(pending_ops.len());
        let mut dropped_pending = 0usize;
        let mut first_conflict_reason: Option<String> = None;

        for pending in pending_ops {
            match apply_parsed(&rebased_base, pending, &foreign_ops, None) {
                Ok(applied) => {
                    rebased_base = applied.doc;
                    pending_results.push(json!({ "op": &applied.op }));
                    surviving_pending.push_back(applied.op);
                }
                Err(ApplyError::Conflict(conflict)) => {
                    dropped_pending += 1;
                    let reason = conflict.as_str().to_string();
                    if first_conflict_reason.is_none() {
                        first_conflict_reason = Some(reason.clone());
                    }
                    pending_results.push(json!({ "conflict": reason }));
                    self.undo_stack.clear();
                    self.redo_stack.clear();
                }
                Err(err) => return Err(err),
            }
        }

        self.optimistic_base = rebased_base.clone();
        self.local_unacked_ops = surviving_pending;

        // Rebase any uncommitted local draft on top of `self.optimistic_base`.
        let mut draft_conflict = false;
        let final_session_doc = if let Some(draft) = local_draft {
            match apply_parsed(&self.optimistic_base, draft, &foreign_ops, None) {
                Ok(applied) => applied.doc,
                Err(ApplyError::Conflict(conflict)) => {
                    draft_conflict = true;
                    if first_conflict_reason.is_none() {
                        first_conflict_reason = Some(conflict.as_str().to_string());
                    }
                    self.undo_stack.clear();
                    self.redo_stack.clear();
                    self.optimistic_base.clone()
                }
                Err(err) => return Err(err),
            }
        } else {
            self.optimistic_base.clone()
        };

        let active_slide_id = self.sync_session_doc(&final_session_doc, draft_conflict);

        let report = json!({
            "dropped_pending": dropped_pending,
            "draft_conflict": draft_conflict,
            "conflict_reason": first_conflict_reason,
            "active_slide_id": active_slide_id,
            "pending_results": pending_results,
        });
        serde_json::to_string(&report)
            .map_err(|err| ApplyError::Error(Error::Write(err.to_string())))
    }

    /// Discards all pending and draft local state, restoring the session to `confirmed`.
    pub fn reset_to_confirmed(&mut self) {
        self.session.settle_composition();
        self.pointer_pre_doc = None;
        self.typing_coalesced_slide = None;
        self.local_unacked_ops.clear();
        self.undo_stack.clear();
        self.redo_stack.clear();
        self.optimistic_base = self.confirmed.clone();
        let target = self.confirmed.clone();
        let _ = self.sync_session_doc(&target, true);
    }

    /// Restores the most recent personal slide snapshot, pushes the current slide onto the Redo
    /// stack, updates `optimistic_base`, and returns the derived `slide.put` [`ChangeSet`] JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if deriving or serializing the undo change set fails.
    pub fn undo(&mut self) -> Result<Option<String>, Error> {
        self.apply_snapshot_step(true)
    }

    /// Re-applies the most recent undone slide snapshot, pushes the current slide onto the Undo
    /// stack, updates `optimistic_base`, and returns the derived `slide.put` [`ChangeSet`] JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if deriving or serializing the redo change set fails.
    pub fn redo(&mut self) -> Result<Option<String>, Error> {
        self.apply_snapshot_step(false)
    }

    fn apply_snapshot_step(&mut self, is_undo: bool) -> Result<Option<String>, Error> {
        self.session.settle_composition();
        self.pointer_pre_doc = None;
        self.typing_coalesced_slide = None;

        let snapshot = if is_undo {
            self.undo_stack.pop()
        } else {
            self.redo_stack.pop()
        };
        let Some(snap) = snapshot else {
            return Ok(None);
        };

        let st = self
            .session
            .active_mut()
            .ok_or_else(|| Error::Invalid("no active presentation".into()))?;
        let Some(pos) = st.doc.slides.iter().position(|s| s.id == snap.slide_id) else {
            self.undo_stack.clear();
            self.redo_stack.clear();
            return Ok(None);
        };
        let Some(current_slide) = st.doc.slides.get(pos).cloned() else {
            return Ok(None);
        };

        if is_undo {
            self.redo_stack.push(SlideSnapshot {
                slide_id: snap.slide_id,
                slide: current_slide,
            });
        } else {
            self.undo_stack.push(SlideSnapshot {
                slide_id: snap.slide_id,
                slide: current_slide,
            });
        }

        let mut next_pres = (*st.doc).clone();
        if let Some(slot) = next_pres.slides.get_mut(pos) {
            *slot = snap.slide;
        }
        next_pres.fix_next_id();
        st.doc = Arc::new(next_pres);
        st.selection.slide = pos;
        st.selection.slides = vec![snap.slide_id];
        clamp_editor_selection(st);
        st.revision = st.revision.wrapping_add(1);

        let cur_doc = self.current_doc();
        let Some(cs) = derive(&self.optimistic_base, &cur_doc)? else {
            return Ok(None);
        };
        let encoded = serde_json::to_string(&cs).map_err(|err| Error::Write(err.to_string()))?;
        let applied =
            apply_parsed(&self.optimistic_base, cs, &[], None).map_err(apply_error_to_error)?;
        self.optimistic_base = applied.doc;
        self.local_unacked_ops.push_back(applied.op);
        if let Some(active_st) = self.session.active_mut() {
            active_st.doc = Arc::clone(self.optimistic_base.presentation_arc());
        }
        Ok(Some(encoded))
    }

    /// Searches the current presentation for `query` and returns JSON array of [`crate::FindMatch`].
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn find(&self, query: &str, match_case: bool) -> Result<String, Error> {
        let matches = find(&self.current_doc(), query, match_case);
        serde_json::to_string(&matches).map_err(|err| Error::Write(err.to_string()))
    }

    /// Returns plain text of the active text range, selected table cells, or selected shapes.
    #[must_use]
    pub fn selected_text(&self) -> String {
        let Some(st) = self.session.active() else {
            return String::new();
        };
        if let Some(t) = &st.selection.text {
            if t.is_range() {
                let Some(body) = body_of(st, t) else {
                    return String::new();
                };
                let (a, b) = t.ordered();
                return deckcraft_model::edit::text_range(body, a, b);
            }
            return String::new();
        }
        if let Some((table_id, (r0, c0), (r1, c1))) = st.selection.cells
            && let Some(sh) = st.shape(table_id)
            && let ShapeKind::Table(table) = &sh.kind
        {
            let row_lo = r0.min(r1);
            let row_hi = r0.max(r1);
            let col_lo = c0.min(c1);
            let col_hi = c0.max(c1);
            let mut rows_txt = Vec::new();
            for r in row_lo..=row_hi {
                if let Some(row) = table.rows.get(r) {
                    let mut cols_txt = Vec::new();
                    for c in col_lo..=col_hi {
                        if let Some(cell) = row.cells.get(c) {
                            cols_txt.push(cell.text.text());
                        }
                    }
                    rows_txt.push(cols_txt.join("\t"));
                }
            }
            return rows_txt.join("\n");
        }
        st.selection
            .shapes
            .iter()
            .filter_map(|id| st.shape(*id))
            .map(shape_plain_text)
            .filter(|txt| !txt.is_empty())
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// Lists safe editor commands matching `query` as JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn commands(&self, query: &str) -> Result<String, Error> {
        let filter = if query.trim().is_empty() {
            None
        } else {
            Some(query)
        };
        serde_json::to_string(&commands(filter)).map_err(|err| Error::Write(err.to_string()))
    }

    /// Exports the current presentation state as `.pptx` bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if `.pptx` serialization fails.
    pub fn export_pptx(&self) -> Result<Vec<u8>, Error> {
        export_pptx(&self.current_doc())
    }

    /// Exports the current presentation state as PDF bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if PDF serialization fails.
    pub fn export_pdf(&self) -> Result<Vec<u8>, Error> {
        export_pdf(&self.current_doc())
    }

    /// Decodes embedded fonts carried in the presentation (`embedded_fonts` and `application/x-fontdata`
    /// media items) through `deckcraft_fonts::embedded_sfnt` and registers them in this Worker's
    /// `FontDb`, returning the number of font faces added.
    #[must_use]
    pub fn load_embedded_fonts(&self) -> usize {
        ensure_isolated_fonts();
        let cur = self.current_doc();
        let pres = cur.presentation();
        let db = FontDb::global();
        let mut seen_media = HashSet::new();
        let mut added = 0usize;

        for ef in &pres.embedded_fonts {
            for media_id in ef.faces().into_iter().flatten() {
                if seen_media.insert(media_id)
                    && let Some(item) = pres.media(media_id)
                    && let Some(sfnt) = deckcraft_fonts::embedded_sfnt(&item.data)
                {
                    added += db.add_font(sfnt.to_vec());
                }
            }
        }

        for item in &pres.media {
            if seen_media.contains(&item.id) {
                continue;
            }
            let lower = item.name.to_ascii_lowercase();
            let is_font = item.content_type == "application/x-fontdata"
                || lower.ends_with(".fntdata")
                || lower.ends_with(".ttf")
                || lower.ends_with(".otf");
            if is_font && let Some(sfnt) = deckcraft_fonts::embedded_sfnt(&item.data) {
                let _ = seen_media.insert(item.id);
                added += db.add_font(sfnt.to_vec());
            }
        }

        added
    }

    /// Adds a raw `.ttf` / `.otf` / `.ttc` font blob to this Worker's `FontDb` and returns the
    /// number of font faces loaded.
    #[must_use]
    pub fn add_font(bytes: &[u8]) -> usize {
        ensure_isolated_fonts();
        FontDb::global().add_font(bytes.to_vec())
    }

    /// Reports requested font families in the presentation that are missing from `FontDb` together
    /// with the actual face family substituted by DeckCraft.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn substituted_fonts(&self) -> Result<String, Error> {
        ensure_isolated_fonts();
        let cur = self.current_doc();
        let missing = deckcraft_engine::fonts::missing_fonts(cur.presentation());
        let db = FontDb::global();
        let items: Vec<Value> = missing
            .into_iter()
            .map(|family| {
                let actual = db.document_face(&family, "Regular").family.clone();
                json!({
                    "requested": family,
                    "substituted": actual,
                })
            })
            .collect();
        serde_json::to_string(&items).map_err(|err| Error::Write(err.to_string()))
    }

    /// Lists canonical site fallback font families needed to cover CJK characters in the current
    /// presentation that no loaded font face in `FontDb::global()` maps yet.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn missing_glyph_fonts(&self) -> Result<String, Error> {
        ensure_isolated_fonts();
        let cur = self.current_doc();
        let families = collect_missing_cjk_families(cur.presentation());
        serde_json::to_string(&families).map_err(|err| Error::Write(err.to_string()))
    }

    /// Returns import warnings recorded when the presentation was opened, as a JSON string array.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn warnings(&self) -> Result<String, Error> {
        serde_json::to_string(self.confirmed.warnings())
            .map_err(|err| Error::Write(err.to_string()))
    }

    fn snapshot_session_state(
        &self,
    ) -> Result<(Arc<Presentation>, deckcraft_engine::Selection), Error> {
        let st = self
            .session
            .active()
            .ok_or_else(|| Error::Invalid("no active presentation".into()))?;
        Ok((Arc::clone(&st.doc), st.selection.clone()))
    }

    fn restore_session_state(
        &mut self,
        doc: Arc<Presentation>,
        selection: deckcraft_engine::Selection,
    ) {
        if let Some(st) = self.session.active_mut() {
            st.doc = doc;
            st.selection = selection;
            st.revision = st.revision.wrapping_add(1);
        }
    }

    fn enforce_media_limit(
        &self,
        before: &Presentation,
        existing_media: &HashSet<MediaId>,
    ) -> Result<(), Error> {
        let Some(st) = self.session.active() else {
            return Ok(());
        };
        for item in &st.doc.media {
            let changed = !existing_media.contains(&item.id)
                || before.media(item.id).is_some_and(|old| {
                    !Arc::ptr_eq(&old.data, &item.data) && *old.data != *item.data
                });
            if changed && item.data.len() > MAX_PICTURE_BYTES {
                return Err(Error::Invalid(format!(
                    "media item {} ({} bytes) exceeds maximum {} bytes",
                    item.id.0,
                    item.data.len(),
                    MAX_PICTURE_BYTES
                )));
            }
        }
        Ok(())
    }

    fn record_undo_from_diff(&mut self, before: &Arc<Presentation>, after: &Arc<Presentation>) {
        if Arc::ptr_eq(before, after) {
            return;
        }
        let b_doc = PresentationDoc::from_parts(Arc::clone(before), Arc::new(Vec::new()));
        let a_doc = PresentationDoc::from_parts(Arc::clone(after), Arc::new(Vec::new()));
        let Ok(Some(cs)) = derive(&b_doc, &a_doc) else {
            return;
        };

        let mut changed_slides = Vec::new();
        for edit in &cs.edits {
            match edit {
                Edit::SlidesOrder { .. } | Edit::DeckSet { .. } => {
                    self.undo_stack.clear();
                    self.redo_stack.clear();
                    return;
                }
                Edit::SlidePut { slide, .. } => {
                    changed_slides.push(SlideId(*slide));
                }
                Edit::MediaPut { .. } | Edit::MediaDelete { .. } => {}
            }
        }

        if let [only_slide_id] = changed_slides.as_slice()
            && let Some(prior_arc) = before.slides.iter().find(|s| s.id == *only_slide_id)
        {
            self.push_undo_snapshot(*only_slide_id, Arc::clone(prior_arc));
        } else if changed_slides.len() > 1 {
            self.undo_stack.clear();
            self.redo_stack.clear();
        }
    }

    fn push_undo_snapshot(&mut self, slide_id: SlideId, slide: Arc<Slide>) {
        self.redo_stack.clear();
        if self.undo_stack.len() >= MAX_UNDO_SNAPSHOTS {
            let _ = self.undo_stack.remove(0);
        }
        self.undo_stack.push(SlideSnapshot { slide_id, slide });
    }

    fn prune_undo_for_foreign_ops(&mut self, foreign_ops: &[ChangeSet]) {
        if foreign_ops.is_empty() {
            return;
        }
        let mut touched_slides = HashSet::new();
        for cs in foreign_ops {
            for edit in &cs.edits {
                match edit {
                    Edit::SlidesOrder { .. } | Edit::DeckSet { .. } => {
                        self.undo_stack.clear();
                        self.redo_stack.clear();
                        return;
                    }
                    Edit::SlidePut { slide, .. } => {
                        touched_slides.insert(SlideId(*slide));
                    }
                    Edit::MediaPut { .. } | Edit::MediaDelete { .. } => {}
                }
            }
        }
        if !touched_slides.is_empty() {
            let hits_stack = self
                .undo_stack
                .iter()
                .chain(self.redo_stack.iter())
                .any(|snap| touched_slides.contains(&snap.slide_id));
            if hits_stack {
                self.undo_stack.clear();
                self.redo_stack.clear();
            }
        }
    }

    fn sync_session_doc(&mut self, doc: &PresentationDoc, clear_text_edit: bool) -> Option<u32> {
        let st = self.session.active_mut()?;
        let prev_slide_id = st.current_slide().map(|s| s.id);
        let prev_slide_idx = st.selection.slide;

        st.doc = Arc::clone(doc.presentation_arc());
        st.interaction = None;
        st.composition = None;

        if let Some(sid) = prev_slide_id
            && let Some(new_idx) = st.doc.slides.iter().position(|s| s.id == sid)
        {
            st.selection.slide = new_idx;
            st.selection.slides = vec![sid];
        } else if st.doc.slides.is_empty() {
            st.selection.slide = 0;
            st.selection.slides.clear();
            st.selection.shapes.clear();
            st.selection.text = None;
            st.selection.cells = None;
        } else {
            let clamped = prev_slide_idx.min(st.doc.slides.len().saturating_sub(1));
            st.selection.slide = clamped;
            st.selection.slides = st
                .doc
                .slides
                .get(clamped)
                .map(|s| vec![s.id])
                .unwrap_or_default();
            st.selection.shapes.clear();
            st.selection.text = None;
            st.selection.cells = None;
        }

        if clear_text_edit {
            st.selection.text = None;
        }
        clamp_editor_selection(st);
        st.revision = st.revision.wrapping_add(1);
        st.current_slide().map(|s| s.id.0)
    }
}

fn clamp_editor_selection(st: &mut DocState) {
    let surviving: Vec<_> = st
        .selection
        .shapes
        .iter()
        .copied()
        .filter(|id| st.shape(*id).is_some())
        .collect();
    st.selection.shapes = surviving;
    if let Some((table_id, _, _)) = st.selection.cells
        && st.shape(table_id).is_none()
    {
        st.selection.cells = None;
    }
    let valid_text = if let Some(t) = &st.selection.text {
        body_of(st, t).map(|body| clamp_text_sel(body, t))
    } else {
        None
    };
    st.selection.text = valid_text;
}

fn clamp_text_sel(body: &TextBody, sel: &TextSel) -> TextSel {
    let clamp_pos = |pos: (usize, usize)| -> (usize, usize) {
        if body.paragraphs.is_empty() {
            return (0, 0);
        }
        let p_idx = pos.0.min(body.paragraphs.len().saturating_sub(1));
        let p_len = body.paragraphs.get(p_idx).map_or(0, |p| p.char_len());
        (p_idx, pos.1.min(p_len))
    };
    let mut next = sel.clone();
    next.anchor = clamp_pos(sel.anchor);
    next.caret = clamp_pos(sel.caret);
    next
}

fn single_changed_slide(before: &Presentation, after: &Presentation) -> Option<SlideSnapshot> {
    if before.slides.len() != after.slides.len() {
        return None;
    }
    let mut found: Option<SlideSnapshot> = None;
    for (b_slide, a_slide) in before.slides.iter().zip(after.slides.iter()) {
        if b_slide.id != a_slide.id {
            return None;
        }
        if !Arc::ptr_eq(b_slide, a_slide) && **b_slide != **a_slide {
            if found.is_some() {
                return None;
            }
            found = Some(SlideSnapshot {
                slide_id: b_slide.id,
                slide: Arc::clone(b_slide),
            });
        }
    }
    found
}

fn changesets_match_modulo_authors(local_op: &ChangeSet, server_op: &ChangeSet) -> bool {
    if local_op.model_version != server_op.model_version
        || local_op.edits.len() != server_op.edits.len()
    {
        return false;
    }
    local_op
        .edits
        .iter()
        .zip(server_op.edits.iter())
        .all(|(l, r)| match (l, r) {
            (
                Edit::SlidePut {
                    slide: s1,
                    value: v1,
                },
                Edit::SlidePut {
                    slide: s2,
                    value: v2,
                },
            ) => s1 == s2 && slides_equal_modulo_comment_authors(v1, v2),
            (
                Edit::SlidesOrder {
                    order: o1,
                    insert: i1,
                },
                Edit::SlidesOrder {
                    order: o2,
                    insert: i2,
                },
            ) => {
                o1 == o2
                    && i1.len() == i2.len()
                    && i1.iter().zip(i2.iter()).all(|(a, b)| {
                        a.id == b.id && slides_equal_modulo_comment_authors(&a.value, &b.value)
                    })
            }
            _ => l == r,
        })
}

fn slides_equal_modulo_comment_authors(a: &Slide, b: &Slide) -> bool {
    if a == b {
        return true;
    }
    let mut a_norm = a.clone();
    let mut b_norm = b.clone();
    clear_comment_authors(&mut a_norm.comments, 0);
    clear_comment_authors(&mut b_norm.comments, 0);
    a_norm == b_norm
}

fn clear_comment_authors(comments: &mut [deckcraft_model::Comment], depth: usize) {
    if depth > 32 {
        return;
    }
    for c in comments {
        c.author.clear();
        c.initials.clear();
        clear_comment_authors(&mut c.replies, depth + 1);
    }
}

fn apply_error_to_error(err: ApplyError) -> Error {
    match err {
        ApplyError::Error(e) => e,
        ApplyError::Conflict(c) => Error::Invalid(c.as_str().to_string()),
        ApplyError::FutureVersion { found, supported } => Error::Invalid(format!(
            "future_model_version: operation model_version {found} exceeds supported version {supported}"
        )),
    }
}

struct ParsedPointer {
    event: PointerEvent,
    tool: Option<ToolKind>,
}

#[derive(Default, Deserialize)]
struct FlexibleMods {
    #[serde(default)]
    shift: bool,
    #[serde(default)]
    alt: bool,
    #[serde(default)]
    cmd: bool,
    #[serde(default)]
    ctrl: bool,
    #[serde(default)]
    meta: bool,
}

impl FlexibleMods {
    fn into_mods(self) -> Mods {
        Mods {
            shift: self.shift,
            alt: self.alt,
            cmd: self.cmd || self.ctrl || self.meta,
        }
    }
}

fn parse_mods(mods_json: &str) -> Result<Mods, Error> {
    if mods_json.trim().is_empty() {
        return Ok(Mods::default());
    }
    let flex: FlexibleMods = serde_json::from_str(mods_json)
        .map_err(|err| Error::Invalid(format!("invalid key modifiers JSON: {err}")))?;
    Ok(flex.into_mods())
}

fn parse_pointer_input(event_json: &str) -> Result<ParsedPointer, Error> {
    let val: Value = serde_json::from_str(event_json)
        .map_err(|err| Error::Invalid(format!("invalid pointer event JSON: {err}")))?;
    let obj = val
        .as_object()
        .ok_or_else(|| Error::Invalid("pointer event must be a JSON object".into()))?;

    let kind_str = obj
        .get("kind")
        .or_else(|| obj.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("down");
    let kind = match kind_str.to_ascii_lowercase().as_str() {
        "down" | "pointerdown" | "mousedown" => PointerKind::Down,
        "drag" => PointerKind::Drag,
        "up" | "pointerup" | "mouseup" => PointerKind::Up,
        "move" | "pointermove" | "mousemove" | "hover" => PointerKind::Move,
        "doubleclick" | "double_click" | "dblclick" => PointerKind::DoubleClick,
        "tripleclick" | "triple_click" => PointerKind::TripleClick,
        "contextclick" | "context_click" | "contextmenu" => PointerKind::ContextClick,
        other => {
            return Err(Error::Invalid(format!(
                "unknown pointer event kind `{other}`"
            )));
        }
    };

    let x = obj
        .get("x")
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::Invalid("pointer event requires numeric `x`".into()))?;
    let y = obj
        .get("y")
        .and_then(Value::as_f64)
        .ok_or_else(|| Error::Invalid("pointer event requires numeric `y`".into()))?;
    let tol = obj.get("tol").and_then(Value::as_f64).unwrap_or(4.0);
    let pressure = obj
        .get("pressure")
        .and_then(Value::as_f64)
        .map(|v| v as f32);

    let mods = if let Some(m_val) = obj.get("mods") {
        let flex: FlexibleMods = serde_json::from_value(m_val.clone())
            .map_err(|err| Error::Invalid(format!("invalid pointer mods: {err}")))?;
        flex.into_mods()
    } else {
        let flex: FlexibleMods = serde_json::from_value(val.clone()).unwrap_or_default();
        flex.into_mods()
    };

    let tool = match obj.get("tool") {
        Some(t_val) if !t_val.is_null() => Some(
            serde_json::from_value::<ToolKind>(t_val.clone())
                .map_err(|err| Error::Invalid(format!("invalid pointer tool: {err}")))?,
        ),
        _ => None,
    };

    Ok(ParsedPointer {
        event: PointerEvent {
            kind,
            x,
            y,
            mods,
            tol,
            pressure,
        },
        tool,
    })
}

fn shortcut_is_blocked(key: &str, mods: Mods) -> bool {
    let tok = key_token(key);
    let key_name = match tok.as_str() {
        "left" => "Left",
        "right" => "Right",
        "up" => "Up",
        "down" => "Down",
        "enter" | "return" => "Enter",
        "escape" | "esc" => "Escape",
        "delete" => "Delete",
        "backspace" => "Backspace",
        "pageup" => "PageUp",
        "pagedown" => "PageDown",
        "home" => "Home",
        "end" => "End",
        "tab" => "Tab",
        "space" | " " => "Space",
        other => other,
    };
    command_specs().iter().any(|spec| {
        spec.shortcut
            .is_some_and(|sc| shortcut_matches(sc, key_name, mods))
            && (is_blocked_command(spec.id) || matches!(spec.id, "edit.undo" | "edit.redo"))
    })
}

fn collect_missing_cjk_families(pres: &Presentation) -> Vec<&'static str> {
    let mut cjk_chars = std::collections::BTreeSet::new();
    for slide in &pres.slides {
        collect_cjk_in_shapes(&slide.shapes, &mut cjk_chars);
        collect_cjk_in_text_body(&slide.notes, &mut cjk_chars);
    }
    for master in pres
        .masters
        .iter()
        .chain(pres.notes_master.iter())
        .chain(pres.handout_master.iter())
    {
        collect_cjk_in_shapes(&master.shapes, &mut cjk_chars);
        for layout in &master.layouts {
            collect_cjk_in_shapes(&layout.shapes, &mut cjk_chars);
        }
    }
    collect_cjk_in_str(&pres.header_footer.footer_text, &mut cjk_chars);
    collect_cjk_in_str(&pres.header_footer.date_text, &mut cjk_chars);

    if cjk_chars.is_empty() {
        return Vec::new();
    }

    let db = FontDb::global();
    let uncovered: Vec<char> = cjk_chars
        .into_iter()
        .filter(|&c| db.fallback_for(c, 0).is_none())
        .collect();
    if uncovered.is_empty() {
        return Vec::new();
    }

    select_cjk_fallback_families(&uncovered, |fam| db.has_family(fam))
}

fn collect_cjk_in_shapes(
    shapes: &[deckcraft_model::Shape],
    out: &mut std::collections::BTreeSet<char>,
) {
    deckcraft_model::walk(shapes, &mut |shape, _| {
        if let Some(tb) = &shape.text {
            collect_cjk_in_text_body(tb, out);
        }
        match &shape.kind {
            ShapeKind::Table(table) => {
                for row in &table.rows {
                    for cell in &row.cells {
                        collect_cjk_in_text_body(&cell.text, out);
                    }
                }
            }
            ShapeKind::Chart(chart) => {
                if let Some(title) = &chart.title {
                    collect_cjk_in_str(title, out);
                }
                for cat in &chart.categories {
                    collect_cjk_in_str(cat, out);
                }
                for series in &chart.series {
                    collect_cjk_in_str(&series.name, out);
                }
                for axis_title in [&chart.axis_titles.0, &chart.axis_titles.1]
                    .into_iter()
                    .flatten()
                {
                    collect_cjk_in_str(axis_title, out);
                }
            }
            _ => {}
        }
        if let Some(diagram) = &shape.diagram {
            for node in &diagram.nodes {
                collect_cjk_in_str(&node.text, out);
                collect_cjk_in_str(&node.title, out);
            }
        }
    });
}

fn collect_cjk_in_text_body(tb: &TextBody, out: &mut std::collections::BTreeSet<char>) {
    for para in &tb.paragraphs {
        for run in &para.runs {
            collect_cjk_in_str(&run.text, out);
        }
    }
}

fn collect_cjk_in_str(s: &str, out: &mut std::collections::BTreeSet<char>) {
    out.extend(s.chars().filter(|&c| is_cjk_char(c)));
}

const fn is_cjk_char(c: char) -> bool {
    matches!(
        c,
        '\u{1100}'..='\u{11FF}'
            | '\u{2E80}'..='\u{2FDF}'
            | '\u{3000}'..='\u{33FF}'
            | '\u{3400}'..='\u{4DBF}'
            | '\u{4E00}'..='\u{9FFF}'
            | '\u{AC00}'..='\u{D7AF}'
            | '\u{F900}'..='\u{FAFF}'
            | '\u{FE30}'..='\u{FE4F}'
            | '\u{FF00}'..='\u{FFEF}'
            | '\u{20000}'..='\u{3FFFF}'
    )
}

fn select_cjk_fallback_families(
    uncovered: &[char],
    is_loaded: impl Fn(&str) -> bool,
) -> Vec<&'static str> {
    let mut has_hangul = false;
    let mut has_kana = false;
    let mut has_bopomofo = false;
    let mut has_other_cjk = false;

    for &c in uncovered {
        if matches!(
            c,
            '\u{AC00}'..='\u{D7AF}' | '\u{1100}'..='\u{11FF}' | '\u{3130}'..='\u{318F}'
        ) {
            has_hangul = true;
        } else if matches!(
            c,
            '\u{3040}'..='\u{30FF}' | '\u{31F0}'..='\u{31FF}' | '\u{FF65}'..='\u{FF9F}'
        ) {
            has_kana = true;
        } else if matches!(c, '\u{3100}'..='\u{312F}' | '\u{31A0}'..='\u{31BF}') {
            has_bopomofo = true;
        } else {
            has_other_cjk = true;
        }
    }

    let mut out = Vec::new();
    let mut push_unique = |fam: &'static str| {
        if !out.contains(&fam) && !is_loaded(fam) {
            out.push(fam);
        }
    };

    if has_hangul {
        push_unique("Noto Sans KR");
    }
    if has_kana {
        push_unique("Noto Sans JP");
    }
    if has_bopomofo {
        push_unique("Noto Sans TC");
    }
    if has_other_cjk && out.is_empty() {
        for candidate in [
            "Noto Sans SC",
            "Noto Sans TC",
            "Noto Sans JP",
            "Noto Sans KR",
        ] {
            if !is_loaded(candidate) {
                out.push(candidate);
                break;
            }
        }
    }
    out
}
