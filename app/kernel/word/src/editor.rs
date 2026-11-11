//! Headless collaborative Word editor state for browser Web Workers (`ankole_word_wasm`).

use std::collections::BTreeMap;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::{Value, json};
use wordcraft_doc::para::OBJ;
use wordcraft_doc::props::{Align, Underline};
use wordcraft_doc::{Block, Document, Paragraph, Path, Pos, StoryRef};
use wordcraft_engine::cmd::{table_mouse, table_resize};
use wordcraft_engine::{ColumnBlock, Selection, Session};
use wordcraft_fonts::FontDb;
use wordcraft_geom::{Point, Rect};
use wordcraft_layout::hit::{ColumnSelection, ObjectHit};
use wordcraft_layout::{DocLayout, Placed};
use wordcraft_render::RenderOptions;

use crate::agent::{
    PageRect, commands_from_registry, ensure_isolated_fonts, export_pdf as agent_export_pdf,
    find_with_layout, is_command_blocked, normalize_command_params,
};
use crate::derive::derive_changeset;
use crate::ops::{ChangeSet, Edit, EntryMap, execute_changeset, parse_changeset_list};
use crate::rebase::{collect_spliced_stories, rebase_changeset};
use crate::{
    ApplyError, Conflict, Error, WordDoc, create_blank_with_macros, export_docx,
    open_with_checkpoint,
};

const MAX_UNDO_ENTRIES: usize = 100;
const OBJECT_HANDLE_REACH_PT: f32 = 6.0;
const MIN_OBJECT_SIDE_PT: f32 = 6.0;

#[derive(Clone, Debug)]
struct BlockUndoEntry {
    story: StoryRef,
    at: usize,
    before_blocks: Vec<Arc<Block>>,
    after_blocks: Vec<Arc<Block>>,
    before_sel: Selection,
    after_sel: Selection,
    coalesce_typing: bool,
}

#[derive(Clone, Debug)]
struct ImeComposition {
    story: StoryRef,
    before_doc: Document,
    before_sel: Selection,
    preedit_start: Pos,
    preedit_len: usize,
}

#[derive(Clone, Debug)]
enum PointerDrag {
    TextSelect {
        anchor: Pos,
        alt: bool,
        start_page: usize,
        start_x: f32,
    },
    TableSelect {
        page: usize,
        x0: f32,
        y0: f32,
        shift: bool,
    },
    TableResize {
        page: usize,
        x0: f32,
        y0: f32,
        last_x: f32,
        last_y: f32,
        shift: bool,
    },
    TableMove {
        page: usize,
        x0: f32,
        y0: f32,
        last_x: f32,
        last_y: f32,
    },
    ObjectResize {
        page: usize,
        pos: Pos,
        orig_w: f32,
        orig_h: f32,
        sign_x: f32,
        sign_y: f32,
        x0: f32,
        y0: f32,
        last_x: f32,
        last_y: f32,
        shift: bool,
    },
}

#[derive(Deserialize)]
struct PresenceEndpoint {
    path: Vec<u32>,
    off: usize,
}

#[derive(Deserialize)]
struct PresenceSelectionPayload {
    story: StoryRef,
    anchor: PresenceEndpoint,
    focus: PresenceEndpoint,
}

/// Collaborative Word editor state wrapping `wordcraft_engine::Session`, layout caching,
/// pointer/keyboard/IME handling, and personal per-block Undo/Redo.
pub struct Editor {
    confirmed: WordDoc,
    optimistic_base: WordDoc,
    emitted_local: Vec<ChangeSet>,
    session: Session,
    last_font_gen: u64,
    undo_stack: Vec<BlockUndoEntry>,
    redo_stack: Vec<BlockUndoEntry>,
    ime: Option<ImeComposition>,
    drag: Option<PointerDrag>,
}

impl std::fmt::Debug for Editor {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Editor")
            .field("macro_enabled", &self.confirmed.is_macro_enabled())
            .field("emitted_local_len", &self.emitted_local.len())
            .field("undo_len", &self.undo_stack.len())
            .field("redo_len", &self.redo_stack.len())
            .field("is_composing", &self.ime.is_some())
            .finish_non_exhaustive()
    }
}

impl Editor {
    fn from_word_doc(doc: WordDoc) -> Self {
        ensure_isolated_fonts();
        let session = Session::new(doc.document().clone());
        let last_font_gen = FontDb::global().generation();
        Self {
            confirmed: doc.clone(),
            optimistic_base: doc,
            emitted_local: Vec::new(),
            session,
            last_font_gen,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            ime: None,
            drag: None,
        }
    }

    /// Creates a new editor on a blank `.docx` document with the given metadata title.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if WordCraft cannot construct or validate the blank document.
    pub fn create_blank(title: &str) -> Result<Self, Error> {
        let (doc, _) = create_blank_with_macros(title, false)?;
        Ok(Self::from_word_doc(doc))
    }

    /// Creates a new editor on a blank macro-enabled `.docm` document with the given metadata title.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if WordCraft cannot construct or validate the blank document.
    pub fn create_blank_docm(title: &str) -> Result<Self, Error> {
        let (doc, _) = create_blank_with_macros(title, true)?;
        Ok(Self::from_word_doc(doc))
    }

    /// Opens `.docx` or `.docm` bytes and replays `tail_ops_json` to initialize an editor.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if the package cannot be decoded or any operation in `tail_ops_json`
    /// fails validation.
    pub fn open(bytes: &[u8], tail_ops_json: &str) -> Result<Self, ApplyError> {
        Self::open_with_checkpoint(bytes, tail_ops_json, None)
    }

    /// Opens `.docx` or `.docm` bytes, restores an optional compaction identity checkpoint, and
    /// replays `tail_ops_json` to initialize an editor.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if the package, checkpoint, or operations in `tail_ops_json` fail
    /// validation.
    pub fn open_with_checkpoint(
        bytes: &[u8],
        tail_ops_json: &str,
        checkpoint_json: Option<&str>,
    ) -> Result<Self, ApplyError> {
        let doc = open_with_checkpoint(bytes, tail_ops_json, checkpoint_json)?;
        Ok(Self::from_word_doc(doc))
    }

    fn ensure_layout(&mut self) -> Arc<DocLayout> {
        let current_gen = FontDb::global().generation();
        if current_gen != self.last_font_gen {
            self.last_font_gen = current_gen;
            self.session.relayout();
        }
        self.session.layout()
    }

    /// Lays out the current document, caches [`DocLayout`], and returns JSON
    /// `[{"index", "width_pt", "height_pt"}, ...]`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn pages_info(&mut self) -> Result<String, Error> {
        let lay = self.ensure_layout();
        let pages: Vec<Value> = lay
            .pages
            .iter()
            .enumerate()
            .map(|(index, p)| {
                json!({
                    "index": index,
                    "width_pt": p.w,
                    "height_pt": p.h,
                })
            })
            .collect();
        serde_json::to_string(&pages).map_err(|e| Error::Write(e.to_string()))
    }

    /// Computes the exact `[width_px, height_px]` raster dimensions for `page_index` at `scale`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or `scale` is non-positive.
    pub fn page_pixel_size(&mut self, page_index: usize, scale: f32) -> Result<Vec<u32>, Error> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(Error::Invalid(format!("invalid render scale {scale}")));
        }
        let lay = self.ensure_layout();
        let page = lay.pages.get(page_index).ok_or_else(|| {
            Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            ))
        })?;
        let w = ((page.w * scale).ceil() as u32).clamp(1, wordcraft_render::MAX_SIDE);
        let h = ((page.h.min(1e6) * scale).ceil() as u32).clamp(1, wordcraft_render::MAX_SIDE);
        let (cw, ch) = wordcraft_geom::fit_pixels(w, h, wordcraft_geom::MAX_RASTER_PIXELS);
        Ok(vec![cw, ch])
    }

    /// Rasterizes `page_index` at `scale` pixels per point into straight RGBA8 bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or `scale` is non-positive.
    pub fn render_page_rgba(&mut self, page_index: usize, scale: f32) -> Result<Vec<u8>, Error> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(Error::Invalid(format!("invalid render scale {scale}")));
        }
        let lay = self.ensure_layout();
        let page = lay.pages.get(page_index).ok_or_else(|| {
            Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            ))
        })?;
        let rendered = wordcraft_render::render_page(
            &self.session.doc,
            page,
            scale,
            &RenderOptions::default(),
        );
        Ok(rendered.to_straight())
    }

    /// Rasterizes `page_index` at `scale` pixels per point and encodes the bitmap as PNG.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or `scale` is non-positive, or
    /// [`Error::Write`] if PNG encoding fails.
    pub fn render_page_png(&mut self, page_index: usize, scale: f32) -> Result<Vec<u8>, Error> {
        if !scale.is_finite() || scale <= 0.0 {
            return Err(Error::Invalid(format!("invalid render scale {scale}")));
        }
        let lay = self.ensure_layout();
        let page = lay.pages.get(page_index).ok_or_else(|| {
            Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            ))
        })?;
        let rendered = wordcraft_render::render_page(
            &self.session.doc,
            page,
            scale,
            &RenderOptions::default(),
        );
        let png = rendered.to_png();
        if png.is_empty() {
            return Err(Error::Write(
                "failed to encode rendered page as PNG".to_string(),
            ));
        }
        Ok(png)
    }

    /// Returns JSON describing the active caret, selection highlight rectangles, Presence cursor
    /// payload, and active character/paragraph formatting state.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn caret_and_selection(&mut self) -> Result<String, Error> {
        let val = self.caret_and_selection_value(None);
        serde_json::to_string(&val).map_err(|e| Error::Write(e.to_string()))
    }

    fn caret_and_selection_value(&mut self, link: Option<String>) -> Value {
        let lay = self.ensure_layout();
        let focus = self.session.sel.focus.clone();
        let anchor = self.session.sel.anchor.clone();
        let active_block = focus.path.0.first().copied().map(|b| b as usize);
        let editing = self.has_local_changes() || self.is_composing();

        let caret_rect = lay
            .caret_on(&focus, self.session.page_hint)
            .map(|c| PageRect {
                page: c.page,
                x: c.x,
                y: c.top,
                w: c.width,
                h: c.height,
            });
        if let Some(c) = &caret_rect {
            self.session.page_hint = c.page;
        }

        let selection_rects = self.compute_selection_rects(&lay);

        let cp = self.session.caret_props();
        let para = self.session.doc.para_at(&focus);
        let para_style = para
            .and_then(|p| p.props.style.as_deref())
            .unwrap_or("Normal")
            .to_string();
        let style_def = self.session.doc.styles.get(&para_style);
        let char_style_def = cp
            .style
            .as_deref()
            .and_then(|s| self.session.doc.styles.get(s));

        let bold = cp
            .bold
            .or_else(|| char_style_def.and_then(|s| s.chr.bold))
            .or_else(|| style_def.and_then(|s| s.chr.bold))
            .unwrap_or(false);
        let italic = cp
            .italic
            .or_else(|| char_style_def.and_then(|s| s.chr.italic))
            .or_else(|| style_def.and_then(|s| s.chr.italic))
            .unwrap_or(false);
        let underline = cp
            .underline
            .or_else(|| char_style_def.and_then(|s| s.chr.underline))
            .or_else(|| style_def.and_then(|s| s.chr.underline))
            .is_some_and(|u| u != Underline::None);
        let strike = cp.strike.unwrap_or(false)
            || cp.double_strike.unwrap_or(false)
            || char_style_def
                .is_some_and(|s| s.chr.strike == Some(true) || s.chr.double_strike == Some(true))
            || style_def
                .is_some_and(|s| s.chr.strike == Some(true) || s.chr.double_strike == Some(true));
        let font_name = cp
            .font
            .as_deref()
            .or_else(|| char_style_def.and_then(|s| s.chr.font.as_deref()))
            .or_else(|| style_def.and_then(|s| s.chr.font.as_deref()));
        let code = font_name.is_some_and(is_monospace_font)
            || cp.style.as_deref().is_some_and(|s| {
                s.eq_ignore_ascii_case("Code") || s.eq_ignore_ascii_case("HTMLCode")
            });

        let align_enum = para
            .and_then(|p| p.props.align)
            .or_else(|| style_def.and_then(|s| s.para.align))
            .unwrap_or(Align::Left);
        let align = match align_enum {
            Align::Left => "left",
            Align::Center => "center",
            Align::Right => "right",
            Align::Justify | Align::Distribute => "justify",
        };

        let mut out = json!({
            "story": focus.story,
            "block": active_block,
            "editing": editing,
            "anchor": {
                "path": anchor.path.0,
                "off": anchor.off,
            },
            "focus": {
                "path": focus.path.0,
                "off": focus.off,
            },
            "caret_rect": caret_rect,
            "selection_rects": selection_rects,
            "bold": bold,
            "italic": italic,
            "underline": underline,
            "strike": strike,
            "code": code,
            "style": para_style,
            "align": align,
            "track_changes": self.session.doc.settings.track_changes,
            "can_undo": !self.undo_stack.is_empty(),
            "can_redo": !self.redo_stack.is_empty(),
        });
        if let Some(url) = link
            && let Some(obj) = out.as_object_mut()
        {
            obj.insert("link".to_string(), Value::String(url));
        }
        out
    }

    fn compute_selection_rects(&self, lay: &DocLayout) -> Vec<PageRect> {
        if let Some(range) = self.session.cell_range() {
            return table_mouse::cell_rects(lay, &self.session.doc, range)
                .into_iter()
                .map(|(page, r)| to_page_rect(page, r))
                .collect();
        }
        if let Some(segs) = self.session.column_segments() {
            let mut rects = Vec::new();
            for (a, b) in segs {
                for (page, r) in
                    lay.selection_rects(&self.session.doc, a, b, self.session.page_hint)
                {
                    rects.push(to_page_rect(page, r));
                }
            }
            return rects;
        }
        if self.session.sel.is_collapsed() {
            return Vec::new();
        }
        let (a, b) = self.session.sel.ordered();
        if a.story == b.story
            && a.path == b.path
            && b.off == a.off.saturating_add(OBJ.len_utf8())
            && let Some(obj) = lay.object(&a, self.session.page_hint)
        {
            return vec![to_page_rect(obj.page, obj.bounds())];
        }
        table_mouse::selection_rects(lay, &self.session.doc, &a, &b, self.session.page_hint)
            .into_iter()
            .map(|(page, r)| to_page_rect(page, r))
            .collect()
    }

    /// Computes page bounding boxes `[{"page", "x", "y", "w", "h"}, ...]` in points for a
    /// top-level block in `story_json`, used to draw Presence soft-lock outlines and badges.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `story_json` cannot be parsed as a [`StoryRef`].
    pub fn block_rects(&mut self, story_json: &str, block_index: usize) -> Result<String, Error> {
        let story = parse_story_ref(story_json)?;
        let Ok(target_block) = u32::try_from(block_index) else {
            return Ok("[]".to_string());
        };
        let lay = self.ensure_layout();
        let mut by_page: BTreeMap<usize, Rect> = BTreeMap::new();
        for (page_idx, page) in lay.pages.iter().enumerate() {
            for items in [&page.items, &page.header, &page.footer] {
                collect_block_rects_in_items(items, story, target_block, page_idx, &mut by_page);
            }
        }
        let rects: Vec<PageRect> = by_page
            .into_iter()
            .map(|(page, r)| to_page_rect(page, r))
            .collect();
        serde_json::to_string(&rects).map_err(|e| Error::Write(e.to_string()))
    }

    /// Resolves a collaborator's Presence selection payload into page highlight rectangles.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `selection_json` is malformed.
    pub fn presence_selection_rects(&mut self, selection_json: &str) -> Result<String, Error> {
        let trimmed = selection_json.trim();
        if trimmed.is_empty() || trimmed == "null" {
            return Ok("[]".to_string());
        }
        let payload: PresenceSelectionPayload = serde_json::from_str(trimmed)
            .map_err(|e| Error::Invalid(format!("invalid presence selection JSON: {e}")))?;
        let anchor = self.session.doc.clamp(&Pos {
            story: payload.story,
            path: Path(payload.anchor.path),
            off: payload.anchor.off,
        });
        let focus = self.session.doc.clamp(&Pos {
            story: payload.story,
            path: Path(payload.focus.path),
            off: payload.focus.off,
        });
        let lay = self.ensure_layout();
        let rects: Vec<PageRect> = if anchor == focus {
            lay.caret_on(&focus, self.session.page_hint)
                .into_iter()
                .map(|c| PageRect {
                    page: c.page,
                    x: c.x,
                    y: c.top,
                    w: c.width.max(1.5),
                    h: c.height,
                })
                .collect()
        } else {
            table_mouse::selection_rects(&lay, &self.session.doc, &anchor, &focus, 0)
                .into_iter()
                .map(|(page, r)| to_page_rect(page, r))
                .collect()
        };
        serde_json::to_string(&rects).map_err(|e| Error::Write(e.to_string()))
    }

    /// Handles a pointer button press at `(x_pt, y_pt)` on `page_index` with click count `clicks`
    /// (`1` single, `2` word/border/header, `3` paragraph) and modifier flags.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_down(
        &mut self,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
        clicks: u32,
        shift: bool,
        alt: bool,
    ) -> Result<String, Error> {
        validate_pointer_coords(x_pt, y_pt)?;
        if self.is_composing() {
            let _ = self.ime_cancel();
        }
        self.close_typing_coalesce();
        let lay = self.ensure_layout();
        if page_index >= lay.pages.len() {
            return Err(Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            )));
        }
        self.session.page_hint = page_index;
        self.drag = None;

        // Double-click on a table column border auto-fits that column.
        if clicks == 2
            && table_resize::resize_target(
                &lay,
                &self.session.doc,
                page_index,
                x_pt,
                y_pt,
                table_resize::REACH,
            )
            .is_some_and(|t| matches!(t.edge, table_resize::Edge::Column(_)))
        {
            let _ = self.run_with_personal_undo(
                "table.fitColumn",
                &json!({ "page": page_index, "x": x_pt, "y": y_pt }),
                false,
            );
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        }

        // Double-click in header/footer zone enters or closes header/footer editing.
        if clicks == 2 {
            if let Some((_, is_header)) = lay.header_footer_zone(page_index, y_pt) {
                let cmd = if is_header {
                    "insert.editHeader"
                } else {
                    "insert.editFooter"
                };
                let _ = self.run_with_personal_undo(cmd, &json!({ "page": page_index }), false);
                return serde_json::to_string(&self.caret_and_selection_value(None))
                    .map_err(|e| Error::Write(e.to_string()));
            } else if self.session.in_header_footer() {
                let _ = self.run_with_personal_undo("insert.closeHeader", &json!({}), false);
                return serde_json::to_string(&self.caret_and_selection_value(None))
                    .map_err(|e| Error::Write(e.to_string()));
            }
        }

        // Check resize handles on an already-selected picture or shape.
        if clicks == 1
            && let Some(obj_drag) =
                self.hit_selected_object_handle(&lay, page_index, x_pt, y_pt, shift)
        {
            self.drag = Some(obj_drag);
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        }

        // Table border or corner resize drag.
        if clicks == 1
            && table_resize::resize_target(
                &lay,
                &self.session.doc,
                page_index,
                x_pt,
                y_pt,
                table_resize::REACH,
            )
            .is_some()
        {
            self.drag = Some(PointerDrag::TableResize {
                page: page_index,
                x0: x_pt,
                y0: y_pt,
                last_x: x_pt,
                last_y: y_pt,
                shift,
            });
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        }

        let current_story = if self.session.in_header_footer() {
            self.session.story()
        } else {
            lay.story_at(page_index, x_pt, y_pt)
                .unwrap_or(StoryRef::Body)
        };

        // Table selection spots, row/column insert buttons, and table move handle.
        if clicks == 1
            && let Some(target) = table_mouse::target_at(
                &lay,
                &self.session.doc,
                current_story,
                page_index,
                x_pt,
                y_pt,
                table_resize::REACH,
            )
        {
            match target.spot {
                table_mouse::Spot::InsertRow(_) | table_mouse::Spot::InsertColumn(_) => {
                    let _ = self.run_with_personal_undo(
                        "table.insertAt",
                        &json!({ "page": page_index, "x": x_pt, "y": y_pt }),
                        false,
                    );
                }
                table_mouse::Spot::Handle => {
                    let _ = self.session.run(
                        "table.selectAt",
                        &json!({ "page": page_index, "x": x_pt, "y": y_pt, "extend": shift }),
                    );
                    if table_mouse::movable(&target.geom) {
                        self.drag = Some(PointerDrag::TableMove {
                            page: page_index,
                            x0: x_pt,
                            y0: y_pt,
                            last_x: x_pt,
                            last_y: y_pt,
                        });
                    }
                }
                _ => {
                    let _ = self.session.run(
                        "table.selectAt",
                        &json!({ "page": page_index, "x": x_pt, "y": y_pt, "extend": shift }),
                    );
                    self.drag = Some(PointerDrag::TableSelect {
                        page: page_index,
                        x0: x_pt,
                        y0: y_pt,
                        shift,
                    });
                }
            }
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        }

        // Inline or floating object selection.
        if clicks == 1
            && let Some(obj) = lay.object_at_in(page_index, x_pt, y_pt, 4.0, current_story)
        {
            let start = obj.pos();
            let end = self.session.doc.clamp(&Pos {
                story: start.story,
                path: start.path.clone(),
                off: start.off.saturating_add(OBJ.len_utf8()),
            });
            self.session.column = None;
            self.session.pending = None;
            self.session.sel = Selection {
                anchor: start,
                focus: end,
            };
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        }

        // Text hit testing.
        let mut clicked_link: Option<String> = None;
        if let Some(hit_pos) = lay.hit(page_index, x_pt, y_pt, current_story) {
            self.session.pending = None;
            self.session.goal_x = None;
            match clicks {
                0 | 1 => {
                    clicked_link = link_at_pos(&self.session.doc, &hit_pos);
                    if shift && self.session.sel.anchor.story == hit_pos.story {
                        let anchor = self.session.sel.anchor.clone();
                        self.session.sel = Selection {
                            anchor: anchor.clone(),
                            focus: hit_pos.clone(),
                        };
                        if alt {
                            self.update_column_selection(&lay, &anchor, &hit_pos, x_pt, x_pt);
                        } else {
                            self.session.column = None;
                        }
                        self.drag = Some(PointerDrag::TextSelect {
                            anchor,
                            alt,
                            start_page: page_index,
                            start_x: x_pt,
                        });
                    } else {
                        self.session.column = None;
                        self.session.sel = Selection::caret(hit_pos.clone());
                        self.drag = Some(PointerDrag::TextSelect {
                            anchor: hit_pos,
                            alt,
                            start_page: page_index,
                            start_x: x_pt,
                        });
                    }
                }
                2 => {
                    self.session.column = None;
                    let (w0, w1) = word_range_at(&self.session.doc, &hit_pos);
                    self.session.sel = Selection {
                        anchor: w0,
                        focus: w1,
                    };
                }
                _ => {
                    self.session.column = None;
                    let para_len = self
                        .session
                        .doc
                        .para_at(&hit_pos)
                        .map_or(hit_pos.off, Paragraph::len);
                    self.session.sel = Selection {
                        anchor: Pos {
                            story: hit_pos.story,
                            path: hit_pos.path.clone(),
                            off: 0,
                        },
                        focus: Pos {
                            story: hit_pos.story,
                            path: hit_pos.path,
                            off: para_len,
                        },
                    };
                }
            }
        }

        serde_json::to_string(&self.caret_and_selection_value(clicked_link))
            .map_err(|e| Error::Write(e.to_string()))
    }

    /// Updates an active pointer drag gesture to `(x_pt, y_pt)` on `page_index`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_move(
        &mut self,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
    ) -> Result<String, Error> {
        validate_pointer_coords(x_pt, y_pt)?;
        let lay = self.ensure_layout();
        if page_index >= lay.pages.len() {
            return Err(Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            )));
        }
        let Some(drag) = self.drag.clone() else {
            return serde_json::to_string(&self.caret_and_selection_value(None))
                .map_err(|e| Error::Write(e.to_string()));
        };

        match drag {
            PointerDrag::TextSelect {
                anchor,
                alt,
                start_page,
                start_x,
            } => {
                if let Some(focus) = lay.hit(page_index, x_pt, y_pt, anchor.story) {
                    self.session.page_hint = page_index;
                    self.session.sel = Selection {
                        anchor: anchor.clone(),
                        focus: focus.clone(),
                    };
                    if alt && page_index == start_page {
                        self.update_column_selection(&lay, &anchor, &focus, start_x, x_pt);
                    } else {
                        self.session.column = None;
                    }
                }
            }
            PointerDrag::TableSelect {
                page,
                x0,
                y0,
                shift,
            } => {
                if page == page_index {
                    let _ = self.session.run(
                        "table.selectAt",
                        &json!({
                            "page": page,
                            "x": x0,
                            "y": y0,
                            "toX": x_pt,
                            "toY": y_pt,
                            "extend": shift,
                        }),
                    );
                }
            }
            PointerDrag::TableResize {
                page,
                x0,
                y0,
                shift,
                ..
            } => {
                self.drag = Some(PointerDrag::TableResize {
                    page,
                    x0,
                    y0,
                    last_x: x_pt,
                    last_y: y_pt,
                    shift,
                });
            }
            PointerDrag::TableMove { page, x0, y0, .. } => {
                self.drag = Some(PointerDrag::TableMove {
                    page,
                    x0,
                    y0,
                    last_x: x_pt,
                    last_y: y_pt,
                });
            }
            PointerDrag::ObjectResize {
                page,
                pos,
                orig_w,
                orig_h,
                sign_x,
                sign_y,
                x0,
                y0,
                shift,
                ..
            } => {
                self.drag = Some(PointerDrag::ObjectResize {
                    page,
                    pos,
                    orig_w,
                    orig_h,
                    sign_x,
                    sign_y,
                    x0,
                    y0,
                    last_x: x_pt,
                    last_y: y_pt,
                    shift,
                });
            }
        }

        serde_json::to_string(&self.caret_and_selection_value(None))
            .map_err(|e| Error::Write(e.to_string()))
    }

    /// Completes any active pointer gesture at `(x_pt, y_pt)` on `page_index`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `page_index` is out of bounds or coordinates are non-finite.
    pub fn pointer_up(&mut self, page_index: usize, x_pt: f32, y_pt: f32) -> Result<String, Error> {
        validate_pointer_coords(x_pt, y_pt)?;
        let lay = self.ensure_layout();
        if page_index >= lay.pages.len() {
            return Err(Error::Invalid(format!(
                "page index {page_index} out of bounds (page_count={})",
                lay.pages.len()
            )));
        }

        let mut released_link: Option<String> = None;
        if let Some(drag) = self.drag.take() {
            match drag {
                PointerDrag::TextSelect {
                    anchor,
                    alt,
                    start_page,
                    start_x,
                } => {
                    if let Some(focus) = lay.hit(page_index, x_pt, y_pt, anchor.story) {
                        self.session.sel = Selection {
                            anchor: anchor.clone(),
                            focus: focus.clone(),
                        };
                        if alt && page_index == start_page && anchor != focus {
                            self.update_column_selection(&lay, &anchor, &focus, start_x, x_pt);
                        }
                        if self.session.sel.is_collapsed() {
                            released_link = link_at_pos(&self.session.doc, &focus);
                        }
                    }
                }
                PointerDrag::TableSelect {
                    page,
                    x0,
                    y0,
                    shift,
                } => {
                    if page == page_index && (x_pt - x0).hypot(y_pt - y0) >= 1.0 {
                        let _ = self.session.run(
                            "table.selectAt",
                            &json!({
                                "page": page,
                                "x": x0,
                                "y": y0,
                                "toX": x_pt,
                                "toY": y_pt,
                                "extend": shift,
                            }),
                        );
                    }
                }
                PointerDrag::TableResize {
                    page,
                    x0,
                    y0,
                    last_x,
                    last_y,
                    shift,
                } => {
                    let (tx, ty) = if page == page_index {
                        (x_pt, y_pt)
                    } else {
                        (last_x, last_y)
                    };
                    if (tx - x0).hypot(ty - y0) >= 0.5 {
                        let _ = self.run_with_personal_undo(
                            "table.resizeDrag",
                            &json!({
                                "page": page,
                                "x": x0,
                                "y": y0,
                                "toX": tx,
                                "toY": ty,
                                "shift": shift,
                            }),
                            false,
                        );
                    }
                }
                PointerDrag::TableMove {
                    page,
                    x0,
                    y0,
                    last_x,
                    last_y,
                } => {
                    let (tx, ty) = if page == page_index {
                        (x_pt, y_pt)
                    } else {
                        (last_x, last_y)
                    };
                    if (tx - x0).hypot(ty - y0) >= 1.0 {
                        let _ = self.run_with_personal_undo(
                            "table.moveDrag",
                            &json!({
                                "page": page,
                                "x": x0,
                                "y": y0,
                                "toX": tx,
                                "toY": ty,
                            }),
                            false,
                        );
                    }
                }
                PointerDrag::ObjectResize {
                    page,
                    pos,
                    orig_w,
                    orig_h,
                    sign_x,
                    sign_y,
                    x0,
                    y0,
                    last_x,
                    last_y,
                    shift,
                } => {
                    let (tx, ty) = if page == page_index {
                        (x_pt, y_pt)
                    } else {
                        (last_x, last_y)
                    };
                    if (tx - x0).hypot(ty - y0) >= 0.5 {
                        let mut new_w = (orig_w + (tx - x0) * sign_x).max(MIN_OBJECT_SIDE_PT);
                        let mut new_h = (orig_h + (ty - y0) * sign_y).max(MIN_OBJECT_SIDE_PT);
                        if !shift && sign_x != 0.0 && sign_y != 0.0 && orig_w > 0.0 && orig_h > 0.0
                        {
                            let ratio = orig_w / orig_h;
                            new_h = (new_w / ratio).max(MIN_OBJECT_SIDE_PT);
                            new_w = (new_h * ratio).max(MIN_OBJECT_SIDE_PT);
                        }
                        self.resize_selected_object(&pos, new_w, new_h, !shift);
                    }
                }
            }
        }

        serde_json::to_string(&self.caret_and_selection_value(released_link))
            .map_err(|e| Error::Write(e.to_string()))
    }

    fn update_column_selection(
        &mut self,
        lay: &DocLayout,
        anchor: &Pos,
        focus: &Pos,
        x0: f32,
        x1: f32,
    ) {
        let sel = Selection {
            anchor: anchor.clone(),
            focus: focus.clone(),
        };
        let segments = lay.column_segments(
            &self.session.doc,
            ColumnSelection {
                start: anchor,
                end: focus,
                left: x0.min(x1),
                right: x0.max(x1),
                page_hint: self.session.page_hint,
                max_lines: 2_000,
            },
        );
        self.session.column = Some(ColumnBlock {
            sel,
            anchor_x: x0,
            focus_x: x1,
            segments,
            cells: None,
        });
    }

    fn hit_selected_object_handle(
        &self,
        lay: &DocLayout,
        page_index: usize,
        x_pt: f32,
        y_pt: f32,
        shift: bool,
    ) -> Option<PointerDrag> {
        let (a, b) = self.session.sel.ordered();
        if a.story != b.story || a.path != b.path || b.off != a.off.saturating_add(OBJ.len_utf8()) {
            return None;
        }
        let hit: ObjectHit = lay.object(&a, page_index)?;
        if hit.page != page_index {
            return None;
        }
        let local: Point = hit.unspin(x_pt, y_pt);
        let r = hit.rect;
        let near_left = (local.x - r.x).abs() <= OBJECT_HANDLE_REACH_PT;
        let near_right = (local.x - r.right()).abs() <= OBJECT_HANDLE_REACH_PT;
        let near_top = (local.y - r.y).abs() <= OBJECT_HANDLE_REACH_PT;
        let near_bottom = (local.y - r.bottom()).abs() <= OBJECT_HANDLE_REACH_PT;
        let in_x = local.x >= r.x - OBJECT_HANDLE_REACH_PT
            && local.x <= r.right() + OBJECT_HANDLE_REACH_PT;
        let in_y = local.y >= r.y - OBJECT_HANDLE_REACH_PT
            && local.y <= r.bottom() + OBJECT_HANDLE_REACH_PT;
        if !in_x || !in_y {
            return None;
        }
        let sign_x = if near_right {
            1.0
        } else if near_left {
            -1.0
        } else {
            0.0
        };
        let sign_y = if near_bottom {
            1.0
        } else if near_top {
            -1.0
        } else {
            0.0
        };
        if sign_x == 0.0 && sign_y == 0.0 {
            return None;
        }
        Some(PointerDrag::ObjectResize {
            page: page_index,
            pos: a,
            orig_w: r.w.max(MIN_OBJECT_SIDE_PT),
            orig_h: r.h.max(MIN_OBJECT_SIDE_PT),
            sign_x,
            sign_y,
            x0: x_pt,
            y0: y_pt,
            last_x: x_pt,
            last_y: y_pt,
            shift,
        })
    }

    fn resize_selected_object(&mut self, pos: &Pos, width: f32, height: f32, lock_aspect: bool) {
        self.session.sel = Selection {
            anchor: pos.clone(),
            focus: self.session.doc.clamp(&Pos {
                story: pos.story,
                path: pos.path.clone(),
                off: pos.off.saturating_add(OBJ.len_utf8()),
            }),
        };
        let params = json!({
            "width": width,
            "height": height,
            "lockAspect": lock_aspect,
        });
        if self
            .run_with_personal_undo("picture.size", &params, false)
            .is_err()
        {
            let _ = self.run_with_personal_undo("shape.size", &params, false);
        }
    }

    /// Dispatches a keyboard event through WordCraft's shortcut map or character/navigation input.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if a resolved engine command fails unexpectedly.
    pub fn key_event(
        &mut self,
        key: &str,
        ctrl_or_meta: bool,
        shift: bool,
        alt: bool,
    ) -> Result<String, Error> {
        if self.is_composing() {
            return serde_json::to_string(&json!({
                "handled": false,
                "composing": true,
                "state": self.caret_and_selection_value(None),
            }))
            .map_err(|e| Error::Write(e.to_string()));
        }

        if let Some(canonical) = build_shortcut_string(key, ctrl_or_meta, shift, alt) {
            if canonical == "Mod+S" {
                self.close_typing_coalesce();
                return serde_json::to_string(&json!({
                    "handled": true,
                    "request_commit": true,
                    "state": self.caret_and_selection_value(None),
                }))
                .map_err(|e| Error::Write(e.to_string()));
            }
            if canonical == "Mod+Z" {
                let applied = self.apply_undo_step_to_session();
                return serde_json::to_string(&json!({
                    "handled": true,
                    "undo_applied": applied,
                    "state": self.caret_and_selection_value(None),
                }))
                .map_err(|e| Error::Write(e.to_string()));
            }
            if canonical == "Mod+Y" || canonical == "Mod+Shift+Z" {
                let applied = self.apply_redo_step_to_session();
                return serde_json::to_string(&json!({
                    "handled": true,
                    "redo_applied": applied,
                    "state": self.caret_and_selection_value(None),
                }))
                .map_err(|e| Error::Write(e.to_string()));
            }

            let resolved_id = self
                .session
                .keymap
                .resolve(&self.session.registry, &canonical)
                .map(|spec| spec.id);
            if let Some(cmd_id) = resolved_id {
                if is_command_blocked(cmd_id) {
                    return serde_json::to_string(&json!({
                        "handled": false,
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                if cmd_id == "edit.undo" {
                    let applied = self.apply_undo_step_to_session();
                    return serde_json::to_string(&json!({
                        "handled": true,
                        "undo_applied": applied,
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                if cmd_id == "edit.redo" {
                    let applied = self.apply_redo_step_to_session();
                    return serde_json::to_string(&json!({
                        "handled": true,
                        "redo_applied": applied,
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                self.close_typing_coalesce();
                let handled = self
                    .run_with_personal_undo(cmd_id, &Value::Null, false)
                    .is_ok();
                return serde_json::to_string(&json!({
                    "handled": handled,
                    "command": cmd_id,
                    "state": self.caret_and_selection_value(None),
                }))
                .map_err(|e| Error::Write(e.to_string()));
            }
        }

        if !ctrl_or_meta && !alt {
            match key {
                "Enter" => {
                    self.close_typing_coalesce();
                    let cmd = if shift {
                        "text.lineBreak"
                    } else {
                        "text.newParagraph"
                    };
                    let handled = self.run_with_personal_undo(cmd, &json!({}), false).is_ok();
                    return serde_json::to_string(&json!({
                        "handled": handled,
                        "command": cmd,
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                "Backspace" => {
                    self.close_typing_coalesce();
                    let handled = self
                        .run_with_personal_undo("text.backspace", &json!({}), false)
                        .is_ok();
                    return serde_json::to_string(&json!({
                        "handled": handled,
                        "command": "text.backspace",
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                "Delete" => {
                    self.close_typing_coalesce();
                    let handled = self
                        .run_with_personal_undo("text.delete", &json!({}), false)
                        .is_ok();
                    return serde_json::to_string(&json!({
                        "handled": handled,
                        "command": "text.delete",
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                "Tab" if !shift => {
                    self.close_typing_coalesce();
                    let handled = self
                        .run_with_personal_undo("text.tab", &json!({}), false)
                        .is_ok();
                    return serde_json::to_string(&json!({
                        "handled": handled,
                        "command": "text.tab",
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                " " | "Spacebar" => {
                    self.close_typing_coalesce();
                    let handled = self
                        .run_with_personal_undo("text.insert", &json!({ "text": " " }), false)
                        .is_ok();
                    return serde_json::to_string(&json!({
                        "handled": handled,
                        "command": "text.insert",
                        "state": self.caret_and_selection_value(None),
                    }))
                    .map_err(|e| Error::Write(e.to_string()));
                }
                _ => {
                    let mut chars = key.chars();
                    if let (Some(ch), None) = (chars.next(), chars.next())
                        && !ch.is_control()
                    {
                        let coalesce = !ch.is_whitespace();
                        let handled = self
                            .run_with_personal_undo(
                                "text.insert",
                                &json!({ "text": key }),
                                coalesce,
                            )
                            .is_ok();
                        return serde_json::to_string(&json!({
                            "handled": handled,
                            "command": "text.insert",
                            "state": self.caret_and_selection_value(None),
                        }))
                        .map_err(|e| Error::Write(e.to_string()));
                    }
                }
            }
        }

        serde_json::to_string(&json!({
            "handled": false,
            "state": self.caret_and_selection_value(None),
        }))
        .map_err(|e| Error::Write(e.to_string()))
    }

    /// Inserts plain text at the current selection (outside IME composition).
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `text.insert` is refused by the active selection or document.
    pub fn insert_text(&mut self, text: &str) -> Result<String, Error> {
        if self.is_composing() {
            let _ = self.ime_cancel();
        }
        self.close_typing_coalesce();
        if !text.is_empty() {
            self.run_with_personal_undo("text.insert", &json!({ "text": text }), false)?;
        }
        self.caret_and_selection()
    }

    /// Updates active IME preedit text and relative cursor range `(cursor_start..cursor_end)`
    /// without allowing [`Self::commit_local_step`] to emit a change set.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if editing inside the target story fails.
    pub fn ime_preedit(
        &mut self,
        text: &str,
        cursor_start: usize,
        cursor_end: usize,
    ) -> Result<String, Error> {
        self.close_typing_coalesce();
        if self.ime.is_none() {
            let story = self.session.sel.focus.story;
            let before_doc = self.session.doc.clone();
            let before_sel = self.session.sel.clone();
            if !self.session.sel.is_collapsed() {
                self.session
                    .run("text.delete", &json!({}))
                    .map_err(|e| Error::Invalid(e.to_string()))?;
            }
            let preedit_start = self.session.sel.focus.clone();
            self.ime = Some(ImeComposition {
                story,
                before_doc,
                before_sel,
                preedit_start,
                preedit_len: 0,
            });
        }

        if let Some(mut comp) = self.ime.take() {
            self.replace_ime_span(&mut comp, text)?;
            let c0 = clamp_utf8_boundary(text, cursor_start);
            let c1 = clamp_utf8_boundary(text, cursor_end.max(c0));
            let anchor = self.session.doc.clamp(&Pos {
                story: comp.preedit_start.story,
                path: comp.preedit_start.path.clone(),
                off: comp.preedit_start.off.saturating_add(c0),
            });
            let focus = self.session.doc.clamp(&Pos {
                story: comp.preedit_start.story,
                path: comp.preedit_start.path.clone(),
                off: comp.preedit_start.off.saturating_add(c1),
            });
            self.session.sel = Selection { anchor, focus };
            self.ime = Some(comp);
        }

        self.caret_and_selection()
    }

    /// Commits an active IME composition with `text` and records one personal Undo entry.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if inserting the committed text fails.
    pub fn ime_commit(&mut self, text: &str) -> Result<String, Error> {
        self.close_typing_coalesce();
        if let Some(mut comp) = self.ime.take() {
            self.replace_ime_span(&mut comp, text)?;
            let end_pos = self.session.doc.clamp(&Pos {
                story: comp.preedit_start.story,
                path: comp.preedit_start.path.clone(),
                off: comp.preedit_start.off.saturating_add(comp.preedit_len),
            });
            self.session.sel = Selection::caret(end_pos);
            let after_blocks = story_blocks(&self.session.doc, comp.story).to_vec();
            let after_sel = self.session.sel.clone();
            self.push_block_undo(
                comp.story,
                story_blocks(&comp.before_doc, comp.story),
                &after_blocks,
                comp.before_sel,
                after_sel,
                false,
            );
            return self.caret_and_selection();
        }
        self.insert_text(text)
    }

    /// Cancels an active IME composition and restores the pre-composition story blocks and caret.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if serializing the restored caret state fails.
    pub fn ime_cancel(&mut self) -> Result<String, Error> {
        if let Some(comp) = self.ime.take() {
            self.session.doc = comp.before_doc;
            self.session.doc.ensure_nonempty();
            self.session.sel = clamp_selection(&self.session.doc, &comp.before_sel);
            self.session.column = None;
            self.session.pending = None;
            self.session.touch();
            self.session.relayout();
        }
        self.caret_and_selection()
    }

    /// Returns `true` while an IME composition session is active.
    #[must_use]
    pub fn is_composing(&self) -> bool {
        self.ime.is_some()
    }

    fn replace_ime_span(&mut self, comp: &mut ImeComposition, new_text: &str) -> Result<(), Error> {
        let start = self.session.doc.clamp(&comp.preedit_start);
        let end = self.session.doc.clamp(&Pos {
            story: start.story,
            path: start.path.clone(),
            off: start.off.saturating_add(comp.preedit_len),
        });
        self.session.column = None;
        self.session.sel = Selection {
            anchor: start.clone(),
            focus: end,
        };
        if !self.session.sel.is_collapsed() {
            self.session
                .run("text.delete", &json!({}))
                .map_err(|e| Error::Invalid(e.to_string()))?;
        }
        let insert_at = self.session.sel.focus.clone();
        if !new_text.is_empty() {
            self.session
                .run("text.insert", &json!({ "text": new_text }))
                .map_err(|e| Error::Invalid(e.to_string()))?;
        }
        comp.preedit_start = insert_at;
        comp.preedit_len = new_text.len();
        Ok(())
    }

    /// Executes a non-blocked WordCraft engine command with JSON parameters (normalizing
    /// `insert.picture` payloads within 2 MiB) and records or clears personal Undo accordingly.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Invalid`] if `command_id` is blocked, `params_json` is malformed, or the
    /// command fails.
    pub fn execute_command(
        &mut self,
        command_id: &str,
        params_json: &str,
    ) -> Result<String, Error> {
        let id = command_id.trim();
        if is_command_blocked(id) {
            return Err(Error::Invalid(format!(
                "command `{id}` is not permitted in Word Pages"
            )));
        }
        if self.is_composing() {
            let _ = self.ime_cancel();
        }
        self.close_typing_coalesce();

        if id == "edit.undo" {
            let applied = self.apply_undo_step_to_session();
            return serde_json::to_string(&json!({ "undo": applied }))
                .map_err(|e| Error::Write(e.to_string()));
        }
        if id == "edit.redo" {
            let applied = self.apply_redo_step_to_session();
            return serde_json::to_string(&json!({ "redo": applied }))
                .map_err(|e| Error::Write(e.to_string()));
        }

        let parsed_params: Value = if params_json.trim().is_empty() {
            json!({})
        } else {
            serde_json::from_str(params_json)
                .map_err(|e| Error::Invalid(format!("invalid command params JSON: {e}")))?
        };
        let normalized = normalize_command_params(id, &parsed_params)?;
        let result = self.run_with_personal_undo(id, &normalized, false)?;
        serde_json::to_string(&result).map_err(|e| Error::Write(e.to_string()))
    }

    fn run_with_personal_undo(
        &mut self,
        command_id: &str,
        params: &Value,
        coalesce_typing: bool,
    ) -> Result<Value, Error> {
        let before_doc = self.session.doc.clone();
        let before_sel = self.session.sel.clone();

        let res = self
            .session
            .run(command_id, params)
            .map_err(|e| Error::Invalid(format!("command `{command_id}` failed: {e}")))?;

        self.session.doc.ensure_nonempty();

        if is_document_wide_command(command_id) {
            self.clear_undo_redo();
            return Ok(res);
        }

        if let Ok(Some(diff)) = derive_changeset(&before_doc, &self.session.doc) {
            let mut spliced_stories = Vec::new();
            let mut has_doc_wide = false;
            for edit in &diff.edits {
                match edit {
                    Edit::BlocksSplice { story, .. } => {
                        if !spliced_stories.contains(story) {
                            spliced_stories.push(*story);
                        }
                    }
                    Edit::FieldSet { .. } => {
                        has_doc_wide = true;
                    }
                    Edit::EntryDelete {
                        map: EntryMap::Parts,
                        ..
                    } => {
                        has_doc_wide = true;
                    }
                    Edit::EntryPut { .. }
                    | Edit::EntryDelete { .. }
                    | Edit::RevisionsAppend { .. } => {}
                }
            }

            if has_doc_wide || spliced_stories.len() > 1 {
                self.clear_undo_redo();
            } else if let Some(&story) = spliced_stories.first() {
                let before_blocks = story_blocks(&before_doc, story);
                let after_blocks = story_blocks(&self.session.doc, story).to_vec();
                let after_sel = self.session.sel.clone();
                self.push_block_undo(
                    story,
                    before_blocks,
                    &after_blocks,
                    before_sel,
                    after_sel,
                    coalesce_typing,
                );
            }
        }

        Ok(res)
    }

    fn push_block_undo(
        &mut self,
        story: StoryRef,
        before_blocks: &[Arc<Block>],
        after_blocks: &[Arc<Block>],
        before_sel: Selection,
        after_sel: Selection,
        coalesce_typing: bool,
    ) {
        let Some((at, b_slice, a_slice)) = trim_block_span(before_blocks, after_blocks) else {
            return;
        };
        self.redo_stack.clear();

        if coalesce_typing
            && b_slice.len() == 1
            && a_slice.len() == 1
            && let Some(last) = self.undo_stack.last_mut()
            && last.coalesce_typing
            && last.story == story
            && last.at == at
            && last.after_blocks.len() == 1
            && blocks_slice_eq(&last.after_blocks, &b_slice)
        {
            last.after_blocks = a_slice;
            last.after_sel = after_sel;
            return;
        }

        if self.undo_stack.len() >= MAX_UNDO_ENTRIES {
            self.undo_stack.remove(0);
        }
        self.undo_stack.push(BlockUndoEntry {
            story,
            at,
            before_blocks: b_slice,
            after_blocks: a_slice,
            before_sel,
            after_sel,
            coalesce_typing,
        });
    }

    fn close_typing_coalesce(&mut self) {
        if let Some(last) = self.undo_stack.last_mut() {
            last.coalesce_typing = false;
        }
    }

    fn clear_undo_redo(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
    }

    fn apply_undo_step_to_session(&mut self) -> bool {
        if self.is_composing() {
            let _ = self.ime_cancel();
        }
        self.close_typing_coalesce();
        let Some(entry) = self.undo_stack.pop() else {
            return false;
        };
        let current = story_blocks(&self.session.doc, entry.story);
        let end = entry.at.saturating_add(entry.after_blocks.len());
        let Some(slice) = current.get(entry.at..end) else {
            self.clear_undo_redo();
            return false;
        };
        if !blocks_slice_eq(slice, &entry.after_blocks) {
            self.clear_undo_redo();
            return false;
        }

        let mut updated = current.to_vec();
        updated.splice(entry.at..end, entry.before_blocks.iter().cloned());
        set_story_blocks(&mut self.session.doc, entry.story, updated);
        self.session.doc.ensure_nonempty();
        self.session.sel = clamp_selection(&self.session.doc, &entry.before_sel);
        self.session.column = None;
        self.session.pending = None;
        self.session.touch();
        self.session.relayout();
        self.redo_stack.push(entry);
        true
    }

    fn apply_redo_step_to_session(&mut self) -> bool {
        if self.is_composing() {
            let _ = self.ime_cancel();
        }
        self.close_typing_coalesce();
        let Some(entry) = self.redo_stack.pop() else {
            return false;
        };
        let current = story_blocks(&self.session.doc, entry.story);
        let end = entry.at.saturating_add(entry.before_blocks.len());
        let Some(slice) = current.get(entry.at..end) else {
            self.clear_undo_redo();
            return false;
        };
        if !blocks_slice_eq(slice, &entry.before_blocks) {
            self.clear_undo_redo();
            return false;
        }

        let mut updated = current.to_vec();
        updated.splice(entry.at..end, entry.after_blocks.iter().cloned());
        set_story_blocks(&mut self.session.doc, entry.story, updated);
        self.session.doc.ensure_nonempty();
        self.session.sel = clamp_selection(&self.session.doc, &entry.after_sel);
        self.session.column = None;
        self.session.pending = None;
        self.session.touch();
        self.session.relayout();
        self.undo_stack.push(entry);
        true
    }

    /// Returns `true` when the active session document has uncommitted changes relative to the
    /// optimistic base document (and no IME composition is preventing commit).
    #[must_use]
    pub fn has_local_changes(&self) -> bool {
        if self.is_composing() {
            return false;
        }
        match derive_changeset(self.optimistic_base.document(), &self.session.doc) {
            Ok(Some(_)) => true,
            Ok(None) | Err(_) => false,
        }
    }

    /// Derives a canonical [`ChangeSet`] JSON string from `optimistic_base` to the current
    /// session document and advances `optimistic_base`. Never commits during an active IME
    /// composition (`returns Ok(None)`).
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if deriving or serializing the change set fails.
    pub fn commit_local_step(&mut self) -> Result<Option<String>, Error> {
        if self.is_composing() {
            return Ok(None);
        }
        self.close_typing_coalesce();
        let Some(cs) = derive_changeset(self.optimistic_base.document(), &self.session.doc)? else {
            return Ok(None);
        };
        let json_str = serde_json::to_string(&cs).map_err(|e| Error::Write(e.to_string()))?;
        self.optimistic_base = WordDoc::from_parts(
            self.session.doc.clone(),
            self.confirmed.is_macro_enabled(),
            Arc::clone(&self.confirmed.missing_pictures),
        );
        self.emitted_local.push(cs);
        Ok(Some(json_str))
    }

    /// Undoes the latest personal block snapshot and derives a `blocks.splice` change set if the
    /// undone state differs from `optimistic_base`.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if deriving or serializing the resulting change set fails.
    pub fn undo(&mut self) -> Result<Option<String>, Error> {
        if !self.apply_undo_step_to_session() {
            return Ok(None);
        }
        self.commit_local_step()
    }

    /// Redoes the latest undone personal block snapshot and derives a `blocks.splice` change set
    /// if the redone state differs from `optimistic_base`.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if deriving or serializing the resulting change set fails.
    pub fn redo(&mut self) -> Result<Option<String>, Error> {
        if !self.apply_redo_step_to_session() {
            return Ok(None);
        }
        self.commit_local_step()
    }

    /// Discards all unconfirmed pending edits and active drafts, resetting the session document
    /// to `confirmed` and clearing local Undo/Redo.
    pub fn reset_to_confirmed(&mut self) {
        self.ime = None;
        self.drag = None;
        self.emitted_local.clear();
        self.clear_undo_redo();
        self.optimistic_base = self.confirmed.clone();
        let prev_sel = self.session.sel.clone();
        let prev_page_hint = self.session.page_hint;
        self.session.set_document(self.confirmed.document().clone());
        self.session.sel = clamp_selection(&self.session.doc, &prev_sel);
        self.session.page_hint = prev_page_hint;
    }

    /// Advances `confirmed` by `confirmed_ops_json`, rebases `pending_ops_json` and any active
    /// uncommitted local draft onto the updated document, updates `Session::set_document`, shifts
    /// the caret's top-level block index across remote splices, and returns JSON
    /// `{"dropped_pending", "draft_conflict", "conflict_reason", "active_block"}`.
    ///
    /// # Errors
    ///
    /// Returns [`ApplyError`] if `confirmed_ops_json` or `pending_ops_json` cannot be parsed or
    /// carries a future `model_version`.
    pub fn apply_remote(
        &mut self,
        confirmed_ops_json: &str,
        pending_ops_json: &str,
    ) -> Result<String, ApplyError> {
        self.drag = None;
        self.close_typing_coalesce();

        let confirmed_ops = parse_changeset_list(confirmed_ops_json)?;
        let pending_ops = parse_changeset_list(pending_ops_json)?;

        let before_ime = self
            .ime
            .as_ref()
            .map_or(&self.session.doc, |ime| &ime.before_doc);
        let active_draft = derive_changeset(self.optimistic_base.document(), before_ime)?;
        let ime_draft = if self.ime.is_some() {
            derive_changeset(before_ime, &self.session.doc)?
        } else {
            None
        };

        // Identify how many previously emitted local ops were acknowledged in this batch so echoes
        // of our own commits update `confirmed` (including stamped author metadata) without
        // double-shifting `pending_ops`, `active_draft`, or the user's caret.
        let ack_budget = self.emitted_local.len().saturating_sub(pending_ops.len());
        let mut expected_acks: Vec<ChangeSet> = self
            .emitted_local
            .iter()
            .take(ack_budget)
            .cloned()
            .collect();

        let mut next_confirmed_raw = self.confirmed.document().clone();
        let mut genuine_remote_ops: Vec<ChangeSet> = Vec::new();

        for conf_op in &confirmed_ops {
            execute_changeset(&mut next_confirmed_raw, conf_op)?;
            if let Some(head) = expected_acks.first()
                && changeset_matches_local_ack(head, conf_op)
            {
                expected_acks.remove(0);
                continue;
            }
            // Genuine remote operation: rebase remaining expected acks over it so a later echo in
            // the same batch still matches at its shifted coordinates.
            let mut next_acks = Vec::with_capacity(expected_acks.len());
            for ack_candidate in expected_acks {
                if let Ok(shifted) = rebase_changeset(
                    ack_candidate,
                    std::slice::from_ref(conf_op),
                    &next_confirmed_raw,
                ) {
                    next_acks.push(shifted);
                }
            }
            expected_acks = next_acks;
            genuine_remote_ops.push(conf_op.clone());
        }
        next_confirmed_raw.ensure_nonempty();

        self.confirmed = WordDoc::from_parts(
            next_confirmed_raw.clone(),
            self.confirmed.is_macro_enabled(),
            Arc::clone(&self.confirmed.missing_pictures),
        );

        let structural_remote = genuine_remote_ops.iter().any(changeset_is_structural);

        // Rebase still-pending operations over `genuine_remote_ops`.
        let mut opt_raw = next_confirmed_raw;
        let mut remote_for_later = genuine_remote_ops.clone();
        let mut kept_pending: Vec<ChangeSet> = Vec::new();
        let mut pending_results: Vec<Value> = Vec::with_capacity(pending_ops.len());
        let mut dropped_pending: usize = 0;
        let mut conflict_reason: Option<String> = None;

        for pending in pending_ops {
            match rebase_and_apply_step(&mut opt_raw, pending.clone(), &remote_for_later) {
                Ok(rebased_pending) => {
                    remote_for_later =
                        advance_remote_past_local(&remote_for_later, &pending, &opt_raw);
                    pending_results.push(json!({ "op": &rebased_pending }));
                    kept_pending.push(rebased_pending);
                }
                Err(ApplyError::Conflict(c)) => {
                    dropped_pending = dropped_pending.saturating_add(1);
                    let reason = c.as_str().to_string();
                    if conflict_reason.is_none() {
                        conflict_reason = Some(reason.clone());
                    }
                    pending_results.push(json!({ "conflict": reason }));
                    // If a dropped pending op changed block counts, invalidate undo and any
                    // coordinate assumptions downstream.
                    if changeset_is_structural(&pending) {
                        remote_for_later.push(invert_structural_hint(&pending));
                    }
                }
                Err(other) => return Err(other),
            }
        }
        opt_raw.ensure_nonempty();

        self.optimistic_base = WordDoc::from_parts(
            opt_raw.clone(),
            self.confirmed.is_macro_enabled(),
            Arc::clone(&self.confirmed.missing_pictures),
        );
        self.emitted_local = kept_pending;

        // Rebase active uncommitted draft onto `opt_raw`.
        let mut session_raw = opt_raw;
        let mut draft_conflict = false;
        if let Some(draft) = active_draft {
            match rebase_and_apply_step(&mut session_raw, draft.clone(), &remote_for_later) {
                Ok(_) => {
                    remote_for_later =
                        advance_remote_past_local(&remote_for_later, &draft, &session_raw);
                }
                Err(ApplyError::Conflict(c)) => {
                    draft_conflict = true;
                    conflict_reason = Some(c.as_str().to_string());
                }
                Err(other) => return Err(other),
            }
        }
        session_raw.ensure_nonempty();

        let mut prev_sel = self.session.sel.clone();
        let mut pending_format = None;
        if let Some(mut ime) = self.ime.take() {
            let before_sel = ime.before_sel.clone();
            ime.before_doc = session_raw.clone();
            ime.before_sel = Selection {
                anchor: shift_pos_across_ops(&before_sel.anchor, &remote_for_later),
                focus: shift_pos_across_ops(&before_sel.focus, &remote_for_later),
            };
            if !draft_conflict && let Some(draft) = ime_draft {
                match rebase_and_apply_step(&mut session_raw, draft.clone(), &remote_for_later) {
                    Ok(_) => {
                        remote_for_later =
                            advance_remote_past_local(&remote_for_later, &draft, &session_raw);
                    }
                    Err(ApplyError::Conflict(c)) => {
                        draft_conflict = true;
                        conflict_reason = Some(c.as_str().to_string());
                    }
                    Err(other) => return Err(other),
                }
            }
            if draft_conflict {
                prev_sel = before_sel;
            } else {
                ime.preedit_start = shift_pos_across_ops(&ime.preedit_start, &remote_for_later);
                self.ime = Some(ime);
                pending_format = self.session.pending.take();
            }
        }

        // Shift caret and selection top-level block indices across remote splices, then update
        // `Session::set_document`.
        let prev_page_hint = self.session.page_hint;
        let shifted_anchor = shift_pos_across_ops(&prev_sel.anchor, &remote_for_later);
        let shifted_focus = shift_pos_across_ops(&prev_sel.focus, &remote_for_later);

        self.session.set_document(session_raw);
        self.session.pending = pending_format;
        self.session.sel = Selection {
            anchor: self.session.doc.clamp(&shifted_anchor),
            focus: self.session.doc.clamp(&shifted_focus),
        };
        self.session.page_hint = prev_page_hint;

        if dropped_pending > 0
            || draft_conflict
            || structural_remote
            || undo_touches_remote_ops(&self.undo_stack, &self.redo_stack, &genuine_remote_ops)
        {
            self.clear_undo_redo();
        }

        let active_block = self
            .session
            .sel
            .focus
            .path
            .0
            .first()
            .copied()
            .map(|b| b as usize);

        serde_json::to_string(&json!({
            "dropped_pending": dropped_pending,
            "draft_conflict": draft_conflict,
            "conflict_reason": conflict_reason,
            "active_block": active_block,
            "pending_results": pending_results,
        }))
        .map_err(|e| ApplyError::Error(Error::Write(e.to_string())))
    }

    /// Searches all stories of the current document using the cached [`DocLayout`], returning JSON
    /// array of [`crate::FindMatch`] items (`page_index`, `block_index`, `snippet`, `rects`).
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn find(&mut self, query: &str, match_case: bool) -> Result<String, Error> {
        let lay = self.ensure_layout();
        let matches = find_with_layout(&self.session.doc, &lay, query, match_case);
        serde_json::to_string(&matches).map_err(|e| Error::Write(e.to_string()))
    }

    /// Returns the plain text of the active selection (empty when collapsed).
    #[must_use]
    pub fn selected_text(&self) -> String {
        if self.session.sel.is_collapsed() {
            return String::new();
        }
        self.session.selected_text()
    }

    /// Returns HTML markup for the active selection for `Ctrl+C` / `Cmd+C` (empty when collapsed).
    #[must_use]
    pub fn selected_html(&self) -> String {
        if self.session.sel.is_collapsed() {
            return String::new();
        }
        let mut copy_session = Session::new(self.session.doc.clone());
        copy_session.sel = self.session.sel.clone();
        copy_session.column = self.session.column.clone();
        if copy_session.run("edit.copy", &Value::Null).is_ok() {
            copy_session.clipboard_html
        } else {
            String::new()
        }
    }

    /// Lists safe WordCraft commands matching `query` as JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn commands(&self, query: &str) -> Result<String, Error> {
        let filter = (!query.trim().is_empty()).then_some(query);
        let list = commands_from_registry(&self.session.registry, filter);
        serde_json::to_string(&list).map_err(|e| Error::Write(e.to_string()))
    }

    /// Exports the current session document as `.docx` or `.docm` bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if WordCraft fails to write the OOXML archive.
    pub fn export_docx(&self) -> Result<Vec<u8>, Error> {
        let doc = WordDoc::from_parts(
            self.session.doc.clone(),
            self.confirmed.is_macro_enabled(),
            Arc::clone(&self.confirmed.missing_pictures),
        );
        export_docx(&doc)
    }

    /// Exports the current session document as PDF bytes.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if WordCraft's PDF writer fails.
    pub fn export_pdf(&self) -> Result<Vec<u8>, Error> {
        let doc = WordDoc::from_parts(
            self.session.doc.clone(),
            self.confirmed.is_macro_enabled(),
            Arc::clone(&self.confirmed.missing_pictures),
        );
        agent_export_pdf(&doc)
    }

    /// Returns diagnostic entries for pictures that could not be loaded on open, as JSON.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn missing_pictures(&self) -> Result<String, Error> {
        serde_json::to_string(self.confirmed.missing_pictures())
            .map_err(|e| Error::Write(e.to_string()))
    }

    /// Decodes and registers any fonts embedded in the opened document into the Worker's
    /// `FontDb::global()`, returning the number of faces loaded.
    ///
    /// Call this only inside an isolated browser Web Worker, never in the server NIF process.
    #[must_use]
    pub fn load_embedded_fonts(&self) -> usize {
        ensure_isolated_fonts();
        let embedded = wordcraft_docx::embedded_fonts(&self.session.doc);
        if embedded.is_empty() {
            return 0;
        }
        let files: Vec<(Vec<u8>, String)> =
            embedded.into_iter().map(|ef| (ef.data, ef.name)).collect();
        FontDb::global().add_document_fonts(files)
    }

    /// Registers a dynamically fetched site font blob in the Worker's `FontDb::global()`,
    /// returning the number of faces added.
    #[must_use]
    pub fn add_font(bytes: &[u8]) -> usize {
        ensure_isolated_fonts();
        FontDb::global().add_font(bytes.to_vec())
    }

    /// Lists font substitutions recorded during layout as JSON
    /// `[{"requested": "...", "used": "..."}, ...]`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn substituted_fonts(&mut self) -> Result<String, Error> {
        let lay = self.ensure_layout();
        let entries: Vec<Value> = lay
            .substituted_fonts()
            .into_iter()
            .map(|(requested, face)| {
                json!({
                    "requested": requested,
                    "used": face.get().family,
                })
            })
            .collect();
        serde_json::to_string(&entries).map_err(|e| Error::Write(e.to_string()))
    }

    /// Lists canonical site fallback font families needed to cover CJK characters in the current
    /// document that no loaded font face in `FontDb::global()` maps yet.
    ///
    /// # Errors
    ///
    /// Returns [`Error::Write`] if JSON serialization fails.
    pub fn missing_glyph_fonts(&self) -> Result<String, Error> {
        ensure_isolated_fonts();
        let families = collect_missing_cjk_families(&self.session.doc);
        serde_json::to_string(&families).map_err(|e| Error::Write(e.to_string()))
    }
}

fn collect_missing_cjk_families(doc: &Document) -> Vec<&'static str> {
    let mut cjk_chars = std::collections::BTreeSet::new();
    for blocks in std::iter::once(&doc.body).chain(doc.parts.values().map(|p| &p.blocks)) {
        collect_cjk_in_blocks(blocks, 0, &mut cjk_chars);
    }
    for sep in [&doc.footnote_separators, &doc.endnote_separators] {
        for blocks in [
            sep.separator.as_ref(),
            sep.continuation_separator.as_ref(),
            sep.continuation_notice.as_ref(),
        ]
        .into_iter()
        .flatten()
        {
            collect_cjk_in_blocks(blocks, 0, &mut cjk_chars);
        }
    }
    if let Some(wm) = &doc.settings.watermark {
        cjk_chars.extend(wm.text.chars().filter(|&c| is_cjk_char(c)));
    }
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

    select_cjk_fallback_families(&uncovered, |fam| db.is_loaded(fam))
}

fn collect_cjk_in_blocks(
    blocks: &[Arc<Block>],
    depth: usize,
    out: &mut std::collections::BTreeSet<char>,
) {
    if depth > 32 {
        return;
    }
    for block in blocks {
        match block.as_ref() {
            Block::Para(para) => {
                out.extend(para.text.chars().filter(|&c| c != OBJ && is_cjk_char(c)));
                for obj in &para.objects {
                    collect_cjk_in_object(obj, depth, out);
                }
            }
            Block::Table(tbl) => {
                for row in &tbl.rows {
                    for cell in &row.cells {
                        collect_cjk_in_blocks(&cell.blocks, depth + 1, out);
                    }
                }
            }
        }
    }
}

fn collect_cjk_in_object(
    obj: &wordcraft_doc::InlineObject,
    depth: usize,
    out: &mut std::collections::BTreeSet<char>,
) {
    if depth > 32 {
        return;
    }
    match obj {
        wordcraft_doc::InlineObject::Field { result, .. } => {
            out.extend(result.chars().filter(|&c| is_cjk_char(c)));
        }
        wordcraft_doc::InlineObject::Ruby { base, ruby, .. } => {
            out.extend(base.chars().filter(|&c| is_cjk_char(c)));
            out.extend(ruby.chars().filter(|&c| is_cjk_char(c)));
        }
        wordcraft_doc::InlineObject::Graphic { graphic, .. } => {
            for item in &graphic.items {
                if let wordcraft_doc::graphic::GraphicItem::Text { text, .. } = item {
                    out.extend(text.chars().filter(|&c| is_cjk_char(c)));
                }
            }
        }
        wordcraft_doc::InlineObject::Group { children, .. } => {
            for child in children {
                collect_cjk_in_object(&child.obj, depth + 1, out);
            }
        }
        _ => {}
    }
}

fn is_cjk_char(c: char) -> bool {
    wordcraft_fonts::is_cjk(c) || matches!(c, '\u{1100}'..='\u{11FF}')
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
        if matches!(c, '\u{AC00}'..='\u{D7AF}' | '\u{1100}'..='\u{11FF}' | '\u{3130}'..='\u{318F}')
        {
            has_hangul = true;
        } else if matches!(c, '\u{3040}'..='\u{30FF}' | '\u{31F0}'..='\u{31FF}' | '\u{FF65}'..='\u{FF9F}')
        {
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

fn to_page_rect(page: usize, r: Rect) -> PageRect {
    PageRect {
        page,
        x: r.x,
        y: r.y,
        w: r.w,
        h: r.h,
    }
}

fn validate_pointer_coords(x_pt: f32, y_pt: f32) -> Result<(), Error> {
    if !x_pt.is_finite() || !y_pt.is_finite() {
        return Err(Error::Invalid(format!(
            "non-finite pointer coordinates ({x_pt}, {y_pt})"
        )));
    }
    Ok(())
}

fn parse_story_ref(story_json: &str) -> Result<StoryRef, Error> {
    let trimmed = story_json.trim();
    if trimmed == "body" {
        return Ok(StoryRef::Body);
    }
    serde_json::from_str::<StoryRef>(trimmed)
        .map_err(|e| Error::Invalid(format!("invalid story reference `{story_json}`: {e}")))
}

fn push_page_rect(by_page: &mut BTreeMap<usize, Rect>, page_idx: usize, r: Rect) {
    if r.w >= 0.0 && r.h >= 0.0 {
        by_page
            .entry(page_idx)
            .and_modify(|acc| *acc = acc.union(&r))
            .or_insert(r);
    }
}

fn collect_block_rects_in_items(
    items: &[Placed],
    target_story: StoryRef,
    target_block: u32,
    page_idx: usize,
    by_page: &mut BTreeMap<usize, Rect>,
) {
    for item in items {
        match item {
            Placed::Lines {
                story,
                path,
                para,
                l0,
                l1,
                x,
                y,
                turn,
            } if *story == target_story && path.0.first().copied() == Some(target_block) => {
                let Some(first) = para.lines.get(*l0) else {
                    continue;
                };
                for li in *l0..*l1 {
                    let Some(line) = para.lines.get(li) else {
                        continue;
                    };
                    let top = line.top - first.top;
                    let width = (line.right - line.left).max(6.0);
                    let height = line.height.max(4.0);
                    let turned = wordcraft_layout::turn_rect(
                        *turn,
                        *x,
                        *y,
                        Rect::new(line.left, top, width, height),
                    );
                    push_page_rect(by_page, page_idx, turned);
                }
            }
            Placed::Cell {
                rect, table, story, ..
            } if *story == target_story && table.0.first().copied() == Some(target_block) => {
                push_page_rect(by_page, page_idx, *rect);
            }
            Placed::Object {
                rect,
                spin,
                story,
                path,
                ..
            } if *story == target_story && path.0.first().copied() == Some(target_block) => {
                push_page_rect(by_page, page_idx, spin.bounds(*rect));
            }
            Placed::Clip { items: inner, .. } => {
                collect_block_rects_in_items(inner, target_story, target_block, page_idx, by_page);
            }
            _ => {}
        }
    }
}

fn link_at_pos(doc: &Document, pos: &Pos) -> Option<String> {
    let para = doc.para_at(pos)?;
    if pos.off < para.len()
        && let Some(link) = &para.props_of_char(pos.off).link
    {
        return Some(link.clone());
    }
    if pos.off > 0 && pos.off < para.len() {
        return para.props_at(pos.off).link.clone();
    }
    None
}

fn word_range_at(doc: &Document, pos: &Pos) -> (Pos, Pos) {
    let Some(para) = doc.para_at(pos) else {
        return (pos.clone(), pos.clone());
    };
    let text = para.text.as_str();
    if text.is_empty() {
        return (pos.clone(), pos.clone());
    }
    let clamped = clamp_utf8_boundary(text, pos.off.min(text.len()));
    let probe = if clamped == text.len() && clamped > 0 {
        prev_char_boundary(text, clamped)
    } else {
        clamped
    };
    let Some(ch) = text.get(probe..).and_then(|s| s.chars().next()) else {
        return (pos.clone(), pos.clone());
    };
    let class = char_word_class(ch);
    let mut start = probe;
    while start > 0 {
        let prev = prev_char_boundary(text, start);
        let Some(pch) = text.get(prev..start).and_then(|s| s.chars().next()) else {
            break;
        };
        if char_word_class(pch) != class {
            break;
        }
        start = prev;
    }
    let mut end = probe.saturating_add(ch.len_utf8());
    while end < text.len() {
        let Some(nch) = text.get(end..).and_then(|s| s.chars().next()) else {
            break;
        };
        if char_word_class(nch) != class {
            break;
        }
        end = end.saturating_add(nch.len_utf8());
    }
    (
        Pos {
            story: pos.story,
            path: pos.path.clone(),
            off: start,
        },
        Pos {
            story: pos.story,
            path: pos.path.clone(),
            off: end,
        },
    )
}

fn char_word_class(ch: char) -> u8 {
    if ch.is_whitespace() {
        0
    } else if ch.is_alphanumeric() || ch == '_' {
        1
    } else {
        2
    }
}

fn clamp_utf8_boundary(text: &str, idx: usize) -> usize {
    let mut i = idx.min(text.len());
    while i > 0 && !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn prev_char_boundary(text: &str, idx: usize) -> usize {
    let mut i = idx.min(text.len()).saturating_sub(1);
    while i > 0 && !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

fn is_monospace_font(font: &str) -> bool {
    let lower = font.to_ascii_lowercase();
    lower.contains("mono")
        || lower.contains("consolas")
        || lower.contains("courier")
        || lower.contains("menlo")
        || lower.contains("fira code")
}

fn build_shortcut_string(key: &str, ctrl_or_meta: bool, shift: bool, alt: bool) -> Option<String> {
    let mapped = match key {
        "ArrowLeft" => "Left",
        "ArrowRight" => "Right",
        "ArrowUp" => "Up",
        "ArrowDown" => "Down",
        " " | "Spacebar" => "Space",
        "Esc" => "Escape",
        other => other,
    };
    let is_named = matches!(
        mapped,
        "Left"
            | "Right"
            | "Up"
            | "Down"
            | "Home"
            | "End"
            | "PageUp"
            | "PageDown"
            | "Enter"
            | "Tab"
            | "Backspace"
            | "Delete"
            | "Escape"
            | "Space"
            | "Insert"
    ) || (mapped.starts_with(['F', 'f'])
        && mapped
            .get(1..)
            .and_then(|s| s.parse::<u8>().ok())
            .is_some_and(|n| (1..=24).contains(&n)));

    if !ctrl_or_meta && !alt && !is_named {
        return None;
    }

    let mut raw = String::new();
    if ctrl_or_meta {
        raw.push_str("Mod+");
    }
    if alt {
        raw.push_str("Alt+");
    }
    if shift {
        raw.push_str("Shift+");
    }
    raw.push_str(mapped);
    wordcraft_engine::keymap::normalize(&raw)
}

fn is_document_wide_command(command_id: &str) -> bool {
    command_id.starts_with("styles.")
        || command_id.starts_with("design.")
        || command_id.starts_with("numbering.")
        || command_id.starts_with("page.")
        || matches!(
            command_id,
            "review.trackChanges"
                | "review.acceptAll"
                | "review.rejectAll"
                | "review.acceptAllShown"
                | "review.rejectAllShown"
        )
}

fn story_blocks(doc: &Document, story: StoryRef) -> &[Arc<Block>] {
    match story {
        StoryRef::Body => &doc.body,
        StoryRef::Part(id) => doc.parts.get(&id).map_or(&[], |p| p.blocks.as_slice()),
    }
}

fn set_story_blocks(doc: &mut Document, story: StoryRef, blocks: Vec<Arc<Block>>) {
    match story {
        StoryRef::Body => {
            doc.body = blocks;
        }
        StoryRef::Part(id) => {
            if let Some(part) = doc.parts.get_mut(&id) {
                part.blocks = blocks;
            }
        }
    }
}

fn clamp_selection(doc: &Document, sel: &Selection) -> Selection {
    Selection {
        anchor: doc.clamp(&sel.anchor),
        focus: doc.clamp(&sel.focus),
    }
}

fn blocks_slice_eq(a: &[Arc<Block>], b: &[Arc<Block>]) -> bool {
    a.len() == b.len()
        && a.iter()
            .zip(b.iter())
            .all(|(x, y)| Arc::ptr_eq(x, y) || x == y)
}

type TrimmedBlockSpan = (usize, Vec<Arc<Block>>, Vec<Arc<Block>>);

fn trim_block_span(before: &[Arc<Block>], after: &[Arc<Block>]) -> Option<TrimmedBlockSpan> {
    let mut prefix = 0usize;
    let max_prefix = before.len().min(after.len());
    while prefix < max_prefix {
        let (Some(b), Some(a)) = (before.get(prefix), after.get(prefix)) else {
            break;
        };
        if Arc::ptr_eq(b, a) || b == a {
            prefix += 1;
        } else {
            break;
        }
    }
    if prefix == before.len() && prefix == after.len() {
        return None;
    }

    let mut suffix = 0usize;
    let max_suffix = before.len().min(after.len()).saturating_sub(prefix);
    while suffix < max_suffix {
        let bi = before.len().saturating_sub(1 + suffix);
        let ai = after.len().saturating_sub(1 + suffix);
        let (Some(b), Some(a)) = (before.get(bi), after.get(ai)) else {
            break;
        };
        if Arc::ptr_eq(b, a) || b == a {
            suffix += 1;
        } else {
            break;
        }
    }

    let before_end = before.len().saturating_sub(suffix);
    let after_end = after.len().saturating_sub(suffix);
    let b_slice = before.get(prefix..before_end)?.to_vec();
    let a_slice = after.get(prefix..after_end)?.to_vec();
    Some((prefix, b_slice, a_slice))
}

fn changeset_matches_local_ack(local: &ChangeSet, server: &ChangeSet) -> bool {
    if local.edits.len() != server.edits.len() {
        return false;
    }
    local
        .edits
        .iter()
        .zip(server.edits.iter())
        .all(|(l, s)| match (l, s) {
            (
                Edit::BlocksSplice {
                    story: s1,
                    at: a1,
                    delete: d1,
                    insert: i1,
                },
                Edit::BlocksSplice {
                    story: s2,
                    at: a2,
                    delete: d2,
                    insert: i2,
                },
            ) => s1 == s2 && a1 == a2 && d1 == d2 && i1 == i2,
            (
                Edit::EntryPut {
                    map: m1,
                    key: k1,
                    value: v1,
                },
                Edit::EntryPut {
                    map: m2,
                    key: k2,
                    value: v2,
                },
            ) => {
                if m1 != m2 || k1 != k2 {
                    return false;
                }
                if *m1 == EntryMap::Comments {
                    // Server overwrites `author` and `initials` on commit.
                    strip_comment_actor(v1) == strip_comment_actor(v2)
                } else {
                    v1 == v2
                }
            }
            (Edit::EntryDelete { map: m1, key: k1 }, Edit::EntryDelete { map: m2, key: k2 }) => {
                m1 == m2 && k1 == k2
            }
            (
                Edit::RevisionsAppend {
                    from: f1,
                    items: i1,
                },
                Edit::RevisionsAppend {
                    from: f2,
                    items: i2,
                },
            ) => {
                f1 == f2
                    && i1.len() == i2.len()
                    && i1.iter().zip(i2.iter()).all(|(r1, r2)| {
                        r1.kind == r2.kind && r1.date == r2.date && r1.move_name == r2.move_name
                    })
            }
            (
                Edit::FieldSet {
                    field: f1,
                    value: v1,
                },
                Edit::FieldSet {
                    field: f2,
                    value: v2,
                },
            ) => f1 == f2 && v1 == v2,
            _ => false,
        })
}

fn strip_comment_actor(val: &Value) -> Value {
    let mut cloned = val.clone();
    if let Some(obj) = cloned.as_object_mut() {
        obj.remove("author");
        obj.remove("initials");
    }
    cloned
}

fn rebase_and_apply_step(
    target_doc: &mut Document,
    incoming: ChangeSet,
    prior_ops: &[ChangeSet],
) -> Result<ChangeSet, ApplyError> {
    let rebased = rebase_changeset(incoming, prior_ops, target_doc)?;
    let spliced_stories = collect_spliced_stories(&rebased);
    let balanced_before: Vec<StoryRef> = spliced_stories
        .iter()
        .copied()
        .filter(|s| crate::markers::story_markers_balanced(target_doc, *s))
        .collect();

    let mut candidate = target_doc.clone();
    execute_changeset(&mut candidate, &rebased)?;
    candidate.ensure_nonempty();

    for story in spliced_stories {
        if (!prior_ops.is_empty() || balanced_before.contains(&story))
            && !crate::markers::story_markers_balanced(&candidate, story)
        {
            return Err(ApplyError::Conflict(Conflict::UnbalancedMarkers));
        }
    }

    *target_doc = candidate;
    Ok(rebased)
}

fn advance_remote_past_local(
    remote_ops: &[ChangeSet],
    local_op: &ChangeSet,
    current_doc: &Document,
) -> Vec<ChangeSet> {
    remote_ops
        .iter()
        .filter_map(|r| {
            rebase_changeset(r.clone(), std::slice::from_ref(local_op), current_doc).ok()
        })
        .collect()
}

fn invert_structural_hint(dropped_local: &ChangeSet) -> ChangeSet {
    let edits = dropped_local
        .edits
        .iter()
        .filter_map(|e| match e {
            Edit::BlocksSplice {
                story,
                at,
                delete,
                insert,
            } => {
                // Reverses the block count delta `(insert.len() -> delete)` so later unconfirmed
                // local drafts shift back onto the server's coordinate frame.
                let dummy = Block::Para(Paragraph::default());
                Some(Edit::BlocksSplice {
                    story: *story,
                    at: *at,
                    delete: insert.len(),
                    insert: vec![dummy; *delete],
                })
            }
            _ => None,
        })
        .collect();
    ChangeSet {
        model_version: crate::MODEL_VERSION,
        edits,
    }
}

fn changeset_is_structural(cs: &ChangeSet) -> bool {
    cs.edits.iter().any(|edit| match edit {
        Edit::BlocksSplice { delete, insert, .. } => *delete != insert.len(),
        Edit::EntryDelete {
            map: EntryMap::Parts,
            ..
        }
        | Edit::FieldSet { .. } => true,
        Edit::EntryPut { .. } | Edit::EntryDelete { .. } | Edit::RevisionsAppend { .. } => false,
    })
}

fn shift_pos_across_ops(pos: &Pos, remote_ops: &[ChangeSet]) -> Pos {
    let Some(&first) = pos.path.0.first() else {
        return pos.clone();
    };
    let mut blk = first as usize;
    for op in remote_ops {
        for edit in &op.edits {
            if let Edit::BlocksSplice {
                story,
                at,
                delete,
                insert,
            } = edit
                && *story == pos.story
            {
                let end = at.saturating_add(*delete);
                if end <= blk {
                    blk = blk.saturating_sub(*delete).saturating_add(insert.len());
                } else if *at < blk {
                    // Caret was inside a remotely replaced span; clamp to the start of the span.
                    blk = *at;
                    let out_path = vec![u32::try_from(blk).unwrap_or(u32::MAX)];
                    return Pos {
                        story: pos.story,
                        path: Path(out_path),
                        off: 0,
                    };
                }
            }
        }
    }
    let mut new_path = pos.path.0.clone();
    if let Some(slot) = new_path.first_mut() {
        *slot = u32::try_from(blk).unwrap_or(u32::MAX);
    }
    Pos {
        story: pos.story,
        path: Path(new_path),
        off: pos.off,
    }
}

fn undo_touches_remote_ops(
    undo_stack: &[BlockUndoEntry],
    redo_stack: &[BlockUndoEntry],
    remote_ops: &[ChangeSet],
) -> bool {
    if remote_ops.is_empty() {
        return false;
    }
    for entry in undo_stack.iter().chain(redo_stack.iter()) {
        let entry_end = entry
            .at
            .saturating_add(entry.before_blocks.len().max(entry.after_blocks.len()));
        for op in remote_ops {
            for edit in &op.edits {
                match edit {
                    Edit::BlocksSplice {
                        story, at, delete, ..
                    } if *story == entry.story => {
                        let op_end = at.saturating_add(*delete);
                        if *at < entry_end && entry.at <= op_end {
                            return true;
                        }
                    }
                    Edit::EntryPut {
                        map: EntryMap::Parts,
                        key,
                        ..
                    }
                    | Edit::EntryDelete {
                        map: EntryMap::Parts,
                        key,
                    } => {
                        if let Ok(part_id) = key.parse::<u32>()
                            && entry.story == StoryRef::Part(part_id)
                        {
                            return true;
                        }
                    }
                    _ => {}
                }
            }
        }
    }
    false
}
