//! Compiles structural block containers (`<callout>`, `<columns>`) and multi-level bullet,
//! numbered, and task lists (`<ul>`, `<ol>`, `<li>`).

use std::collections::BTreeMap;
use std::sync::Arc;

use wordcraft_doc::numbering::{AbstractNum, Level, LevelSuffix, Num};
use wordcraft_doc::para::{Float, InlineObject};
use wordcraft_doc::props::{
    Align, Border, BorderStyle, Borders, CellProps, CharProps, LineSpacing, NumRef, Rgb, RowProps,
    TableProps, TextColor, VAlign,
};
use wordcraft_doc::section::NumFormat;
use wordcraft_doc::{Block, Cell, Paragraph, Row, Table, para_block};

use super::inline::{
    append_inline_object, append_styled_text, default_body_char_props, sanitize_control_chars,
};
use super::tables::{finalize_cell_blocks, plain_table_look, waterfill_with_floor};
use super::{
    BODY_FONT_EA, BODY_FONT_LATIN, CALLOUT_ICON_COL_PT, COLUMN_GUTTER_PT, ExportNode,
    LIST_HANGING_PT, LIST_STEP_PT, LayoutContext, MAX_NESTING_DEPTH, MAX_TABLE_COLS,
    MIN_COLUMN_WIDTH_PT, MIN_CONTAINER_WIDTH_PT, PageCompiler, heading_level,
};

#[derive(Clone, Copy)]
struct TonePalette {
    bg: Rgb,
    accent: Rgb,
    border: Rgb,
}

fn callout_palette(tone: Option<&str>) -> TonePalette {
    match tone.unwrap_or("info") {
        "warning" => TonePalette {
            bg: Rgb(0xFF, 0xFB, 0xEB),
            accent: Rgb(0xD9, 0x77, 0x06),
            border: Rgb(0xFD, 0xE6, 0x8A),
        },
        "success" => TonePalette {
            bg: Rgb(0xF0, 0xFD, 0xF4),
            accent: Rgb(0x16, 0xA3, 0x4A),
            border: Rgb(0xBB, 0xF7, 0xD0),
        },
        "danger" => TonePalette {
            bg: Rgb(0xFE, 0xF2, 0xF2),
            accent: Rgb(0xDC, 0x26, 0x26),
            border: Rgb(0xFE, 0xCA, 0xCA),
        },
        "neutral" => TonePalette {
            bg: Rgb(0xF8, 0xFA, 0xFC),
            accent: Rgb(0x64, 0x74, 0x8B),
            border: Rgb(0xE2, 0xE8, 0xF0),
        },
        _ => TonePalette {
            bg: Rgb(0xF0, 0xF6, 0xFF),
            accent: Rgb(0x25, 0x63, 0xEB),
            border: Rgb(0xD6, 0xE4, 0xFF),
        },
    }
}

impl PageCompiler<'_> {
    pub(super) fn compile_callout(
        &mut self,
        attrs: &BTreeMap<String, String>,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
    ) -> Table {
        let palette = callout_palette(attrs.get("tone").map(String::as_str));
        let total_w = ctx.content_width_pt.max(MIN_CONTAINER_WIDTH_PT);
        let icon_col_w = CALLOUT_ICON_COL_PT.min(total_w * 0.25);
        let body_col_w = (total_w - icon_col_w).max(40.0);

        let mut icon_para = Paragraph::new();
        icon_para.props.align = Some(Align::Center);
        icon_para.props.space_after = Some(0.0);
        icon_para.props.line_spacing = Some(LineSpacing::Multiple(1.35));
        let icon_chr = CharProps {
            font: Some(BODY_FONT_LATIN.into()),
            font_ea: Some(BODY_FONT_EA.into()),
            size: Some(11.0 * ctx.font_scale),
            color: Some(TextColor::Rgb(palette.accent)),
            ..CharProps::default()
        };

        if let Some(icon_asset) = attrs.get("_export_icon_asset")
            && let Some((media_name, _)) = self.register_media(icon_asset)
        {
            let side = (13.0 * ctx.font_scale).max(9.0);
            append_inline_object(
                &mut icon_para,
                InlineObject::Image {
                    media: media_name,
                    w: side,
                    h: side,
                    alt: attrs.get("icon").cloned().unwrap_or_default(),
                    float: Float::default(),
                    crop: [0.0; 4],
                    fx: Default::default(),
                    ole: None,
                },
                &icon_chr,
            );
        } else {
            let raw_icon = attrs
                .get("icon")
                .map(|s| sanitize_control_chars(s.trim()))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "•".into());
            append_styled_text(&mut icon_para, &raw_icon, &icon_chr);
        }

        let body_pad_l = 4.0;
        let body_pad_r = 10.0;
        let body_ctx = ctx.enter_cell(body_col_w - body_pad_l - body_pad_r, 1.0);
        let mut content_blocks = Vec::new();
        self.compile_block_list(children, body_ctx, depth + 1, &mut content_blocks);
        let hide_mark = finalize_cell_blocks(&mut content_blocks);

        let nil = Border {
            style: BorderStyle::None,
            width: 0.0,
            color: None,
            space: 0.0,
        };
        let accent_left = Border {
            style: BorderStyle::Single,
            width: 3.0,
            color: Some(palette.accent),
            space: 0.0,
        };
        let thin_border = Border {
            style: BorderStyle::Single,
            width: 0.5,
            color: Some(palette.border),
            space: 0.0,
        };

        Table {
            props: TableProps {
                width: Some(icon_col_w + body_col_w),
                indent: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                fixed: true,
                borders: Some(Borders {
                    left: Some(accent_left),
                    top: Some(thin_border),
                    bottom: Some(thin_border),
                    right: Some(thin_border),
                    between: Some(nil),
                    inside_v: Some(nil),
                }),
                shading: Some(palette.bg),
                space_before: Some(6.0),
                space_after: Some(8.0),
                look: plain_table_look(),
                ..TableProps::default()
            },
            grid: vec![icon_col_w, body_col_w],
            rows: vec![Row {
                props: RowProps {
                    cant_split: false,
                    ..RowProps::default()
                },
                cells: vec![
                    Cell {
                        props: CellProps {
                            width: Some(icon_col_w),
                            span: 1,
                            shading: Some(palette.bg),
                            margins: Some([8.0, 6.0, 8.0, 2.0]),
                            valign: Some(VAlign::Top),
                            ..CellProps::default()
                        },
                        blocks: vec![para_block(icon_para)],
                        controls: Default::default(),
                    },
                    Cell {
                        props: CellProps {
                            width: Some(body_col_w),
                            span: 1,
                            shading: Some(palette.bg),
                            margins: Some([8.0, body_pad_l, 8.0, body_pad_r]),
                            valign: Some(VAlign::Top),
                            hide_mark,
                            ..CellProps::default()
                        },
                        blocks: content_blocks,
                        controls: Default::default(),
                    },
                ],
                controls: Default::default(),
            }],
            controls: Default::default(),
        }
    }

    pub(super) fn compile_columns(
        &mut self,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
    ) -> Option<Table> {
        let cols: Vec<(&BTreeMap<String, String>, &[ExportNode])> = children
            .iter()
            .filter_map(|node| match node {
                ExportNode::Element {
                    name,
                    attrs,
                    children: col_children,
                } if name == "column" => Some((attrs, col_children.as_slice())),
                _ => None,
            })
            .take(MAX_TABLE_COLS)
            .collect();

        if cols.is_empty() {
            return None;
        }
        let n = cols.len();
        let weights: Vec<f32> = cols
            .iter()
            .map(|(attrs, _)| {
                attrs
                    .get("width")
                    .and_then(|w| w.parse::<u32>().ok())
                    .unwrap_or(1000)
                    .clamp(1, 9999) as f32
            })
            .collect();
        let total_gutter = if n > 1 {
            COLUMN_GUTTER_PT * ((n - 1) as f32)
        } else {
            0.0
        };
        let distributable = (ctx.content_width_pt - total_gutter).max((n as f32) * 24.0);
        let net_widths = waterfill_with_floor(&weights, distributable, MIN_COLUMN_WIDTH_PT);

        let mut grid = Vec::with_capacity(n);
        let mut cells = Vec::with_capacity(n);

        for (i, ((_, col_children), &net_w)) in cols.iter().zip(net_widths.iter()).enumerate() {
            let pad_l = if i == 0 { 0.0 } else { COLUMN_GUTTER_PT * 0.5 };
            let pad_r = if i + 1 == n {
                0.0
            } else {
                COLUMN_GUTTER_PT * 0.5
            };
            let cell_w = net_w + pad_l + pad_r;
            grid.push(cell_w);

            let col_ctx = ctx.enter_cell(net_w, 1.0);
            let mut col_blocks = Vec::new();
            self.compile_block_list(col_children, col_ctx, depth + 1, &mut col_blocks);
            let hide_mark = finalize_cell_blocks(&mut col_blocks);

            cells.push(Cell {
                props: CellProps {
                    width: Some(cell_w),
                    span: 1,
                    margins: Some([2.0, pad_l, 2.0, pad_r]),
                    valign: Some(VAlign::Top),
                    hide_mark,
                    ..CellProps::default()
                },
                blocks: col_blocks,
                controls: Default::default(),
            });
        }

        let nil = Border {
            style: BorderStyle::None,
            width: 0.0,
            color: None,
            space: 0.0,
        };
        let total_grid_w: f32 = grid.iter().sum();

        Some(Table {
            props: TableProps {
                width: Some(total_grid_w),
                indent: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                fixed: true,
                borders: Some(Borders::all(nil)),
                space_before: Some(4.0),
                space_after: Some(6.0),
                look: plain_table_look(),
                ..TableProps::default()
            },
            grid,
            rows: vec![Row {
                props: RowProps {
                    cant_split: false,
                    ..RowProps::default()
                },
                cells,
                controls: Default::default(),
            }],
            controls: Default::default(),
        })
    }

    fn allocate_numbering(&mut self, ordered: bool, start: u32, base_indent_pt: f32) -> u32 {
        let num_id = self.next_num_id;
        self.next_num_id = self.next_num_id.saturating_add(1);

        let levels: Vec<Level> = (0..9u8)
            .map(|lvl| {
                let indent = base_indent_pt + LIST_STEP_PT * (f32::from(lvl) + 1.0);
                if ordered {
                    let fmt = match lvl % 3 {
                        0 => NumFormat::Decimal,
                        1 => NumFormat::LowerLetter,
                        _ => NumFormat::LowerRoman,
                    };
                    let n = lvl + 1;
                    Level {
                        start: if lvl == 0 { start } else { 1 },
                        format: fmt,
                        text: format!("%{n}."),
                        align: Align::Left,
                        indent,
                        hanging: LIST_HANGING_PT,
                        suffix: LevelSuffix::Space,
                        chr: CharProps {
                            font: Some(BODY_FONT_LATIN.into()),
                            ..CharProps::default()
                        },
                        restart: true,
                        ..Level::default()
                    }
                } else {
                    let bullet = match lvl % 3 {
                        0 => "•",
                        1 => "◦",
                        _ => "▪",
                    };
                    Level {
                        start: 1,
                        format: NumFormat::Bullet,
                        text: bullet.into(),
                        align: Align::Left,
                        indent,
                        hanging: LIST_HANGING_PT,
                        suffix: LevelSuffix::Space,
                        chr: CharProps {
                            font: Some(BODY_FONT_LATIN.into()),
                            ..CharProps::default()
                        },
                        restart: true,
                        ..Level::default()
                    }
                }
            })
            .collect();

        let numbering = Arc::make_mut(&mut self.doc.numbering);
        numbering.abstracts.push(AbstractNum {
            id: num_id,
            name: None,
            levels,
            nsid: None,
            tmpl: None,
            multi_level_type: Some("multilevel".into()),
        });
        numbering.nums.push(Num {
            id: num_id,
            abstract_id: num_id,
            start_overrides: Vec::new(),
            level_overrides: Vec::new(),
        });
        num_id
    }

    pub(super) fn compile_list(
        &mut self,
        ordered: bool,
        start: Option<u32>,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
        out: &mut Vec<Arc<Block>>,
    ) {
        let num_id = self.allocate_numbering(ordered, start.unwrap_or(1), ctx.para_indent_left_pt);
        self.compile_list_with_num(num_id, children, ctx, depth, out);
    }

    fn compile_list_with_num(
        &mut self,
        num_id: u32,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
        out: &mut Vec<Arc<Block>>,
    ) {
        if depth > MAX_NESTING_DEPTH {
            return;
        }
        let level = ctx.list_depth.min(8);

        for item in children {
            let ExportNode::Element {
                name,
                attrs,
                children: li_children,
            } = item
            else {
                continue;
            };
            if name != "li" {
                continue;
            }

            let task_state = attrs.get("task").map(String::as_str);
            let mut attached_marker = false;

            for child in li_children {
                match child {
                    ExportNode::Element {
                        name: sub_name,
                        attrs: sub_attrs,
                        children: sub_children,
                    } if sub_name == "ul" || sub_name == "ol" => {
                        if !attached_marker {
                            let empty_item =
                                self.make_empty_list_item_para(num_id, level, task_state, ctx);
                            out.push(para_block(empty_item));
                            attached_marker = true;
                        }
                        let mut sub_ctx = ctx;
                        sub_ctx.list_depth = ctx.list_depth.saturating_add(1).min(8);
                        let sub_ordered = sub_name == "ol";
                        let sub_start = sub_attrs
                            .get("start")
                            .and_then(|s| s.parse::<u32>().ok())
                            .unwrap_or(1);
                        let sub_num_id = self.allocate_numbering(
                            sub_ordered,
                            sub_start,
                            ctx.para_indent_left_pt,
                        );
                        self.compile_list_with_num(
                            sub_num_id,
                            sub_children,
                            sub_ctx,
                            depth + 1,
                            out,
                        );
                    }
                    ExportNode::Element {
                        name: p_name,
                        attrs: p_attrs,
                        children: p_children,
                    } if !attached_marker && (p_name == "p" || heading_level(p_name).is_some()) => {
                        let mut item_ctx = ctx;
                        item_ctx.para_indent_left_pt = 0.0;
                        let mut para = self.compile_paragraph(
                            heading_level(p_name),
                            p_attrs,
                            p_children,
                            item_ctx,
                            depth + 1,
                        );
                        para.props.space_after = Some(3.0);
                        self.decorate_list_item_first_para(
                            &mut para, num_id, level, task_state, ctx,
                        );
                        out.push(para_block(para));
                        attached_marker = true;
                    }
                    other => {
                        let follow_indent = LIST_STEP_PT * (f32::from(level) + 1.0);
                        let follow_ctx = ctx.indented_by(follow_indent);
                        if !attached_marker {
                            let empty_item =
                                self.make_empty_list_item_para(num_id, level, task_state, ctx);
                            out.push(para_block(empty_item));
                            attached_marker = true;
                        }
                        self.compile_block_node(other, follow_ctx, depth + 1, out);
                    }
                }
            }

            if !attached_marker {
                let empty_item = self.make_empty_list_item_para(num_id, level, task_state, ctx);
                out.push(para_block(empty_item));
            }
        }
    }

    fn make_empty_list_item_para(
        &self,
        num_id: u32,
        level: u8,
        task_state: Option<&str>,
        ctx: LayoutContext,
    ) -> Paragraph {
        let mut p = Paragraph::new();
        p.props.space_after = Some(3.0);
        p.mark = default_body_char_props(ctx.font_scale);
        self.decorate_list_item_first_para(&mut p, num_id, level, task_state, ctx);
        p
    }

    fn decorate_list_item_first_para(
        &self,
        para: &mut Paragraph,
        num_id: u32,
        level: u8,
        task_state: Option<&str>,
        ctx: LayoutContext,
    ) {
        if let Some(task) = task_state {
            let is_done = task == "done";
            let left = ctx.para_indent_left_pt + LIST_STEP_PT * (f32::from(level) + 1.0);
            para.props.indent_left = Some(left);
            para.props.indent_first = Some(-LIST_HANGING_PT);
            para.props.cancel_char_indents(true, false, true);

            let check_chr = CharProps {
                font: Some(BODY_FONT_LATIN.into()),
                size: Some((10.5 * ctx.font_scale).max(7.5)),
                color: Some(if is_done {
                    TextColor::Rgb(Rgb(0x16, 0xA3, 0x4A))
                } else {
                    TextColor::Rgb(Rgb(0x64, 0x74, 0x8B))
                }),
                ..CharProps::default()
            };
            let prefix = if is_done { "☑ " } else { "☐ " };
            let _ = para.insert_text(0, prefix, &check_chr);

            if is_done {
                let prefix_bytes = prefix.len();
                let mut byte_cursor = 0usize;
                for run in &mut para.runs {
                    if byte_cursor >= prefix_bytes
                        && run.props.color == Some(TextColor::Rgb(Rgb(0x1F, 0x23, 0x29)))
                    {
                        run.props.color = Some(TextColor::Rgb(Rgb(0x64, 0x74, 0x8B)));
                    }
                    byte_cursor = byte_cursor.saturating_add(run.len);
                }
            }
        } else {
            para.props.numbering = Some(NumRef { num: num_id, level });
        }
    }
}
