//! Direct conversion from WordCraft's [`Document`] to Ankole's `page_document` XML and assets.

use std::collections::{BTreeMap, HashMap};
use std::io::Cursor;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use wordcraft_doc::numbering::Counters;
use wordcraft_doc::para::{COLUMN_BREAK, InlineObject, OBJ, PAGE_BREAK};
use wordcraft_doc::props::{
    Align, CharProps, Highlight, Rgb, TextColor, Underline, VMerge, VertAlign,
};
use wordcraft_doc::section::NumFormat;
use wordcraft_doc::{Block, Cell, Document, Paragraph, PartKind, Table};
use wordcraft_engine::Session;

use crate::{Error, WordDoc};

/// Maximum UTF-16 code units allowed by `page_document` (`8 MiB` UTF-16).
const MAX_PAGE_UTF16_UNITS: usize = 8 * 1024 * 1024;
/// Maximum XML element count allowed by `page_document`.
const MAX_PAGE_ELEMENTS: usize = 100_000;
/// Maximum XML nesting depth allowed by `page_document`.
const MAX_PAGE_DEPTH: usize = 128;

/// Extracted binary image asset referenced by `ankole:asset/<sha256>/<filename>` in converted XML.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConvertedAsset {
    /// Lowercase hexadecimal SHA-256 digest of `bytes`.
    pub sha256: String,
    /// Sanitized file name safe for asset URLs.
    pub filename: String,
    /// Detected MIME type (such as `image/png` or `image/jpeg`).
    pub mime: String,
    /// Raw asset bytes.
    pub bytes: Vec<u8>,
}

/// Counts of Word features omitted or downgraded during conversion to a document Page.
///
/// Keys with a zero count are omitted so callers only report features encountered in the file.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConversionReport {
    /// Features omitted because native document Pages have no equivalent representation.
    pub omitted: BTreeMap<String, usize>,
    /// Features preserved in a simpler representation (such as inline equations in `<code>`).
    pub downgraded: BTreeMap<String, usize>,
}

impl ConversionReport {
    fn add_omitted(&mut self, key: &str, count: usize) {
        if count > 0 {
            *self.omitted.entry(key.to_string()).or_insert(0) += count;
        }
    }

    fn add_downgraded(&mut self, key: &str, count: usize) {
        if count > 0 {
            *self.downgraded.entry(key.to_string()).or_insert(0) += count;
        }
    }
}

/// Result of converting a [`WordDoc`] into a native Ankole document Page.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConvertedDocument {
    /// Canonical `<page>...</page>` XML conforming to `app/kernel/src/page_document/`.
    pub xml: String,
    /// Deduplicated media assets extracted from `Document::media`.
    pub assets: Vec<ConvertedAsset>,
    /// Summary counts of omitted and downgraded features.
    pub report: ConversionReport,
}

struct Converter<'a> {
    doc: &'a Document,
    assets: Vec<ConvertedAsset>,
    asset_by_sha256: HashMap<String, usize>,
    report: ConversionReport,
    notes: Vec<(usize, u32)>,
    graphic_objects_seen: usize,
    element_count: usize,
    max_depth_seen: usize,
}

#[derive(Clone, Debug)]
struct RawListItem {
    num: u32,
    level: u8,
    ordered: bool,
    start: u32,
    p_xml: String,
}

#[derive(Clone, Debug)]
struct ListGroup {
    ordered: bool,
    start: u32,
    items: Vec<ListItemNode>,
}

#[derive(Clone, Debug)]
struct ListItemNode {
    p_xml: String,
    sublists: Vec<ListGroup>,
}

/// Converts `doc` into canonical `page_document` XML, deduplicated image assets, and a
/// [`ConversionReport`].
///
/// # Errors
///
/// Returns [`Error::Invalid`] prefixed with `document_too_large` if the converted XML exceeds
/// `page_document` limits (`8 MiB` UTF-16, `100,000` elements, or `128` depth).
pub fn to_document(doc: &WordDoc) -> Result<ConvertedDocument, Error> {
    let accepted = accept_all_revisions(doc.document());
    let mut conv = Converter {
        doc: &accepted,
        assets: Vec::new(),
        asset_by_sha256: HashMap::new(),
        report: ConversionReport::default(),
        notes: Vec::new(),
        graphic_objects_seen: 0,
        element_count: 1, // `<page>`
        max_depth_seen: 1,
    };

    // Count omitted document-level containers (`headers_footers` and `comments`).
    let hf_count = accepted
        .parts
        .values()
        .filter(|p| matches!(p.kind, PartKind::Header | PartKind::Footer))
        .count();
    conv.report.add_omitted("headers_footers", hf_count);
    conv.report.add_omitted("comments", accepted.comments.len());

    let mut inner_xml = conv.convert_blocks(&accepted.body, 2, true, &mut Counters::default())?;

    if !conv.notes.is_empty() {
        let collected = std::mem::take(&mut conv.notes);
        conv.note_element(2)?; // `<hr />`
        inner_xml.push_str("<hr />");

        conv.note_element(2)?; // `<ol>`
        inner_xml.push_str("<ol>");
        for (_num, part_id) in collected {
            conv.note_element(3)?; // `<li>`
            inner_xml.push_str("<li>");
            let note_xml = if let Some(part) = accepted.parts.get(&part_id) {
                conv.convert_blocks(&part.blocks, 4, false, &mut Counters::default())?
            } else {
                String::new()
            };
            if note_xml.is_empty() {
                conv.note_element(4)?;
                inner_xml.push_str("<p></p>");
            } else {
                inner_xml.push_str(&note_xml);
            }
            inner_xml.push_str("</li>");
        }
        inner_xml.push_str("</ol>");
    }

    if conv.graphic_objects_seen == 0 {
        let passthrough_charts = accepted
            .passthrough
            .keys()
            .filter(|k| {
                (k.starts_with("word/charts/chart") || k.starts_with("word/diagrams/data"))
                    && k.ends_with(".xml")
            })
            .count();
        conv.report
            .add_omitted("charts_smartart", passthrough_charts);
    }

    if inner_xml.is_empty() {
        conv.note_element(2)?;
        inner_xml.push_str("<p></p>");
    }

    let mut xml = String::with_capacity(inner_xml.len().saturating_add(13));
    xml.push_str("<page>");
    xml.push_str(&inner_xml);
    xml.push_str("</page>");

    let utf16_len = xml.encode_utf16().count();
    if utf16_len > MAX_PAGE_UTF16_UNITS {
        return Err(Error::Invalid(format!(
            "document_too_large: UTF-16 length {utf16_len} exceeds limit {MAX_PAGE_UTF16_UNITS}"
        )));
    }

    Ok(ConvertedDocument {
        xml,
        assets: conv.assets,
        report: conv.report,
    })
}

fn accept_all_revisions(raw: &Document) -> Document {
    let mut cloned = raw.clone();
    if !cloned.revisions.is_empty() || has_any_revision_marks(&cloned) {
        let mut session = Session::new(cloned);
        let _ = session.run("review.acceptAll", &json!({ "stopTracking": true }));
        session.doc.ensure_nonempty();
        cloned = session.doc;
    }
    cloned
}

fn has_any_revision_marks(doc: &Document) -> bool {
    let check_blocks =
        |blocks: &[Arc<Block>]| -> bool { blocks.iter().any(|b| block_has_revision(b)) };
    check_blocks(&doc.body) || doc.parts.values().any(|p| check_blocks(&p.blocks))
}

fn block_has_revision(block: &Block) -> bool {
    match block {
        Block::Para(p) => {
            p.mark.ins.is_some()
                || p.mark.del.is_some()
                || p.mark.fmt_change.is_some()
                || p.props.fmt_change.is_some()
                || p.props.num_change.is_some()
                || p.runs.iter().any(|r| {
                    r.props.ins.is_some() || r.props.del.is_some() || r.props.fmt_change.is_some()
                })
        }
        Block::Table(t) => t.rows.iter().any(|row| {
            row.cells
                .iter()
                .any(|cell| cell.blocks.iter().any(|b| block_has_revision(b)))
        }),
    }
}

impl Converter<'_> {
    fn note_element(&mut self, depth: usize) -> Result<(), Error> {
        self.element_count = self.element_count.saturating_add(1);
        if self.element_count > MAX_PAGE_ELEMENTS {
            return Err(Error::Invalid(format!(
                "document_too_large: element count {} exceeds limit {MAX_PAGE_ELEMENTS}",
                self.element_count
            )));
        }
        if depth > self.max_depth_seen {
            self.max_depth_seen = depth;
        }
        if depth > MAX_PAGE_DEPTH {
            return Err(Error::Invalid(format!(
                "document_too_large: element depth {depth} exceeds limit {MAX_PAGE_DEPTH}"
            )));
        }
        Ok(())
    }

    fn convert_blocks(
        &mut self,
        blocks: &[Arc<Block>],
        depth: usize,
        allow_notes: bool,
        counters: &mut Counters,
    ) -> Result<String, Error> {
        let mut out = String::new();
        let mut pending_list: Vec<RawListItem> = Vec::new();

        for blk in blocks {
            match blk.as_ref() {
                Block::Para(para) => {
                    let resolved = self.doc.styles.resolve_para(&para.props);
                    if resolved.page_break_before {
                        self.report.add_omitted("page_breaks", 1);
                    }
                    if para.section.is_some() {
                        self.report.add_omitted("section_breaks", 1);
                    }

                    let list_item = resolved.numbering.map(|num_ref| {
                        let level = num_ref.level.min(8);
                        let (ordered, start) = self.advance_list(counters, num_ref.num, level);
                        (num_ref.num, level, ordered, start)
                    });
                    // Headings display as headings but still advance their Word numbering.
                    if resolved.outline_level.is_none()
                        && let Some((num, level, ordered, start)) = list_item
                    {
                        let inline = self.convert_para_inline(
                            para,
                            false,
                            depth.saturating_add(3),
                            allow_notes,
                        )?;
                        let mut p_xml = String::new();
                        p_xml.push_str("<p");
                        append_align_attr(&mut p_xml, resolved.align);
                        p_xml.push('>');
                        p_xml.push_str(&inline);
                        p_xml.push_str("</p>");
                        pending_list.push(RawListItem {
                            num,
                            level,
                            ordered,
                            start,
                            p_xml,
                        });
                        continue;
                    }

                    if !pending_list.is_empty() {
                        let list_items = std::mem::take(&mut pending_list);
                        self.emit_list_run(&mut out, &list_items, depth)?;
                    }

                    let block_xml =
                        self.convert_single_para(para, &resolved, depth, allow_notes)?;
                    out.push_str(&block_xml);
                }
                Block::Table(table) => {
                    if !pending_list.is_empty() {
                        let list_items = std::mem::take(&mut pending_list);
                        self.emit_list_run(&mut out, &list_items, depth)?;
                    }
                    let table_xml = self.convert_table(table, depth, allow_notes, counters)?;
                    out.push_str(&table_xml);
                }
            }
        }

        if !pending_list.is_empty() {
            self.emit_list_run(&mut out, &pending_list, depth)?;
        }

        Ok(out)
    }

    fn advance_list(&self, counters: &mut Counters, num: u32, level: u8) -> (bool, u32) {
        let numbering = &self.doc.numbering;
        let Some((_, definition)) = counters.next_label(numbering, num, level) else {
            return (true, 1);
        };
        let start = counters
            .values(numbering, num)
            .and_then(|values| values.get(usize::from(level)).copied())
            .unwrap_or(definition.start);
        (definition.format != NumFormat::Bullet, start)
    }

    fn emit_list_run(
        &mut self,
        out: &mut String,
        items: &[RawListItem],
        depth: usize,
    ) -> Result<(), Error> {
        let groups = build_list_groups(items);
        for group in &groups {
            self.write_list_group(out, group, depth)?;
        }
        Ok(())
    }

    fn write_list_group(
        &mut self,
        out: &mut String,
        group: &ListGroup,
        depth: usize,
    ) -> Result<(), Error> {
        self.note_element(depth)?;
        if group.ordered {
            out.push_str("<ol");
            let clamped = group.start.min(999_999_999);
            if clamped != 1 {
                out.push_str(&format!(" start=\"{clamped}\""));
            }
            out.push('>');
        } else {
            out.push_str("<ul>");
        }

        for item in &group.items {
            self.note_element(depth.saturating_add(1))?; // `<li>`
            self.note_element(depth.saturating_add(2))?; // `<p>`
            out.push_str("<li>");
            out.push_str(&item.p_xml);
            for sub in &item.sublists {
                self.write_list_group(out, sub, depth.saturating_add(2))?;
            }
            out.push_str("</li>");
        }

        if group.ordered {
            out.push_str("</ol>");
        } else {
            out.push_str("</ul>");
        }
        Ok(())
    }

    fn convert_single_para(
        &mut self,
        para: &Paragraph,
        resolved: &wordcraft_doc::resolve::ResolvedPara,
        depth: usize,
        allow_notes: bool,
    ) -> Result<String, Error> {
        // Standalone block checks apply only to ordinary body/cell paragraphs (not headings).
        if resolved.outline_level.is_none() {
            match classify_standalone_object(para, self.doc) {
                Some(StandaloneKind::Picture {
                    media,
                    w,
                    h,
                    alt,
                    page_breaks,
                }) => {
                    self.report.add_omitted("page_breaks", page_breaks);
                    let asset = self.intern_media(&media, w, h);
                    if let Some(asset_idx) = asset
                        && let Some(entry) = self.assets.get(asset_idx)
                    {
                        let src = format!("ankole:asset/{}/{}", entry.sha256, entry.filename);
                        let mime = entry.mime.clone();
                        let size = entry.bytes.len();
                        self.note_element(depth)?;
                        let mut xml = String::new();
                        xml.push_str("<media src=\"");
                        push_escaped_attr(&mut xml, &src);
                        xml.push_str("\" kind=\"image\" view=\"preview\" mime=\"");
                        push_escaped_attr(&mut xml, &mime);
                        xml.push_str(&format!("\" size=\"{size}\""));
                        if !alt.trim().is_empty() {
                            xml.push_str(" title=\"");
                            push_escaped_attr(&mut xml, alt.trim());
                            xml.push('"');
                        }
                        xml.push_str(" />");
                        return Ok(xml);
                    }
                }
                Some(StandaloneKind::Equation { latex, page_breaks }) => {
                    self.report.add_omitted("page_breaks", page_breaks);
                    self.note_element(depth)?;
                    let mut xml = String::new();
                    xml.push_str("<math>");
                    push_escaped_text(&mut xml, &latex);
                    xml.push_str("</math>");
                    return Ok(xml);
                }
                None => {}
            }
        }

        let is_heading = resolved.outline_level.is_some();
        let tag = match resolved.outline_level {
            Some(lvl) => match lvl.saturating_add(1).clamp(1, 6) {
                1 => "h1",
                2 => "h2",
                3 => "h3",
                4 => "h4",
                5 => "h5",
                _ => "h6",
            },
            None => "p",
        };

        self.note_element(depth)?;
        let inline =
            self.convert_para_inline(para, is_heading, depth.saturating_add(1), allow_notes)?;
        let mut xml = String::new();
        xml.push('<');
        xml.push_str(tag);
        append_align_attr(&mut xml, resolved.align);
        append_indent_attr(&mut xml, resolved.indent_left);
        xml.push('>');
        xml.push_str(&inline);
        xml.push_str("</");
        xml.push_str(tag);
        xml.push('>');
        Ok(xml)
    }

    fn convert_para_inline(
        &mut self,
        para: &Paragraph,
        is_heading: bool,
        depth: usize,
        allow_notes: bool,
    ) -> Result<String, Error> {
        let mut out = String::new();
        let mut obj_idx = 0usize;
        let para_style = if is_heading {
            None
        } else {
            para.props.style.as_deref()
        };

        for (range, run_props) in para.run_ranges() {
            let slice = para.text.get(range).unwrap_or("");
            let obj_count = slice.chars().filter(|c| *c == OBJ).count();
            if run_props.del.is_some() {
                obj_idx = obj_idx.saturating_add(obj_count);
                continue;
            }

            let resolved_char = self.doc.styles.resolve_char(para_style, run_props);
            if resolved_char.hidden {
                obj_idx = obj_idx.saturating_add(obj_count);
                continue;
            }

            let style_marks = compute_run_marks(run_props, &resolved_char);
            let mut text_buf = String::new();

            for ch in slice.chars() {
                match ch {
                    OBJ => {
                        self.flush_text_run(&mut out, &mut text_buf, &style_marks, depth)?;
                        if let Some(obj) = para.objects.get(obj_idx) {
                            self.emit_inline_object(
                                &mut out,
                                obj,
                                &style_marks,
                                depth,
                                allow_notes,
                            )?;
                        }
                        obj_idx = obj_idx.saturating_add(1);
                    }
                    PAGE_BREAK => {
                        self.report.add_omitted("page_breaks", 1);
                    }
                    COLUMN_BREAK => {}
                    '\n' => {
                        if style_marks.code {
                            text_buf.push(' ');
                        } else {
                            self.flush_text_run(&mut out, &mut text_buf, &style_marks, depth)?;
                            self.emit_line_break(&mut out, style_marks.href.as_deref(), depth)?;
                        }
                    }
                    c if is_xml_text_char(c) => {
                        text_buf.push(c);
                    }
                    _ => {}
                }
            }

            self.flush_text_run(&mut out, &mut text_buf, &style_marks, depth)?;
        }

        Ok(out)
    }

    fn flush_text_run(
        &mut self,
        out: &mut String,
        text_buf: &mut String,
        marks: &RunMarks,
        depth: usize,
    ) -> Result<(), Error> {
        if text_buf.is_empty() {
            return Ok(());
        }
        let chunk = std::mem::take(text_buf);

        let mut cur_depth = depth;
        if let Some(href) = &marks.href {
            self.note_element(cur_depth)?;
            cur_depth = cur_depth.saturating_add(1);
            out.push_str("<a href=\"");
            push_escaped_attr(out, href);
            out.push_str("\">");
        }

        if marks.code {
            self.note_element(cur_depth)?;
            out.push_str("<code>");
            push_escaped_text(out, &chunk);
            out.push_str("</code>");
            if marks.href.is_some() {
                out.push_str("</a>");
            }
            return Ok(());
        }

        if let Some(style_str) = &marks.text_style {
            self.note_element(cur_depth)?;
            cur_depth = cur_depth.saturating_add(1);
            out.push_str("<span style=\"");
            push_escaped_attr(out, style_str);
            out.push_str("\">");
        }

        let mut open_tags: Vec<&'static str> = Vec::new();
        for (active, tag) in [
            (marks.bold, "strong"),
            (marks.italic, "em"),
            (marks.underline, "u"),
            (marks.strike, "s"),
            (marks.highlight_mark, "mark"),
            (marks.sup, "sup"),
            (marks.sub, "sub"),
        ] {
            if active {
                self.note_element(cur_depth)?;
                cur_depth = cur_depth.saturating_add(1);
                out.push('<');
                out.push_str(tag);
                out.push('>');
                open_tags.push(tag);
            }
        }

        push_escaped_text(out, &chunk);

        for tag in open_tags.into_iter().rev() {
            out.push_str("</");
            out.push_str(tag);
            out.push('>');
        }
        if marks.text_style.is_some() {
            out.push_str("</span>");
        }
        if marks.href.is_some() {
            out.push_str("</a>");
        }
        Ok(())
    }

    fn emit_line_break(
        &mut self,
        out: &mut String,
        href: Option<&str>,
        depth: usize,
    ) -> Result<(), Error> {
        if let Some(url) = href {
            self.note_element(depth)?;
            self.note_element(depth.saturating_add(1))?;
            out.push_str("<a href=\"");
            push_escaped_attr(out, url);
            out.push_str("\"><br /></a>");
        } else {
            self.note_element(depth)?;
            out.push_str("<br />");
        }
        Ok(())
    }

    fn emit_inline_object(
        &mut self,
        out: &mut String,
        obj: &InlineObject,
        marks: &RunMarks,
        depth: usize,
        allow_notes: bool,
    ) -> Result<(), Error> {
        match obj {
            InlineObject::Image {
                media, w, h, alt, ..
            } => {
                if let Some(asset_idx) = self.intern_media(media, *w, *h)
                    && let Some(entry) = self.assets.get(asset_idx)
                {
                    let src = format!("ankole:asset/{}/{}", entry.sha256, entry.filename);
                    let mut cur_depth = depth;
                    if let Some(url) = &marks.href {
                        self.note_element(cur_depth)?;
                        cur_depth = cur_depth.saturating_add(1);
                        out.push_str("<a href=\"");
                        push_escaped_attr(out, url);
                        out.push_str("\">");
                    }
                    self.note_element(cur_depth)?;
                    out.push_str("<img src=\"");
                    push_escaped_attr(out, &src);
                    out.push('"');
                    if !alt.trim().is_empty() {
                        out.push_str(" alt=\"");
                        push_escaped_attr(out, alt.trim());
                        out.push('"');
                    }
                    out.push_str(" />");
                    if marks.href.is_some() {
                        out.push_str("</a>");
                    }
                }
            }
            InlineObject::Equation { linear, math, .. } => {
                let latex = equation_to_latex(linear, math);
                self.report.add_downgraded("inline_equations", 1);
                let clean: String = latex
                    .chars()
                    .map(|c| if c == '\n' || c == '\r' { ' ' } else { c })
                    .filter(|c| is_xml_text_char(*c))
                    .collect();
                if !clean.is_empty() {
                    let mut cur_depth = depth;
                    if let Some(url) = &marks.href {
                        self.note_element(cur_depth)?;
                        cur_depth = cur_depth.saturating_add(1);
                        out.push_str("<a href=\"");
                        push_escaped_attr(out, url);
                        out.push_str("\">");
                    }
                    self.note_element(cur_depth)?;
                    out.push_str("<code>");
                    push_escaped_text(out, &clean);
                    out.push_str("</code>");
                    if marks.href.is_some() {
                        out.push_str("</a>");
                    }
                }
            }
            InlineObject::NoteRef { id, custom, .. } => {
                if allow_notes {
                    let n = self.notes.len().saturating_add(1);
                    self.notes.push((n, *id));
                    let label = if custom.trim().is_empty() {
                        format!("[{n}]")
                    } else {
                        format!("[{}]", custom.trim())
                    };
                    let mut buf = label;
                    self.flush_text_run(out, &mut buf, marks, depth)?;
                }
            }
            InlineObject::Field { result, .. } => {
                let clean: String = result.chars().filter(|c| is_xml_text_char(*c)).collect();
                if !clean.is_empty() {
                    let mut buf = clean;
                    self.flush_text_run(out, &mut buf, marks, depth)?;
                }
            }
            InlineObject::Ruby { base, .. } => {
                let clean: String = base.chars().filter(|c| is_xml_text_char(*c)).collect();
                if !clean.is_empty() {
                    let mut buf = clean;
                    self.flush_text_run(out, &mut buf, marks, depth)?;
                }
            }
            InlineObject::Shape { .. } | InlineObject::Group { .. } => {
                self.report.add_omitted("floating_shapes", 1);
            }
            InlineObject::Graphic { .. } => {
                self.graphic_objects_seen = self.graphic_objects_seen.saturating_add(1);
                self.report.add_omitted("charts_smartart", 1);
            }
            _ => {}
        }
        Ok(())
    }

    fn convert_table(
        &mut self,
        table: &Table,
        depth: usize,
        allow_notes: bool,
        counters: &mut Counters,
    ) -> Result<String, Error> {
        self.note_element(depth)?; // `<table>`
        let mut out = String::new();
        out.push_str("<table");
        if !table.grid.is_empty() {
            let widths: Vec<String> = table
                .grid
                .iter()
                .map(|w_pt| {
                    let px = if w_pt.is_finite() {
                        ((*w_pt * 96.0 / 72.0).round() as i64).clamp(1, 9999)
                    } else {
                        100
                    };
                    px.to_string()
                })
                .collect();
            out.push_str(" widths=\"");
            out.push_str(&widths.join(","));
            out.push('"');
        }
        out.push('>');

        for (r_idx, row) in table.rows.iter().enumerate() {
            self.note_element(depth.saturating_add(1))?; // `<tr>`
            out.push_str("<tr>");
            let cell_tag = if row.props.header { "th" } else { "td" };

            let mut grid_col = row.first_grid();
            let mut emitted_any_cell = false;

            for cell in &row.cells {
                let span = cell.span().clamp(1, 9999);
                if r_idx > 0 && cell.props.vmerge == VMerge::Continue {
                    grid_col = grid_col.saturating_add(span);
                    continue;
                }

                let rowspan = compute_rowspan(table, r_idx, grid_col).clamp(1, 9999);
                self.note_element(depth.saturating_add(2))?; // `<th>` / `<td>`
                emitted_any_cell = true;

                out.push('<');
                out.push_str(cell_tag);
                if span > 1 {
                    out.push_str(&format!(" colspan=\"{span}\""));
                }
                if rowspan > 1 {
                    out.push_str(&format!(" rowspan=\"{rowspan}\""));
                }
                if let Some(bg) = cell.props.shading.or(table.props.shading) {
                    out.push_str(&format!(
                        " background=\"#{:02x}{:02x}{:02x}\"",
                        bg.0, bg.1, bg.2
                    ));
                }
                out.push('>');

                let cell_inner = self.convert_blocks(
                    &cell.blocks,
                    depth.saturating_add(3),
                    allow_notes,
                    counters,
                )?;
                if cell_inner.is_empty() {
                    self.note_element(depth.saturating_add(3))?;
                    out.push_str("<p></p>");
                } else {
                    out.push_str(&cell_inner);
                }

                out.push_str("</");
                out.push_str(cell_tag);
                out.push('>');

                grid_col = grid_col.saturating_add(span);
            }

            // If every cell in the row was a continuation cell, keep `<tr>` schema-valid only when
            // empty `<tr></tr>` is allowed (`TableRow` allows `Some(vec![])`), which `document_schema` permits.
            let _ = emitted_any_cell;
            out.push_str("</tr>");
        }

        out.push_str("</table>");
        Ok(out)
    }

    fn intern_media(
        &mut self,
        media_key: &str,
        display_w_pt: f32,
        display_h_pt: f32,
    ) -> Option<usize> {
        let bytes_arc = self.doc.media.get(media_key)?;
        let bytes = bytes_arc.as_slice();
        if has_custom_image_size(bytes, display_w_pt, display_h_pt) {
            self.report.add_downgraded("custom_image_sizes", 1);
        }

        let digest = Sha256::digest(bytes);
        let sha256 = hex::encode(digest);
        if let Some(&idx) = self.asset_by_sha256.get(&sha256) {
            return Some(idx);
        }

        let (mime, default_ext) = sniff_mime_and_ext(bytes, media_key);
        let filename = sanitize_asset_filename(media_key, default_ext);
        let idx = self.assets.len();
        self.assets.push(ConvertedAsset {
            sha256: sha256.clone(),
            filename,
            mime: mime.to_string(),
            bytes: bytes.to_vec(),
        });
        self.asset_by_sha256.insert(sha256, idx);
        Some(idx)
    }
}

fn compute_rowspan(table: &Table, start_row: usize, target_grid_col: usize) -> usize {
    let mut span = 1usize;
    let mut r = start_row.saturating_add(1);
    while let Some(row) = table.rows.get(r) {
        let Some(cell) = cell_starting_at_grid_col(row, target_grid_col) else {
            break;
        };
        if cell.props.vmerge == VMerge::Continue {
            span = span.saturating_add(1);
            r = r.saturating_add(1);
        } else {
            break;
        }
    }
    span
}

fn cell_starting_at_grid_col(row: &wordcraft_doc::Row, target_grid_col: usize) -> Option<&Cell> {
    let mut col = row.first_grid();
    for cell in &row.cells {
        if col == target_grid_col {
            return Some(cell);
        }
        col = col.saturating_add(cell.span());
        if col > target_grid_col {
            break;
        }
    }
    None
}

enum StandaloneKind {
    Picture {
        media: String,
        w: f32,
        h: f32,
        alt: String,
        page_breaks: usize,
    },
    Equation {
        latex: String,
        page_breaks: usize,
    },
}

fn classify_standalone_object(para: &Paragraph, doc: &Document) -> Option<StandaloneKind> {
    let mut obj_idx = 0usize;
    let mut found_obj: Option<&InlineObject> = None;
    let mut page_breaks = 0usize;

    for (range, run_props) in para.run_ranges() {
        let slice = para.text.get(range).unwrap_or("");
        let obj_count = slice.chars().filter(|c| *c == OBJ).count();
        if run_props.del.is_some() {
            obj_idx = obj_idx.saturating_add(obj_count);
            continue;
        }
        for ch in slice.chars() {
            if ch == OBJ {
                let obj = para.objects.get(obj_idx)?;
                obj_idx = obj_idx.saturating_add(1);
                match obj {
                    InlineObject::BookmarkStart { .. }
                    | InlineObject::BookmarkEnd { .. }
                    | InlineObject::CommentStart { .. }
                    | InlineObject::CommentEnd { .. }
                    | InlineObject::PermStart { .. }
                    | InlineObject::PermEnd { .. } => {}
                    InlineObject::Image { .. } | InlineObject::Equation { .. } => {
                        if found_obj.is_some() {
                            return None;
                        }
                        found_obj = Some(obj);
                    }
                    _ => return None,
                }
            } else if ch == PAGE_BREAK {
                page_breaks = page_breaks.saturating_add(1);
            } else if ch == COLUMN_BREAK || ch.is_whitespace() {
                // Ignore surrounding whitespace around a standalone picture or equation.
            } else {
                return None;
            }
        }
    }

    match found_obj? {
        InlineObject::Image {
            media, w, h, alt, ..
        } if doc.media.contains_key(media) => Some(StandaloneKind::Picture {
            media: media.clone(),
            w: *w,
            h: *h,
            alt: alt.clone(),
            page_breaks,
        }),
        InlineObject::Equation { linear, math, .. } => Some(StandaloneKind::Equation {
            latex: equation_to_latex(linear, math),
            page_breaks,
        }),
        _ => None,
    }
}

fn equation_to_latex(linear: &str, math: &wordcraft_doc::math::Math) -> String {
    if !math.nodes.is_empty() {
        let rendered = wordcraft_doc::math_latex::to_latex(&math.nodes);
        if !rendered.trim().is_empty() {
            return rendered;
        }
    }
    let parsed = wordcraft_doc::math::parse_linear(linear);
    if !parsed.is_empty() {
        let rendered = wordcraft_doc::math_latex::to_latex(&parsed);
        if !rendered.trim().is_empty() {
            return rendered;
        }
    }
    linear.to_string()
}

struct RunMarks {
    bold: bool,
    italic: bool,
    underline: bool,
    strike: bool,
    code: bool,
    sup: bool,
    sub: bool,
    highlight_mark: bool,
    text_style: Option<String>,
    href: Option<String>,
}

fn compute_run_marks(
    raw_props: &CharProps,
    resolved: &wordcraft_doc::resolve::ResolvedChar,
) -> RunMarks {
    let code = is_code_run(raw_props, resolved);
    let href = resolved.link.as_deref().and_then(sanitize_href);

    let fg_hex = match resolved.color {
        TextColor::Auto => None,
        TextColor::Rgb(Rgb(r, g, b)) => Some(format!("#{r:02x}{g:02x}{b:02x}")),
    };

    // Uncolored default highlight (`Highlight::Yellow` with no explicit shading) maps to `<mark>`,
    // whereas colored highlights and character shading map to `background-color: #RRGGBB`.
    let is_yellow_default_highlight = raw_props.highlight == Some(Highlight::Yellow)
        && resolved.shading.is_none()
        || (raw_props.highlight.is_none()
            && resolved.highlight == Some(Rgb(255, 255, 0))
            && resolved.shading.is_none());

    let bg_hex = if is_yellow_default_highlight {
        None
    } else {
        resolved
            .shading
            .or(resolved.highlight)
            .map(|Rgb(r, g, b)| format!("#{r:02x}{g:02x}{b:02x}"))
    };

    let text_style = match (fg_hex, bg_hex) {
        (Some(c), Some(bg)) => Some(format!("color: {c}; background-color: {bg}")),
        (Some(c), None) => Some(format!("color: {c}")),
        (None, Some(bg)) => Some(format!("background-color: {bg}")),
        (None, None) => None,
    };

    // Hyperlinks often inherit Word's `Hyperlink` style underline/blue; keep explicit or resolved marks cleanly.
    let underline = resolved.underline != Underline::None
        && !(href.is_some()
            && raw_props.underline.is_none()
            && raw_props.style.as_deref() == Some("Hyperlink"));

    RunMarks {
        bold: resolved.bold,
        italic: resolved.italic,
        underline,
        strike: resolved.strike || resolved.double_strike,
        code,
        sup: resolved.vert_align == VertAlign::Superscript,
        sub: resolved.vert_align == VertAlign::Subscript,
        highlight_mark: is_yellow_default_highlight,
        text_style,
        href,
    }
}

fn is_code_run(raw_props: &CharProps, resolved: &wordcraft_doc::resolve::ResolvedChar) -> bool {
    if let Some(style) = raw_props.style.as_deref() {
        let lower = style.to_ascii_lowercase();
        if lower == "code" || lower == "htmlcode" || lower == "macrotext" || lower == "verbatim" {
            return true;
        }
    }
    is_monospace_font(&resolved.font)
}

fn is_monospace_font(font: &str) -> bool {
    let lower = font.trim().to_ascii_lowercase();
    lower.contains("mono")
        || matches!(
            lower.as_str(),
            "consolas"
                | "courier"
                | "courier new"
                | "menlo"
                | "monaco"
                | "lucida console"
                | "inconsolata"
                | "fira code"
                | "source code pro"
        )
}

fn sanitize_href(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    let allowed = lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("mailto:")
        || trimmed.starts_with('/')
        || trimmed.starts_with('#');
    allowed.then(|| trimmed.to_string())
}

fn append_align_attr(out: &mut String, align: Align) {
    let value = match align {
        Align::Left => None,
        Align::Center => Some("center"),
        Align::Right => Some("right"),
        Align::Justify | Align::Distribute => Some("justify"),
    };
    if let Some(a) = value {
        out.push_str(" align=\"");
        out.push_str(a);
        out.push('"');
    }
}

fn append_indent_attr(out: &mut String, indent_left_pt: f32) {
    if !indent_left_pt.is_finite() || indent_left_pt <= 0.0 {
        return;
    }
    // Word's standard indent step is 36 pt (0.5 in).
    let level = (indent_left_pt / 36.0).round() as i64;
    if level >= 1 {
        let clamped = level.min(999);
        out.push_str(&format!(" indent=\"{clamped}\""));
    }
}

fn build_list_groups(items: &[RawListItem]) -> Vec<ListGroup> {
    let mut groups = Vec::new();
    let mut idx = 0usize;
    while let Some(first) = items.get(idx) {
        let base_level = first.level;
        let ordered = first.ordered;
        let start = first.start;
        let mut group_items = Vec::new();

        while let Some(cur) = items.get(idx) {
            if cur.level < base_level {
                break;
            }
            if cur.level == base_level {
                if cur.num != first.num || cur.ordered != ordered {
                    break;
                }
                let p_xml = cur.p_xml.clone();
                idx = idx.saturating_add(1);
                let sub_start = idx;
                while let Some(sub) = items.get(idx) {
                    if sub.level <= base_level {
                        break;
                    }
                    idx = idx.saturating_add(1);
                }
                let sublists = items
                    .get(sub_start..idx)
                    .map_or_else(Vec::new, build_list_groups);
                group_items.push(ListItemNode { p_xml, sublists });
            } else {
                // Unexpected jump past `base_level`: group remaining deeper items cleanly.
                let sub_start = idx;
                while let Some(sub) = items.get(idx) {
                    if sub.level <= base_level {
                        break;
                    }
                    idx = idx.saturating_add(1);
                }
                if let Some(last) = group_items.last_mut()
                    && let Some(slice) = items.get(sub_start..idx)
                {
                    last.sublists.extend(build_list_groups(slice));
                }
            }
        }

        if !group_items.is_empty() {
            groups.push(ListGroup {
                ordered,
                start,
                items: group_items,
            });
        }
    }
    groups
}

fn has_custom_image_size(bytes: &[u8], w_pt: f32, h_pt: f32) -> bool {
    if !w_pt.is_finite() || !h_pt.is_finite() || w_pt <= 0.0 || h_pt <= 0.0 {
        return false;
    }
    let Some((px_w, px_h)) = image::ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()
        .and_then(|r| r.into_dimensions().ok())
    else {
        return true;
    };
    let natural_w_pt = px_w as f32 * 72.0 / 96.0;
    let natural_h_pt = px_h as f32 * 72.0 / 96.0;
    (w_pt - natural_w_pt).abs() > 1.0 || (h_pt - natural_h_pt).abs() > 1.0
}

fn sniff_mime_and_ext(bytes: &[u8], key: &str) -> (&'static str, &'static str) {
    if let Ok(fmt) = image::guess_format(bytes) {
        match fmt {
            image::ImageFormat::Png => return ("image/png", "png"),
            image::ImageFormat::Jpeg => return ("image/jpeg", "jpg"),
            image::ImageFormat::WebP => return ("image/webp", "webp"),
            image::ImageFormat::Gif => return ("image/gif", "gif"),
            image::ImageFormat::Bmp => return ("image/bmp", "bmp"),
            _ => {}
        }
    }
    let lower = key.to_ascii_lowercase();
    if lower.ends_with(".svg") {
        ("image/svg+xml", "svg")
    } else if lower.ends_with(".png") {
        ("image/png", "png")
    } else if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        ("image/jpeg", "jpg")
    } else if lower.ends_with(".gif") {
        ("image/gif", "gif")
    } else if lower.ends_with(".webp") {
        ("image/webp", "webp")
    } else if lower.ends_with(".bmp") {
        ("image/bmp", "bmp")
    } else {
        ("application/octet-stream", "bin")
    }
}

fn sanitize_asset_filename(raw_key: &str, default_ext: &str) -> String {
    let base = raw_key.rsplit(['/', '\\']).next().unwrap_or(raw_key).trim();
    let mut cleaned: String = base
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(*c, '.' | '-' | '_'))
        .collect();
    while cleaned.contains("..") {
        cleaned = cleaned.replace("..", ".");
    }
    let cleaned = cleaned.trim_matches('.').to_string();
    if cleaned.is_empty() {
        format!("image.{default_ext}")
    } else if cleaned.contains('.') {
        cleaned
    } else {
        format!("{cleaned}.{default_ext}")
    }
}

fn is_xml_text_char(ch: char) -> bool {
    matches!(ch, '\t' | '\n' | '\r' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..='\u{10FFFF}')
}

fn push_escaped_text(out: &mut String, s: &str) {
    for ch in s.chars() {
        if !is_xml_text_char(ch) {
            continue;
        }
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            c => out.push(c),
        }
    }
}

fn push_escaped_attr(out: &mut String, s: &str) {
    for ch in s.chars() {
        if !is_xml_text_char(ch) {
            continue;
        }
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c => out.push(c),
        }
    }
}
