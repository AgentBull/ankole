//! Compiles boxed and media leaf blocks (`<blockquote>`, `<pre>`, `<mermaid>`, `<infographic>`,
//! `<math>`, `<media>`, `<embed>`, `<hr>`).

use std::collections::BTreeMap;
use std::io::Cursor;
use std::sync::Arc;

use image::ImageReader;
use wordcraft_doc::math::Math;
use wordcraft_doc::para::{Float, InlineObject};
use wordcraft_doc::props::{
    Align, Border, BorderStyle, Borders, CellProps, CharProps, LineSpacing, ParaProps, Rgb,
    RowProps, TableProps, TextColor, Underline,
};
use wordcraft_doc::{Block, Cell, Paragraph, Row, Table, para_block};

use super::inline::{
    append_inline_object, append_styled_text, apply_context_para_indent,
    collect_plain_text_from_nodes, default_body_char_props, sanitize_control_chars,
    sanitize_export_href, unwrap_math_delimiters,
};
use super::tables::{finalize_cell_blocks, plain_table_look};
use super::{
    BODY_FONT_EA, BODY_FONT_LATIN, CODE_BOX_MAX_KEEP_HEIGHT_PT, CODE_FONT_EA, CODE_FONT_LATIN,
    CodeSpan, ExportNode, HEADING_FONT_LATIN, LayoutContext, MAX_DISPLAY_IMAGE_HEIGHT_PT,
    MIN_CONTAINER_WIDTH_PT, PageCompiler,
};

struct BoxTableSpec {
    width_pt: f32,
    indent_pt: Option<f32>,
    borders: Borders,
    shading: Option<Rgb>,
    margins: [f32; 4],
    space_before: f32,
    space_after: f32,
    cant_split: bool,
}

fn single_cell_box_table(spec: BoxTableSpec, mut blocks: Vec<Arc<Block>>) -> Table {
    let hide_mark = finalize_cell_blocks(&mut blocks);
    Table {
        props: TableProps {
            width: Some(spec.width_pt),
            indent: spec.indent_pt,
            fixed: true,
            borders: Some(spec.borders),
            shading: spec.shading,
            cell_margins: Some(spec.margins),
            space_before: Some(spec.space_before),
            space_after: Some(spec.space_after),
            look: plain_table_look(),
            ..TableProps::default()
        },
        grid: vec![spec.width_pt],
        rows: vec![Row {
            props: RowProps {
                cant_split: spec.cant_split,
                ..RowProps::default()
            },
            cells: vec![Cell {
                props: CellProps {
                    width: Some(spec.width_pt),
                    span: 1,
                    shading: spec.shading,
                    hide_mark,
                    ..CellProps::default()
                },
                blocks,
                controls: Default::default(),
            }],
            controls: Default::default(),
        }],
        controls: Default::default(),
    }
}

impl PageCompiler<'_> {
    pub(super) fn compile_blockquote(
        &mut self,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
        out: &mut Vec<Arc<Block>>,
    ) {
        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH {
            let pad_left = 10.0;
            let pad_right = 4.0;
            let col_w = ctx.content_width_pt;
            let inner_ctx = ctx.enter_cell(col_w - pad_left - pad_right, 1.0);
            let mut inner_blocks = Vec::new();
            self.compile_block_list(children, inner_ctx, depth + 1, &mut inner_blocks);
            for blk in &mut inner_blocks {
                if let Block::Para(p) = Arc::make_mut(blk) {
                    for run in &mut p.runs {
                        if run.props.color.is_none()
                            || run.props.color == Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29)))
                        {
                            run.props.color = Some(TextColor::Rgb(Rgb(0x47, 0x55, 0x69)));
                        }
                    }
                }
            }
            let nil = Border {
                style: BorderStyle::None,
                width: 0.0,
                color: None,
                space: 0.0,
            };
            let left_bar = Border {
                style: BorderStyle::Single,
                width: 2.5,
                color: Some(Rgb(0xCB, 0xD5, 0xE1)),
                space: 0.0,
            };
            let tbl = single_cell_box_table(
                BoxTableSpec {
                    width_pt: col_w,
                    indent_pt: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                    borders: Borders {
                        left: Some(left_bar),
                        top: Some(nil),
                        bottom: Some(nil),
                        right: Some(nil),
                        between: Some(nil),
                        inside_v: Some(nil),
                    },
                    shading: None,
                    margins: [3.0, pad_left, 3.0, pad_right],
                    space_before: 4.0,
                    space_after: 6.0,
                    cant_split: false,
                },
                inner_blocks,
            );
            out.push(Arc::new(Block::Table(tbl)));
        } else {
            self.compile_block_list(children, ctx.indented_levels(1), depth + 1, out);
        }
    }

    pub(super) fn compile_code_block(
        &mut self,
        lang: Option<&str>,
        meta: Option<&str>,
        children: &[ExportNode],
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        let code_lines = extract_code_lines(children);
        let box_w = ctx.content_width_pt.max(MIN_CONTAINER_WIDTH_PT);
        let pad_h = 9.0;
        let pad_v = 7.0;
        let net_w = (box_w - 2.0 * pad_h).max(36.0);

        let font_size = (8.5 * ctx.font_scale).max(6.5);
        let approx_char_w = (font_size * 0.61).max(3.5);
        let cols_per_line = (net_w / approx_char_w).floor().max(12.0) as usize;

        let wrapped_visual_lines: usize = code_lines
            .iter()
            .map(|runs| {
                let cols: usize = runs
                    .iter()
                    .flat_map(|s| s.text.chars())
                    .map(|c| if c.is_ascii() { 1usize } else { 2usize })
                    .sum();
                if cols == 0 {
                    1
                } else {
                    cols.div_ceil(cols_per_line)
                }
            })
            .sum::<usize>()
            .max(1);

        let est_height_pt = (wrapped_visual_lines as f32) * (font_size * 1.45) + 2.0 * pad_v;
        let keep_together = est_height_pt <= CODE_BOX_MAX_KEEP_HEIGHT_PT;

        let mut cell_blocks: Vec<Arc<Block>> = Vec::with_capacity(code_lines.len() + 1);
        let header_label = match (
            lang.map(str::trim)
                .filter(|l| !l.is_empty() && !l.eq_ignore_ascii_case("plaintext")),
            meta.map(str::trim).filter(|m| !m.is_empty()),
        ) {
            (Some(l), Some(m)) => Some(format!("{l}  ·  {m}")),
            (Some(l), None) => Some(l.to_string()),
            (None, Some(m)) => Some(m.to_string()),
            (None, None) => None,
        };

        if let Some(label) = header_label {
            let mut hdr = Paragraph::new();
            hdr.props.space_before = Some(0.0);
            hdr.props.space_after = Some(4.0);
            hdr.props.line_spacing = Some(LineSpacing::Multiple(1.2));
            hdr.props.keep_next = Some(true);
            hdr.props.keep_lines = Some(true);
            let hdr_chr = CharProps {
                font: Some(HEADING_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some((7.5 * ctx.font_scale).max(6.5)),
                bold: Some(true),
                color: Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))),
                ..CharProps::default()
            };
            append_styled_text(&mut hdr, &sanitize_control_chars(&label), &hdr_chr);
            cell_blocks.push(para_block(hdr));
        }

        let total_lines = code_lines.len();
        for (idx, line_runs) in code_lines.iter().enumerate() {
            let is_last = idx + 1 == total_lines;
            let mut p = build_code_line_para(line_runs, ctx.font_scale, keep_together && !is_last);
            if keep_together {
                p.props.keep_lines = Some(true);
            }
            cell_blocks.push(para_block(p));
        }

        if cell_blocks.is_empty() {
            cell_blocks.push(para_block(build_code_line_para(&[], ctx.font_scale, false)));
        }

        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH {
            let border = Border {
                style: BorderStyle::Single,
                width: 0.5,
                color: Some(Rgb(0xE2, 0xE8, 0xF0)),
                space: 0.0,
            };
            let tbl = single_cell_box_table(
                BoxTableSpec {
                    width_pt: box_w,
                    indent_pt: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                    borders: Borders::box_(border),
                    shading: Some(Rgb(0xF6, 0xF8, 0xFA)),
                    margins: [pad_v, pad_h, pad_v, pad_h],
                    space_before: 6.0,
                    space_after: 8.0,
                    cant_split: keep_together,
                },
                cell_blocks,
            );
            out.push(Arc::new(Block::Table(tbl)));
        } else {
            out.extend(cell_blocks);
        }
    }

    pub(super) fn compile_diagram_block(
        &mut self,
        tag_name: &str,
        attrs: &BTreeMap<String, String>,
        children: &[ExportNode],
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        let view = attrs.get("view").map_or("both", String::as_str);
        let show_diagram = view == "diagram" || view == "both";
        let show_code = view == "code" || view == "both";

        let mut rendered_diagram = false;
        if show_diagram {
            if let Some(err_msg) = attrs.get("_export_error").filter(|s| !s.trim().is_empty()) {
                out.push(Arc::new(Block::Table(build_error_box_table(
                    &format!("{tag_name} error: {err_msg}"),
                    ctx,
                ))));
                rendered_diagram = true;
            } else if let Some(asset_key) = attrs.get("_export_asset")
                && let Some((media_name, dims)) = self.register_media(asset_key)
            {
                let req_w = attrs
                    .get("_export_w_pt")
                    .and_then(|s| s.parse::<f32>().ok())
                    .filter(|v| v.is_finite() && *v > 0.0);
                let req_h = attrs
                    .get("_export_h_pt")
                    .and_then(|s| s.parse::<f32>().ok())
                    .filter(|v| v.is_finite() && *v > 0.0);

                let (w_pt, h_pt) = fit_display_box(
                    req_w,
                    req_h,
                    dims,
                    ctx.content_width_pt,
                    MAX_DISPLAY_IMAGE_HEIGHT_PT,
                );
                let mut img_para = Paragraph::new();
                apply_context_para_indent(&mut img_para.props, ctx);
                img_para.props.align = Some(Align::Center);
                img_para.props.space_before = Some(6.0);
                img_para.props.space_after = Some(8.0);
                img_para.props.keep_lines = Some(true);
                if show_code {
                    img_para.props.keep_next = Some(true);
                }
                let chr = default_body_char_props(ctx.font_scale);
                append_inline_object(
                    &mut img_para,
                    InlineObject::Image {
                        media: media_name,
                        w: w_pt,
                        h: h_pt,
                        alt: format!("{tag_name} diagram"),
                        float: Float::default(),
                        crop: [0.0; 4],
                        fx: Default::default(),
                        ole: None,
                    },
                    &chr,
                );
                out.push(para_block(img_para));
                rendered_diagram = true;
            }
        }

        if show_code || (show_diagram && !rendered_diagram) {
            self.compile_code_block(Some(tag_name), None, children, ctx, out);
        }
    }

    pub(super) fn compile_math_block(
        &mut self,
        attrs: &BTreeMap<String, String>,
        children: &[ExportNode],
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        let raw_latex = collect_plain_text_from_nodes(children);
        let trimmed = unwrap_math_delimiters(&raw_latex).trim();
        if trimmed.is_empty() {
            return;
        }

        if attrs.get("_export_invalid").map(String::as_str) == Some("true")
            && ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH
        {
            out.push(Arc::new(Block::Table(build_error_box_table(trimmed, ctx))));
            return;
        }

        let nodes = wordcraft_doc::math_latex::parse_latex(trimmed);
        let mut para = Paragraph::new();
        apply_context_para_indent(&mut para.props, ctx);
        para.props.align = Some(Align::Center);
        para.props.space_before = Some(6.0);
        para.props.space_after = Some(8.0);
        para.props.keep_lines = Some(true);
        let chr = default_body_char_props(ctx.font_scale);

        if nodes.is_empty() {
            let mono = CharProps {
                font: Some(CODE_FONT_LATIN.into()),
                font_ea: Some(CODE_FONT_EA.into()),
                size: Some((9.5 * ctx.font_scale).max(7.5)),
                ..chr
            };
            append_styled_text(&mut para, &sanitize_control_chars(trimmed), &mono);
        } else {
            let linear = wordcraft_doc::math::to_linear(&nodes);
            append_inline_object(
                &mut para,
                InlineObject::Equation {
                    linear: if linear.is_empty() {
                        sanitize_control_chars(trimmed)
                    } else {
                        linear
                    },
                    display: true,
                    math: Math {
                        nodes,
                        ..Math::default()
                    },
                },
                &chr,
            );
        }
        out.push(para_block(para));
    }

    pub(super) fn compile_media_block(
        &mut self,
        attrs: &BTreeMap<String, String>,
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        let kind = attrs.get("kind").map_or("image", String::as_str);
        let view = attrs.get("view").map_or("preview", String::as_str);
        let title = attrs
            .get("title")
            .map(|s| sanitize_control_chars(s.trim()))
            .filter(|s| !s.is_empty());
        let desc = attrs
            .get("description")
            .map(|s| sanitize_control_chars(s.trim()))
            .filter(|s| !s.is_empty());

        if kind == "image"
            && (view == "preview" || view.is_empty())
            && let Some(asset_key) = attrs.get("_export_asset")
            && let Some((media_name, dims)) = self.register_media(asset_key)
        {
            let (w_pt, h_pt) = fit_display_box(
                None,
                None,
                dims,
                ctx.content_width_pt,
                MAX_DISPLAY_IMAGE_HEIGHT_PT,
            );
            let has_caption = title.is_some() || desc.is_some();

            let mut img_para = Paragraph::new();
            apply_context_para_indent(&mut img_para.props, ctx);
            img_para.props.align = Some(Align::Center);
            img_para.props.space_before = Some(6.0);
            img_para.props.space_after = Some(if has_caption { 3.0 } else { 8.0 });
            img_para.props.keep_lines = Some(true);
            if has_caption {
                img_para.props.keep_next = Some(true);
            }

            let chr = default_body_char_props(ctx.font_scale);
            append_inline_object(
                &mut img_para,
                InlineObject::Image {
                    media: media_name,
                    w: w_pt,
                    h: h_pt,
                    alt: title.clone().unwrap_or_default(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &chr,
            );
            out.push(para_block(img_para));

            if has_caption {
                let caption_text = match (title, desc) {
                    (Some(t), Some(d)) if t != d => format!("{t} — {d}"),
                    (Some(t), _) => t,
                    (None, Some(d)) => d,
                    (None, None) => String::new(),
                };
                if !caption_text.is_empty() {
                    let mut cap = Paragraph::new();
                    apply_context_para_indent(&mut cap.props, ctx);
                    cap.props.align = Some(Align::Center);
                    cap.props.space_after = Some(8.0);
                    let cap_chr = CharProps {
                        font: Some(BODY_FONT_LATIN.into()),
                        font_ea: Some(BODY_FONT_EA.into()),
                        size: Some((9.0 * ctx.font_scale).max(7.5)),
                        italic: Some(true),
                        color: Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))),
                        ..CharProps::default()
                    };
                    append_styled_text(&mut cap, &caption_text, &cap_chr);
                    out.push(para_block(cap));
                }
            }
            return;
        }

        let raw_href = attrs
            .get("_export_href")
            .or_else(|| attrs.get("src"))
            .and_then(|u| sanitize_export_href(u, &self.req.references));
        let display_title = title
            .or_else(|| {
                attrs
                    .get("src")
                    .and_then(|s| s.rsplit('/').next())
                    .map(sanitize_control_chars)
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or_else(|| {
                if kind == "video" {
                    "Video attachment".into()
                } else {
                    "Media attachment".into()
                }
            });

        self.emit_resource_card(
            &display_title,
            desc.as_deref(),
            raw_href.as_deref(),
            false,
            ctx,
            out,
        );
    }

    pub(super) fn compile_embed_block(
        &mut self,
        attrs: &BTreeMap<String, String>,
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        if let Some(ref_id) = attrs.get("ref").filter(|s| !s.trim().is_empty()) {
            if let Some(resolved) = self.req.references.get(ref_id) {
                let href = (!resolved.restricted)
                    .then(|| sanitize_export_href(&resolved.href, &self.req.references))
                    .flatten();
                self.emit_resource_card(
                    &sanitize_control_chars(&resolved.title),
                    None,
                    href.as_deref(),
                    resolved.restricted,
                    ctx,
                    out,
                );
            } else {
                self.emit_resource_card("Restricted page", None, None, true, ctx, out);
            }
            return;
        }

        let href = attrs
            .get("_export_href")
            .or_else(|| attrs.get("href"))
            .and_then(|u| sanitize_export_href(u, &self.req.references));
        let title = attrs
            .get("title")
            .map(|s| sanitize_control_chars(s.trim()))
            .filter(|s| !s.is_empty())
            .or_else(|| href.clone())
            .unwrap_or_else(|| "Embedded link".into());
        let desc = attrs
            .get("description")
            .map(|s| sanitize_control_chars(s.trim()))
            .filter(|s| !s.is_empty());

        self.emit_resource_card(&title, desc.as_deref(), href.as_deref(), false, ctx, out);
    }

    fn emit_resource_card(
        &self,
        title: &str,
        description: Option<&str>,
        href: Option<&str>,
        restricted: bool,
        ctx: LayoutContext,
        out: &mut Vec<Arc<Block>>,
    ) {
        let mut title_para = Paragraph::new();
        title_para.props.space_after = Some(if description.is_some() || href.is_some() {
            2.0
        } else {
            0.0
        });
        title_para.props.line_spacing = Some(LineSpacing::Multiple(1.35));

        let title_chr = CharProps {
            font: Some(HEADING_FONT_LATIN.into()),
            font_ea: Some(BODY_FONT_EA.into()),
            size: Some((9.5 * ctx.font_scale).max(7.5)),
            bold: Some(!restricted),
            color: Some(if restricted {
                TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))
            } else if href.is_some() {
                TextColor::Rgb(Rgb(0x25, 0x63, 0xEB))
            } else {
                TextColor::Rgb(Rgb(0x1F, 0x23, 0x29))
            }),
            underline: href.map(|_| Underline::Single),
            link: href.map(str::to_string),
            ..CharProps::default()
        };
        append_styled_text(&mut title_para, title, &title_chr);

        let mut card_blocks = vec![para_block(title_para)];

        if let Some(desc) = description.filter(|d| !d.is_empty() && !restricted) {
            let truncated: String = desc.chars().take(240).collect();
            let mut desc_para = Paragraph::new();
            desc_para.props.space_after = Some(if href.is_some() { 2.0 } else { 0.0 });
            desc_para.props.line_spacing = Some(LineSpacing::Multiple(1.35));
            let desc_chr = CharProps {
                font: Some(BODY_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some((8.5 * ctx.font_scale).max(7.0)),
                color: Some(TextColor::Rgb(Rgb(0x47, 0x55, 0x69))),
                ..CharProps::default()
            };
            append_styled_text(&mut desc_para, &truncated, &desc_chr);
            card_blocks.push(para_block(desc_para));
        }

        if let Some(url) = href.filter(|u| *u != title && !restricted) {
            let mut url_para = Paragraph::new();
            url_para.props.space_after = Some(0.0);
            url_para.props.line_spacing = Some(LineSpacing::Multiple(1.25));
            let url_chr = CharProps {
                font: Some(BODY_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some((8.0 * ctx.font_scale).max(6.5)),
                color: Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))),
                link: Some(url.to_string()),
                ..CharProps::default()
            };
            append_styled_text(&mut url_para, url, &url_chr);
            card_blocks.push(para_block(url_para));
        }

        if ctx.table_depth < wordcraft_doc::table::MAX_TABLE_DEPTH {
            let box_w = ctx.content_width_pt.max(MIN_CONTAINER_WIDTH_PT);
            let border = Border {
                style: BorderStyle::Single,
                width: 0.5,
                color: Some(Rgb(0xCB, 0xD5, 0xE1)),
                space: 0.0,
            };
            let tbl = single_cell_box_table(
                BoxTableSpec {
                    width_pt: box_w,
                    indent_pt: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                    borders: Borders::box_(border),
                    shading: Some(Rgb(0xF8, 0xFA, 0xFC)),
                    margins: [6.0, 9.0, 6.0, 9.0],
                    space_before: 4.0,
                    space_after: 6.0,
                    cant_split: true,
                },
                card_blocks,
            );
            out.push(Arc::new(Block::Table(tbl)));
        } else {
            out.extend(card_blocks);
        }
    }
}

pub(super) fn build_hr_paragraph(ctx: LayoutContext) -> Paragraph {
    let mut p = Paragraph::new();
    apply_context_para_indent(&mut p.props, ctx);
    p.props.space_before = Some(6.0);
    p.props.space_after = Some(8.0);
    p.props.line_spacing = Some(LineSpacing::Exactly(4.0));
    p.props.borders = Some(Borders {
        bottom: Some(Border {
            style: BorderStyle::Single,
            width: 0.75,
            color: Some(Rgb(0xE2, 0xE8, 0xF0)),
            space: 1.0,
        }),
        ..Borders::default()
    });
    p
}

fn build_error_box_table(message: &str, ctx: LayoutContext) -> Table {
    let box_w = ctx.content_width_pt.max(MIN_CONTAINER_WIDTH_PT);
    let mut p = Paragraph::new();
    p.props.space_after = Some(0.0);
    p.props.line_spacing = Some(LineSpacing::Multiple(1.35));
    let chr = CharProps {
        font: Some(CODE_FONT_LATIN.into()),
        font_ea: Some(CODE_FONT_EA.into()),
        size: Some((8.5 * ctx.font_scale).max(7.0)),
        color: Some(TextColor::Rgb(Rgb(0xB9, 0x1C, 0x1C))),
        ..CharProps::default()
    };
    append_styled_text(&mut p, &sanitize_control_chars(message), &chr);

    let accent = Border {
        style: BorderStyle::Single,
        width: 2.5,
        color: Some(Rgb(0xDC, 0x26, 0x26)),
        space: 0.0,
    };
    let thin = Border {
        style: BorderStyle::Single,
        width: 0.5,
        color: Some(Rgb(0xFE, 0xCA, 0xCA)),
        space: 0.0,
    };
    single_cell_box_table(
        BoxTableSpec {
            width_pt: box_w,
            indent_pt: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
            borders: Borders {
                left: Some(accent),
                top: Some(thin),
                bottom: Some(thin),
                right: Some(thin),
                between: None,
                inside_v: None,
            },
            shading: Some(Rgb(0xFE, 0xF2, 0xF2)),
            margins: [6.0, 8.0, 6.0, 8.0],
            space_before: 6.0,
            space_after: 8.0,
            cant_split: true,
        },
        vec![para_block(p)],
    )
}

fn extract_code_lines(children: &[ExportNode]) -> Vec<Vec<CodeSpan>> {
    if children
        .iter()
        .any(|n| matches!(n, ExportNode::CodeLine { .. }))
    {
        return children
            .iter()
            .filter_map(|n| match n {
                ExportNode::CodeLine { runs } => Some(runs.clone()),
                _ => None,
            })
            .collect();
    }
    let raw = collect_plain_text_from_nodes(children);
    let normalized = raw.replace("\r\n", "\n").replace('\r', "\n");
    normalized
        .split('\n')
        .map(|line| {
            if line.is_empty() {
                Vec::new()
            } else {
                vec![CodeSpan {
                    text: line.to_string(),
                    color: None,
                    bold: false,
                    italic: false,
                }]
            }
        })
        .collect()
}

pub(super) fn build_code_line_para(
    runs: &[CodeSpan],
    font_scale: f32,
    keep_next: bool,
) -> Paragraph {
    let mut p = Paragraph::new();
    p.props = ParaProps {
        space_before: Some(0.0),
        space_after: Some(0.0),
        line_spacing: Some(LineSpacing::Multiple(1.42)),
        keep_next: keep_next.then_some(true),
        // OOXML `<w:wordWrap w:val="0"/>`: allow breaking long unbroken Latin tokens mid-word inside code cells.
        word_wrap: Some(false),
        suppress_hyphens: Some(true),
        snap_to_grid: Some(false),
        ..ParaProps::default()
    };
    let base_chr = CharProps {
        font: Some(CODE_FONT_LATIN.into()),
        font_ea: Some(CODE_FONT_EA.into()),
        size: Some((8.5 * font_scale).max(6.5)),
        color: Some(TextColor::Rgb(Rgb(0x24, 0x29, 0x2F))),
        no_proof: Some(true),
        ..CharProps::default()
    };
    p.mark = base_chr.clone();

    if runs.is_empty() {
        append_styled_text(&mut p, "\u{00A0}", &base_chr);
        return p;
    }

    let mut prev_space = true;
    for span in runs {
        if span.text.is_empty() {
            continue;
        }
        let mut c = base_chr.clone();
        if let Some(hex) = &span.color
            && let Some(rgb) = Rgb::parse(hex)
        {
            c.color = Some(TextColor::Rgb(rgb));
        }
        if span.bold {
            c.bold = Some(true);
        }
        if span.italic {
            c.italic = Some(true);
        }
        let preserved =
            preserve_code_whitespace(&sanitize_control_chars(&span.text), &mut prev_space);
        append_styled_text(&mut p, &preserved, &c);
    }
    p
}

fn preserve_code_whitespace(segment: &str, prev_space: &mut bool) -> String {
    let expanded = segment.replace('\t', "  ");
    let mut out = String::with_capacity(expanded.len());
    for ch in expanded.chars() {
        if ch == ' ' {
            if *prev_space {
                out.push('\u{00A0}');
            } else {
                out.push(' ');
                *prev_space = true;
            }
        } else {
            out.push(ch);
            *prev_space = false;
        }
    }
    out
}

pub(super) fn fit_display_box(
    explicit_w_pt: Option<f32>,
    explicit_h_pt: Option<f32>,
    pixel_dims: Option<(u32, u32)>,
    max_w_pt: f32,
    max_h_pt: f32,
) -> (f32, f32) {
    let (mut w, mut h) = match (explicit_w_pt, explicit_h_pt, pixel_dims) {
        (Some(ew), Some(eh), _) => (ew, eh),
        (_, _, Some((px_w, px_h))) if px_w > 0 && px_h > 0 => {
            ((px_w as f32) * 0.75, (px_h as f32) * 0.75)
        }
        _ => (max_w_pt.min(320.0), 180.0),
    };

    let bound_w = max_w_pt.max(24.0);
    let bound_h = max_h_pt.max(24.0);
    if w > bound_w && w > 0.0 {
        let scale = bound_w / w;
        w = bound_w;
        h *= scale;
    }
    if h > bound_h && h > 0.0 {
        let scale = bound_h / h;
        h = bound_h;
        w *= scale;
    }
    (w.max(6.0), h.max(6.0))
}

pub(super) fn image_pixel_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

pub(super) fn guess_media_ext(bytes: &[u8], key: &str) -> &'static str {
    if let Ok(fmt) = image::guess_format(bytes) {
        match fmt {
            image::ImageFormat::Png => return "png",
            image::ImageFormat::Jpeg => return "jpg",
            image::ImageFormat::Gif => return "gif",
            image::ImageFormat::WebP => return "webp",
            image::ImageFormat::Bmp => return "bmp",
            _ => {}
        }
    }
    let lower = key.to_ascii_lowercase();
    if lower.ends_with(".jpg") || lower.ends_with(".jpeg") {
        "jpg"
    } else if lower.ends_with(".gif") {
        "gif"
    } else if lower.ends_with(".webp") {
        "webp"
    } else if lower.ends_with(".bmp") {
        "bmp"
    } else {
        "png"
    }
}
