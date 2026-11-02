//! Structural edits: inserting and deleting lines and cells, moving blocks, and rewriting every
//! formula that refers to what moved.
//!
//! GridCraft implements these as engine commands bound to its editing session (selection,
//! clipboard, undo history). This module ports the parts that change the workbook, so the
//! canonical operations run without a session and the rebase uses the same coordinate mapping.

use std::sync::Arc;

use gridcraft_core::{CellRef, MAX_COLS, MAX_ROWS, RangeRef};
use gridcraft_formula::adjust::{Axis as GridAxis, Edit, adjust};
use gridcraft_formula::{Expr, RefKind, Reference, SheetSel};
use gridcraft_model::{Anchor, AnchorMode, Formula, LineInfo, Sheet, Table, TableColumn, Workbook};

use crate::Error;
use crate::doc::require_sheet;
use crate::ids::SheetId;
use crate::ops::edit::sheet_mut;
use crate::ops::{Axis, Outcome, Shift};

/// Where a range of the edited sheet lands after `edit`, or `None` when the edit deletes it.
pub(crate) fn map_range(range: RangeRef, edit: &Edit) -> Option<RangeRef> {
    let anchor = |cell: CellRef| gridcraft_formula::Anchor {
        row: cell.row,
        col: cell.col,
        row_abs: false,
        col_abs: false,
    };
    let expr = Expr::Ref(Reference {
        sheet: SheetSel::Current,
        kind: RefKind::Range(anchor(range.start), anchor(range.end)),
    });
    match adjust(expr, "S", "S", edit) {
        Expr::Ref(reference) => Some(reference.range()),
        _ => None,
    }
}

fn map_cell(cell: CellRef, edit: &Edit) -> Option<CellRef> {
    map_range(RangeRef::cell(cell), edit).map(|range| range.start)
}

/// Whether lines or cells are inserted or deleted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LineChange {
    Insert,
    Delete,
}

/// Where a moved block lands relative to the sheet it left.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Destination {
    SameSheet,
    OtherSheet,
}

/// Where line `line` lands after inserting or deleting `count` lines at `at`.
fn map_line(line: u32, at: u32, count: u32, change: LineChange) -> Option<u32> {
    if change == LineChange::Insert {
        if line >= at {
            line.checked_add(count)
        } else {
            Some(line)
        }
    } else if line < at {
        Some(line)
    } else if line >= at.saturating_add(count) {
        Some(line - count)
    } else {
        None
    }
}

/// Rewrites every stored formula with `rewrite(expr, host_sheet_name)`: cell formulas, defined
/// names (whose host is no sheet), chart series and sources, sparkline sources, and PivotTable
/// sources. `arrays` names the edited sheet and edit whose legacy array ranges move with it.
pub(crate) fn rewrite_formulas(
    wb: &mut Workbook,
    rewrite: &dyn Fn(Expr, &str) -> Expr,
    arrays: Option<(&str, &Edit)>,
) {
    for index in 0..wb.sheets.len() {
        let Some(sheet) = wb.sheet(index) else {
            continue;
        };
        let host = sheet.name.clone();
        let array_edit = arrays
            .filter(|(target, _)| host.eq_ignore_ascii_case(target))
            .map(|(_, edit)| edit);
        let mut updates: Vec<(CellRef, Formula)> = Vec::new();
        for (at, cell) in sheet.cells.iter() {
            let Some(formula) = &cell.formula else {
                continue;
            };
            let Some(expr) = formula.expr() else { continue };
            let expr = rewrite(expr, &host);
            let array = match (formula.array, array_edit) {
                (Some(range), Some(edit)) => map_range(range, edit),
                (array, _) => array,
            };
            let text = gridcraft_formula::print(&expr);
            if text != formula.text || array != formula.array {
                updates.push((
                    at,
                    Formula {
                        array,
                        dynamic: formula.dynamic,
                        ..Formula::from_expr(expr)
                    },
                ));
            }
        }
        let has_objects =
            !sheet.charts.is_empty() || !sheet.sparklines.is_empty() || !sheet.pivots.is_empty();
        if updates.is_empty() && !has_objects {
            continue;
        }
        let Some(sheet) = wb.sheet_mut(index) else {
            continue;
        };
        for (at, formula) in updates {
            if let Some(cell) = sheet.cells.get_mut(at) {
                cell.formula = Some(Arc::new(formula));
            }
        }
        let fix = |text: &str| match gridcraft_formula::parse(text) {
            Ok(expr) => gridcraft_formula::print(&rewrite(expr, &host)),
            Err(_) => text.to_string(),
        };
        for chart in sheet.charts.iter_mut() {
            // A chart whose source block was deleted loses the source, as in GridCraft.
            chart.source = chart
                .source
                .as_deref()
                .map(fix)
                .filter(|source| !source.contains("#REF!"));
            for series in chart.series.iter_mut() {
                series.values = fix(&series.values);
                series.categories = series.categories.as_deref().map(fix);
                series.name = series.name.as_deref().map(fix);
            }
        }
        for sparkline in sheet.sparklines.iter_mut() {
            sparkline.source = fix(&sparkline.source);
        }
        for pivot in sheet.pivots.iter_mut() {
            // Table and name sources keep their text unless the edit moves them.
            if let Ok(expr) = gridcraft_formula::parse(pivot.source.trim().trim_start_matches('='))
            {
                let before = gridcraft_formula::print(&expr);
                let after = gridcraft_formula::print(&rewrite(expr, &host));
                if after != before {
                    pivot.source = after;
                }
            }
        }
    }
    for defined in wb.names.iter_mut() {
        if let Ok(expr) = gridcraft_formula::parse_name(&defined.formula) {
            let text = gridcraft_formula::print(&rewrite(expr, "\u{0}"));
            if text != defined.formula {
                defined.formula = text;
            }
        }
    }
}

/// Rewrites every formula for a structural edit on the sheet named `target`.
fn rewrite_structural(wb: &mut Workbook, target: &str, edit: &Edit) {
    let moves_arrays = !matches!(edit, Edit::Move { .. } | Edit::MoveToSheet { .. });
    rewrite_formulas(
        wb,
        &|expr, host| adjust(expr, host, target, edit),
        moves_arrays.then_some((target, edit)),
    );
}

pub(crate) fn insert_lines(
    wb: &mut Workbook,
    sheet_id: SheetId,
    axis: Axis,
    at: u32,
    count: u32,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let limit = axis.limit();
    if count == 0 || at.checked_add(count).is_none_or(|end| end > limit) {
        return Err(Error::invalid(
            "the inserted lines must fit on the worksheet",
        ));
    }
    let sheet = sheet_mut(wb, index)?;
    if let Some(used) = sheet.used_range() {
        let last = if axis == Axis::Rows {
            used.end.row
        } else {
            used.end.col
        };
        if last >= at && u64::from(last) + u64::from(count) >= u64::from(limit) {
            return Err(Error::invalid(
                "inserting these lines would push nonblank cells off the worksheet",
            ));
        }
    }
    match axis {
        Axis::Rows => sheet.cells.shift_rows(at, i64::from(count)),
        Axis::Cols => sheet.cells.shift_cols(at, i64::from(count)),
    }
    shift_sheet_features(sheet, axis, at, count, LineChange::Insert);
    inherit_line_format(sheet, axis, at, count);
    let name = sheet.name.clone();
    rewrite_structural(
        wb,
        &name,
        &Edit::Insert {
            axis: axis.grid(),
            at,
            count,
        },
    );
    Ok(Outcome {
        changed: Vec::new(),
        structural: true,
    })
}

pub(crate) fn delete_lines(
    wb: &mut Workbook,
    sheet_id: SheetId,
    axis: Axis,
    at: u32,
    count: u32,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    if count == 0 || at.checked_add(count).is_none_or(|end| end > axis.limit()) {
        return Err(Error::invalid(
            "the deleted lines must lie on the worksheet",
        ));
    }
    let sheet = sheet_mut(wb, index)?;
    let block = match axis {
        Axis::Rows => RangeRef::rows(at, at + count - 1),
        Axis::Cols => RangeRef::cols(at, at + count - 1),
    };
    sheet.take_cells(block);
    match axis {
        Axis::Rows => sheet.cells.shift_rows(at + count, -i64::from(count)),
        Axis::Cols => sheet.cells.shift_cols(at + count, -i64::from(count)),
    }
    shift_sheet_features(sheet, axis, at, count, LineChange::Delete);
    let name = sheet.name.clone();
    rewrite_structural(
        wb,
        &name,
        &Edit::Delete {
            axis: axis.grid(),
            at,
            count,
        },
    );
    Ok(Outcome {
        changed: Vec::new(),
        structural: true,
    })
}

pub(crate) fn insert_cells(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    shift: Shift,
) -> Result<Outcome, Error> {
    let right = match shift {
        Shift::Down => false,
        Shift::Right => true,
        Shift::Up | Shift::Left => {
            return Err(Error::invalid("cells.insert shifts cells down or right"));
        }
    };
    let index = require_sheet(wb, sheet_id)?;
    let edit = Edit::InsertCells {
        axis: if right {
            GridAxis::Cols
        } else {
            GridAxis::Rows
        },
        range,
    };
    let sheet = sheet_mut(wb, index)?;
    check_table_shift(sheet, &edit)?;
    // The cells in the last `width` columns (or `height` rows) would be pushed off the sheet.
    let doomed = if right {
        RangeRef::new(
            CellRef::new(
                range.start.row,
                range.start.col.max(MAX_COLS.saturating_sub(range.width())),
            ),
            CellRef::new(range.end.row, MAX_COLS - 1),
        )
    } else {
        RangeRef::new(
            CellRef::new(
                range.start.row.max(MAX_ROWS.saturating_sub(range.height())),
                range.start.col,
            ),
            CellRef::new(MAX_ROWS - 1, range.end.col),
        )
    };
    if sheet
        .cells
        .iter_range(doomed)
        .any(|(_, cell)| cell.formula.is_some() || !cell.value.is_empty())
    {
        return Err(Error::invalid(
            "inserting these cells would push nonblank cells off the worksheet",
        ));
    }
    if right {
        sheet.cells.shift_cols_in_rows(
            range.start.row,
            range.end.row,
            range.start.col,
            i64::from(range.width()),
        );
    } else {
        sheet.cells.shift_rows_in_cols(
            range.start.col,
            range.end.col,
            range.start.row,
            i64::from(range.height()),
        );
    }
    shift_cell_features(sheet, &edit);
    let name = sheet.name.clone();
    rewrite_structural(wb, &name, &edit);
    Ok(Outcome {
        changed: Vec::new(),
        structural: true,
    })
}

pub(crate) fn delete_cells(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    shift: Shift,
) -> Result<Outcome, Error> {
    let left = match shift {
        Shift::Up => false,
        Shift::Left => true,
        Shift::Down | Shift::Right => {
            return Err(Error::invalid("cells.delete shifts cells up or left"));
        }
    };
    let index = require_sheet(wb, sheet_id)?;
    let edit = Edit::DeleteCells {
        axis: if left { GridAxis::Cols } else { GridAxis::Rows },
        range,
    };
    let sheet = sheet_mut(wb, index)?;
    check_table_shift(sheet, &edit)?;
    sheet.take_cells(range);
    if left {
        sheet.cells.shift_cols_in_rows(
            range.start.row,
            range.end.row,
            range.end.col + 1,
            -i64::from(range.width()),
        );
    } else {
        sheet.cells.shift_rows_in_cols(
            range.start.col,
            range.end.col,
            range.end.row + 1,
            -i64::from(range.height()),
        );
    }
    shift_cell_features(sheet, &edit);
    let name = sheet.name.clone();
    rewrite_structural(wb, &name, &edit);
    Ok(Outcome {
        changed: Vec::new(),
        structural: true,
    })
}

/// Cut and paste of `from` to `to_cell` on `to_sheet_id`. The destination block is replaced, and
/// notes, links, and merged areas inside `from` travel with it.
pub(crate) fn move_range(
    wb: &mut Workbook,
    sheet_id: SheetId,
    from: RangeRef,
    to_sheet_id: SheetId,
    to_cell: CellRef,
) -> Result<Outcome, Error> {
    let source = require_sheet(wb, sheet_id)?;
    let target = require_sheet(wb, to_sheet_id)?;
    let end = to_cell
        .offset(i64::from(from.height()) - 1, i64::from(from.width()) - 1)
        .ok_or_else(|| {
            Error::invalid("the moved block does not fit on the worksheet at to_cell")
        })?;
    let dest = RangeRef::new(to_cell, end);
    if source == target && dest == from {
        return Ok(Outcome::default());
    }
    let (dr, dc) = (
        i64::from(to_cell.row) - i64::from(from.start.row),
        i64::from(to_cell.col) - i64::from(from.start.col),
    );
    let shifted = |cell: CellRef| cell.offset(dr, dc).unwrap_or(cell);
    for (index, area) in [(source, from), (target, dest)] {
        let Some(sheet) = wb.sheet(index) else {
            continue;
        };
        if sheet
            .tables
            .iter()
            .any(|table| table.range.intersects(&area))
        {
            return Err(Error::invalid(
                "moving cells into or out of a table is not supported",
            ));
        }
    }
    let source_sheet = sheet_mut(wb, source)?;
    if source_sheet
        .merges
        .iter()
        .any(|merge| merge.intersects(&from) && !from.contains_range(merge))
    {
        return Err(Error::invalid("cannot move part of a merged area"));
    }
    let source_name = source_sheet.name.clone();
    let pictures: Vec<_> = source_sheet
        .cell_pictures
        .iter()
        .filter(|(at, _)| from.contains(**at))
        .map(|(at, p)| (shifted(*at), p.clone()))
        .collect();
    let comments: Vec<_> = source_sheet
        .comments
        .iter()
        .filter(|(at, _)| from.contains(**at))
        .map(|(at, c)| (shifted(*at), c.clone()))
        .collect();
    let links: Vec<_> = source_sheet
        .hyperlinks
        .iter()
        .filter(|(at, _)| from.contains(**at))
        .map(|(at, l)| (shifted(*at), l.clone()))
        .collect();
    let merges: Vec<RangeRef> = source_sheet
        .merges
        .iter()
        .filter(|merge| from.contains_range(merge))
        .map(|m| RangeRef::new(shifted(m.start), shifted(m.end)))
        .collect();
    let cells = source_sheet.take_cells(from);
    source_sheet.comments.retain(|at, _| !from.contains(*at));
    source_sheet.hyperlinks.retain(|at, _| !from.contains(*at));
    source_sheet
        .merges
        .retain(|merge| !from.contains_range(merge));
    let target_sheet = sheet_mut(wb, target)?;
    let mut changed: Vec<_> = target_sheet
        .take_cells(dest)
        .into_iter()
        .map(|(at, _)| (target, at))
        .collect();
    target_sheet.comments.retain(|at, _| !dest.contains(*at));
    target_sheet.hyperlinks.retain(|at, _| !dest.contains(*at));
    target_sheet.merges.retain(|merge| !merge.intersects(&dest));
    for (at, mut cell) in cells {
        if let Some(formula) = &cell.formula {
            let destination = if source == target {
                Destination::SameSheet
            } else {
                Destination::OtherSheet
            };
            cell.formula = Some(Arc::new(moved_formula(
                formula,
                &source_name,
                destination,
                dr,
                dc,
            )));
        }
        let to = shifted(at);
        target_sheet.cells.set(to, cell);
        changed.extend([(source, at), (target, to)]);
    }
    target_sheet.cell_pictures.extend(pictures);
    target_sheet.comments.extend(comments);
    target_sheet.hyperlinks.extend(links);
    target_sheet.merges.extend(merges);
    let edit = if source == target {
        Edit::Move {
            from,
            to_row: to_cell.row,
            to_col: to_cell.col,
        }
    } else {
        Edit::MoveToSheet {
            from,
            to_sheet: target_sheet.name.clone(),
            to_row: to_cell.row,
            to_col: to_cell.col,
        }
    };
    rewrite_structural(wb, &source_name, &edit);
    Ok(Outcome {
        changed,
        structural: true,
    })
}

/// A formula carried by a cut: references keep pointing where they did, so a formula moved to
/// another sheet names its original sheet on references that had none. The workbook-wide rewrite
/// that follows moves the references into the block itself.
fn moved_formula(
    formula: &Formula,
    source_name: &str,
    destination: Destination,
    dr: i64,
    dc: i64,
) -> Formula {
    let expr = formula.expr().map(|expr| {
        if destination == Destination::SameSheet {
            return expr;
        }
        expr.map(&mut |node| match node {
            Expr::Ref(mut reference) if reference.sheet == SheetSel::Current => {
                reference.sheet = SheetSel::Named(source_name.to_string());
                Expr::Ref(reference)
            }
            other => other,
        })
    });
    let mut moved = expr.map_or_else(|| formula.clone(), Formula::from_expr);
    moved.array = formula.array.and_then(|array| {
        Some(RangeRef::new(
            array.start.offset(dr, dc)?,
            array.end.offset(dr, dc)?,
        ))
    });
    moved.dynamic = formula.dynamic;
    moved
}

/// New lines take the format of the line before them, as Excel's "Format Same As Above".
fn inherit_line_format(sheet: &mut Sheet, axis: Axis, at: u32, count: u32) {
    let Some(previous) = at.checked_sub(1) else {
        return;
    };
    let lines = if axis == Axis::Rows {
        &mut sheet.rows
    } else {
        &mut sheet.cols
    };
    if let Some(info) = lines.get(&previous).copied() {
        for line in at..at + count {
            lines.insert(
                line,
                LineInfo {
                    hidden: false,
                    outline: 0,
                    collapsed: false,
                    ..info
                },
            );
        }
    }
}

/// The bottom-right line of a floating object's anchor and the offset of that corner inside it.
fn anchor_corner(sheet: &Sheet, anchor: &Anchor) -> (u32, u32, f32, f32) {
    let x =
        sheet.col_left(anchor.cell.col) + f64::from(anchor.dx) + f64::from(anchor.width.max(0.0));
    let y =
        sheet.row_top(anchor.cell.row) + f64::from(anchor.dy) + f64::from(anchor.height.max(0.0));
    let (col, row) = (sheet.col_at(x), sheet.row_at(y));
    (
        col,
        row,
        (x - sheet.col_left(col)) as f32,
        (y - sheet.row_top(row)) as f32,
    )
}

/// Moves one floating object for an inserted or deleted line according to its anchor mode:
/// absolute objects stay, "move only" objects follow their cell, and "move and size" objects are
/// re-fitted to the lines they land on. A deleted edge line collapses onto `at`.
fn shift_anchor(
    sheet: &Sheet,
    anchor: Anchor,
    corner: (u32, u32, f32, f32),
    axis: Axis,
    at: u32,
    map: &impl Fn(u32) -> Option<u32>,
) -> Anchor {
    if anchor.mode == AnchorMode::Absolute {
        return anchor;
    }
    let main = if axis == Axis::Rows {
        anchor.cell.row
    } else {
        anchor.cell.col
    };
    let moved = map(main).unwrap_or(at);
    let (row, col) = if axis == Axis::Rows {
        (moved, anchor.cell.col)
    } else {
        (anchor.cell.row, moved)
    };
    if anchor.mode == AnchorMode::MoveOnly {
        return Anchor {
            cell: CellRef::new(row, col),
            ..anchor
        };
    }
    let (far_col, far_row, far_dx, far_dy) = corner;
    let far = map(if axis == Axis::Rows { far_row } else { far_col }).unwrap_or(moved);
    let (end_row, end_col) = if axis == Axis::Rows {
        (far, far_col)
    } else {
        (far_row, far)
    };
    let x = sheet.col_left(col) + f64::from(anchor.dx);
    let y = sheet.row_top(row) + f64::from(anchor.dy);
    let width = (sheet.col_left(end_col) + f64::from(far_dx) - x).max(0.0) as f32;
    let height = (sheet.row_top(end_row) + f64::from(far_dy) - y).max(0.0) as f32;
    Anchor {
        cell: CellRef::new(row, col),
        width,
        height,
        ..anchor
    }
}

/// Moves everything positioned on the sheet for an inserted or deleted line.
fn shift_sheet_features(sheet: &mut Sheet, axis: Axis, at: u32, count: u32, change: LineChange) {
    let map = |line: u32| map_line(line, at, count, change);
    let edit = if change == LineChange::Insert {
        Edit::Insert {
            axis: axis.grid(),
            at,
            count,
        }
    } else {
        Edit::Delete {
            axis: axis.grid(),
            at,
            count,
        }
    };
    let map_cell_line = |cell: CellRef| match axis {
        Axis::Rows => map(cell.row).map(|row| CellRef::new(row, cell.col)),
        Axis::Cols => map(cell.col).map(|col| CellRef::new(cell.row, col)),
    };
    let corners: Vec<_> = floating_anchors(sheet)
        .map(|anchor| anchor_corner(sheet, &anchor))
        .collect();
    let limit = axis.limit();
    let lines = if axis == Axis::Rows {
        &mut sheet.rows
    } else {
        &mut sheet.cols
    };
    *lines = std::mem::take(lines)
        .into_iter()
        .filter_map(|(line, info)| {
            map(line)
                .filter(|line| *line < limit)
                .map(|line| (line, info))
        })
        .collect();
    shift_ranges(sheet, &edit);
    for table in sheet.tables.iter_mut() {
        match map_range(table.range, &edit) {
            Some(range) => {
                if axis == Axis::Cols {
                    shift_table_columns(table, at, count, change);
                }
                table.range = range;
            }
            None => table.range = RangeRef::default(),
        }
    }
    sheet
        .tables
        .retain(|table| table.range != RangeRef::default() && !table.columns.is_empty());
    shift_cell_maps(sheet, &map_cell_line);
    // New anchors are measured against the shifted grid, then written back.
    let anchors: Vec<Anchor> = floating_anchors(sheet)
        .zip(corners)
        .map(|(anchor, corner)| shift_anchor(sheet, anchor, corner, axis, at, &map))
        .collect();
    let slots = sheet
        .charts
        .iter_mut()
        .map(|o| &mut o.anchor)
        .chain(sheet.images.iter_mut().map(|o| &mut o.anchor))
        .chain(sheet.shapes.iter_mut().map(|o| &mut o.anchor));
    for (slot, anchor) in slots.zip(anchors) {
        *slot = anchor;
    }
    sheet
        .sparklines
        .retain_mut(|sparkline| match map_cell_line(sparkline.cell) {
            Some(cell) => {
                sparkline.cell = cell;
                true
            }
            None => false,
        });
    for pivot in sheet.pivots.iter_mut() {
        pivot.anchor = map_cell_line(pivot.anchor).unwrap_or(match axis {
            Axis::Rows => CellRef::new(at, pivot.anchor.col),
            Axis::Cols => CellRef::new(pivot.anchor.row, at),
        });
        pivot.last_range = pivot.last_range.and_then(|range| map_range(range, &edit));
    }
}

fn floating_anchors(sheet: &Sheet) -> impl Iterator<Item = Anchor> + '_ {
    sheet
        .charts
        .iter()
        .map(|o| o.anchor)
        .chain(sheet.images.iter().map(|o| o.anchor))
        .chain(sheet.shapes.iter().map(|o| o.anchor))
}

/// Moves the range-valued features: merged areas, conditional formats, validations, protected
/// edit ranges, the AutoFilter, and the print area.
fn shift_ranges(sheet: &mut Sheet, edit: &Edit) {
    sheet.merges = sheet
        .merges
        .iter()
        .filter_map(|merge| map_range(*merge, edit))
        .filter(|merge| !merge.is_single())
        .collect();
    for format in sheet.cond_formats.iter_mut() {
        format.ranges = format
            .ranges
            .iter()
            .filter_map(|range| map_range(*range, edit))
            .collect();
    }
    sheet
        .cond_formats
        .retain(|format| !format.ranges.is_empty());
    for validation in sheet.validations.iter_mut() {
        validation.ranges = validation
            .ranges
            .iter()
            .filter_map(|range| map_range(*range, edit))
            .collect();
    }
    sheet
        .validations
        .retain(|validation| !validation.ranges.is_empty());
    for edit_range in sheet.edit_ranges.iter_mut() {
        edit_range.ranges = edit_range
            .ranges
            .iter()
            .filter_map(|range| map_range(*range, edit))
            .collect();
    }
    sheet
        .edit_ranges
        .retain(|edit_range| !edit_range.ranges.is_empty());
    if let Some(filter) = sheet.autofilter.as_mut() {
        match map_range(filter.range, edit) {
            Some(range) => filter.range = range,
            None => sheet.autofilter = None,
        }
    }
    if let Some(area) = sheet.print.print_area {
        sheet.print.print_area = map_range(area, edit);
    }
}

/// Moves the cell-keyed features: cell pictures, notes, and hyperlinks.
fn shift_cell_maps(sheet: &mut Sheet, map: &impl Fn(CellRef) -> Option<CellRef>) {
    sheet.cell_pictures = std::mem::take(&mut sheet.cell_pictures)
        .into_iter()
        .filter_map(|(at, v)| map(at).filter(CellRef::is_valid).map(|at| (at, v)))
        .collect();
    sheet.comments = std::mem::take(&mut sheet.comments)
        .into_iter()
        .filter_map(|(at, v)| map(at).map(|at| (at, v)))
        .collect();
    sheet.hyperlinks = std::mem::take(&mut sheet.hyperlinks)
        .into_iter()
        .filter_map(|(at, v)| map(at).map(|at| (at, v)))
        .collect();
}

/// Moves what inserting or deleting cells moves along with them.
fn shift_cell_features(sheet: &mut Sheet, edit: &Edit) {
    shift_ranges(sheet, edit);
    for table in sheet.tables.iter_mut() {
        // Cells inserted or deleted across a table's full height add or remove table columns.
        if let Edit::InsertCells {
            axis: GridAxis::Cols,
            range,
        }
        | Edit::DeleteCells {
            axis: GridAxis::Cols,
            range,
        } = *edit
            && range.start.row <= table.range.start.row
            && range.end.row >= table.range.end.row
        {
            shift_table_columns(
                table,
                range.start.col,
                range.width(),
                if matches!(edit, Edit::InsertCells { .. }) {
                    LineChange::Insert
                } else {
                    LineChange::Delete
                },
            );
        }
        table.range = map_range(table.range, edit).unwrap_or_default();
    }
    sheet
        .tables
        .retain(|table| table.range != RangeRef::default() && !table.columns.is_empty());
    shift_cell_maps(sheet, &|cell| map_cell(cell, edit));
    for sparkline in sheet.sparklines.iter_mut() {
        if let Some(cell) = map_cell(sparkline.cell, edit) {
            sparkline.cell = cell;
        }
    }
}

/// Columns inserted inside a table become new table columns with unused names; deleted columns
/// leave it.
fn shift_table_columns(table: &mut Table, at: u32, count: u32, change: LineChange) {
    if change == LineChange::Insert {
        if at > table.range.start.col && at <= table.range.end.col {
            let position = (at - table.range.start.col) as usize;
            let mut n = table.columns.len();
            for k in 0..count as usize {
                let name = loop {
                    n += 1;
                    let name = format!("Column{n}");
                    if !table
                        .columns
                        .iter()
                        .any(|column| column.name.eq_ignore_ascii_case(&name))
                    {
                        break name;
                    }
                };
                let column = TableColumn {
                    name,
                    totals: Default::default(),
                    totals_label: None,
                    formula: None,
                    unique_name: None,
                    xml: None,
                };
                table
                    .columns
                    .insert((position + k).min(table.columns.len()), column);
            }
        }
        return;
    }
    let lo = at.max(table.range.start.col);
    let hi = at.saturating_add(count).min(table.range.end.col + 1);
    if hi > lo {
        let (a, b) = (
            (lo - table.range.start.col) as usize,
            (hi - table.range.start.col) as usize,
        );
        if b <= table.columns.len() {
            table.columns.drain(a..b);
        }
    }
}

/// Like Excel, inserting or deleting cells never shifts part of a table: cells shifted up or down
/// must hold whole table columns, cells shifted left or right whole table rows, and a delete never
/// takes a table's header row without the whole table.
fn check_table_shift(sheet: &Sheet, edit: &Edit) -> Result<(), Error> {
    let (axis, range, delete) = match *edit {
        Edit::InsertCells { axis, range } => (axis, range, false),
        Edit::DeleteCells { axis, range } => (axis, range, true),
        _ => return Ok(()),
    };
    for table in &sheet.tables {
        let t = table.range;
        let allowed = match axis {
            GridAxis::Rows => {
                let moves = t.end.row >= range.start.row
                    && t.start.col <= range.end.col
                    && t.end.col >= range.start.col;
                let header_alone = delete
                    && table.header_row
                    && range.start.row <= t.start.row
                    && range.end.row >= t.start.row
                    && range.end.row < t.end.row;
                !moves
                    || (range.start.col <= t.start.col
                        && range.end.col >= t.end.col
                        && !header_alone)
            }
            GridAxis::Cols => {
                let moves = t.end.col >= range.start.col
                    && t.start.row <= range.end.row
                    && t.end.row >= range.start.row;
                !moves || (range.start.row <= t.start.row && range.end.row >= t.end.row)
            }
        };
        if !allowed {
            return Err(Error::invalid(
                "This operation isn't allowed: it would shift cells in a table on your worksheet.",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use gridcraft_core::{CellRef, RangeRef};
    use gridcraft_formula::adjust::{Axis, Edit};

    use super::{LineChange, map_line, map_range};

    #[test]
    fn ranges_follow_line_edits() {
        let b2_d5 = RangeRef::new(CellRef::new(1, 1), CellRef::new(4, 3));
        assert_eq!(
            map_range(
                b2_d5,
                &Edit::Insert {
                    axis: Axis::Rows,
                    at: 0,
                    count: 2
                }
            ),
            Some(RangeRef::new(CellRef::new(3, 1), CellRef::new(6, 3)))
        );
        assert_eq!(
            map_range(
                b2_d5,
                &Edit::Delete {
                    axis: Axis::Rows,
                    at: 1,
                    count: 4
                }
            ),
            None
        );
        assert_eq!(map_line(5, 2, 3, LineChange::Delete), Some(2));
        assert_eq!(map_line(3, 2, 3, LineChange::Delete), None);
    }
}
