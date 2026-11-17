//! Reconstructs OOXML `<w:tbl>` grids (`gridSpan`, `VMerge`, `tblHeader`) and solves bounded column
//! widths via water-filling across `1..=63` columns.

use std::collections::BTreeMap;
use std::sync::Arc;

use wordcraft_doc::props::{
    Border, BorderStyle, Borders, CellProps, LineSpacing, Rgb, RowProps, TableLook, TableProps,
    VAlign, VMerge,
};
use wordcraft_doc::{Block, Cell, Paragraph, Row, Table, para_block};

use super::inline::{collect_plain_text_from_nodes, parse_align};
use super::{ExportNode, LayoutContext, MAX_TABLE_COLS, PageCompiler};

impl PageCompiler<'_> {
    pub(super) fn compile_table(
        &mut self,
        attrs: &BTreeMap<String, String>,
        children: &[ExportNode],
        ctx: LayoutContext,
        depth: usize,
    ) -> Option<Table> {
        let tr_nodes: Vec<&[ExportNode]> = children
            .iter()
            .filter_map(|n| match n {
                ExportNode::Element {
                    name,
                    children: row_children,
                    ..
                } if name == "tr" => Some(row_children.as_slice()),
                _ => None,
            })
            .take(wordcraft_doc::table::MAX_ROWS)
            .collect();

        if tr_nodes.is_empty() {
            return None;
        }

        let num_cols = compute_logical_column_count(&tr_nodes);
        if num_cols == 0 {
            return None;
        }

        let declared_widths = parse_declared_widths(attrs.get("widths").map(String::as_str));
        let is_full_layout = attrs.get("layout").map(String::as_str) == Some("full");
        let estimated_weights =
            estimate_column_desired_widths(&tr_nodes, &declared_widths, num_cols);

        let (grid, font_scale, pad_h) =
            solve_table_column_widths(&estimated_weights, ctx.content_width_pt, is_full_layout);
        let pad_v = if font_scale < 0.85 { 3.5 } else { 5.0 };

        let mut active_vmerge: Vec<Option<(usize, usize, Option<Rgb>)>> = vec![None; num_cols];
        let mut covered_by_span: Vec<usize> = vec![0; num_cols];
        let mut out_rows = Vec::with_capacity(tr_nodes.len());
        let mut leading_header_streak = true;

        for row_children in &tr_nodes {
            let raw_cells: Vec<(&str, &BTreeMap<String, String>, &[ExportNode])> = row_children
                .iter()
                .filter_map(|c| match c {
                    ExportNode::Element {
                        name,
                        attrs: c_attrs,
                        children: c_children,
                    } if name == "th" || name == "td" => {
                        Some((name.as_str(), c_attrs, c_children.as_slice()))
                    }
                    _ => None,
                })
                .collect();

            let all_th = !raw_cells.is_empty() && raw_cells.iter().all(|(tag, _, _)| *tag == "th");
            if !all_th {
                leading_header_streak = false;
            }
            let is_header_row = leading_header_streak && all_th;

            let mut row_cells: Vec<Cell> = Vec::new();
            let mut raw_iter = raw_cells.into_iter();
            let mut col = 0usize;

            while col < num_cols {
                if let Some((rem, span, bg)) = active_vmerge.get_mut(col).and_then(Option::take) {
                    let eff_span = span.min(num_cols - col).max(1);
                    let cell_w: f32 = grid
                        .get(col..col + eff_span)
                        .map_or(28.0, |s| s.iter().sum());
                    row_cells.push(Cell {
                        props: CellProps {
                            width: Some(cell_w),
                            span: eff_span as u32,
                            vmerge: VMerge::Continue,
                            shading: bg,
                            margins: Some([pad_v, pad_h, pad_v, pad_h]),
                            ..CellProps::default()
                        },
                        blocks: vec![para_block(compact_empty_para())],
                        controls: Default::default(),
                    });
                    if rem > 1
                        && let Some(slot) = active_vmerge.get_mut(col)
                    {
                        *slot = Some((rem - 1, eff_span, bg));
                    }
                    let next_cov = rem.saturating_sub(1);
                    for k in (col + 1)..(col + eff_span) {
                        if let Some(cov) = covered_by_span.get_mut(k) {
                            *cov = next_cov;
                        }
                    }
                    col += eff_span;
                    continue;
                }

                if let Some(cov) = covered_by_span.get_mut(col)
                    && *cov > 0
                {
                    *cov -= 1;
                    col += 1;
                    continue;
                }

                if let Some((tag, c_attrs, c_children)) = raw_iter.next() {
                    let req_colspan = c_attrs
                        .get("colspan")
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or(1)
                        .max(1);
                    let max_free_span = (1..req_colspan.min(num_cols - col) + 1)
                        .take_while(|&step| {
                            let check_col = col + step - 1;
                            step == 1
                                || (active_vmerge.get(check_col).is_some_and(Option::is_none)
                                    && covered_by_span.get(check_col).copied().unwrap_or(0) == 0)
                        })
                        .last()
                        .unwrap_or(1);

                    let req_rowspan = c_attrs
                        .get("rowspan")
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or(1)
                        .max(1);

                    let explicit_bg = c_attrs.get("background").and_then(|hex| Rgb::parse(hex));
                    let shading =
                        explicit_bg.or_else(|| (tag == "th").then_some(Rgb(0xF8, 0xFA, 0xFC)));

                    let cell_w: f32 = grid
                        .get(col..col + max_free_span)
                        .map_or(28.0, |s| s.iter().sum());
                    let net_cell_w = (cell_w - 2.0 * pad_h).max(10.0);
                    let cell_ctx = ctx.enter_cell(net_cell_w, font_scale);

                    let mut cell_blocks = Vec::new();
                    self.compile_block_list(c_children, cell_ctx, depth + 1, &mut cell_blocks);

                    let cell_align = c_attrs.get("align").and_then(|a| parse_align(a));
                    for blk in &mut cell_blocks {
                        if let Block::Para(p) = Arc::make_mut(blk) {
                            if p.props.space_after.is_none() || p.props.space_after == Some(6.0) {
                                p.props.space_after = Some(2.0);
                            }
                            if let Some(al) = cell_align
                                && p.props.align.is_none()
                            {
                                p.props.align = Some(al);
                            }
                            if tag == "th" {
                                p.mark.bold = Some(true);
                                for run in &mut p.runs {
                                    if run.props.bold.is_none() {
                                        run.props.bold = Some(true);
                                    }
                                }
                            }
                        }
                    }
                    let hide_mark = finalize_cell_blocks(&mut cell_blocks);

                    if req_rowspan > 1 {
                        if let Some(slot) = active_vmerge.get_mut(col) {
                            *slot = Some((req_rowspan - 1, max_free_span, shading));
                        }
                        for k in (col + 1)..(col + max_free_span) {
                            if let Some(cov) = covered_by_span.get_mut(k) {
                                *cov = req_rowspan - 1;
                            }
                        }
                    }

                    row_cells.push(Cell {
                        props: CellProps {
                            width: Some(cell_w),
                            span: max_free_span as u32,
                            vmerge: if req_rowspan > 1 {
                                VMerge::Restart
                            } else {
                                VMerge::None
                            },
                            shading,
                            margins: Some([pad_v, pad_h, pad_v, pad_h]),
                            valign: Some(VAlign::Top),
                            hide_mark,
                            ..CellProps::default()
                        },
                        blocks: cell_blocks,
                        controls: Default::default(),
                    });
                    col += max_free_span;
                } else {
                    let cell_w = grid.get(col).copied().unwrap_or(28.0);
                    row_cells.push(Cell {
                        props: CellProps {
                            width: Some(cell_w),
                            span: 1,
                            margins: Some([pad_v, pad_h, pad_v, pad_h]),
                            ..CellProps::default()
                        },
                        blocks: vec![para_block(compact_empty_para())],
                        controls: Default::default(),
                    });
                    col += 1;
                }
            }

            out_rows.push(Row {
                props: RowProps {
                    header: is_header_row,
                    cant_split: is_header_row,
                    ..RowProps::default()
                },
                cells: row_cells,
                controls: Default::default(),
            });
        }

        let border = Border {
            style: BorderStyle::Single,
            width: 0.5,
            color: Some(Rgb(0xCB, 0xD5, 0xE1)),
            space: 0.0,
        };
        let total_w: f32 = grid.iter().sum();

        Some(Table {
            props: TableProps {
                width: Some(total_w),
                indent: (ctx.para_indent_left_pt > 0.0).then_some(ctx.para_indent_left_pt),
                fixed: true,
                borders: Some(Borders::all(border)),
                cell_margins: Some([pad_v, pad_h, pad_v, pad_h]),
                space_before: Some(6.0),
                space_after: Some(8.0),
                look: TableLook {
                    header_row: out_rows.first().is_some_and(|r| r.props.header),
                    banded_rows: false,
                    first_column: false,
                    ..TableLook::default()
                },
                ..TableProps::default()
            },
            grid,
            rows: out_rows,
            controls: Default::default(),
        })
    }
}

fn compute_logical_column_count(tr_nodes: &[&[ExportNode]]) -> usize {
    let mut active_spans: Vec<usize> = Vec::new();
    let mut max_cols = 0usize;

    for row_children in tr_nodes {
        let mut col = 0usize;
        let mut pending_spans: Vec<(usize, usize, usize)> = Vec::new();
        for child in *row_children {
            let ExportNode::Element { name, attrs, .. } = child else {
                continue;
            };
            if name != "th" && name != "td" {
                continue;
            }
            while active_spans.get(col).copied().unwrap_or(0) > 0 {
                col += 1;
            }
            if col >= MAX_TABLE_COLS {
                break;
            }
            let req_colspan = attrs
                .get("colspan")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(1)
                .clamp(1, MAX_TABLE_COLS);
            let span = (1..=req_colspan.min(MAX_TABLE_COLS - col))
                .take_while(|&step| {
                    let check_col = col + step - 1;
                    step == 1 || active_spans.get(check_col).copied().unwrap_or(0) == 0
                })
                .last()
                .unwrap_or(1);
            let rowspan = attrs
                .get("rowspan")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(1)
                .max(1);

            if rowspan > 1 {
                pending_spans.push((col, span, rowspan - 1));
            }
            col += span;
            if col >= MAX_TABLE_COLS {
                break;
            }
        }
        let occupied_end = active_spans
            .iter()
            .rposition(|&rem| rem > 0)
            .map_or(0, |idx| idx + 1);
        max_cols = max_cols.max(col.max(occupied_end).min(MAX_TABLE_COLS));
        for rem in &mut active_spans {
            *rem = rem.saturating_sub(1);
        }
        for (start, span, extra_rows) in pending_spans {
            let end_col = (start + span).min(MAX_TABLE_COLS);
            if active_spans.len() < end_col {
                active_spans.resize(end_col, 0);
            }
            for c in start..end_col {
                if let Some(slot) = active_spans.get_mut(c) {
                    *slot = (*slot).max(extra_rows);
                }
            }
        }
    }
    max_cols.min(MAX_TABLE_COLS)
}

fn parse_declared_widths(raw: Option<&str>) -> Vec<f32> {
    let Some(s) = raw else {
        return Vec::new();
    };
    s.split(',')
        .filter_map(|part| part.trim().parse::<u32>().ok())
        .map(|px| (px.clamp(1, 9999) as f32) * 0.75)
        .collect()
}

fn estimate_column_desired_widths(
    tr_nodes: &[&[ExportNode]],
    declared: &[f32],
    num_cols: usize,
) -> Vec<f32> {
    let mut est = vec![48.0f32; num_cols];
    for (i, &w) in declared.iter().take(num_cols).enumerate() {
        if let Some(slot) = est.get_mut(i) {
            *slot = w.max(24.0);
        }
    }
    if declared.len() >= num_cols {
        return est;
    }

    let mut active_spans = vec![0usize; num_cols];
    for row_children in tr_nodes.iter().take(24) {
        let mut col = 0usize;
        let mut pending_spans: Vec<(usize, usize, usize)> = Vec::new();
        for child in *row_children {
            let ExportNode::Element {
                name,
                attrs,
                children,
            } = child
            else {
                continue;
            };
            if name != "th" && name != "td" {
                continue;
            }
            while active_spans.get(col).copied().unwrap_or(0) > 0 {
                col += 1;
            }
            if col >= num_cols {
                break;
            }
            let req_colspan = attrs
                .get("colspan")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(1)
                .clamp(1, MAX_TABLE_COLS);
            let span = (1..=req_colspan.min(num_cols - col))
                .take_while(|&step| {
                    let check_col = col + step - 1;
                    step == 1 || active_spans.get(check_col).copied().unwrap_or(0) == 0
                })
                .last()
                .unwrap_or(1);
            let rowspan = attrs
                .get("rowspan")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(1)
                .max(1);
            if span == 1 && col >= declared.len() {
                let text = collect_plain_text_from_nodes(children);
                let longest_line = text
                    .lines()
                    .map(|l| {
                        l.chars()
                            .map(|c| if c.is_ascii() { 5.5f32 } else { 10.5f32 })
                            .sum::<f32>()
                    })
                    .fold(0.0f32, f32::max);
                let needed = (longest_line + 16.0).clamp(36.0, 180.0);
                if let Some(slot) = est.get_mut(col) {
                    *slot = slot.max(needed);
                }
            }
            if rowspan > 1 {
                pending_spans.push((col, span, rowspan - 1));
            }
            col += span;
            if col >= num_cols {
                break;
            }
        }
        for rem in &mut active_spans {
            *rem = rem.saturating_sub(1);
        }
        for (start, span, extra_rows) in pending_spans {
            for c in start..(start + span).min(num_cols) {
                if let Some(slot) = active_spans.get_mut(c) {
                    *slot = (*slot).max(extra_rows);
                }
            }
        }
    }
    est
}

/// Three-tier deterministic column width solver with water-filling floor relaxation.
fn solve_table_column_widths(
    desired: &[f32],
    avail_width_pt: f32,
    force_full: bool,
) -> (Vec<f32>, f32, f32) {
    let c = desired.len().max(1);
    let w_avail = avail_width_pt.max((c as f32) * 8.0);
    let sum_desired: f32 = desired.iter().sum::<f32>().max(1.0);

    if !force_full && sum_desired <= w_avail {
        return (desired.to_vec(), 1.0, 6.0);
    }

    let avg_col = w_avail / (c as f32);
    if avg_col >= 28.0 {
        let grid = waterfill_with_floor(desired, w_avail, 28.0);
        let ratio = w_avail / sum_desired;
        let (font_scale, pad_h) = if ratio < 0.75 {
            (8.5 / 10.5, 3.5)
        } else {
            (1.0, 5.5)
        };
        (grid, font_scale, pad_h)
    } else {
        let relaxed_floor = (0.65 * avg_col).clamp(8.0, avg_col);
        let grid = waterfill_with_floor(desired, w_avail, relaxed_floor);
        (grid, 7.5 / 10.5, 2.0)
    }
}

pub(super) fn waterfill_with_floor(weights: &[f32], target_total: f32, floor: f32) -> Vec<f32> {
    let n = weights.len();
    if n == 0 {
        return Vec::new();
    }
    let effective_floor = floor.min(target_total / (n as f32)).max(1.0);
    let mut out = vec![0.0f32; n];
    let mut locked = vec![false; n];

    for _ in 0..=n {
        let locked_count = locked.iter().filter(|&&b| b).count();
        let rem_total = (target_total - (locked_count as f32) * effective_floor).max(0.0);
        let rem_weight: f32 = weights
            .iter()
            .zip(locked.iter())
            .filter_map(|(&w, &is_locked)| (!is_locked).then_some(w.max(0.1)))
            .sum();

        if rem_weight <= 0.0 {
            for (slot, &is_locked) in out.iter_mut().zip(locked.iter()) {
                if !is_locked {
                    *slot = effective_floor;
                }
            }
            break;
        }

        let mut newly_locked = false;
        for ((slot, is_locked), &w) in out.iter_mut().zip(locked.iter_mut()).zip(weights.iter()) {
            if *is_locked {
                continue;
            }
            let share = rem_total * (w.max(0.1) / rem_weight);
            if share < effective_floor - 1e-3 {
                *slot = effective_floor;
                *is_locked = true;
                newly_locked = true;
            } else {
                *slot = share;
            }
        }
        if !newly_locked {
            break;
        }
    }
    out
}

pub(super) fn finalize_cell_blocks(blocks: &mut Vec<Arc<Block>>) -> bool {
    if blocks.is_empty() {
        blocks.push(para_block(compact_empty_para()));
        return false;
    }
    if matches!(blocks.last().map(Arc::as_ref), Some(Block::Table(_))) {
        blocks.push(para_block(compact_empty_para()));
        return true;
    }
    if let Some(last_blk) = blocks.last_mut()
        && let Block::Para(p) = Arc::make_mut(last_blk)
    {
        p.props.space_after = Some(0.0);
    }
    false
}

pub(super) fn compact_empty_para() -> Paragraph {
    let mut p = Paragraph::new();
    p.props.space_before = Some(0.0);
    p.props.space_after = Some(0.0);
    p.props.line_spacing = Some(LineSpacing::Multiple(1.0));
    p.mark.size = Some(2.0);
    p
}

pub(super) fn plain_table_look() -> TableLook {
    TableLook {
        header_row: false,
        total_row: false,
        banded_rows: false,
        first_column: false,
        last_column: false,
        banded_columns: false,
    }
}
