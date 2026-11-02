//! Rebasing an incoming operation over the operations committed after its base revision.
//!
//! The incoming operation is transformed through each committed operation in revision order:
//! its target coordinates follow inserted, deleted, and moved lines and cells, and the formulas it
//! carries are rewritten the way GridCraft rewrites stored formulas. Whenever the result would be a
//! guess (the target was deleted, two structural edits overlap, the sheet is gone, or a concurrent
//! sort or merge reshuffled the target), the rebase refuses with a [`Conflict`] instead.

use std::collections::HashMap;

use gridcraft_core::RangeRef;
use gridcraft_formula::Expr;
use gridcraft_formula::adjust::{Edit, adjust, delete_sheet, rename_sheet};
use gridcraft_model::Workbook;

use crate::ids::SheetId;
use crate::ops::{Axis, Op, Scalar, Shift, shift_axis};
use crate::structure::map_range;
use crate::{ApplyError, Error};

/// Why an incoming operation cannot be rebased without guessing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Conflict {
    /// A concurrent operation deleted the cells, lines, or block the operation targets.
    TargetDeleted,
    /// The operation's own structural edit, or the block it writes, overlaps a concurrent
    /// structural edit.
    OverlappingStructuralEdit,
    /// A concurrent operation deleted the sheet.
    SheetDeleted,
    /// A concurrent sort or merge rearranged cells the operation touches.
    ConcurrentSortOrMerge,
}

impl Conflict {
    /// The wire name of the conflict.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Conflict::TargetDeleted => "target_deleted",
            Conflict::OverlappingStructuralEdit => "overlapping_structural_edit",
            Conflict::SheetDeleted => "sheet_deleted",
            Conflict::ConcurrentSortOrMerge => "concurrent_sort_or_merge",
        }
    }
}

/// Sheet names by `sheet_id` at one revision.
type Names = HashMap<SheetId, String>;

pub(crate) fn rebase(wb: &Workbook, mut op: Op, prior: &[Op]) -> Result<Op, ApplyError> {
    let mut names = names_before(wb, prior)?;
    for committed in prior {
        transform(&mut op, committed, &names).map_err(ApplyError::Conflict)?;
        advance_names(&mut names, committed);
    }
    Ok(op)
}

/// The sheet names at the base revision: the current names with the committed sheet operations
/// undone from the last to the first.
fn names_before(wb: &Workbook, prior: &[Op]) -> Result<Names, ApplyError> {
    let mut names: Names = wb
        .sheets
        .iter()
        .map(|sheet| (SheetId(sheet.file_id), sheet.name.clone()))
        .collect();
    let uncommitted =
        || ApplyError::Error(Error::invalid("prior_ops must hold committed operations"));
    for committed in prior.iter().rev() {
        match committed {
            Op::SheetInsert { sheet_id, .. } => {
                names.remove(&sheet_id.ok_or_else(uncommitted)?);
            }
            Op::SheetDelete { sheet_id, name } => {
                names.insert(*sheet_id, name.clone().ok_or_else(uncommitted)?);
            }
            Op::SheetRename {
                sheet_id, old_name, ..
            } => {
                names.insert(*sheet_id, old_name.clone().ok_or_else(uncommitted)?);
            }
            _ => {}
        }
    }
    Ok(names)
}

fn advance_names(names: &mut Names, committed: &Op) {
    match committed {
        Op::SheetInsert {
            sheet_id: Some(id),
            name: Some(name),
            ..
        }
        | Op::SheetRename {
            sheet_id: id, name, ..
        } => {
            names.insert(*id, name.clone());
        }
        Op::SheetDelete { sheet_id, .. } => {
            names.remove(sheet_id);
        }
        _ => {}
    }
}

/// A committed structural edit as GridCraft's reference adjustment sees it.
struct Structural {
    sheet_id: SheetId,
    edit: Edit,
    /// The sheet name the edit applies to, at that revision.
    target: String,
}

fn structural(committed: &Op, names: &Names) -> Option<Structural> {
    let name = |id: SheetId| names.get(&id).cloned().unwrap_or_default();
    let (sheet_id, edit) = match *committed {
        Op::LineInsert {
            sheet_id,
            axis,
            at,
            count,
        } => (
            sheet_id,
            Edit::Insert {
                axis: axis.grid(),
                at,
                count,
            },
        ),
        Op::LineDelete {
            sheet_id,
            axis,
            at,
            count,
        } => (
            sheet_id,
            Edit::Delete {
                axis: axis.grid(),
                at,
                count,
            },
        ),
        Op::CellsInsert {
            sheet_id,
            range,
            shift,
        } => (
            sheet_id,
            Edit::InsertCells {
                axis: shift_axis(shift).grid(),
                range: range.0,
            },
        ),
        Op::CellsDelete {
            sheet_id,
            range,
            shift,
        } => (
            sheet_id,
            Edit::DeleteCells {
                axis: shift_axis(shift).grid(),
                range: range.0,
            },
        ),
        Op::RangeMove {
            sheet_id,
            from,
            to_sheet_id,
            to_cell,
        } if sheet_id == to_sheet_id => (
            sheet_id,
            Edit::Move {
                from: from.0,
                to_row: to_cell.0.row,
                to_col: to_cell.0.col,
            },
        ),
        Op::RangeMove {
            sheet_id,
            from,
            to_sheet_id,
            to_cell,
        } => (
            sheet_id,
            Edit::MoveToSheet {
                from: from.0,
                to_sheet: name(to_sheet_id),
                to_row: to_cell.0.row,
                to_col: to_cell.0.col,
            },
        ),
        _ => return None,
    };
    Some(Structural {
        sheet_id,
        edit,
        target: name(sheet_id),
    })
}

fn transform(op: &mut Op, committed: &Op, names: &Names) -> Result<(), Conflict> {
    match committed {
        Op::SheetDelete { sheet_id, name } => {
            if op.sheet_id() == Some(*sheet_id)
                || matches!(op, Op::RangeMove { to_sheet_id, .. } if to_sheet_id == sheet_id)
            {
                return Err(Conflict::SheetDeleted);
            }
            let deleted = name.clone().unwrap_or_default();
            rewrite_formulas(op, names, &|expr, _| delete_sheet(expr, &deleted, &[]));
            Ok(())
        }
        Op::SheetRename {
            name,
            old_name: Some(old),
            ..
        } => {
            rewrite_formulas(op, names, &|expr, _| rename_sheet(expr, old, name));
            Ok(())
        }
        Op::RangeSort {
            sheet_id, range, ..
        }
        | Op::RangeMerge {
            sheet_id, range, ..
        } => {
            if footprint(op)
                .iter()
                .any(|(id, area)| id == sheet_id && area.intersects(&range.0))
            {
                return Err(Conflict::ConcurrentSortOrMerge);
            }
            Ok(())
        }
        _ => match structural(committed, names) {
            Some(edit) => {
                move_targets(op, &edit)?;
                rewrite_formulas(op, names, &|expr, host| {
                    adjust(expr, host, &edit.target, &edit.edit)
                });
                Ok(())
            }
            None => Ok(()),
        },
    }
}

/// Rewrites the formulas an operation carries: a `cell.set` input, `range.set_values` strings, and
/// validation formulas that start with `=`. `rewrite` receives the name of the sheet that holds
/// the formula.
fn rewrite_formulas(op: &mut Op, names: &Names, rewrite: &dyn Fn(Expr, &str) -> Expr) {
    let host = op
        .sheet_id()
        .and_then(|id| names.get(&id))
        .cloned()
        .unwrap_or_default();
    let fix = |text: &mut String| {
        let Some(body) = text.strip_prefix('=') else {
            return;
        };
        let Ok(expr) = gridcraft_formula::parse_closing_parens(body, gridcraft_formula::parse)
        else {
            return;
        };
        let before = gridcraft_formula::print(&expr);
        let after = gridcraft_formula::print(&rewrite(expr, &host));
        if after != before {
            *text = format!("={after}");
        }
    };
    match op {
        Op::CellSet { input, .. } => fix(input),
        Op::RangeSetValues { values, .. } => {
            for value in values.iter_mut().flatten().flatten() {
                if let Scalar::Text(text) = value {
                    fix(text);
                }
            }
        }
        Op::RangePaste { cells, .. } => {
            for input in cells
                .iter_mut()
                .flatten()
                .filter_map(|cell| cell.input.as_mut())
            {
                fix(input);
            }
        }
        Op::ValidationSet {
            rule: Some(rule), ..
        } => {
            fix(&mut rule.formula1);
            if let Some(formula2) = rule.formula2.as_mut() {
                fix(formula2);
            }
        }
        _ => {}
    }
}

/// Where a target range on `sheet_id` lands after a committed structural edit. A block moved on
/// its own sheet carries the targets it contains; a target it only partly covers, or a block moved
/// to another sheet, is a conflict.
fn map_target(sheet_id: SheetId, range: RangeRef, edit: &Structural) -> Result<RangeRef, Conflict> {
    if sheet_id != edit.sheet_id {
        return Ok(range);
    }
    match &edit.edit {
        Edit::Move { from, .. } if from.contains_range(&range) => {
            map_range(range, &edit.edit).ok_or(Conflict::TargetDeleted)
        }
        Edit::Move { from, .. } | Edit::MoveToSheet { from, .. } if from.intersects(&range) => {
            Err(Conflict::OverlappingStructuralEdit)
        }
        Edit::Move { .. } | Edit::MoveToSheet { .. } => Ok(range),
        other => map_range(range, other).ok_or(Conflict::TargetDeleted),
    }
}

/// Like [`map_target`] for targets whose shape must not change: a block of values or the block a
/// structural edit of its own shifts or moves.
fn map_block(sheet_id: SheetId, range: RangeRef, edit: &Structural) -> Result<RangeRef, Conflict> {
    let moved = map_target(sheet_id, range, edit)?;
    if (moved.height(), moved.width()) != (range.height(), range.width()) {
        return Err(Conflict::OverlappingStructuralEdit);
    }
    Ok(moved)
}

fn move_targets(op: &mut Op, edit: &Structural) -> Result<(), Conflict> {
    match op {
        Op::CellSet { sheet_id, cell, .. } | Op::CommentSet { sheet_id, cell, .. } => {
            cell.0 = map_target(*sheet_id, RangeRef::cell(cell.0), edit)?.start;
        }
        Op::RangeSetValues {
            sheet_id, range, ..
        } => range.0 = map_block(*sheet_id, range.0, edit)?,
        Op::RangeClear {
            sheet_id, range, ..
        }
        | Op::RangeFormat {
            sheet_id, range, ..
        }
        | Op::RangeMerge {
            sheet_id, range, ..
        }
        | Op::RangeUnmerge { sheet_id, range }
        | Op::RangeSort {
            sheet_id, range, ..
        }
        | Op::ValidationSet {
            sheet_id, range, ..
        }
        | Op::TableToggle {
            sheet_id, range, ..
        } => range.0 = map_target(*sheet_id, range.0, edit)?,
        Op::FilterSet {
            sheet_id,
            range: Some(range),
            ..
        } => range.0 = map_target(*sheet_id, range.0, edit)?,
        Op::CellsInsert {
            sheet_id, range, ..
        }
        | Op::CellsDelete {
            sheet_id, range, ..
        } => range.0 = map_block(*sheet_id, range.0, edit)?,
        Op::RangePaste {
            sheet_id, range, ..
        }
        | Op::RangeRestoreFormats {
            sheet_id, range, ..
        } => range.0 = map_block(*sheet_id, range.0, edit)?,
        Op::ImageInsert {
            sheet_id, anchor, ..
        }
        | Op::ImageUpdate {
            sheet_id, anchor, ..
        } => anchor.cell.0 = map_target(*sheet_id, RangeRef::cell(anchor.cell.0), edit)?.start,
        Op::CellPicture { sheet_id, cell, .. } | Op::ImageToCell { sheet_id, cell, .. } => {
            cell.0 = map_target(*sheet_id, RangeRef::cell(cell.0), edit)?.start;
        }
        Op::ImageFromCell {
            sheet_id,
            cell,
            anchor,
            ..
        } => {
            cell.0 = map_target(*sheet_id, RangeRef::cell(cell.0), edit)?.start;
            anchor.cell.0 = map_target(*sheet_id, RangeRef::cell(anchor.cell.0), edit)?.start;
        }
        Op::RangeFill {
            sheet_id,
            range,
            to,
            ..
        } => {
            range.0 = map_block(*sheet_id, range.0, edit)?;
            to.0 = map_block(*sheet_id, to.0, edit)?;
        }
        Op::RangeMove {
            sheet_id,
            from,
            to_sheet_id,
            to_cell,
        } => {
            from.0 = map_block(*sheet_id, from.0, edit)?;
            to_cell.0 = map_target(*to_sheet_id, RangeRef::cell(to_cell.0), edit)?.start;
        }
        Op::LineResize {
            sheet_id,
            axis,
            start,
            end,
            ..
        } => {
            let lines = lines(*axis, *start, *end);
            if *sheet_id == edit.sheet_id
                && matches!(edit.edit, Edit::Insert { axis: a, .. } | Edit::Delete { axis: a, .. } if a == axis.grid())
            {
                let moved = map_range(lines, &edit.edit).ok_or(Conflict::TargetDeleted)?;
                (*start, *end) = span(*axis, moved);
            }
        }
        Op::LineInsert {
            sheet_id, axis, at, ..
        } => {
            if *sheet_id == edit.sheet_id {
                *at = shift_insert(*axis, *at, &edit.edit)?;
            }
        }
        Op::LineDelete {
            sheet_id,
            axis,
            at,
            count,
        } => {
            if *sheet_id == edit.sheet_id {
                *at = shift_delete(*axis, *at, *count, &edit.edit)?;
            }
        }
        Op::FilterSet { range: None, .. }
        | Op::ImageDelete { .. }
        | Op::SheetFreeze { .. }
        | Op::SheetInsert { .. }
        | Op::SheetDelete { .. }
        | Op::SheetRename { .. }
        | Op::SheetReorder { .. }
        | Op::SheetTabColor { .. } => {}
    }
    Ok(())
}

fn lines(axis: Axis, start: u32, end: u32) -> RangeRef {
    match axis {
        Axis::Rows => RangeRef::rows(start, end),
        Axis::Cols => RangeRef::cols(start, end),
    }
}

fn span(axis: Axis, range: RangeRef) -> (u32, u32) {
    match axis {
        Axis::Rows => (range.start.row, range.end.row),
        Axis::Cols => (range.start.col, range.end.col),
    }
}

/// The committed edit as `(insert, at, count)` when it inserts or deletes lines on `axis`.
fn line_edit(axis: Axis, edit: &Edit) -> Option<(bool, u32, u32)> {
    match *edit {
        Edit::Insert { axis: a, at, count } if a == axis.grid() => Some((true, at, count)),
        Edit::Delete { axis: a, at, count } if a == axis.grid() => Some((false, at, count)),
        _ => None,
    }
}

/// An insertion point after a committed line edit on the same axis. Lines inserted at the same
/// point come first; a point inside a deleted block is ambiguous.
fn shift_insert(axis: Axis, at: u32, edit: &Edit) -> Result<u32, Conflict> {
    match line_edit(axis, edit) {
        Some((true, p_at, p_count)) if at >= p_at => Ok(at.saturating_add(p_count)),
        Some((false, p_at, p_count)) if at > p_at && at < p_at.saturating_add(p_count) => {
            Err(Conflict::OverlappingStructuralEdit)
        }
        Some((false, p_at, p_count)) if at >= p_at.saturating_add(p_count) => Ok(at - p_count),
        _ => Ok(at),
    }
}

/// The start of a deleted block after a committed line edit on the same axis. Lines inserted
/// inside the block, or a deletion that overlaps it, make the block ambiguous.
fn shift_delete(axis: Axis, at: u32, count: u32, edit: &Edit) -> Result<u32, Conflict> {
    let end = at.saturating_add(count);
    match line_edit(axis, edit) {
        Some((true, p_at, p_count)) if p_at <= at => Ok(at.saturating_add(p_count)),
        Some((true, p_at, _)) if p_at < end => Err(Conflict::OverlappingStructuralEdit),
        Some((false, p_at, p_count)) if p_at.saturating_add(p_count) <= at => Ok(at - p_count),
        Some((false, p_at, _)) if p_at < end => Err(Conflict::OverlappingStructuralEdit),
        _ => Ok(at),
    }
}

/// The cells an operation writes or reshapes, by sheet, for the concurrent sort and merge check.
fn footprint(op: &Op) -> Vec<(SheetId, RangeRef)> {
    use gridcraft_core::{CellRef, MAX_COLS, MAX_ROWS};
    match op {
        Op::CellSet { sheet_id, cell, .. } | Op::CommentSet { sheet_id, cell, .. } => {
            vec![(*sheet_id, RangeRef::cell(cell.0))]
        }
        Op::RangeSetValues {
            sheet_id, range, ..
        }
        | Op::RangeClear {
            sheet_id, range, ..
        }
        | Op::RangeFormat {
            sheet_id, range, ..
        }
        | Op::RangeMerge {
            sheet_id, range, ..
        }
        | Op::RangeUnmerge { sheet_id, range }
        | Op::RangeSort {
            sheet_id, range, ..
        }
        | Op::ValidationSet {
            sheet_id, range, ..
        }
        | Op::TableToggle {
            sheet_id, range, ..
        } => vec![(*sheet_id, range.0)],
        Op::RangeFill { sheet_id, to, .. } => vec![(*sheet_id, to.0)],
        Op::RangePaste {
            sheet_id, range, ..
        }
        | Op::RangeRestoreFormats {
            sheet_id, range, ..
        } => vec![(*sheet_id, range.0)],
        Op::CellPicture { sheet_id, cell, .. }
        | Op::ImageToCell { sheet_id, cell, .. }
        | Op::ImageFromCell { sheet_id, cell, .. } => vec![(*sheet_id, RangeRef::cell(cell.0))],
        Op::ImageInsert { .. } | Op::ImageUpdate { .. } | Op::ImageDelete { .. } => Vec::new(),
        Op::FilterSet {
            sheet_id, range, ..
        } => range.iter().map(|range| (*sheet_id, range.0)).collect(),
        Op::LineResize {
            sheet_id,
            axis,
            start,
            end,
            ..
        } => vec![(*sheet_id, lines(*axis, *start, *end))],
        Op::LineInsert {
            sheet_id, axis, at, ..
        } => vec![(*sheet_id, lines(*axis, *at, *at))],
        Op::LineDelete {
            sheet_id,
            axis,
            at,
            count,
        } => vec![(
            *sheet_id,
            lines(*axis, *at, at.saturating_add(*count).saturating_sub(1)),
        )],
        // Inserting or deleting cells moves everything after the range in the shift direction.
        Op::CellsInsert {
            sheet_id,
            range,
            shift,
        }
        | Op::CellsDelete {
            sheet_id,
            range,
            shift,
        } => {
            let r = range.0;
            let reach = match shift {
                Shift::Down | Shift::Up => {
                    RangeRef::new(r.start, CellRef::new(MAX_ROWS - 1, r.end.col))
                }
                Shift::Right | Shift::Left => {
                    RangeRef::new(r.start, CellRef::new(r.end.row, MAX_COLS - 1))
                }
            };
            vec![(*sheet_id, reach)]
        }
        Op::RangeMove {
            sheet_id,
            from,
            to_sheet_id,
            to_cell,
        } => {
            let end = to_cell
                .0
                .offset(
                    i64::from(from.0.height()) - 1,
                    i64::from(from.0.width()) - 1,
                )
                .unwrap_or(to_cell.0);
            vec![
                (*sheet_id, from.0),
                (*to_sheet_id, RangeRef::new(to_cell.0, end)),
            ]
        }
        Op::SheetFreeze { .. }
        | Op::SheetInsert { .. }
        | Op::SheetDelete { .. }
        | Op::SheetRename { .. }
        | Op::SheetReorder { .. }
        | Op::SheetTabColor { .. } => Vec::new(),
    }
}
