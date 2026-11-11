//! Fonts initialization, PDF/PNG/RGBA rendering, find, inspection, and headless Agent commands.

use std::io::Cursor;
#[cfg(not(target_arch = "wasm32"))]
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Once};

use image::ImageFormat;
use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::{canonical_combining_class, compose};
use unicode_segmentation::UnicodeSegmentation;
use wordcraft_doc::para::{COLUMN_BREAK, InlineObject, OBJ, PAGE_BREAK};
use wordcraft_doc::{Block, Document, Paragraph, Pos, StoryRef};
use wordcraft_engine::Session;
use wordcraft_fonts::FontDb;
use wordcraft_layout::{DocLayout, LayoutCache, LayoutOptions};
use wordcraft_pdf::PdfOptions;
use wordcraft_render::RenderOptions;

use crate::derive::derive_changeset;
use crate::ops::ChangeSet;
use crate::{Error, MAX_PICTURE_BYTES, WordDoc};

static SITE_FONTS_INIT: Once = Once::new();

#[cfg(not(target_arch = "wasm32"))]
static TEMP_DIR_SEQ: AtomicU64 = AtomicU64::new(1);

/// Blocked command prefixes that touch host files, exports, windows, or process state.
pub(crate) const BLOCKED_COMMAND_PREFIXES: [&str; 7] = [
    "file.",
    "export.",
    "import.",
    "print.",
    "app.",
    "window.",
    "recovery.",
];

/// Bounding rectangle on a laid-out page in points.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct PageRect {
    /// Zero-based page index.
    pub page: usize,
    /// Left coordinate in page points.
    pub x: f32,
    /// Top coordinate in page points.
    pub y: f32,
    /// Width in page points.
    pub w: f32,
    /// Height in page points.
    pub h: f32,
}

/// One text search match returned by [`find`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FindMatch {
    /// Story containing the match (`"body"` or `{"part": id}`).
    pub story: StoryRef,
    /// Zero-based top-level block index inside `story`.
    pub block_index: usize,
    /// Zero-based page index of the first highlight rectangle (or caret fallback).
    pub page_index: usize,
    /// Plain-text excerpt surrounding the match.
    pub snippet: String,
    /// Highlight rectangles in page points.
    pub rects: Vec<PageRect>,
}

/// Ensures `FontDb::global()` is initialized without host system font directories and with system
/// fallback disabled.
pub(crate) fn ensure_isolated_fonts() {
    let _ = FontDb::init_test_fonts();
    FontDb::global().set_system_fallback(false);
}

/// Initializes the process-wide WordCraft [`FontDb`] once with the site's open-licensed font
/// blobs and disables host system-font fallback.
///
/// Server-side code never loads per-document embedded fonts into `FontDb`.
pub fn init_site_fonts(font_blobs: &[Vec<u8>]) {
    ensure_isolated_fonts();
    SITE_FONTS_INIT.call_once(|| {
        let db = FontDb::global();
        db.set_system_fallback(false);
        for blob in font_blobs {
            db.add_font(blob.clone());
        }
    });
}

/// Exports `doc` to PDF bytes using the site-wide font database.
///
/// # Errors
///
/// Returns [`Error::Write`] if WordCraft's PDF writer fails.
pub fn export_pdf(doc: &WordDoc) -> Result<Vec<u8>, Error> {
    ensure_isolated_fonts();
    let refreshed = wordcraft_engine::cmd::references::output_fields(doc.document());
    let target = refreshed.as_ref().unwrap_or_else(|| doc.document());
    wordcraft_pdf::export(target, &PdfOptions::default()).map_err(|e| Error::Write(e.to_string()))
}

/// Rasterizes a zero-based page of `doc` at `scale` pixels per point into straight RGBA8 pixels,
/// returning `(width, height, rgba_bytes)`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `page_index` is out of range or `scale` is non-positive/non-finite.
pub fn render_page_rgba(
    doc: &WordDoc,
    page_index: usize,
    scale: f32,
) -> Result<(u32, u32, Vec<u8>), Error> {
    if !scale.is_finite() || scale <= 0.0 {
        return Err(Error::Invalid(format!("invalid render scale {scale}")));
    }
    ensure_isolated_fonts();
    let refreshed = wordcraft_engine::cmd::references::output_fields(doc.document());
    let target = refreshed.as_ref().unwrap_or_else(|| doc.document());
    let lay = wordcraft_layout::layout(target, &mut LayoutCache::new(), &LayoutOptions::default());
    let page = lay.pages.get(page_index).ok_or_else(|| {
        Error::Invalid(format!(
            "page index {page_index} out of bounds (page_count={})",
            lay.pages.len()
        ))
    })?;
    let rendered = wordcraft_render::render_page(target, page, scale, &RenderOptions::default());
    Ok((rendered.width, rendered.height, rendered.to_straight()))
}

/// Rasterizes a zero-based page of `doc` at `scale` pixels per point and encodes it as PNG,
/// returning `(png_bytes, width_px, height_px, page_count)`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `page_index` is out of range or `scale` is non-positive/non-finite,
/// or [`Error::Write`] if PNG encoding fails.
pub fn render_page_png_meta(
    doc: &WordDoc,
    page_index: usize,
    scale: f32,
) -> Result<(Vec<u8>, u32, u32, usize), Error> {
    if !scale.is_finite() || scale <= 0.0 {
        return Err(Error::Invalid(format!("invalid render scale {scale}")));
    }
    ensure_isolated_fonts();
    let refreshed = wordcraft_engine::cmd::references::output_fields(doc.document());
    let target = refreshed.as_ref().unwrap_or_else(|| doc.document());
    let lay = wordcraft_layout::layout(target, &mut LayoutCache::new(), &LayoutOptions::default());
    let count = lay.pages.len();
    let page = lay.pages.get(page_index).ok_or_else(|| {
        Error::Invalid(format!(
            "page index {page_index} out of bounds (page_count={count})"
        ))
    })?;
    let rendered = wordcraft_render::render_page(target, page, scale, &RenderOptions::default());
    let png = rendered.to_png();
    if png.is_empty() {
        return Err(Error::Write(
            "failed to encode rendered page as PNG".to_string(),
        ));
    }
    Ok((png, rendered.width, rendered.height, count))
}

/// Rasterizes a zero-based page of `doc` at `scale` pixels per point and encodes it as PNG.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `page_index` is out of range or `scale` is non-positive/non-finite,
/// or [`Error::Write`] if PNG encoding fails.
pub fn render_page_png(doc: &WordDoc, page_index: usize, scale: f32) -> Result<Vec<u8>, Error> {
    render_page_png_meta(doc, page_index, scale).map(|(png, ..)| png)
}

/// Searches all logical stories of `doc` for `query`, returning match positions, snippets, and
/// page highlight rectangles.
#[must_use]
pub fn find(doc: &WordDoc, query: &str, match_case: bool) -> Vec<FindMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    let raw = doc.document();
    ensure_isolated_fonts();
    let lay = wordcraft_layout::layout(raw, &mut LayoutCache::new(), &LayoutOptions::default());
    find_with_layout(raw, &lay, query, match_case)
}

pub(crate) fn find_with_layout(
    doc: &Document,
    lay: &DocLayout,
    query: &str,
    match_case: bool,
) -> Vec<FindMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    let mut needle = String::new();
    append_search_text(&mut needle, query.nfkc(), match_case);
    if needle.is_empty() {
        return Vec::new();
    }

    let mut matches = Vec::new();
    let stories =
        std::iter::once(StoryRef::Body).chain(doc.parts.keys().copied().map(StoryRef::Part));
    for story in stories {
        let paths = doc.para_paths(story);
        for path in paths {
            let Some(para) = doc.para(story, &path) else {
                continue;
            };
            let block_index = path.0.first().copied().unwrap_or(0) as usize;
            for (start_off, end_off) in find_in_text(&para.text, &needle, match_case) {
                let start_pos = Pos {
                    story,
                    path: path.clone(),
                    off: start_off,
                };
                let end_pos = Pos {
                    story,
                    path: path.clone(),
                    off: end_off,
                };
                let rects: Vec<PageRect> = lay
                    .selection_rects(doc, &start_pos, &end_pos, 0)
                    .into_iter()
                    .map(|(page, r)| PageRect {
                        page,
                        x: r.x,
                        y: r.y,
                        w: r.w,
                        h: r.h,
                    })
                    .collect();
                let page_index = rects
                    .first()
                    .map(|r| r.page)
                    .or_else(|| lay.caret(&start_pos).map(|c| c.page))
                    .unwrap_or(0);
                let snippet = make_snippet(&para.text, start_off, end_off);
                matches.push(FindMatch {
                    story,
                    block_index,
                    page_index,
                    snippet,
                    rects,
                });
            }
        }
    }
    matches
}

fn append_search_text(out: &mut String, chars: impl Iterator<Item = char>, match_case: bool) {
    if match_case {
        out.extend(chars);
    } else {
        out.extend(chars.flat_map(char::to_lowercase));
    }
}

fn find_in_text(text: &str, needle: &str, match_case: bool) -> Vec<(usize, usize)> {
    let mut normalized = String::with_capacity(text.len());
    let mut spans = Vec::new();
    let mut group = String::new();
    let mut next = String::new();
    let mut source_start = 0;
    let mut source_end = 0;

    // Map normalized text back to source clusters for layout. Compatibility decomposition
    // can also join separate clusters, as with Hangul compatibility jamo.
    for (start, cluster) in text.grapheme_indices(true) {
        next.clear();
        if matches!(
            cluster.chars().next(),
            Some(OBJ | PAGE_BREAK | COLUMN_BREAK)
        ) {
            next.push('\u{FFFD}');
        } else {
            next.extend(cluster.nfkc());
        }
        let joins_previous = group
            .chars()
            .next_back()
            .zip(next.chars().next())
            .is_some_and(|(last, first)| {
                canonical_combining_class(first) != 0 || compose(last, first).is_some()
            });
        if joins_previous {
            group.push_str(&next);
            group = group.nfc().collect();
        } else {
            if !group.is_empty() {
                append_search_text(&mut normalized, group.chars(), match_case);
                spans.push((normalized.len(), source_start, source_end));
            }
            std::mem::swap(&mut group, &mut next);
            source_start = start;
        }
        source_end = start + cluster.len();
    }
    if !group.is_empty() {
        append_search_text(&mut normalized, group.chars(), match_case);
        spans.push((normalized.len(), source_start, source_end));
    }

    let mut matches = Vec::new();
    for (start, matched) in normalized.match_indices(needle) {
        let end = start + matched.len();
        let first = spans.partition_point(|(offset, ..)| *offset <= start);
        let last = spans.partition_point(|(offset, ..)| *offset < end);
        if let (Some((_, original_start, _)), Some((_, _, original_end))) =
            (spans.get(first), spans.get(last))
        {
            let range = (*original_start, *original_end);
            if matches.last() != Some(&range) {
                matches.push(range);
            }
        }
    }
    matches
}

fn make_snippet(text: &str, start_off: usize, end_off: usize) -> String {
    let prefix = text.get(..start_off).unwrap_or("");
    let matched = text.get(start_off..end_off).unwrap_or("");
    let suffix = text.get(end_off..).unwrap_or("");

    let before_chars: Vec<char> = prefix.chars().collect();
    let before_skip = before_chars.len().saturating_sub(32);
    let mut out = String::new();
    if before_skip > 0 {
        out.push('…');
    }
    for ch in before_chars.into_iter().skip(before_skip) {
        push_clean_char(&mut out, ch);
    }
    for ch in matched.chars() {
        push_clean_char(&mut out, ch);
    }
    let mut after_iter = suffix.chars();
    for _ in 0..32 {
        let Some(ch) = after_iter.next() else {
            return out;
        };
        push_clean_char(&mut out, ch);
    }
    if after_iter.next().is_some() {
        out.push('…');
    }
    out
}

fn push_clean_char(out: &mut String, ch: char) {
    match ch {
        OBJ => {}
        PAGE_BREAK | COLUMN_BREAK | '\n' | '\r' | '\t' => out.push(' '),
        c if c.is_control() => {}
        c => out.push(c),
    }
}

#[derive(Default, Deserialize)]
struct InspectParams {
    #[serde(default)]
    story: Option<StoryRef>,
    #[serde(default)]
    from_block: Option<usize>,
    #[serde(default)]
    to_block: Option<usize>,
}

/// Inspects the logical structure and text of `doc` with optional `{story, from_block, to_block}`
/// pagination parameters.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `params_json` is malformed or names a nonexistent story part.
pub fn inspect(doc: &WordDoc, params_json: &str) -> Result<Value, Error> {
    let trimmed = params_json.trim();
    let params: InspectParams = if trimmed.is_empty() {
        InspectParams::default()
    } else {
        serde_json::from_str(trimmed)
            .map_err(|e| Error::Invalid(format!("invalid inspect params JSON: {e}")))?
    };

    let raw = doc.document();
    let story = params.story.unwrap_or(StoryRef::Body);
    let story_blocks = raw
        .story(story)
        .ok_or_else(|| Error::Invalid(format!("story {story:?} does not exist")))?;

    let total_blocks = story_blocks.len();
    let from = params.from_block.unwrap_or(0).min(total_blocks);
    let to = params
        .to_block
        .unwrap_or(total_blocks)
        .min(total_blocks)
        .max(from);

    ensure_isolated_fonts();
    let lay = wordcraft_layout::layout(raw, &mut LayoutCache::new(), &LayoutOptions::default());
    let page_count = lay.pages.len();

    let parts: Vec<Value> = raw
        .parts
        .iter()
        .map(|(id, part)| {
            json!({
                "id": id,
                "kind": part.kind,
                "block_count": part.blocks.len(),
            })
        })
        .collect();

    let mut blocks_json = Vec::with_capacity(to.saturating_sub(from));
    for (offset, blk) in story_blocks.get(from..to).unwrap_or(&[]).iter().enumerate() {
        let index = from.saturating_add(offset);
        match blk.as_ref() {
            Block::Para(p) => {
                let resolved = raw.styles.resolve_para(&p.props);
                let outline_level = resolved.outline_level.map(|lvl| lvl.saturating_add(1));
                blocks_json.push(json!({
                    "index": index,
                    "kind": "paragraph",
                    "style": p.props.style,
                    "outline_level": outline_level,
                    "text": paragraph_visible_text(p),
                    "rows": Value::Null,
                    "cols": Value::Null,
                }));
            }
            Block::Table(t) => {
                let cols = t
                    .rows
                    .iter()
                    .map(|r| {
                        r.first_grid().saturating_add(
                            r.cells.iter().map(wordcraft_doc::Cell::span).sum::<usize>(),
                        )
                    })
                    .max()
                    .unwrap_or(t.grid.len());
                blocks_json.push(json!({
                    "index": index,
                    "kind": "table",
                    "style": t.props.style,
                    "outline_level": Value::Null,
                    "text": table_visible_text(t),
                    "rows": t.rows.len(),
                    "cols": cols,
                }));
            }
        }
    }

    Ok(json!({
        "title": raw.core.title,
        "block_count": total_blocks,
        "page_count": page_count,
        "track_changes": raw.settings.track_changes,
        "comments_count": raw.comments.len(),
        "parts": parts,
        "blocks": blocks_json,
    }))
}

fn paragraph_visible_text(para: &Paragraph) -> String {
    let mut out = String::new();
    let mut obj_idx = 0usize;
    for (range, run_props) in para.run_ranges() {
        let slice = para.text.get(range).unwrap_or("");
        let obj_count = slice.chars().filter(|c| *c == OBJ).count();
        if run_props.del.is_some() {
            obj_idx = obj_idx.saturating_add(obj_count);
            continue;
        }
        for ch in slice.chars() {
            if ch == OBJ {
                if let Some(obj) = para.objects.get(obj_idx) {
                    match obj {
                        InlineObject::Field { result, .. } => out.push_str(result),
                        InlineObject::Equation { linear, .. } => out.push_str(linear),
                        InlineObject::Ruby { base, .. } => out.push_str(base),
                        _ => {}
                    }
                }
                obj_idx = obj_idx.saturating_add(1);
            } else if ch == PAGE_BREAK || ch == COLUMN_BREAK {
                out.push(' ');
            } else {
                out.push(ch);
            }
        }
    }
    out
}

fn table_visible_text(table: &wordcraft_doc::Table) -> String {
    let mut row_texts = Vec::with_capacity(table.rows.len());
    for row in &table.rows {
        let mut cell_texts = Vec::with_capacity(row.cells.len());
        for cell in &row.cells {
            if cell.props.vmerge == wordcraft_doc::props::VMerge::Continue {
                continue;
            }
            let mut block_texts = Vec::new();
            for blk in &cell.blocks {
                match blk.as_ref() {
                    Block::Para(p) => block_texts.push(paragraph_visible_text(p)),
                    Block::Table(nested) => block_texts.push(table_visible_text(nested)),
                }
            }
            cell_texts.push(block_texts.join("\n"));
        }
        row_texts.push(cell_texts.join("\t"));
    }
    row_texts.join("\n")
}

pub(crate) fn is_command_blocked(id: &str) -> bool {
    let trimmed = id.trim();
    BLOCKED_COMMAND_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
        || trimmed == "font.add"
}

/// Lists safe WordCraft engine commands matching the optional case-insensitive `query`.
#[must_use]
pub fn commands(query: Option<&str>) -> Value {
    let reg = wordcraft_engine::cmd::registry();
    commands_from_registry(&reg, query)
}

pub(crate) fn commands_from_registry(
    reg: &wordcraft_engine::Registry,
    query: Option<&str>,
) -> Value {
    let filter = query
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(str::to_lowercase);
    let items: Vec<Value> = reg
        .all()
        .iter()
        .filter(|spec| !is_command_blocked(spec.id))
        .filter(|spec| match &filter {
            None => true,
            Some(q) => {
                spec.id.to_lowercase().contains(q)
                    || spec.label.to_lowercase().contains(q)
                    || spec.location.to_lowercase().contains(q)
                    || spec.params.to_lowercase().contains(q)
            }
        })
        .map(|spec| {
            json!({
                "id": spec.id,
                "label": spec.label,
                "location": spec.location,
                "shortcut": spec.shortcut,
                "params": spec.params,
                "mutates": spec.mutates,
            })
        })
        .collect();
    Value::Array(items)
}

#[derive(Deserialize)]
struct RawCommandCall {
    #[serde(default)]
    command: Option<String>,
    #[serde(default)]
    id: Option<String>,
    #[serde(default = "empty_object")]
    params: Value,
}

fn empty_object() -> Value {
    json!({})
}

/// Runs a batch of WordCraft engine commands atomically in a confined headless [`Session`],
/// deriving a single unit [`ChangeSet`] and returning `(new_doc, changeset, results)`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `commands_json` is malformed, any command is blocked or fails,
/// or filesystem confinement blocks host file access.
pub fn apply_commands(
    doc: &WordDoc,
    commands_json: &str,
    actor_name: &str,
) -> Result<(WordDoc, Option<ChangeSet>, Vec<Value>), Error> {
    let raw_batch: Vec<RawCommandCall> = serde_json::from_str(commands_json)
        .map_err(|e| Error::Invalid(format!("invalid commands JSON: {e}")))?;
    if raw_batch.is_empty() {
        return Err(Error::Invalid(
            "commands_json must contain at least one command".to_string(),
        ));
    }

    let mut batch = Vec::with_capacity(raw_batch.len());
    for raw in raw_batch {
        let id = raw
            .command
            .or(raw.id)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                Error::Invalid(
                    "each command entry must specify a non-empty `command` or `id`".to_string(),
                )
            })?;
        if is_command_blocked(&id) {
            return Err(Error::Invalid(format!(
                "command `{id}` is not permitted in Word Pages"
            )));
        }
        let params = if raw.params.is_null() {
            empty_object()
        } else {
            raw.params
        };
        batch.push((id, params));
    }

    ensure_isolated_fonts();
    let mut session = Session::new(doc.document().clone());
    session.author = actor_name.to_string();

    let results = run_confined(|| {
        let mut out = Vec::with_capacity(batch.len());
        for (id, params) in &batch {
            let normalized_params = normalize_command_params(id, params)?;
            let res = session
                .run(id, &normalized_params)
                .map_err(|e| Error::Invalid(format!("command `{id}` failed: {e}")))?;
            out.push(res);
        }
        Ok(out)
    })?;

    session.doc.ensure_nonempty();
    let changeset = derive_changeset(doc.document(), &session.doc)?;
    let next_doc = match &changeset {
        None => doc.clone(),
        Some(_) => WordDoc::from_parts(
            session.doc,
            doc.is_macro_enabled(),
            Arc::clone(&doc.missing_pictures),
        ),
    };
    Ok((next_doc, changeset, results))
}

/// Normalizes command parameters (downscaling oversized `insert.picture` payloads to fit within
/// [`MAX_PICTURE_BYTES`], matching Spreadsheet Pages).
pub(crate) fn normalize_command_params(command_id: &str, params: &Value) -> Result<Value, Error> {
    if command_id != "insert.picture" {
        return Ok(params.clone());
    }
    let Some(obj) = params.as_object() else {
        return Ok(params.clone());
    };
    let Some(data_b64) = obj.get("data").and_then(Value::as_str) else {
        return Ok(params.clone());
    };
    let raw_bytes = base64_simd::STANDARD
        .decode_to_vec(data_b64)
        .map_err(|e| Error::Invalid(format!("invalid picture base64: {e}")))?;
    let fitted = fit_picture_bytes(&raw_bytes)?;
    if fitted.as_slice() == raw_bytes.as_slice() {
        return Ok(params.clone());
    }
    let mut updated = obj.clone();
    updated.insert(
        "data".to_string(),
        Value::String(base64_simd::STANDARD.encode_to_string(&fitted)),
    );
    Ok(Value::Object(updated))
}

fn fit_picture_bytes(bytes: &[u8]) -> Result<Vec<u8>, Error> {
    if bytes.is_empty() {
        return Err(Error::Invalid("picture data is empty".to_string()));
    }
    if let Ok(fmt) = image::guess_format(bytes)
        && matches!(fmt, ImageFormat::Png | ImageFormat::Jpeg)
        && bytes.len() <= MAX_PICTURE_BYTES
        && image::ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .ok()
            .and_then(|r| r.into_dimensions().ok())
            .is_some()
    {
        return Ok(bytes.to_vec());
    }

    let decoded = image::load_from_memory(bytes)
        .map_err(|e| Error::Invalid(format!("unsupported or corrupt picture: {e}")))?;
    let has_alpha = decoded.color().has_alpha();
    if let Some(encoded) = encode_within_budget(&decoded, has_alpha)? {
        return Ok(encoded);
    }

    let mut width = decoded.width();
    let mut height = decoded.height();
    for _ in 0..14 {
        let next_w = ((f64::from(width) * 0.82).round() as u32).max(1);
        let next_h = ((f64::from(height) * 0.82).round() as u32).max(1);
        if next_w == width && next_h == height {
            break;
        }
        width = next_w;
        height = next_h;
        let resized = decoded.resize_exact(width, height, FilterType::Lanczos3);
        if let Some(encoded) = encode_within_budget(&resized, has_alpha)? {
            return Ok(encoded);
        }
    }

    Err(Error::Invalid(format!(
        "picture cannot be compressed within {} bytes",
        MAX_PICTURE_BYTES
    )))
}

fn encode_within_budget(
    img: &image::DynamicImage,
    has_alpha: bool,
) -> Result<Option<Vec<u8>>, Error> {
    if has_alpha {
        let mut png = Vec::new();
        img.write_to(&mut Cursor::new(&mut png), ImageFormat::Png)
            .map_err(|e| Error::Invalid(format!("failed to encode PNG: {e}")))?;
        if png.len() <= MAX_PICTURE_BYTES {
            return Ok(Some(png));
        }
    }
    let rgb = img.to_rgb8();
    for quality in [85u8, 70, 55] {
        let mut jpg = Vec::new();
        let encoder = JpegEncoder::new_with_quality(&mut jpg, quality);
        rgb.write_with_encoder(encoder)
            .map_err(|e| Error::Invalid(format!("failed to encode JPEG: {e}")))?;
        if jpg.len() <= MAX_PICTURE_BYTES {
            return Ok(Some(jpg));
        }
    }
    Ok(None)
}

#[cfg(not(target_arch = "wasm32"))]
struct EmptyTempDir(std::path::PathBuf);

#[cfg(not(target_arch = "wasm32"))]
impl EmptyTempDir {
    fn create() -> Result<Self, Error> {
        let seq = TEMP_DIR_SEQ.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("ankole-word-confine-{}-{seq}", std::process::id()));
        std::fs::create_dir_all(&dir)
            .map_err(|e| Error::Invalid(format!("failed to create confinement directory: {e}")))?;
        Ok(Self(dir))
    }
}

#[cfg(not(target_arch = "wasm32"))]
impl Drop for EmptyTempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn run_confined<T>(f: impl FnOnce() -> Result<T, Error>) -> Result<T, Error> {
    #[cfg(not(target_arch = "wasm32"))]
    {
        let empty = EmptyTempDir::create()?;
        let roots = wordcraft_engine::file_access::AutomationRoots::new(Some(&empty.0), None)
            .map_err(Error::Invalid)?;
        wordcraft_engine::file_access::confine(roots.as_ref(), f)
    }
    #[cfg(target_arch = "wasm32")]
    {
        f()
    }
}
