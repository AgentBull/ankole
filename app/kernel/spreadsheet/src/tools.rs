//! The reads an editor makes around its data tools: the values a filter column offers, whether
//! typed input passes a cell's validation, and where a text occurs in the workbook.

use std::collections::BTreeMap;

use gridcraft_core::{CellRef, RangeRef, Value, sort_compare};
use gridcraft_engine::cmd::data::check_validation;
use gridcraft_model::{ErrorStyle, FilterCriterion};
use serde::{Deserialize, Serialize};

use crate::Error;
use crate::doc::{SpreadsheetDoc, require_sheet, sheet_by_id};
use crate::ids::SheetId;
use crate::view::{cell_input_at, display_text};

/// The most matches a search reports.
pub const MAX_FIND_MATCHES: usize = 1_000;

/// One value a filter column offers.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FilterValue {
    /// The value as its cells show it; empty for the blank entry.
    pub text: String,
    /// Whether this entry stands for the blank cells of the column.
    pub blank: bool,
    /// Whether the current criteria of the column show rows with this value.
    pub selected: bool,
}

/// The distinct values of column `col` inside the sheet's filter range, sorted as a sort would
/// order them, with the blank entry last when the column has blank cells. A column without a
/// criterion shows every value.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet, a sheet without a filter, or a column outside
/// the filter range.
pub fn filter_values(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    col: u32,
) -> Result<Vec<FilterValue>, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let filter = sheet
        .autofilter
        .as_ref()
        .ok_or_else(|| Error::invalid("the sheet has no filter"))?;
    if !(filter.range.start.col..=filter.range.end.col).contains(&col) {
        return Err(Error::invalid("the column lies outside the filter range"));
    }
    let criterion = filter
        .criteria
        .iter()
        .find(|(offset, _)| filter.range.start.col + offset == col)
        .map(|(_, criterion)| criterion);
    let selected = |text: &str, blank: bool| match criterion {
        Some(FilterCriterion::Values { values, blanks }) => {
            if blank {
                *blanks
            } else {
                values.iter().any(|value| value.eq_ignore_ascii_case(text))
            }
        }
        _ => true,
    };
    let body = RangeRef::new(
        CellRef::new(filter.range.start.row + 1, col),
        CellRef::new(filter.range.end.row, col),
    );
    let mut seen: BTreeMap<String, Value> = BTreeMap::new();
    let mut stored = 0u64;
    let mut blank = false;
    for (at, _) in sheet.cells.iter_range(body) {
        stored += 1;
        let text = display_text(wb, sheet, at);
        if text.is_empty() {
            blank = true;
        } else {
            seen.entry(text).or_insert_with(|| sheet.value(at));
        }
    }
    blank |= stored < body.count();
    let mut values: Vec<(String, Value)> = seen.into_iter().collect();
    values.sort_by(|(text_a, a), (text_b, b)| sort_compare(a, b).then_with(|| text_a.cmp(text_b)));
    let mut list: Vec<FilterValue> = values
        .into_iter()
        .map(|(text, _)| FilterValue {
            selected: selected(&text, false),
            text,
            blank: false,
        })
        .collect();
    if blank {
        list.push(FilterValue {
            text: String::new(),
            blank: true,
            selected: selected("", true),
        });
    }
    Ok(list)
}

/// Why typed input fails a cell's validation, and how firmly the rule rejects it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ValidationFailure {
    /// The rule's error message, or a general one when the rule has none.
    pub message: String,
    /// `stop` rejects the input; `warning` and `information` let the author keep it.
    pub style: &'static str,
}

/// Checks `input` against the validation of the A1 cell `cell`: `None` when the cell has no rule
/// or the input passes. A formula passes unchecked, because its value is not known before it is
/// committed.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet or an invalid cell.
pub fn validate_input(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    cell: &str,
    input: &str,
) -> Result<Option<ValidationFailure>, Error> {
    let wb = doc.workbook();
    let index = require_sheet(wb, sheet_id)?;
    let at = CellRef::parse(cell)
        .filter(CellRef::is_valid)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{cell}`")))?;
    if input.starts_with('=') {
        return Ok(None);
    }
    Ok(
        check_validation(wb, index, at, input).map(|(validation, message)| ValidationFailure {
            message,
            style: match validation.error_style {
                ErrorStyle::Stop => "stop",
                ErrorStyle::Warning => "warning",
                ErrorStyle::Information => "information",
            },
        }),
    )
}

/// How a search compares cells with its query.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct FindOptions {
    /// Whether letter case must match.
    pub match_case: bool,
    /// Whether the whole cell text must equal the query, rather than contain it.
    pub whole_cell: bool,
    /// Whether to search the text a cell editor shows, formulas included, instead of the
    /// displayed values.
    pub formulas: bool,
}

/// One cell a search found.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct FindMatch {
    /// The sheet the cell is on.
    pub sheet_id: SheetId,
    /// The cell, in A1 form.
    pub cell: String,
    /// The text that matched.
    pub text: String,
}

/// The cells whose text matches `query`, on one sheet or on every sheet in tab order, in row-major
/// order, up to [`MAX_FIND_MATCHES`].
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an empty query or an unknown sheet.
pub fn find(
    doc: &SpreadsheetDoc,
    sheet_id: Option<SheetId>,
    query: &str,
    options: FindOptions,
) -> Result<Vec<FindMatch>, Error> {
    if query.is_empty() {
        return Err(Error::invalid("the search text is empty"));
    }
    let wb = doc.workbook();
    let sheets: Vec<(SheetId, &gridcraft_model::Sheet)> = match sheet_id {
        Some(id) => vec![(id, sheet_by_id(wb, id)?)],
        None => wb
            .sheets
            .iter()
            .map(|sheet| (SheetId(sheet.file_id), sheet.as_ref()))
            .collect(),
    };
    let wanted = if options.match_case {
        query.to_string()
    } else {
        query.to_lowercase()
    };
    let matches = |text: &str| {
        let text = if options.match_case {
            text.to_string()
        } else {
            text.to_lowercase()
        };
        if options.whole_cell {
            text == wanted
        } else {
            text.contains(&wanted)
        }
    };
    let mut found = Vec::new();
    for (id, sheet) in sheets {
        for (at, _) in sheet.cells.iter() {
            let text = if options.formulas {
                cell_input_at(wb, sheet, at)
            } else {
                display_text(wb, sheet, at)
            };
            if matches(&text) {
                found.push(FindMatch {
                    sheet_id: id,
                    cell: at.a1(),
                    text,
                });
                if found.len() >= MAX_FIND_MATCHES {
                    return Ok(found);
                }
            }
        }
    }
    Ok(found)
}
