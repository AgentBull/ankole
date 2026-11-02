//! Sheet tabs: insert, delete, rename, reorder, and tab colour.

use std::sync::Arc;

use gridcraft_model::{Color, Sheet, Visibility, Workbook};

use super::edit::sheet_mut;
use super::{HexColor, Outcome};
use crate::Error;
use crate::doc::{next_sheet_id, require_sheet, used_ids};
use crate::ids::SheetId;
use crate::structure::rewrite_formulas;

/// Checks a sheet name like Excel, and also against the chart sheets GridCraft keeps for saving,
/// which share the workbook's name space.
fn check_name(wb: &Workbook, name: &str, except: Option<usize>) -> Result<(), Error> {
    wb.check_sheet_name(name, except).map_err(Error::Invalid)?;
    let mut chart_sheets = wb.preserved.iter().flat_map(|kept| kept.sheets.iter());
    if chart_sheets.any(|sheet| sheet.name.eq_ignore_ascii_case(name)) {
        return Err(Error::invalid(
            "That name is already taken. Try a different one.",
        ));
    }
    Ok(())
}

pub(super) fn insert(
    wb: &mut Workbook,
    sheet_id: &mut Option<SheetId>,
    name: &mut Option<String>,
    index: &mut Option<usize>,
) -> Result<Outcome, Error> {
    let id = match *sheet_id {
        Some(SheetId(id)) if id == 0 || used_ids(wb).any(|used| used == id) => {
            return Err(Error::invalid(format!("sheet_id {id} is already in use")));
        }
        Some(SheetId(id)) => id,
        None => next_sheet_id(wb)?,
    };
    let new_name = name
        .as_deref()
        .map_or_else(|| wb.next_sheet_name(), |name| name.trim().to_string());
    check_name(wb, &new_name, None)?;
    let at = index.unwrap_or(wb.sheets.len());
    if at > wb.sheets.len() {
        return Err(Error::invalid(format!("index {at} is past the last sheet")));
    }
    if wb.protected_structure {
        return Err(Error::invalid("the workbook structure is protected"));
    }
    let mut sheet = Sheet::new(new_name.clone());
    sheet.file_id = id;
    wb.sheets.insert(at, Arc::new(sheet));
    for defined in wb.names.iter_mut() {
        if let Some(scope) = defined.scope.as_mut()
            && *scope >= at
        {
            *scope += 1;
        }
    }
    // The active tab is view state saved in the file; it stays on the sheet it showed.
    if wb.active_sheet() >= at {
        wb.set_active_sheet(wb.active_sheet() + 1);
    }
    *sheet_id = Some(SheetId(id));
    *name = Some(new_name);
    *index = Some(at);
    Ok(Outcome::structural())
}

pub(super) fn delete(
    wb: &mut Workbook,
    sheet_id: SheetId,
    name: &mut Option<String>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    if wb.protected_structure {
        return Err(Error::invalid("the workbook structure is protected"));
    }
    let visible_left = wb
        .sheets
        .iter()
        .enumerate()
        .filter(|(i, sheet)| *i != index && sheet.visibility == Visibility::Visible)
        .count();
    if visible_left == 0 {
        return Err(Error::invalid(
            "A workbook must contain at least one visible worksheet.",
        ));
    }
    let order: Vec<String> = wb.sheets.iter().map(|sheet| sheet.name.clone()).collect();
    let deleted = wb.sheets.remove(index).name.clone();
    rewrite_formulas(
        wb,
        &|expr, _| gridcraft_formula::adjust::delete_sheet(expr, &deleted, &order),
        None,
    );
    wb.names.retain(|defined| defined.scope != Some(index));
    for defined in wb.names.iter_mut() {
        if let Some(scope) = defined.scope.as_mut()
            && *scope > index
        {
            *scope -= 1;
        }
    }
    let active = wb.active_sheet();
    if active > index || active >= wb.sheets.len() {
        wb.set_active_sheet(
            active
                .saturating_sub(1)
                .min(wb.sheets.len().saturating_sub(1)),
        );
    }
    *name = Some(deleted);
    Ok(Outcome::structural())
}

pub(super) fn rename(
    wb: &mut Workbook,
    sheet_id: SheetId,
    name: &mut String,
    old_name: &mut Option<String>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    if wb.protected_structure {
        return Err(Error::invalid("the workbook structure is protected"));
    }
    let new_name = name.trim().to_string();
    check_name(wb, &new_name, Some(index))?;
    let old = std::mem::replace(&mut sheet_mut(wb, index)?.name, new_name.clone());
    rewrite_formulas(
        wb,
        &|expr, _| gridcraft_formula::adjust::rename_sheet(expr, &old, &new_name),
        None,
    );
    // A PivotChart names its PivotTable as `Sheet!PivotTable`.
    let pivot_on_old = |link: &Option<String>| {
        link.as_deref()
            .and_then(split_pivot_link)
            .filter(|(sheet, _)| sheet.eq_ignore_ascii_case(&old))
    };
    for at in 0..wb.sheets.len() {
        if !wb.sheet(at).is_some_and(|sheet| {
            sheet
                .charts
                .iter()
                .any(|chart| pivot_on_old(&chart.pivot).is_some())
        }) {
            continue;
        }
        for chart in sheet_mut(wb, at)?.charts.iter_mut() {
            if let Some((_, pivot)) = pivot_on_old(&chart.pivot) {
                chart.pivot = Some(format!(
                    "{}!{pivot}",
                    gridcraft_core::quote_sheet(&new_name)
                ));
            }
        }
    }
    *name = new_name;
    *old_name = Some(old);
    Ok(Outcome::structural())
}

/// The sheet and PivotTable of a PivotChart link, ignoring a leading `[Book.xlsx]`.
fn split_pivot_link(link: &str) -> Option<(String, String)> {
    let link = link.trim();
    let link = link.strip_prefix('[').map_or(link, |rest| {
        rest.split_once(']').map_or(rest, |(_, rest)| rest)
    });
    let (sheet, pivot) = link.rsplit_once('!')?;
    let sheet = gridcraft_core::unquote_sheet(sheet.trim());
    (!sheet.is_empty() && !pivot.trim().is_empty()).then(|| (sheet, pivot.trim().to_string()))
}

pub(super) fn reorder(wb: &mut Workbook, sheet_id: SheetId, to: usize) -> Result<Outcome, Error> {
    let from = require_sheet(wb, sheet_id)?;
    if to >= wb.sheets.len() {
        return Err(Error::invalid(format!("index {to} is past the last sheet")));
    }
    if wb.protected_structure {
        return Err(Error::invalid("the workbook structure is protected"));
    }
    if from == to {
        return Ok(Outcome::default());
    }
    let active = wb.active_sheet();
    let sheet = wb.sheets.remove(from);
    wb.sheets.insert(to, sheet);
    // Sheet-scoped names and the active tab follow their sheets.
    let moved = |position: usize| match position {
        p if p == from => to,
        p if from < p && p <= to => p - 1,
        p if to <= p && p < from => p + 1,
        p => p,
    };
    for defined in wb.names.iter_mut() {
        if let Some(scope) = defined.scope.as_mut() {
            *scope = moved(*scope);
        }
    }
    wb.set_active_sheet(moved(active));
    Ok(Outcome::structural())
}

pub(super) fn tab_color(
    wb: &mut Workbook,
    sheet_id: SheetId,
    color: Option<HexColor>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    sheet_mut(wb, index)?.tab_color = color.map(|color| Color::Rgb(color.0));
    Ok(Outcome::default())
}
