//! Configures A4 page geometry, built-in typographic styles, running headers/footers, document
//! title blocks, and Knowledge Page structured metadata summary tables.

use std::sync::Arc;

use wordcraft_doc::para::{Float, InlineObject};
use wordcraft_doc::props::{
    Align, Border, BorderStyle, Borders, CellProps, CharProps, LineSpacing, ParaProps, Rgb,
    RowProps, TableLook, TableProps, TextColor, VAlign,
};
use wordcraft_doc::section::{HeaderSet, SectionProps};
use wordcraft_doc::styles::{Style, StyleKind};
use wordcraft_doc::{Cell, Document, Paragraph, Part, PartKind, Row, Table, para_block};

use super::inline::{append_inline_object, append_styled_text, sanitize_control_chars};
use super::{
    A4_HEIGHT_PT, A4_WIDTH_PT, BODY_FONT_EA, BODY_FONT_LATIN, HEADING_FONT_LATIN, LayoutContext,
    MetadataRow, PAGE_MARGIN_H_PT, PAGE_MARGIN_V_PT, PageCompiler,
};

pub(super) fn configure_styles_and_section(doc: &mut Document, title: &str) {
    doc.last_section = SectionProps {
        page_w: A4_WIDTH_PT,
        page_h: A4_HEIGHT_PT,
        landscape: false,
        margin_top: PAGE_MARGIN_V_PT,
        margin_bottom: PAGE_MARGIN_V_PT,
        margin_left: PAGE_MARGIN_H_PT,
        margin_right: PAGE_MARGIN_H_PT,
        header: 28.0,
        footer: 28.0,
        title_page: true,
        headers: HeaderSet {
            default: Some(1),
            first: None,
            even: None,
        },
        footers: HeaderSet {
            default: Some(2),
            first: Some(2),
            even: None,
        },
        ..SectionProps::default()
    };

    let styles = Arc::make_mut(&mut doc.styles);
    styles.default_chr.font = Some(BODY_FONT_LATIN.into());
    styles.default_chr.font_ea = Some(BODY_FONT_EA.into());
    styles.default_chr.size = Some(10.5);
    styles.default_chr.color = Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29)));

    styles.default_para.line_spacing = Some(LineSpacing::Multiple(1.55));
    styles.default_para.space_after = Some(6.0);
    styles.default_para.widow_control = Some(true);
    styles.default_para_present = true;

    if let Some(normal) = styles
        .styles
        .iter_mut()
        .find(|s| s.id.eq_ignore_ascii_case("Normal"))
    {
        normal.chr.font = Some(BODY_FONT_LATIN.into());
        normal.chr.font_ea = Some(BODY_FONT_EA.into());
        normal.chr.size = Some(10.5);
        normal.chr.color = Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29)));
        normal.para.line_spacing = Some(LineSpacing::Multiple(1.55));
        normal.para.space_after = Some(6.0);
        normal.para.widow_control = Some(true);
    }

    for (lvl, size_pt, before_pt, after_pt, line_mult) in [
        (1u8, 17.0f32, 18.0f32, 6.0f32, 1.30f32),
        (2, 14.0, 15.0, 5.0, 1.35),
        (3, 12.0, 12.0, 4.0, 1.40),
        (4, 10.5, 10.0, 3.0, 1.45),
        (5, 10.5, 8.0, 3.0, 1.45),
        (6, 10.0, 8.0, 2.0, 1.45),
    ] {
        let style_id = format!("Heading{lvl}");
        let style_name = format!("Heading {lvl}");
        let para_props = ParaProps {
            space_before: Some(before_pt),
            space_after: Some(after_pt),
            line_spacing: Some(LineSpacing::Multiple(line_mult)),
            keep_next: Some(true),
            keep_lines: Some(true),
            widow_control: Some(true),
            outline_level: Some(lvl - 1),
            ..ParaProps::default()
        };
        let chr_props = CharProps {
            font: Some(HEADING_FONT_LATIN.into()),
            font_ea: Some(BODY_FONT_EA.into()),
            size: Some(size_pt),
            bold: Some(true),
            color: Some(if lvl == 6 {
                TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))
            } else {
                TextColor::Rgb(Rgb(0x11, 0x18, 0x27))
            }),
            ..CharProps::default()
        };
        if let Some(existing) = styles
            .styles
            .iter_mut()
            .find(|s| s.id.eq_ignore_ascii_case(&style_id))
        {
            existing.para = para_props;
            existing.chr = chr_props;
        } else {
            styles.styles.push(Style {
                id: style_id,
                name: style_name,
                kind: StyleKind::Paragraph,
                based_on: Some("Normal".into()),
                next: Some("Normal".into()),
                para: para_props,
                chr: chr_props,
                builtin: true,
                quick: true,
                ..Style::default()
            });
        }
    }

    let mut hdr_para = Paragraph::new();
    hdr_para.props.align = Some(Align::Right);
    hdr_para.props.space_after = Some(0.0);
    let hdr_chr = CharProps {
        font: Some(BODY_FONT_LATIN.into()),
        font_ea: Some(BODY_FONT_EA.into()),
        size: Some(8.5),
        color: Some(TextColor::Rgb(Rgb(0x8C, 0x8C, 0x8C))),
        ..CharProps::default()
    };
    if !title.is_empty() {
        let truncated: String = title.chars().take(120).collect();
        append_styled_text(&mut hdr_para, &truncated, &hdr_chr);
    }
    doc.parts.insert(
        1,
        Part {
            kind: PartKind::Header,
            blocks: vec![para_block(hdr_para)],
            body: Default::default(),
        },
    );

    let mut ftr_para = Paragraph::new();
    ftr_para.props.align = Some(Align::Center);
    ftr_para.props.space_after = Some(0.0);
    let ftr_chr = CharProps {
        font: Some(BODY_FONT_LATIN.into()),
        font_ea: Some(BODY_FONT_EA.into()),
        size: Some(8.5),
        color: Some(TextColor::Rgb(Rgb(0x8C, 0x8C, 0x8C))),
        ..CharProps::default()
    };
    append_inline_object(
        &mut ftr_para,
        InlineObject::Field {
            instr: "PAGE".into(),
            result: "1".into(),
            locked: false,
            dirty: true,
            code: false,
            form: String::new(),
        },
        &ftr_chr,
    );
    append_styled_text(&mut ftr_para, " / ", &ftr_chr);
    append_inline_object(
        &mut ftr_para,
        InlineObject::Field {
            instr: "NUMPAGES".into(),
            result: "1".into(),
            locked: false,
            dirty: true,
            code: false,
            form: String::new(),
        },
        &ftr_chr,
    );
    doc.parts.insert(
        2,
        Part {
            kind: PartKind::Footer,
            blocks: vec![para_block(ftr_para)],
            body: Default::default(),
        },
    );
}

impl PageCompiler<'_> {
    pub(super) fn build_title_paragraph(&mut self, title: &str) -> Option<Paragraph> {
        let has_icon_asset = self
            .req
            .icon_asset_key
            .as_deref()
            .is_some_and(|k| self.raw_assets.contains_key(k));
        let icon_text = self
            .req
            .icon_text
            .as_deref()
            .map(sanitize_control_chars)
            .filter(|s| !s.trim().is_empty());

        if title.is_empty() && !has_icon_asset && icon_text.is_none() {
            return None;
        }

        let mut para = Paragraph::new();
        para.props = ParaProps {
            space_before: Some(0.0),
            space_after: Some(14.0),
            line_spacing: Some(LineSpacing::Multiple(1.25)),
            keep_next: Some(true),
            keep_lines: Some(true),
            widow_control: Some(true),
            ..ParaProps::default()
        };
        let title_chr = CharProps {
            font: Some(HEADING_FONT_LATIN.into()),
            font_ea: Some(BODY_FONT_EA.into()),
            size: Some(22.0),
            bold: Some(true),
            color: Some(TextColor::Rgb(Rgb(0x11, 0x18, 0x27))),
            ..CharProps::default()
        };
        para.mark = title_chr.clone();

        if let Some(key) = self.req.icon_asset_key.clone()
            && let Some((media_name, _)) = self.register_media(&key)
        {
            append_inline_object(
                &mut para,
                InlineObject::Image {
                    media: media_name,
                    w: 20.0,
                    h: 20.0,
                    alt: String::new(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &title_chr,
            );
            if !title.is_empty() {
                append_styled_text(&mut para, "  ", &title_chr);
            }
        } else if let Some(glyph) = icon_text {
            append_styled_text(&mut para, glyph.trim(), &title_chr);
            if !title.is_empty() {
                append_styled_text(&mut para, " ", &title_chr);
            }
        }

        if !title.is_empty() {
            append_styled_text(&mut para, title, &title_chr);
        }
        Some(para)
    }

    pub(super) fn build_metadata_table(
        &mut self,
        rows: &[MetadataRow],
        ctx: LayoutContext,
    ) -> Option<Table> {
        let valid_rows: Vec<&MetadataRow> =
            rows.iter().filter(|r| !r.key.trim().is_empty()).collect();
        if valid_rows.is_empty() {
            return None;
        }

        let key_w = (ctx.content_width_pt * 0.28).clamp(84.0, 140.0);
        let val_w = (ctx.content_width_pt - key_w).max(60.0);
        let border = Border {
            style: BorderStyle::Single,
            width: 0.5,
            color: Some(Rgb(0xE2, 0xE8, 0xF0)),
            space: 0.0,
        };

        let mut tbl_rows = Vec::with_capacity(valid_rows.len());
        for entry in valid_rows {
            let mut k_para = Paragraph::new();
            k_para.props.space_after = Some(0.0);
            k_para.props.line_spacing = Some(LineSpacing::Multiple(1.35));
            let k_chr = CharProps {
                font: Some(HEADING_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some(9.0),
                bold: Some(true),
                color: Some(TextColor::Rgb(Rgb(0x47, 0x55, 0x69))),
                ..CharProps::default()
            };
            append_styled_text(
                &mut k_para,
                &sanitize_control_chars(entry.key.trim()),
                &k_chr,
            );

            let mut v_para = Paragraph::new();
            v_para.props.space_after = Some(0.0);
            v_para.props.line_spacing = Some(LineSpacing::Multiple(1.35));
            let v_chr = CharProps {
                font: Some(BODY_FONT_LATIN.into()),
                font_ea: Some(BODY_FONT_EA.into()),
                size: Some(9.0),
                color: Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29))),
                ..CharProps::default()
            };
            append_styled_text(
                &mut v_para,
                &sanitize_control_chars(entry.value.trim()),
                &v_chr,
            );

            tbl_rows.push(Row {
                props: RowProps {
                    cant_split: true,
                    ..RowProps::default()
                },
                cells: vec![
                    Cell {
                        props: CellProps {
                            width: Some(key_w),
                            span: 1,
                            shading: Some(Rgb(0xF8, 0xFA, 0xFC)),
                            valign: Some(VAlign::Top),
                            ..CellProps::default()
                        },
                        blocks: vec![para_block(k_para)],
                        controls: Default::default(),
                    },
                    Cell {
                        props: CellProps {
                            width: Some(val_w),
                            span: 1,
                            valign: Some(VAlign::Top),
                            ..CellProps::default()
                        },
                        blocks: vec![para_block(v_para)],
                        controls: Default::default(),
                    },
                ],
                controls: Default::default(),
            });
        }

        Some(Table {
            props: TableProps {
                width: Some(key_w + val_w),
                fixed: true,
                borders: Some(Borders::all(border)),
                cell_margins: Some([4.5, 7.0, 4.5, 7.0]),
                space_after: Some(12.0),
                look: TableLook {
                    header_row: false,
                    banded_rows: false,
                    first_column: false,
                    ..TableLook::default()
                },
                ..TableProps::default()
            },
            grid: vec![key_w, val_w],
            rows: tbl_rows,
            controls: Default::default(),
        })
    }
}
