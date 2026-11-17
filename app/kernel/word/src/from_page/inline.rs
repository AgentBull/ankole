//! Compiles inline formatting runs, mentions, images, CSS style spans, and safe reader hyperlinks.

use std::collections::BTreeMap;

use wordcraft_doc::Paragraph;
use wordcraft_doc::math::Math;
use wordcraft_doc::para::{Float, InlineObject, OBJ};
use wordcraft_doc::props::{
    Align, CharProps, Highlight, ParaProps, Rgb, TextColor, Underline, VertAlign,
};

use super::blocks::fit_display_box;
use super::{
    BODY_FONT_EA, BODY_FONT_LATIN, CODE_FONT_EA, CODE_FONT_LATIN, ExportNode, LayoutContext,
    MAX_NESTING_DEPTH, PageCompiler, ResolvedReference,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum TextTransform {
    None,
    Uppercase,
    Lowercase,
    Capitalize,
}

#[derive(Clone, Debug)]
pub(super) struct InlineState {
    pub(super) chr: CharProps,
    pub(super) transform: TextTransform,
    pub(super) effective_size_pt: f32,
}

pub(super) struct ParsedCssStyle {
    pub(super) fg: Option<Rgb>,
    pub(super) bg: Option<Rgb>,
    pub(super) transform: TextTransform,
}

impl PageCompiler<'_> {
    pub(super) fn compile_inline_list(
        &mut self,
        para: &mut Paragraph,
        nodes: &[ExportNode],
        state: &InlineState,
        ctx: LayoutContext,
        depth: usize,
    ) {
        if depth > MAX_NESTING_DEPTH * 2 {
            return;
        }
        for node in nodes {
            self.compile_inline_node(para, node, state, ctx, depth);
        }
    }

    fn compile_inline_node(
        &mut self,
        para: &mut Paragraph,
        node: &ExportNode,
        state: &InlineState,
        ctx: LayoutContext,
        depth: usize,
    ) {
        if depth > MAX_NESTING_DEPTH * 2 {
            return;
        }
        match node {
            ExportNode::Text { value } => {
                let cleaned = sanitize_inline_text(value);
                let transformed = apply_text_transform(&cleaned, state.transform);
                append_styled_text(para, &transformed, &state.chr);
            }
            ExportNode::EmojiImage { asset_key, alt } => {
                self.append_emoji_image(para, asset_key, alt, state.effective_size_pt, &state.chr);
            }
            ExportNode::CodeLine { runs } => {
                for span in runs {
                    let mut c = state.chr.clone();
                    c.font = Some(CODE_FONT_LATIN.into());
                    c.font_ea = Some(CODE_FONT_EA.into());
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
                    append_styled_text(para, &sanitize_inline_text(&span.text), &c);
                }
            }
            ExportNode::Element {
                name,
                attrs,
                children,
            } => match name.as_str() {
                "comment" => {
                    self.compile_inline_list(para, children, state, ctx, depth + 1);
                }
                "br" => {
                    append_styled_text(para, "\n", &state.chr);
                }
                "strong" => {
                    let mut next = state.clone();
                    next.chr.bold = Some(true);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "em" => {
                    let mut next = state.clone();
                    next.chr.italic = Some(true);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "u" => {
                    let mut next = state.clone();
                    next.chr.underline = Some(Underline::Single);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "s" => {
                    let mut next = state.clone();
                    next.chr.strike = Some(true);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "mark" => {
                    let mut next = state.clone();
                    if next.chr.shading.is_none() {
                        next.chr.highlight = Some(Highlight::Yellow);
                    }
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "sup" => {
                    let mut next = state.clone();
                    next.chr.vert_align = Some(VertAlign::Superscript);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "sub" => {
                    let mut next = state.clone();
                    next.chr.vert_align = Some(VertAlign::Subscript);
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "code" => {
                    let mut next = state.clone();
                    next.chr.font = Some(CODE_FONT_LATIN.into());
                    next.chr.font_ea = Some(CODE_FONT_EA.into());
                    let code_sz = (state.effective_size_pt * 0.90).max(7.5);
                    next.chr.size = Some(code_sz);
                    next.effective_size_pt = code_sz;
                    if next.chr.shading.is_none() {
                        next.chr.shading = Some(Rgb(0xF2, 0xF3, 0xF5));
                    }
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "inline-math" => {
                    let raw_latex = collect_plain_text_from_nodes(children);
                    let unwrapped = unwrap_math_delimiters(&raw_latex).trim();
                    if !unwrapped.is_empty() {
                        if attrs.get("_export_invalid").map(String::as_str) == Some("true") {
                            let mut err_chr = state.chr.clone();
                            err_chr.font = Some(CODE_FONT_LATIN.into());
                            err_chr.font_ea = Some(CODE_FONT_EA.into());
                            err_chr.size = Some((state.effective_size_pt * 0.90).max(7.5));
                            err_chr.color = Some(TextColor::Rgb(Rgb(0xB9, 0x1C, 0x1C)));
                            append_styled_text(para, &sanitize_inline_text(unwrapped), &err_chr);
                        } else {
                            let nodes = wordcraft_doc::math_latex::parse_latex(unwrapped);
                            if nodes.is_empty() {
                                let mut mono = state.chr.clone();
                                mono.font = Some(CODE_FONT_LATIN.into());
                                mono.font_ea = Some(CODE_FONT_EA.into());
                                mono.size = Some((state.effective_size_pt * 0.92).max(7.5));
                                append_styled_text(para, &sanitize_inline_text(unwrapped), &mono);
                            } else {
                                let linear = wordcraft_doc::math::to_linear(&nodes);
                                append_inline_object(
                                    para,
                                    InlineObject::Equation {
                                        linear: if linear.is_empty() {
                                            sanitize_inline_text(unwrapped)
                                        } else {
                                            linear
                                        },
                                        display: false,
                                        math: Math {
                                            nodes,
                                            ..Math::default()
                                        },
                                    },
                                    &state.chr,
                                );
                            }
                        }
                    }
                }
                "span" => {
                    let mut next = state.clone();
                    if let Some(style_str) = attrs.get("style") {
                        let parsed = parse_inline_css_style(style_str);
                        if let Some(fg) = parsed.fg {
                            next.chr.color = Some(TextColor::Rgb(fg));
                        }
                        if let Some(bg) = parsed.bg {
                            next.chr.shading = Some(bg);
                            next.chr.highlight = None;
                        }
                        if parsed.transform != TextTransform::None {
                            next.transform = parsed.transform;
                        }
                    }
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "a" => {
                    let mut next = state.clone();
                    if let Some(safe_href) = attrs
                        .get("_export_href")
                        .or_else(|| attrs.get("href"))
                        .and_then(|h| sanitize_export_href(h, &self.req.references))
                    {
                        next.chr.link = Some(safe_href);
                        if next.chr.underline.is_none() {
                            next.chr.underline = Some(Underline::Single);
                        }
                        if next.chr.color.is_none()
                            || next.chr.color == Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29)))
                        {
                            next.chr.color = Some(TextColor::Rgb(Rgb(0x25, 0x63, 0xEB)));
                        }
                    }
                    self.compile_inline_list(para, children, &next, ctx, depth + 1);
                }
                "mention" => {
                    if let Some(uid) = attrs.get("principal") {
                        let (label, restricted) = match self.req.principals.get(uid) {
                            Some(p) if !p.restricted => {
                                (format!("@{}", sanitize_inline_text(&p.name)), false)
                            }
                            Some(p) => (sanitize_inline_text(&p.name), true),
                            None => ("@Restricted user".into(), true),
                        };
                        let mut c = state.chr.clone();
                        if restricted {
                            c.color = Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B)));
                        } else {
                            c.color = Some(TextColor::Rgb(Rgb(0x1D, 0x4E, 0xD8)));
                            c.shading = Some(Rgb(0xEF, 0xF6, 0xFF));
                        }
                        append_styled_text(para, &label, &c);
                    } else if let Some(page_id) = attrs.get("page") {
                        let (title, href, restricted) = match self.req.references.get(page_id) {
                            Some(r) => (
                                sanitize_inline_text(&r.title),
                                (!r.restricted)
                                    .then(|| sanitize_export_href(&r.href, &self.req.references))
                                    .flatten(),
                                r.restricted,
                            ),
                            None => ("Restricted page".into(), None, true),
                        };
                        let mut c = state.chr.clone();
                        if restricted {
                            c.color = Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B)));
                            c.link = None;
                        } else {
                            c.color = Some(TextColor::Rgb(Rgb(0x25, 0x63, 0xEB)));
                            c.underline = Some(Underline::Single);
                            c.link = href;
                        }
                        append_styled_text(para, &title, &c);
                    }
                }
                "img" => {
                    let alt = attrs
                        .get("alt")
                        .or_else(|| attrs.get("title"))
                        .map(|s| sanitize_inline_text(s))
                        .unwrap_or_default();
                    if let Some(asset_key) = attrs.get("_export_asset")
                        && let Some((media_name, dims)) = self.register_media(asset_key)
                    {
                        let max_inline_h = (state.effective_size_pt * 2.2).max(16.0);
                        let (w_pt, h_pt) = fit_display_box(
                            None,
                            None,
                            dims,
                            ctx.content_width_pt.min(180.0),
                            max_inline_h,
                        );
                        append_inline_object(
                            para,
                            InlineObject::Image {
                                media: media_name,
                                w: w_pt,
                                h: h_pt,
                                alt,
                                float: Float::default(),
                                crop: [0.0; 4],
                                fx: Default::default(),
                                ole: None,
                            },
                            &state.chr,
                        );
                    } else if !alt.trim().is_empty() {
                        append_styled_text(para, &format!("[{alt}]"), &state.chr);
                    }
                }
                _ => {
                    self.compile_inline_list(para, children, state, ctx, depth + 1);
                }
            },
        }
    }

    pub(super) fn append_emoji_image(
        &mut self,
        para: &mut Paragraph,
        asset_key: &str,
        alt: &str,
        size_pt: f32,
        chr: &CharProps,
    ) {
        if let Some((media_name, _)) = self.register_media(asset_key) {
            let side = size_pt.clamp(8.0, 28.0);
            append_inline_object(
                para,
                InlineObject::Image {
                    media: media_name,
                    w: side,
                    h: side,
                    alt: sanitize_inline_text(alt),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                chr,
            );
        } else if !alt.is_empty() {
            append_styled_text(para, &sanitize_inline_text(alt), chr);
        }
    }
}

pub(super) fn parse_inline_css_style(style: &str) -> ParsedCssStyle {
    let mut fg = None;
    let mut bg = None;
    let mut transform = TextTransform::None;

    for decl in style.split(';') {
        let Some((k, v)) = decl.split_once(':') else {
            continue;
        };
        let key = k.trim().to_ascii_lowercase();
        let val = v.trim();
        match key.as_str() {
            "color" => {
                fg = Rgb::parse(val);
            }
            "background-color" => {
                bg = Rgb::parse(val);
            }
            "text-transform" => {
                transform = match val.to_ascii_lowercase().as_str() {
                    "uppercase" => TextTransform::Uppercase,
                    "lowercase" => TextTransform::Lowercase,
                    "capitalize" => TextTransform::Capitalize,
                    _ => TextTransform::None,
                };
            }
            _ => {}
        }
    }
    ParsedCssStyle { fg, bg, transform }
}

fn apply_text_transform(text: &str, transform: TextTransform) -> String {
    match transform {
        TextTransform::None => text.to_string(),
        TextTransform::Uppercase => text.to_uppercase(),
        TextTransform::Lowercase => text.to_lowercase(),
        TextTransform::Capitalize => {
            let mut out = String::with_capacity(text.len());
            let mut start_of_word = true;
            for ch in text.chars() {
                if ch.is_whitespace() {
                    start_of_word = true;
                    out.push(ch);
                } else if start_of_word {
                    out.extend(ch.to_uppercase());
                    start_of_word = false;
                } else {
                    out.push(ch);
                }
            }
            out
        }
    }
}

/// Sanitizes external or internal hyperlinks for exported `.docx` and `.pdf` artifacts:
/// - Resolves `ankole:page/<uuid>` through `references`, dropping the link when missing or restricted.
/// - Strips any `authentication_ref` query parameter from HTTP(S) and anchor URLs.
pub(super) fn sanitize_export_href(
    raw: &str,
    references: &BTreeMap<String, ResolvedReference>,
) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return None;
    }
    if let Some(page_id) = trimmed.strip_prefix("ankole:page/") {
        let resolved = references.get(page_id.trim())?;
        if resolved.restricted {
            return None;
        }
        return strip_auth_ref_param(resolved.href.trim());
    }
    let lower = trimmed.to_ascii_lowercase();
    let safe_scheme = lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("mailto:")
        || trimmed.starts_with('#');
    if !safe_scheme {
        return None;
    }
    strip_auth_ref_param(trimmed)
}

fn strip_auth_ref_param(url: &str) -> Option<String> {
    if url.is_empty() {
        return None;
    }
    let (before_hash, hash_suffix) = match url.split_once('#') {
        Some((b, h)) => (b, Some(h)),
        None => (url, None),
    };
    let Some((base, query)) = before_hash.split_once('?') else {
        return Some(url.to_string());
    };
    let kept: Vec<&str> = query
        .split('&')
        .filter(|pair| {
            let key = pair.split_once('=').map_or(*pair, |(k, _)| k);
            !key.eq_ignore_ascii_case("authentication_ref") && !pair.is_empty()
        })
        .collect();

    let mut rebuilt = String::from(base);
    if !kept.is_empty() {
        rebuilt.push('?');
        rebuilt.push_str(&kept.join("&"));
    }
    if let Some(h) = hash_suffix {
        rebuilt.push('#');
        rebuilt.push_str(h);
    }
    (!rebuilt.is_empty()).then_some(rebuilt)
}

pub(super) fn parse_align(val: &str) -> Option<Align> {
    match val {
        "left" => Some(Align::Left),
        "center" => Some(Align::Center),
        "right" => Some(Align::Right),
        "justify" => Some(Align::Justify),
        _ => None,
    }
}

pub(super) fn apply_context_para_indent(props: &mut ParaProps, ctx: LayoutContext) {
    if ctx.para_indent_left_pt > 0.0 {
        props.indent_left = Some(ctx.para_indent_left_pt);
        props.cancel_char_indents(true, false, false);
    }
}

pub(super) fn default_body_char_props(font_scale: f32) -> CharProps {
    CharProps {
        font: Some(BODY_FONT_LATIN.into()),
        font_ea: Some(BODY_FONT_EA.into()),
        size: Some((10.5 * font_scale).max(7.5)),
        color: Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29))),
        ..CharProps::default()
    }
}

pub(super) fn is_likely_block_node(node: &ExportNode) -> bool {
    matches!(
        node,
        ExportNode::Element { name, .. }
            if matches!(
                name.as_str(),
                "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6"
                    | "block" | "blockquote" | "callout" | "columns" | "column"
                    | "ul" | "ol" | "li" | "pre" | "mermaid" | "infographic"
                    | "math" | "hr" | "table" | "media" | "embed"
            )
    )
}

pub(super) fn collect_plain_text_from_nodes(nodes: &[ExportNode]) -> String {
    let mut out = String::new();
    fn visit(node: &ExportNode, out: &mut String) {
        match node {
            ExportNode::Text { value } => out.push_str(value),
            ExportNode::EmojiImage { alt, .. } => out.push_str(alt),
            ExportNode::CodeLine { runs } => {
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                for r in runs {
                    out.push_str(&r.text);
                }
            }
            ExportNode::Element { name, children, .. } => {
                if name == "br" {
                    out.push('\n');
                }
                for child in children {
                    visit(child, out);
                }
            }
        }
    }
    for n in nodes {
        visit(n, &mut out);
    }
    out
}

pub(super) fn sanitize_control_chars(s: &str) -> String {
    s.chars()
        .filter(|&c| c != OBJ && (c == '\t' || !c.is_control()))
        .collect()
}

fn sanitize_inline_text(s: &str) -> String {
    s.chars()
        .filter(|&c| c != OBJ && (matches!(c, '\t' | '\n') || !c.is_control()))
        .collect()
}

pub(super) fn append_styled_text(para: &mut Paragraph, text: &str, props: &CharProps) {
    if !text.is_empty() {
        let _ = para.insert_text(para.len(), text, props);
    }
}

pub(super) fn append_inline_object(para: &mut Paragraph, obj: InlineObject, props: &CharProps) {
    let _ = para.insert_object(para.len(), obj, props);
}

fn is_escaped_at(bytes: &[u8], index: usize) -> bool {
    bytes.get(..index).map_or(0, |prefix| {
        prefix.iter().rev().take_while(|&&b| b == b'\\').count()
    }) % 2
        == 1
}

fn has_unescaped_dollar(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes
        .iter()
        .enumerate()
        .any(|(i, &b)| b == b'$' && !is_escaped_at(bytes, i))
}

fn has_unescaped_sequence(text: &str, seq: &str) -> bool {
    let bytes = text.as_bytes();
    let mut start = 0usize;
    while let Some(rest) = text.get(start..) {
        let Some(rel) = rest.find(seq) else {
            break;
        };
        let idx = start + rel;
        if !is_escaped_at(bytes, idx) {
            return true;
        }
        start = idx + 1;
    }
    false
}

pub(super) fn unwrap_math_delimiters(source: &str) -> &str {
    let trimmed = source.trim();
    let bytes = trimmed.as_bytes();
    if !trimmed.starts_with("$$$")
        && let Some(after_open) = trimmed.strip_prefix("$$")
        && let Some(raw_inner) = after_open.strip_suffix("$$")
        && !is_escaped_at(bytes, bytes.len().saturating_sub(2))
    {
        let inner = raw_inner.trim();
        if !inner.is_empty() && !has_unescaped_dollar(inner) {
            return inner;
        }
    }
    if !trimmed.starts_with("$$")
        && let Some(after_open) = trimmed.strip_prefix('$')
        && let Some(raw_inner) = after_open.strip_suffix('$')
        && !is_escaped_at(bytes, bytes.len().saturating_sub(1))
    {
        let inner = raw_inner.trim();
        if !inner.is_empty() && !has_unescaped_dollar(inner) {
            return inner;
        }
    }
    if let Some(after_open) = trimmed.strip_prefix(r"\(")
        && let Some(raw_inner) = after_open.strip_suffix(r"\)")
        && !is_escaped_at(bytes, bytes.len().saturating_sub(2))
    {
        let inner = raw_inner.trim();
        if !inner.is_empty()
            && !has_unescaped_sequence(inner, r"\(")
            && !has_unescaped_sequence(inner, r"\)")
        {
            return inner;
        }
    }
    if let Some(after_open) = trimmed.strip_prefix(r"\[")
        && let Some(raw_inner) = after_open.strip_suffix(r"\]")
        && !is_escaped_at(bytes, bytes.len().saturating_sub(2))
    {
        let inner = raw_inner.trim();
        if !inner.is_empty()
            && !has_unescaped_sequence(inner, r"\[")
            && !has_unescaped_sequence(inner, r"\]")
        {
            return inner;
        }
    }
    source
}
