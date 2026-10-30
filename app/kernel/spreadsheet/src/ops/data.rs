//! Sorting, filtering, data validation, and tables.

use std::cmp::Ordering;
use std::sync::Arc;

use gridcraft_core::{CellRef, RangeRef, Value, sort_compare};
use gridcraft_model::{
    AutoFilter, CfOperator, FilterCriterion, Formula, Sheet, Table, TableColumn, Validation,
    Workbook,
};

use super::edit::sheet_mut;
use super::{
    FilterColumn, Outcome, SortKey, ValidationKind, ValidationOperator, ValidationRule, check_size,
};
use crate::Error;
use crate::doc::require_sheet;
use crate::view::display_text;

pub(super) fn sort(
    wb: &mut Workbook,
    sheet_id: u32,
    range: RangeRef,
    keys: &[SortKey],
    header: bool,
) -> Result<Outcome, Error> {
    if keys.is_empty() || keys.len() > 64 {
        return Err(Error::invalid("range.sort needs 1 to 64 keys"));
    }
    if keys
        .iter()
        .any(|key| !(range.start.col..=range.end.col).contains(&key.col.0))
    {
        return Err(Error::invalid(
            "every sort key column must lie inside the range",
        ));
    }
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    // Rows past the last stored cell are empty and would stay in place, so they are left out.
    let first = range.start.row + u32::from(header);
    let last = sheet
        .used_range()
        .map_or(0, |used| used.end.row)
        .min(range.end.row);
    if first >= last {
        return Ok(Outcome::default());
    }
    let body = RangeRef::new(
        CellRef::new(first, range.start.col),
        CellRef::new(last, range.end.col),
    );
    check_size(body, "range.sort")?;
    if sheet.merges.iter().any(|merge| merge.intersects(&body)) {
        return Err(Error::invalid("a range with merged cells cannot be sorted"));
    }
    let rows: Vec<Vec<Value>> = (first..=last)
        .map(|row| {
            keys.iter()
                .map(|key| sheet.value(CellRef::new(row, key.col.0)))
                .collect()
        })
        .collect();
    let mut order: Vec<u32> = (0..=last - first).collect();
    order.sort_by(|&a, &b| {
        for (position, key) in keys.iter().enumerate() {
            let (Some(va), Some(vb)) = (
                rows.get(a as usize).and_then(|r| r.get(position)),
                rows.get(b as usize).and_then(|r| r.get(position)),
            ) else {
                continue;
            };
            // Blanks sort last in either direction, as in Excel.
            let ordering = match (va.is_empty(), vb.is_empty()) {
                (true, true) => Ordering::Equal,
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                _ if key.descending => sort_compare(va, vb).reverse(),
                _ => sort_compare(va, vb),
            };
            if ordering != Ordering::Equal {
                return ordering;
            }
        }
        Ordering::Equal
    });
    if order
        .iter()
        .enumerate()
        .all(|(position, &source)| position as u32 == source)
    {
        return Ok(Outcome::default());
    }
    move_rows(sheet, index, body, &order)
}

/// Rewrites the rows of `body` so that row `i` holds what row `order[i]` held: cells (formulas
/// adjusted for relative references), pictures, notes, links, and row sizes.
fn move_rows(
    sheet: &mut Sheet,
    index: usize,
    body: RangeRef,
    order: &[u32],
) -> Result<Outcome, Error> {
    let row_of = |offset: u32| body.start.row + offset;
    let mut cells = Vec::new();
    let mut pictures = Vec::new();
    let mut comments = Vec::new();
    let mut links = Vec::new();
    let mut heights = Vec::new();
    for (to, &from) in order.iter().enumerate() {
        let (src_row, dst_row) = (row_of(from), row_of(to as u32));
        for (col, cell) in sheet.cells.row(src_row, body.start.col, body.end.col) {
            let mut cell = cell.clone();
            if let Some(formula) = &cell.formula
                && let Some(expr) = formula.expr()
            {
                let expr = gridcraft_formula::adjust::shift_relative(
                    expr,
                    i64::from(dst_row) - i64::from(src_row),
                    0,
                );
                cell.formula = Some(Arc::new(Formula {
                    dynamic: formula.dynamic,
                    ..Formula::from_expr(expr)
                }));
            }
            cells.push((CellRef::new(dst_row, col), cell));
        }
        for col in body.start.col..=body.end.col {
            let (src, dst) = (CellRef::new(src_row, col), CellRef::new(dst_row, col));
            pictures.extend(sheet.cell_pictures.get(&src).map(|p| (dst, p.clone())));
            comments.extend(sheet.comments.get(&src).map(|c| (dst, c.clone())));
            links.extend(sheet.hyperlinks.get(&src).map(|l| (dst, l.clone())));
        }
        heights.push((dst_row, sheet.rows.get(&src_row).copied()));
    }
    let mut changed: Vec<_> = sheet
        .take_cells(body)
        .into_iter()
        .map(|(at, _)| (index, at))
        .collect();
    sheet.comments.retain(|at, _| !body.contains(*at));
    sheet.hyperlinks.retain(|at, _| !body.contains(*at));
    for (at, cell) in cells {
        sheet.cells.set(at, cell);
        changed.push((index, at));
    }
    sheet.cell_pictures.extend(pictures);
    sheet.comments.extend(comments);
    sheet.hyperlinks.extend(links);
    for (row, info) in heights {
        match info {
            Some(info) => sheet.rows.insert(row, info),
            None => sheet.rows.remove(&row),
        };
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

pub(super) fn filter(
    wb: &mut Workbook,
    sheet_id: u32,
    range: Option<RangeRef>,
    columns: &[FilterColumn],
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    if let Some(range) = range {
        if range.height() < 2 || range.is_full_cols() {
            return Err(Error::invalid(
                "a filter range needs a header row, data rows, and a last row",
            ));
        }
        check_size(range, "filter.set")?;
        if columns
            .iter()
            .any(|column| !(range.start.col..=range.end.col).contains(&column.col.0))
        {
            return Err(Error::invalid(
                "every filter column must lie inside the range",
            ));
        }
    } else if !columns.is_empty() {
        return Err(Error::invalid("removing a filter takes no columns"));
    }
    let sheet = wb
        .sheet(index)
        .ok_or_else(|| Error::invalid("the sheet disappeared during the operation"))?;
    // Rows the previous filter hid come back; rows hidden by hand stay hidden.
    let unfiltered: Vec<u32> = sheet.autofilter.as_ref().map_or_else(Vec::new, |previous| {
        (previous.range.start.row + 1..=previous.range.end.row)
            .filter(|row| sheet.is_row_filtered(*row))
            .collect()
    });
    let shown = |row: u32| {
        columns.iter().all(|column| {
            let text = display_text(wb, sheet, CellRef::new(row, column.col.0)).to_lowercase();
            if text.is_empty() {
                column.blanks
            } else {
                column
                    .values
                    .iter()
                    .any(|value| value.to_lowercase() == text)
            }
        })
    };
    let hidden: Vec<u32> = range.map_or_else(Vec::new, |range| {
        (range.start.row + 1..=range.end.row)
            .filter(|row| !shown(*row))
            .collect()
    });
    let sheet = sheet_mut(wb, index)?;
    for row in unfiltered {
        if let Some(info) = sheet.rows.get_mut(&row) {
            info.hidden = false;
        }
    }
    for row in hidden {
        sheet.rows.entry(row).or_default().hidden = true;
    }
    sheet.autofilter = range.map(|range| {
        let criteria = columns
            .iter()
            .map(|column| {
                (
                    column.col.0 - range.start.col,
                    FilterCriterion::Values {
                        values: column.values.clone(),
                        blanks: column.blanks,
                    },
                )
            })
            .collect();
        AutoFilter { range, criteria }
    });
    Ok(Outcome::default())
}

pub(super) fn validation(
    wb: &mut Workbook,
    sheet_id: u32,
    range: RangeRef,
    rule: Option<&ValidationRule>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let added = rule.map(|rule| model_validation(range, rule)).transpose()?;
    let sheet = sheet_mut(wb, index)?;
    for existing in sheet.validations.iter_mut() {
        existing.ranges = existing
            .ranges
            .iter()
            .flat_map(|area| subtract(*area, range))
            .collect();
    }
    sheet
        .validations
        .retain(|existing| !existing.ranges.is_empty());
    sheet.validations.extend(added);
    Ok(Outcome::default())
}

/// The parts of `area` outside `cut`: at most four rectangles.
fn subtract(area: RangeRef, cut: RangeRef) -> Vec<RangeRef> {
    let Some(overlap) = area.intersection(&cut) else {
        return vec![area];
    };
    let mut parts = Vec::new();
    if overlap.start.row > area.start.row {
        parts.push(RangeRef::new(
            area.start,
            CellRef::new(overlap.start.row - 1, area.end.col),
        ));
    }
    if overlap.end.row < area.end.row {
        parts.push(RangeRef::new(
            CellRef::new(overlap.end.row + 1, area.start.col),
            area.end,
        ));
    }
    if overlap.start.col > area.start.col {
        parts.push(RangeRef::new(
            CellRef::new(overlap.start.row, area.start.col),
            CellRef::new(overlap.end.row, overlap.start.col - 1),
        ));
    }
    if overlap.end.col < area.end.col {
        parts.push(RangeRef::new(
            CellRef::new(overlap.start.row, overlap.end.col + 1),
            CellRef::new(overlap.end.row, area.end.col),
        ));
    }
    parts
}

/// Converts the wire rule to GridCraft's storage: a list's literal items are quoted, a range list
/// keeps its `=`, and other formulas drop it.
fn model_validation(range: RangeRef, rule: &ValidationRule) -> Result<Validation, Error> {
    let list = rule.kind == ValidationKind::List;
    let f1 = rule.formula1.trim();
    let f1 = if list && !f1.starts_with('=') {
        if f1.is_empty() || f1.contains('"') {
            return Err(Error::invalid(
                "a list needs comma-separated items without quotes, or a formula starting with =",
            ));
        }
        format!("\"{f1}\"")
    } else {
        check_rule_formula(rule.kind, f1)?
    };
    let f2 = rule
        .formula2
        .as_deref()
        .map(|f2| check_rule_formula(rule.kind, f2.trim()))
        .transpose()?;
    let needs_value = !matches!(rule.kind, ValidationKind::Any);
    if needs_value && f1.is_empty() {
        return Err(Error::invalid("this validation kind needs formula1"));
    }
    let op = rule
        .operator
        .map_or(CfOperator::Between, |operator| match operator {
            ValidationOperator::Between => CfOperator::Between,
            ValidationOperator::NotBetween => CfOperator::NotBetween,
            ValidationOperator::Equal => CfOperator::Equal,
            ValidationOperator::NotEqual => CfOperator::NotEqual,
            ValidationOperator::Greater => CfOperator::Greater,
            ValidationOperator::Less => CfOperator::Less,
            ValidationOperator::GreaterOrEqual => CfOperator::GreaterOrEqual,
            ValidationOperator::LessOrEqual => CfOperator::LessOrEqual,
        });
    if matches!(op, CfOperator::Between | CfOperator::NotBetween)
        && f2.is_none()
        && !matches!(
            rule.kind,
            ValidationKind::Any | ValidationKind::List | ValidationKind::Custom
        )
    {
        return Err(Error::invalid("between and not_between need formula2"));
    }
    Ok(Validation {
        ranges: vec![range],
        kind: match rule.kind {
            ValidationKind::Any => gridcraft_model::ValidationKind::Any,
            ValidationKind::Whole => gridcraft_model::ValidationKind::Whole,
            ValidationKind::Decimal => gridcraft_model::ValidationKind::Decimal,
            ValidationKind::List => gridcraft_model::ValidationKind::List,
            ValidationKind::Date => gridcraft_model::ValidationKind::Date,
            ValidationKind::Time => gridcraft_model::ValidationKind::Time,
            ValidationKind::TextLength => gridcraft_model::ValidationKind::TextLength,
            ValidationKind::Custom => gridcraft_model::ValidationKind::Custom,
        },
        op,
        f1,
        f2,
        allow_blank: rule.allow_blank,
        in_cell_dropdown: rule.show_dropdown,
        input_message: rule.input_message.clone(),
        show_input: !rule.input_message.is_empty(),
        error_message: rule.error_message.clone(),
        ..Validation::default()
    })
}

/// A rule formula is a formula starting with `=`, kept with it for lists and without it otherwise,
/// or a constant that reads as a number, date, or time.
fn check_rule_formula(kind: ValidationKind, text: &str) -> Result<String, Error> {
    if let Some(body) = text.strip_prefix('=') {
        gridcraft_formula::parse(body)
            .map_err(|error| Error::invalid(format!("invalid validation formula: {error}")))?;
        return Ok(if kind == ValidationKind::List {
            text.to_string()
        } else {
            body.to_string()
        });
    }
    if text.is_empty()
        || matches!(kind, ValidationKind::Custom | ValidationKind::Any)
        || gridcraft_core::parse::parse_number_text(text).is_some()
    {
        return Ok(text.to_string());
    }
    Err(Error::invalid(format!(
        "`{text}` is neither a formula nor a number, date, or time"
    )))
}

pub(super) fn table(
    wb: &mut Workbook,
    sheet_id: u32,
    range: RangeRef,
    enabled: bool,
    name: &mut Option<String>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    if !enabled {
        let sheet = sheet_mut(wb, index)?;
        let mut hits = sheet
            .tables
            .iter()
            .enumerate()
            .filter(|(_, table)| table.range.intersects(&range))
            .map(|(position, _)| position);
        let (Some(position), None) = (hits.next(), hits.next()) else {
            return Err(Error::invalid(
                "table.toggle with enabled false needs a range that intersects exactly one table",
            ));
        };
        let removed = sheet.tables.remove(position);
        *name = Some(removed.name);
        // Structured references to the table now resolve to #REF!.
        return Ok(Outcome {
            changed: Vec::new(),
            structural: true,
        });
    }
    if range.height() < 2 || range.is_full_rows() || range.is_full_cols() {
        return Err(Error::invalid(
            "a table needs a bounded range with a header row and at least one data row",
        ));
    }
    check_size(range, "table.toggle")?;
    let table_name = match name.as_deref() {
        Some(requested) => {
            if !valid_table_name(requested)
                || wb.table(requested).is_some()
                || wb
                    .names
                    .iter()
                    .any(|n| n.name.eq_ignore_ascii_case(requested))
            {
                return Err(Error::invalid(format!(
                    "`{requested}` is not a valid, unused table name"
                )));
            }
            requested.to_string()
        }
        None => (1..)
            .map(|n| format!("Table{n}"))
            .find(|candidate| wb.table(candidate).is_none())
            .unwrap_or_default(),
    };
    let id = wb.next_object_id();
    let sheet = wb
        .sheet(index)
        .ok_or_else(|| Error::invalid("the sheet disappeared during the operation"))?;
    if sheet
        .tables
        .iter()
        .any(|table| table.range.intersects(&range))
        || sheet.merges.iter().any(|merge| merge.intersects(&range))
        || sheet
            .autofilter
            .as_ref()
            .is_some_and(|filter| filter.range.intersects(&range))
    {
        return Err(Error::invalid(
            "a table cannot overlap another table, a merged area, or the sheet's filter",
        ));
    }
    // Header cells hold the column names as text, each unique within the table.
    let mut columns: Vec<TableColumn> = Vec::new();
    let mut headers = Vec::new();
    for col in range.start.col..=range.end.col {
        let at = CellRef::new(range.start.row, col);
        let shown = display_text(wb, sheet, at);
        let base = if shown.trim().is_empty() {
            format!("Column{}", col - range.start.col + 1)
        } else {
            shown.trim().to_string()
        };
        let mut column_name = base.clone();
        let mut n = 1;
        while columns
            .iter()
            .any(|column| column.name.eq_ignore_ascii_case(&column_name))
        {
            n += 1;
            column_name = format!("{base}{n}");
        }
        if sheet.cell(at).is_none_or(|cell| {
            cell.formula.is_some() || cell.value.as_text() != Some(column_name.as_str())
        }) {
            headers.push((at, column_name.clone()));
        }
        columns.push(TableColumn {
            name: column_name,
            totals: Default::default(),
            totals_label: None,
            formula: None,
            unique_name: None,
            xml: None,
        });
    }
    let sheet = sheet_mut(wb, index)?;
    let changed = headers.iter().map(|(at, _)| (index, *at)).collect();
    for (at, text) in headers {
        sheet.set_value(at, Value::text(text));
    }
    sheet.tables.push(Table {
        id,
        name: table_name.clone(),
        range,
        header_row: true,
        totals_row: false,
        columns,
        style: "TableStyleMedium2".into(),
        banded_rows: true,
        banded_cols: false,
        first_col: false,
        last_col: false,
        filter_button: true,
        filter: Vec::new(),
        table_type: None,
        connection_id: None,
    });
    *name = Some(table_name);
    Ok(Outcome {
        changed,
        structural: false,
    })
}

/// Excel's rule for table names: a letter, `_`, or `\` first, then letters, digits, `_`, and `.`,
/// and nothing that reads as a cell reference.
fn valid_table_name(name: &str) -> bool {
    name.chars().count() <= 255
        && name.starts_with(|c: char| c.is_alphabetic() || c == '_' || c == '\\')
        && CellRef::parse(name).is_none()
        && name
            .chars()
            .enumerate()
            .all(|(i, c)| c.is_alphanumeric() || c == '_' || c == '.' || (i == 0 && c == '\\'))
}

#[cfg(test)]
mod tests {
    use gridcraft_core::{CellRef, RangeRef};

    use super::subtract;

    #[test]
    fn subtracting_a_block_leaves_the_surrounding_rectangles() {
        let area = RangeRef::new(CellRef::new(0, 0), CellRef::new(9, 9));
        let cut = RangeRef::new(CellRef::new(2, 2), CellRef::new(4, 4));
        let parts = subtract(area, cut);
        assert_eq!(parts.len(), 4);
        assert_eq!(parts.iter().map(RangeRef::count).sum::<u64>(), 100 - 9);
        assert!(parts.iter().all(|part| !part.intersects(&cut)));
        assert_eq!(subtract(area, area), Vec::<RangeRef>::new());
    }
}
