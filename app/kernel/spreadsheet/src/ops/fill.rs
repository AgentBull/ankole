//! Filling a range from the cells at its start, as dragging the fill handle does.
//!
//! The source block repeats along the fill direction. Each line of the source along that
//! direction (a column when filling down or up, a row when filling right or left) continues on
//! its own: in series mode a run of numbers follows its linear trend, a lone number counts up by
//! one, text ending in a number counts that number up, and weekday or month names continue their
//! list. Everything else, and every cell in copy mode, repeats. A formula moves its relative
//! references by the distance between its source cell and the cell it fills, and every filled
//! cell takes the format of the source cell it repeats.

use std::sync::Arc;

use gridcraft_core::{CellRef, RangeRef, Value};
use gridcraft_formula::adjust::shift_relative;
use gridcraft_model::{Cell as ModelCell, Formula, StyleId};
use serde::{Deserialize, Serialize};

use super::edit::sheet_mut;
use super::{Outcome, check_size};
use crate::Error;
use crate::doc::require_sheet;

/// How a fill continues its source.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FillMode {
    /// Continue numbers, numbered text, and named lists; repeat everything else.
    #[default]
    Series,
    /// Repeat the source as it is.
    Copy,
    /// Continue like `series`, keeping the formats of the filled cells.
    Values,
    /// Repeat only the formats, keeping the content of the filled cells.
    Formats,
}

/// The direction a fill extends its source in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Direction {
    Down,
    Up,
    Right,
    Left,
}

impl Direction {
    /// Whether the fill runs along rows (down or up) rather than columns.
    fn vertical(self) -> bool {
        matches!(self, Direction::Down | Direction::Up)
    }
}

/// Lists that continue by name. Each list is matched case-insensitively and in full.
const LISTS: &[&[&str]] = &[
    &[
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
        "Sunday",
    ],
    &["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
    &[
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ],
    &[
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ],
    &[
        "星期一",
        "星期二",
        "星期三",
        "星期四",
        "星期五",
        "星期六",
        "星期日",
    ],
    &["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
    &[
        "一月",
        "二月",
        "三月",
        "四月",
        "五月",
        "六月",
        "七月",
        "八月",
        "九月",
        "十月",
        "十一月",
        "十二月",
    ],
    &["第一季度", "第二季度", "第三季度", "第四季度"],
    &["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"],
    &[
        "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥",
    ],
];

/// One source cell as a series sees it.
#[derive(Clone, Debug)]
enum Item {
    /// A constant number.
    Number(f64),
    /// Text that ends in a run of digits, split around that number.
    Numbered {
        prefix: String,
        number: u64,
        digits: usize,
        suffix: String,
    },
    /// A name from at least one of [`LISTS`].
    Named(String),
    /// Anything that repeats as it is: other text, booleans, errors, formulas, and blanks.
    Other,
}

/// How one line of the source continues.
enum Plan {
    /// Numbers that follow `intercept + slope * position`.
    Trend { intercept: f64, slope: f64 },
    /// Numbered text with one prefix and suffix whose number follows a constant step.
    NumberedTrend {
        prefix: String,
        start: i128,
        step: i128,
        digits: usize,
        suffix: String,
    },
    /// Names of one list that advance by a constant step.
    ListTrend {
        list: usize,
        start: usize,
        step: i64,
    },
    /// Each cell continues on its own: numbered text and list names count up by one for every
    /// repetition, and everything else repeats.
    PerCell,
}

pub(super) fn fill(
    wb: &mut gridcraft_model::Workbook,
    sheet_id: u32,
    source: RangeRef,
    to: RangeRef,
    mode: FillMode,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let Some(direction) = direction(source, to)? else {
        return Ok(Outcome::default());
    };
    check_size(to, "range.fill")?;
    let sheet = wb
        .sheet(index)
        .ok_or_else(|| Error::invalid("the sheet disappeared during the operation"))?;
    let (lanes, length) = if direction.vertical() {
        (source.start.col..=source.end.col, source.height())
    } else {
        (source.start.row..=source.end.row, source.width())
    };
    let length = i64::from(length);
    let mut writes: Vec<(CellRef, Option<ModelCell>)> = Vec::new();
    for lane in lanes {
        let at = |offset: i64| -> Option<CellRef> {
            let (row, col) = if direction.vertical() {
                (i64::from(source.start.row) + offset, i64::from(lane))
            } else {
                (i64::from(lane), i64::from(source.start.col) + offset)
            };
            Some(CellRef::new(
                u32::try_from(row).ok()?,
                u32::try_from(col).ok()?,
            ))
        };
        let cells: Vec<Option<ModelCell>> = (0..length)
            .map(|offset| at(offset).and_then(|cell| sheet.cell(cell).cloned()))
            .collect();
        let items: Vec<Item> = cells.iter().map(|cell| item(cell.as_ref())).collect();
        let plan = match mode {
            FillMode::Series | FillMode::Values => plan(&items),
            FillMode::Copy | FillMode::Formats => Plan::PerCell,
        };
        for offset in targets(source, to, direction) {
            let Some(target) = at(offset) else { continue };
            let position = usize::try_from(offset.rem_euclid(length)).unwrap_or(0);
            let repetition = offset.div_euclid(length);
            let Some(origin) = at(i64::try_from(position).unwrap_or(0)) else {
                continue;
            };
            let source_cell = cells.get(position).and_then(Option::as_ref);
            let source_style =
                source_cell.map_or_else(|| sheet.style_id(origin), |cell| cell.style);
            if mode == FillMode::Formats {
                let mut kept = sheet.cell(target).cloned().unwrap_or_default();
                kept.style = source_style;
                writes.push((target, Some(kept)));
                continue;
            }
            let style = if mode == FillMode::Values {
                sheet.style_id(target)
            } else {
                source_style
            };
            let value = match (mode, items.get(position)) {
                (FillMode::Series | FillMode::Values, Some(item)) => {
                    continued(&plan, item, offset, repetition)
                }
                _ => None,
            };
            let cell = match value {
                Some(value) => Some(ModelCell {
                    value,
                    formula: None,
                    style,
                }),
                None => repeated(source_cell, style, origin, target),
            };
            writes.push((target, cell));
        }
    }
    let sheet = sheet_mut(wb, index)?;
    let mut changed = Vec::with_capacity(writes.len());
    for (target, cell) in writes {
        match cell.filter(|cell| !cell.is_blank()) {
            Some(cell) => sheet.set_cell(target, cell),
            None => {
                sheet.remove_cell(target);
            }
        }
        changed.push((index, target));
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

/// The direction `to` extends `source` in, or `None` when they are the same range.
fn direction(source: RangeRef, to: RangeRef) -> Result<Option<Direction>, Error> {
    if to == source {
        return Ok(None);
    }
    let same_cols = to.start.col == source.start.col && to.end.col == source.end.col;
    let same_rows = to.start.row == source.start.row && to.end.row == source.end.row;
    let direction = if same_cols && to.start.row == source.start.row && to.end.row > source.end.row
    {
        Direction::Down
    } else if same_cols && to.end.row == source.end.row && to.start.row < source.start.row {
        Direction::Up
    } else if same_rows && to.start.col == source.start.col && to.end.col > source.end.col {
        Direction::Right
    } else if same_rows && to.end.col == source.end.col && to.start.col < source.start.col {
        Direction::Left
    } else {
        return Err(Error::invalid(format!(
            "range.fill must extend {} past one of its edges; {} does not",
            source.a1(),
            to.a1()
        )));
    };
    Ok(Some(direction))
}

/// The offsets from the source's first line of the lines a fill writes, outside the source.
fn targets(source: RangeRef, to: RangeRef, direction: Direction) -> Vec<i64> {
    let (source_start, source_len, to_start, to_end) = if direction.vertical() {
        (source.start.row, source.height(), to.start.row, to.end.row)
    } else {
        (source.start.col, source.width(), to.start.col, to.end.col)
    };
    let start = i64::from(source_start);
    let len = i64::from(source_len);
    (i64::from(to_start)..=i64::from(to_end))
        .map(|line| line - start)
        .filter(|offset| *offset < 0 || *offset >= len)
        .collect()
}

/// A source cell as a series sees it.
fn item(cell: Option<&ModelCell>) -> Item {
    let Some(cell) = cell.filter(|cell| cell.formula.is_none()) else {
        return Item::Other;
    };
    match &cell.value {
        Value::Number(number) => Item::Number(*number),
        Value::Text(text) if position_in_any_list(text).is_some() => Item::Named(text.to_string()),
        Value::Text(text) => numbered(text).unwrap_or(Item::Other),
        _ => Item::Other,
    }
}

fn position_in(list: usize, text: &str) -> Option<usize> {
    LISTS
        .get(list)?
        .iter()
        .position(|name| name.eq_ignore_ascii_case(text))
}

/// The first list that names `text`, with its position there.
fn position_in_any_list(text: &str) -> Option<(usize, usize)> {
    (0..LISTS.len()).find_map(|list| position_in(list, text).map(|position| (list, position)))
}

fn numbered(text: &str) -> Option<Item> {
    let end = text
        .char_indices()
        .rev()
        .find(|(_, c)| c.is_ascii_digit())
        .map(|(at, c)| at + c.len_utf8())?;
    let head = &text[..end];
    let start = head
        .char_indices()
        .rev()
        .take_while(|(_, c)| c.is_ascii_digit())
        .last()
        .map_or(end, |(at, _)| at);
    let digits = &text[start..end];
    Some(Item::Numbered {
        prefix: text[..start].to_string(),
        number: digits.parse().ok()?,
        digits: digits.len(),
        suffix: text[end..].to_string(),
    })
}

/// How a line of source items continues.
fn plan(items: &[Item]) -> Plan {
    let numbers: Option<Vec<f64>> = items
        .iter()
        .map(|item| match item {
            Item::Number(number) => Some(*number),
            _ => None,
        })
        .collect();
    if let Some(numbers) = numbers {
        let (intercept, slope) = trend(&numbers);
        return Plan::Trend { intercept, slope };
    }
    if let Some(plan) = numbered_trend(items) {
        return plan;
    }
    if let Some(plan) = list_trend(items) {
        return plan;
    }
    Plan::PerCell
}

/// The least-squares line through `(position, number)`; a lone number counts up by one.
fn trend(numbers: &[f64]) -> (f64, f64) {
    match numbers {
        [] => (0.0, 0.0),
        [only] => (*only, 1.0),
        _ => {
            #[allow(
                clippy::cast_precision_loss,
                reason = "a fill source is far shorter than 2^52"
            )]
            let count = numbers.len() as f64;
            let mean_x = (count - 1.0) / 2.0;
            let mean_y = numbers.iter().sum::<f64>() / count;
            let (mut covariance, mut variance) = (0.0, 0.0);
            for (position, number) in numbers.iter().enumerate() {
                #[allow(clippy::cast_precision_loss, reason = "see above")]
                let dx = position as f64 - mean_x;
                covariance += dx * (number - mean_y);
                variance += dx * dx;
            }
            let slope = covariance / variance;
            (mean_y - slope * mean_x, slope)
        }
    }
}

fn numbered_trend(items: &[Item]) -> Option<Plan> {
    let first = items.first()?;
    let Item::Numbered {
        prefix,
        number,
        digits,
        suffix,
    } = first
    else {
        return None;
    };
    let mut numbers = Vec::with_capacity(items.len());
    for item in items {
        match item {
            Item::Numbered {
                prefix: p,
                number,
                suffix: s,
                ..
            } if p == prefix && s == suffix => numbers.push(i128::from(*number)),
            _ => return None,
        }
    }
    let step = match numbers.as_slice() {
        [_] => 1,
        [a, b, ..] => b - a,
        [] => return None,
    };
    let constant = numbers.windows(2).all(|pair| pair[1] - pair[0] == step);
    constant.then(|| Plan::NumberedTrend {
        prefix: prefix.clone(),
        start: i128::from(*number),
        step,
        digits: *digits,
        suffix: suffix.clone(),
    })
}

/// Names that all belong to one list, such as `Mar, May` among the short month names (`May` is
/// also a full month name), continue by the step between the first two.
fn list_trend(items: &[Item]) -> Option<Plan> {
    let texts: Vec<&str> = items
        .iter()
        .map(|item| match item {
            Item::Named(text) => Some(text.as_str()),
            _ => None,
        })
        .collect::<Option<_>>()?;
    let (list, positions) = (0..LISTS.len()).find_map(|list| {
        let positions: Option<Vec<i64>> = texts
            .iter()
            .map(|text| position_in(list, text).and_then(|at| i64::try_from(at).ok()))
            .collect();
        positions.map(|positions| (list, positions))
    })?;
    let size = i64::try_from(LISTS.get(list)?.len()).ok()?;
    let position = usize::try_from(*positions.first()?).ok()?;
    let step = match positions.as_slice() {
        [_] => 1,
        [a, b, ..] => (b - a).rem_euclid(size),
        [] => return None,
    };
    let constant = positions
        .windows(2)
        .all(|pair| (pair[1] - pair[0]).rem_euclid(size) == step);
    constant.then_some(Plan::ListTrend {
        list,
        start: position,
        step,
    })
}

/// The value a series gives the cell at `offset` from the source's first line, or `None` when
/// the source cell repeats as it is.
fn continued(plan: &Plan, item: &Item, offset: i64, repetition: i64) -> Option<Value> {
    match plan {
        Plan::Trend { intercept, slope } => {
            #[allow(clippy::cast_precision_loss, reason = "fill offsets are below 2^21")]
            let at = offset as f64;
            Some(Value::number(round(intercept + slope * at)))
        }
        Plan::NumberedTrend {
            prefix,
            start,
            step,
            digits,
            suffix,
        } => Some(numbered_text(
            prefix,
            start + step * i128::from(offset),
            *digits,
            suffix,
        )),
        Plan::ListTrend { list, start, step } => Some(list_name(
            *list,
            i64::try_from(*start).ok()? + step * offset,
        )),
        Plan::PerCell => match item {
            Item::Numbered {
                prefix,
                number,
                digits,
                suffix,
            } => Some(numbered_text(
                prefix,
                i128::from(*number) + i128::from(repetition),
                *digits,
                suffix,
            )),
            Item::Named(text) => {
                let (list, position) = position_in_any_list(text)?;
                Some(list_name(list, i64::try_from(position).ok()? + repetition))
            }
            Item::Number(_) | Item::Other => None,
        },
    }
}

/// Removes the binary noise of a fitted line, so `0.1, 0.2` continues as `0.3`.
fn round(value: f64) -> f64 {
    let scaled = (value * 1e10).round() / 1e10;
    if scaled.is_finite() { scaled } else { value }
}

/// Numbered text with `number` padded to `digits`; a number below zero keeps its sign.
fn numbered_text(prefix: &str, number: i128, digits: usize, suffix: &str) -> Value {
    let magnitude = number.unsigned_abs();
    let sign = if number < 0 { "-" } else { "" };
    Value::text(format!("{prefix}{sign}{magnitude:0digits$}{suffix}").as_str())
}

fn list_name(list: usize, position: i64) -> Value {
    let names = LISTS.get(list).copied().unwrap_or_default();
    let size = i64::try_from(names.len()).unwrap_or(1).max(1);
    let index = usize::try_from(position.rem_euclid(size)).unwrap_or(0);
    Value::text(names.get(index).copied().unwrap_or_default())
}

/// The source cell repeated at `target`: a formula moves its relative references by the distance
/// from `origin`, and a blank source keeps only its format.
fn repeated(
    source: Option<&ModelCell>,
    style: StyleId,
    origin: CellRef,
    target: CellRef,
) -> Option<ModelCell> {
    let Some(source) = source else {
        return Some(ModelCell {
            style,
            ..ModelCell::default()
        });
    };
    let Some(formula) = source.formula.as_ref() else {
        return Some(source.clone());
    };
    let Some(expr) = formula.expr() else {
        return Some(source.clone());
    };
    let rows = i64::from(target.row) - i64::from(origin.row);
    let cols = i64::from(target.col) - i64::from(origin.col);
    Some(ModelCell {
        value: Value::Empty,
        formula: Some(Arc::new(Formula::from_expr(shift_relative(
            expr, rows, cols,
        )))),
        style,
    })
}
