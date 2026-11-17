//! Compiles a normalized Ankole `<page>` export tree into a styled [`WordDoc`] for `.docx` and
//! `.pdf` export.

mod blocks;
mod chrome;
mod containers;
mod inline;
mod tables;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use wordcraft_doc::para::{InlineObject, OBJ};
use wordcraft_doc::props::{CharProps, Rgb, TextColor};
use wordcraft_doc::{Block, Document, Paragraph, para_block};
use wordcraft_fonts::FontDb;
use wordcraft_layout::{LayoutCache, LayoutOptions};

use crate::agent::ensure_isolated_fonts;
use crate::editor::{is_cjk_char, select_cjk_fallback_families};
use crate::{Error, WordDoc};

use blocks::build_hr_paragraph;
use chrome::configure_styles_and_section;
use inline::{
    InlineState, TextTransform, append_styled_text, apply_context_para_indent,
    default_body_char_props, is_likely_block_node, parse_align, parse_inline_css_style,
    sanitize_control_chars,
};
use tables::compact_empty_para;

/// A4 portrait page width in points (`210 mm`).
pub const A4_WIDTH_PT: f32 = 595.28;
/// A4 portrait page height in points (`297 mm`).
pub const A4_HEIGHT_PT: f32 = 841.89;
/// Top and bottom page margins in points.
pub const PAGE_MARGIN_V_PT: f32 = 64.0;
/// Left and right page margins in points.
pub const PAGE_MARGIN_H_PT: f32 = 60.0;
/// Root body net content width (`475.28 pt`).
pub const ROOT_CONTENT_WIDTH_PT: f32 = A4_WIDTH_PT - 2.0 * PAGE_MARGIN_H_PT;

const INDENT_STEP_PT: f32 = 18.0;
const LIST_STEP_PT: f32 = 20.0;
const LIST_HANGING_PT: f32 = 14.0;
const MIN_CONTAINER_WIDTH_PT: f32 = 72.0;
const COLUMN_GUTTER_PT: f32 = 12.0;
const MIN_COLUMN_WIDTH_PT: f32 = 48.0;
const CALLOUT_ICON_COL_PT: f32 = 26.0;
const CODE_BOX_MAX_KEEP_HEIGHT_PT: f32 = 240.0;
const MAX_DISPLAY_IMAGE_HEIGHT_PT: f32 = 560.0;
const MAX_NESTING_DEPTH: usize = 32;
const MAX_TABLE_COLS: usize = wordcraft_doc::table::MAX_COLS;

const BODY_FONT_LATIN: &str = "Source Sans 3";
const HEADING_FONT_LATIN: &str = "Inter";
const BODY_FONT_EA: &str = "Microsoft YaHei";
const CODE_FONT_LATIN: &str = "JetBrains Mono";
const CODE_FONT_EA: &str = "IBMPlexMonoSCHalf";

const KNOWN_SITE_FONT_FAMILIES: [&str; 17] = [
    BODY_FONT_LATIN,
    HEADING_FONT_LATIN,
    CODE_FONT_LATIN,
    "Source Serif 4",
    "Carlito",
    "Liberation Sans",
    "Liberation Serif",
    "Liberation Mono",
    "IBM Plex Sans SC",
    "IBMPlexMonoSCHalf",
    "寒蝉锦书宋",
    "LXGW WenKai GB",
    "Noto Sans TC",
    "Noto Serif TC",
    "Noto Sans JP",
    "Noto Serif JP",
    "Noto Sans KR",
];

/// Input payload describing a normalized `<page>` export request.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageExportRequest {
    /// Document title shown at the top of page 1 and in subsequent page headers.
    pub title: String,
    /// Optional Unicode icon glyph shown beside the document title.
    #[serde(default)]
    pub icon_text: Option<String>,
    /// Optional rasterized icon asset key (custom image emoji or PDF color-emoji PNG).
    #[serde(default)]
    pub icon_asset_key: Option<String>,
    /// Optional Knowledge Page structured properties rendered below the title.
    #[serde(default)]
    pub metadata_rows: Vec<MetadataRow>,
    /// Normalized `<page>` element tree enriched with syntax-colored code lines and diagram keys.
    pub root: ExportNode,
    /// Access-checked Pod Page references keyed by canonical page UUID.
    #[serde(default)]
    pub references: BTreeMap<String, ResolvedReference>,
    /// Access-checked Principal references keyed by `principal_uid`.
    #[serde(default)]
    pub principals: BTreeMap<String, ResolvedPrincipal>,
}

/// One Knowledge Page property key-value pair formatted for display.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct MetadataRow {
    /// Property key name.
    pub key: String,
    /// Formatted property value text.
    pub value: String,
}

/// Access-checked metadata for a referenced Pod Page (`<mention page>` or `<embed ref>`).
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedReference {
    /// Display title (already localized/redacted when `restricted` is `true`).
    pub title: String,
    /// Clean canonical reader URL without `authentication_ref`.
    #[serde(default)]
    pub href: String,
    /// Whether the current viewer lacks access or the target was deleted.
    #[serde(default)]
    pub restricted: bool,
}

/// Access-checked metadata for a mentioned Principal (`<mention principal>`).
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedPrincipal {
    /// Display name (or redacted placeholder when `restricted` is `true`).
    pub name: String,
    /// Whether the current viewer cannot resolve this Principal.
    #[serde(default)]
    pub restricted: bool,
}

/// Normalized export tree node matching `@ankole/block-editor`'s tree plus pre-tokenized code and
/// rasterized emoji runs.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ExportNode {
    /// Structural or inline XML element.
    Element {
        /// Element tag name (`page`, `p`, `h1`..`h6`, `table`, `callout`, `columns`, `pre`, ...).
        name: String,
        /// Normalized attribute map, including optional `_export_*` enrichment keys.
        #[serde(default)]
        attrs: BTreeMap<String, String>,
        /// Ordered child nodes.
        #[serde(default)]
        children: Vec<ExportNode>,
    },
    /// Plain text leaf.
    Text {
        /// UTF-8 text content.
        value: String,
    },
    /// Rasterized inline emoji image used on the PDF branch so color emoji never render as `.notdef`.
    EmojiImage {
        /// Key into the supplied binary `assets` map.
        asset_key: String,
        /// Original emoji cluster preserved as image alt text.
        alt: String,
    },
    /// Pre-tokenized syntax-highlighted line inside a `<pre>` or diagram code view.
    CodeLine {
        /// Colored text runs on this single line (no newline characters).
        runs: Vec<CodeSpan>,
    },
}

/// One syntax-highlighted run inside an [`ExportNode::CodeLine`].
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CodeSpan {
    /// Run text content.
    pub text: String,
    /// Optional `#RRGGBB` foreground color from the light print syntax palette.
    #[serde(default)]
    pub color: Option<String>,
    /// Optional bold flag for syntax keywords/headings.
    #[serde(default)]
    pub bold: bool,
    /// Optional italic flag for comments/emphasis.
    #[serde(default)]
    pub italic: bool,
}

/// Font coverage report returned by [`report_font_needs`] to drive algebraic font convergence
/// before PDF export.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExportFontNeeds {
    /// Requested font families that layout had to substitute.
    pub substituted_families: Vec<String>,
    /// Canonical site CJK fallback families needed for uncovered Han/Kana/Hangul characters.
    pub missing_glyph_families: Vec<String>,
    /// Count of non-ASCII Unicode scalar values in the document still lacking a glyph in `FontDb`.
    pub uncovered_char_count: usize,
    /// Current `FontDb::global().generation()` value.
    pub font_generation: u64,
}

#[derive(Clone, Copy, Debug)]
struct LayoutContext {
    content_width_pt: f32,
    para_indent_left_pt: f32,
    list_depth: u8,
    table_depth: usize,
    font_scale: f32,
}

impl LayoutContext {
    const fn root() -> Self {
        Self {
            content_width_pt: ROOT_CONTENT_WIDTH_PT,
            para_indent_left_pt: 0.0,
            list_depth: 0,
            table_depth: 0,
            font_scale: 1.0,
        }
    }

    fn indented_by(self, delta_pt: f32) -> Self {
        if delta_pt <= 0.0 {
            return self;
        }
        Self {
            content_width_pt: (self.content_width_pt - delta_pt).max(MIN_CONTAINER_WIDTH_PT),
            para_indent_left_pt: self.para_indent_left_pt + delta_pt,
            ..self
        }
    }

    fn indented_levels(self, levels: u32) -> Self {
        self.indented_by((levels.min(16) as f32) * INDENT_STEP_PT)
    }

    fn enter_cell(self, cell_net_width_pt: f32, font_scale: f32) -> Self {
        Self {
            content_width_pt: cell_net_width_pt.max(12.0),
            para_indent_left_pt: 0.0,
            list_depth: 0,
            table_depth: self.table_depth.saturating_add(1),
            font_scale: (self.font_scale * font_scale).clamp(0.65, 1.0),
        }
    }
}

pub(super) fn heading_level(tag: &str) -> Option<u8> {
    match tag {
        "h1" => Some(1),
        "h2" => Some(2),
        "h3" => Some(3),
        "h4" => Some(4),
        "h5" => Some(5),
        "h6" => Some(6),
        _ => None,
    }
}

struct PageCompiler<'a> {
    req: &'a PageExportRequest,
    raw_assets: &'a BTreeMap<String, Vec<u8>>,
    doc: Document,
    media_key_map: BTreeMap<String, String>,
    next_num_id: u32,
}

/// Compiles a normalized [`PageExportRequest`] JSON payload and binary asset map into an immutable
/// [`WordDoc`] ready for [`crate::export_docx`] or [`crate::export_pdf`].
///
/// # Errors
///
/// Returns [`Error::Invalid`] if `request_json` is malformed or if the root node is not `<page>`.
pub fn from_page_tree(
    request_json: &str,
    assets: &BTreeMap<String, Vec<u8>>,
) -> Result<WordDoc, Error> {
    let req: PageExportRequest = serde_json::from_str(request_json)
        .map_err(|e| Error::Invalid(format!("invalid page export request JSON: {e}")))?;
    compile_request(&req, assets)
}

/// Inspects `doc` against the active process/Worker `FontDb` and reports substituted families,
/// missing CJK fallback families, and any remaining uncovered non-ASCII characters.
#[must_use]
pub fn report_font_needs(doc: &WordDoc) -> ExportFontNeeds {
    ensure_isolated_fonts();
    let raw = doc.document();
    let mut cache = LayoutCache::new();
    let lay = wordcraft_layout::layout(raw, &mut cache, &LayoutOptions::default());

    let mut substituted = Vec::new();
    for (requested, _) in lay.substituted_fonts() {
        if !substituted
            .iter()
            .any(|existing: &String| existing.eq_ignore_ascii_case(&requested))
        {
            substituted.push(requested);
        }
    }

    let db = FontDb::global();
    let all_chars = collect_non_ascii_chars(raw);
    let mut uncovered = Vec::new();
    let mut uncovered_cjk = Vec::new();
    for ch in all_chars {
        if !any_loaded_face_covers(db, ch) && db.fallback_for(ch, 0).is_none() {
            uncovered.push(ch);
            if is_cjk_char(ch) {
                uncovered_cjk.push(ch);
            }
        }
    }

    let missing_glyph_families =
        select_cjk_fallback_families(&uncovered_cjk, |fam| db.is_loaded(fam))
            .into_iter()
            .map(str::to_string)
            .collect();

    ExportFontNeeds {
        substituted_families: substituted,
        missing_glyph_families,
        uncovered_char_count: uncovered.len(),
        font_generation: db.generation(),
    }
}

fn any_loaded_face_covers(db: &FontDb, ch: char) -> bool {
    for fam in KNOWN_SITE_FONT_FAMILIES
        .into_iter()
        .chain(["Noto Serif KR"])
    {
        if db.is_loaded(fam) && db.face(fam, "Regular").covers(ch) {
            return true;
        }
    }
    false
}

fn collect_non_ascii_chars(doc: &Document) -> BTreeSet<char> {
    let mut out = BTreeSet::new();
    for blocks in std::iter::once(&doc.body).chain(doc.parts.values().map(|p| &p.blocks)) {
        collect_chars_in_blocks(blocks, 0, &mut out);
    }
    out
}

fn collect_chars_in_blocks(blocks: &[Arc<Block>], depth: usize, out: &mut BTreeSet<char>) {
    if depth > MAX_NESTING_DEPTH {
        return;
    }
    for blk in blocks {
        match blk.as_ref() {
            Block::Para(p) => {
                for ch in p.text.chars() {
                    if ch != OBJ && !ch.is_ascii() && !ch.is_control() {
                        out.insert(ch);
                    }
                }
                for obj in &p.objects {
                    match obj {
                        InlineObject::Field { result, .. } => {
                            for ch in result.chars() {
                                if !ch.is_ascii() && !ch.is_control() {
                                    out.insert(ch);
                                }
                            }
                        }
                        InlineObject::Equation { linear, .. } => {
                            for ch in linear.chars() {
                                if !ch.is_ascii() && !ch.is_control() {
                                    out.insert(ch);
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Block::Table(t) => {
                for row in &t.rows {
                    for cell in &row.cells {
                        collect_chars_in_blocks(&cell.blocks, depth + 1, out);
                    }
                }
            }
        }
    }
}

fn compile_request(
    req: &PageExportRequest,
    assets: &BTreeMap<String, Vec<u8>>,
) -> Result<WordDoc, Error> {
    let ExportNode::Element { name, children, .. } = &req.root else {
        return Err(Error::Invalid(
            "export root must be a <page> element".into(),
        ));
    };
    if name != "page" {
        return Err(Error::Invalid(format!(
            "expected <page> root element, found <{name}>"
        )));
    }

    let mut doc = wordcraft_engine::blank_document(&wordcraft_geom::Region::default());
    let clean_title = sanitize_control_chars(req.title.trim());
    doc.core.title.clone_from(&clean_title);

    configure_styles_and_section(&mut doc, &clean_title);

    let mut compiler = PageCompiler {
        req,
        raw_assets: assets,
        doc,
        media_key_map: BTreeMap::new(),
        next_num_id: 1,
    };

    let mut body_blocks: Vec<Arc<Block>> = Vec::new();
    let root_ctx = LayoutContext::root();

    if let Some(title_para) = compiler.build_title_paragraph(&clean_title) {
        body_blocks.push(para_block(title_para));
    }

    if !req.metadata_rows.is_empty()
        && let Some(meta_tbl) = compiler.build_metadata_table(&req.metadata_rows, root_ctx)
    {
        body_blocks.push(Arc::new(Block::Table(meta_tbl)));
    }

    compiler.compile_block_list(children, root_ctx, 0, &mut body_blocks);

    if body_blocks.is_empty()
        || matches!(body_blocks.last().map(Arc::as_ref), Some(Block::Table(_)))
    {
        body_blocks.push(para_block(compact_empty_para()));
    }
    compiler.doc.body = body_blocks;
    compiler.doc.ensure_nonempty();

    Ok(WordDoc::from_parts(
        compiler.doc,
        false,
        Arc::new(Vec::new()),
    ))
}

impl PageCompiler<'_> {
    pub(super) fn register_media(
        &mut self,
        asset_key: &str,
    ) -> Option<(String, Option<(u32, u32)>)> {
        let raw_bytes = self.raw_assets.get(asset_key)?;
        if raw_bytes.is_empty() {
            return None;
        }
        let dims = blocks::image_pixel_dimensions(raw_bytes);
        if let Some(existing_name) = self.media_key_map.get(asset_key) {
            return Some((existing_name.clone(), dims));
        }

        let ext = blocks::guess_media_ext(raw_bytes, asset_key);
        let idx = self.media_key_map.len().saturating_add(1);
        let media_name = format!("export_asset_{idx}.{ext}");
        self.doc
            .media
            .insert(media_name.clone(), Arc::new(raw_bytes.clone()));
        self.media_key_map
            .insert(asset_key.to_string(), media_name.clone());
        Some((media_name, dims))
    }

    pub(super) fn compile_block_list(
        &mut self,
        nodes: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
        out: &mut Vec<Arc<Block>>,
    ) {
        if depth > MAX_NESTING_DEPTH {
            return;
        }
        for node in nodes {
            self.compile_block_node(node, ctx, depth, out);
        }
    }

    pub(super) fn compile_block_node(
        &mut self,
        node: &ExportNode,
        ctx: LayoutContext,
        depth: usize,
        out: &mut Vec<Arc<Block>>,
    ) {
        if depth > MAX_NESTING_DEPTH {
            return;
        }
        match node {
            ExportNode::Element {
                name,
                attrs,
                children,
            } => {
                if let Some(lvl) = heading_level(name) {
                    let para = self.compile_paragraph(Some(lvl), attrs, children, ctx, depth);
                    out.push(para_block(para));
                    return;
                }
                match name.as_str() {
                    "p" => {
                        let para = self.compile_paragraph(None, attrs, children, ctx, depth);
                        out.push(para_block(para));
                    }
                    "block" => {
                        if let Some((first, rest)) = children.split_first() {
                            self.compile_block_node(first, ctx, depth + 1, out);
                            if !rest.is_empty() {
                                let child_ctx = ctx.indented_levels(1);
                                self.compile_block_list(rest, child_ctx, depth + 1, out);
                            }
                        }
                    }
                    "blockquote" => {
                        self.compile_blockquote(children, ctx, depth, out);
                    }
                    "callout" => {
                        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH {
                            let tbl = self.compile_callout(attrs, children, ctx, depth);
                            out.push(Arc::new(Block::Table(tbl)));
                        } else {
                            self.compile_block_list(
                                children,
                                ctx.indented_levels(1),
                                depth + 1,
                                out,
                            );
                        }
                    }
                    "columns" => {
                        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH {
                            if let Some(tbl) = self.compile_columns(children, ctx, depth) {
                                out.push(Arc::new(Block::Table(tbl)));
                            }
                        } else {
                            for col in children {
                                if let ExportNode::Element {
                                    name: col_name,
                                    children: col_children,
                                    ..
                                } = col
                                    && col_name == "column"
                                {
                                    self.compile_block_list(col_children, ctx, depth + 1, out);
                                }
                            }
                        }
                    }
                    "ul" => {
                        self.compile_list(false, None, children, ctx, depth, out);
                    }
                    "ol" => {
                        let start = attrs
                            .get("start")
                            .and_then(|s| s.parse::<u32>().ok())
                            .unwrap_or(1);
                        self.compile_list(true, Some(start), children, ctx, depth, out);
                    }
                    "pre" => {
                        self.compile_code_block(
                            attrs.get("lang").map(String::as_str),
                            attrs.get("meta").map(String::as_str),
                            children,
                            ctx,
                            out,
                        );
                    }
                    "mermaid" | "infographic" => {
                        self.compile_diagram_block(name, attrs, children, ctx, out);
                    }
                    "math" => {
                        self.compile_math_block(attrs, children, ctx, out);
                    }
                    "hr" => {
                        out.push(para_block(build_hr_paragraph(ctx)));
                    }
                    "table" => {
                        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH
                            && let Some(tbl) = self.compile_table(attrs, children, ctx, depth)
                        {
                            out.push(Arc::new(Block::Table(tbl)));
                        }
                    }
                    "media" => {
                        self.compile_media_block(attrs, ctx, out);
                    }
                    "embed" => {
                        self.compile_embed_block(attrs, ctx, out);
                    }
                    "comment" => {
                        self.compile_block_list(children, ctx, depth + 1, out);
                    }
                    _ => {
                        if children.iter().any(is_likely_block_node) {
                            self.compile_block_list(children, ctx, depth + 1, out);
                        } else if !children.is_empty() {
                            let para = self.compile_paragraph(None, attrs, children, ctx, depth);
                            out.push(para_block(para));
                        }
                    }
                }
            }
            ExportNode::Text { value } => {
                if !value.trim().is_empty() {
                    let mut p = Paragraph::new();
                    apply_context_para_indent(&mut p.props, ctx);
                    let chr = default_body_char_props(ctx.font_scale);
                    append_styled_text(&mut p, &sanitize_control_chars(value), &chr);
                    out.push(para_block(p));
                }
            }
            ExportNode::EmojiImage { asset_key, alt } => {
                let mut p = Paragraph::new();
                apply_context_para_indent(&mut p.props, ctx);
                let chr = default_body_char_props(ctx.font_scale);
                self.append_emoji_image(&mut p, asset_key, alt, 11.0 * ctx.font_scale, &chr);
                out.push(para_block(p));
            }
            ExportNode::CodeLine { runs } => {
                let p = blocks::build_code_line_para(runs, ctx.font_scale, false);
                out.push(para_block(p));
            }
        }
    }

    pub(super) fn compile_paragraph(
        &mut self,
        heading_lvl: Option<u8>,
        attrs: &BTreeMap<String, String>,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
    ) -> Paragraph {
        let mut para = Paragraph::new();
        let attr_indent = attrs
            .get("indent")
            .and_then(|v| v.parse::<u32>().ok())
            .unwrap_or(0);
        let effective_ctx = ctx.indented_levels(attr_indent);

        let (base_size_pt, mut base_chr) = if let Some(lvl) = heading_lvl {
            let clamped = lvl.clamp(1, 6);
            para.props.style = Some(format!("Heading{clamped}"));
            para.props.outline_level = Some(clamped - 1);
            para.props.keep_next = Some(true);
            para.props.keep_lines = Some(true);
            let raw_size = match clamped {
                1 => 17.0,
                2 => 14.0,
                3 => 12.0,
                4 | 5 => 10.5,
                _ => 10.0,
            };
            let scaled = (raw_size * ctx.font_scale).max(8.0);
            let chr = CharProps {
                font: Some(HEADING_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some(scaled),
                bold: Some(true),
                color: Some(if clamped == 6 {
                    TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))
                } else {
                    TextColor::Rgb(Rgb(0x11, 0x18, 0x27))
                }),
                ..CharProps::default()
            };
            (scaled, chr)
        } else {
            let scaled = (10.5 * ctx.font_scale).max(7.5);
            let chr = default_body_char_props(ctx.font_scale);
            (scaled, chr)
        };

        apply_context_para_indent(&mut para.props, effective_ctx);
        if let Some(align) = attrs.get("align").and_then(|a| parse_align(a)) {
            para.props.align = Some(align);
        }

        let mut transform = TextTransform::None;
        if let Some(style_str) = attrs.get("style") {
            let parsed = parse_inline_css_style(style_str);
            if let Some(fg) = parsed.fg {
                base_chr.color = Some(TextColor::Rgb(fg));
            }
            if let Some(bg) = parsed.bg {
                para.props.shading = Some(bg);
            }
            if parsed.transform != TextTransform::None {
                transform = parsed.transform;
            }
        }

        para.mark = base_chr.clone();
        let state = InlineState {
            chr: base_chr,
            transform,
            effective_size_pt: base_size_pt,
        };
        self.compile_inline_list(&mut para, children, &state, effective_ctx, depth + 1);
        para
    }
}
