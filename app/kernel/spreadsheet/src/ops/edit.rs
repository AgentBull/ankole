//! Cell content, formats, merged areas, line sizes, frozen panes, and notes.

use std::collections::HashMap;
use std::sync::Arc;

use gridcraft_calc::Key;
use gridcraft_core::{CellError, CellRef, RangeRef, Value};
use gridcraft_model::{
    BorderLine, Cell as ModelCell, Color, Comment, Fill, Formula, LineInfo, NumFmt, Sheet, Style,
    StyleId, Underline, Workbook,
};

use super::{
    Axis, Border, BorderStyle, ClearMode, FormatPatch, FormulaStorage, LineKeyword, LineSize,
    MergeShape, Outcome, PasteCell, Scalar, TextInput, check_size,
};
use crate::Error;
use crate::doc::require_sheet;
use crate::ids::SheetId;

/// Excel's longest cell text and note, in characters.
const MAX_TEXT_CHARS: usize = 32_767;
/// Excel's tallest row (409 pt) and widest column (255 characters), in pixels at 96 dpi.
const MAX_ROW_PX: f32 = 409.0 * 96.0 / 72.0;
const MAX_COL_PX: f32 = 255.0 * 7.0 + 5.0;

pub(crate) fn sheet_mut(wb: &mut Workbook, index: usize) -> Result<&mut Sheet, Error> {
    wb.sheet_mut(index)
        .ok_or_else(|| Error::invalid("the sheet disappeared during the operation"))
}

pub(super) fn cell_set(
    wb: &mut Workbook,
    sheet_id: SheetId,
    at: CellRef,
    input: &str,
    storage: FormulaStorage,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let mut cell = input_to_cell(wb, index, at, input)?;
    if storage == FormulaStorage::LegacyArray {
        let Some(formula) = cell.as_mut().and_then(|cell| cell.formula.as_mut()) else {
            return Err(Error::invalid(
                "an array formula needs input that starts with =",
            ));
        };
        Arc::make_mut(formula).array = Some(RangeRef::cell(at));
    }
    let sheet = sheet_mut(wb, index)?;
    match cell {
        Some(cell) => sheet.set_cell(at, cell),
        None => {
            sheet.remove_cell(at);
        }
    }
    Ok(Outcome {
        changed: vec![(index, at)],
        structural: false,
    })
}

pub(super) fn set_values(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    values: &[Vec<Option<Scalar>>],
    input: TextInput,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_size(range, "range.set_values")?;
    let (height, width) = (range.height() as usize, range.width() as usize);
    if values.len() != height || values.iter().any(|row| row.len() != width) {
        return Err(Error::invalid(format!(
            "values must hold {height} rows of {width} cells to fill {}",
            range.a1()
        )));
    }
    let mut changed = Vec::with_capacity(height * width);
    for (at, value) in range.iter().zip(values.iter().flatten()) {
        let style = wb
            .sheet(index)
            .map(|sheet| sheet.style_id(at))
            .unwrap_or_default();
        let cell = match value {
            None => Some(ModelCell {
                style,
                ..ModelCell::default()
            }),
            Some(Scalar::Bool(value)) => Some(ModelCell {
                value: Value::Bool(*value),
                formula: None,
                style,
            }),
            Some(Scalar::Number(number)) => {
                let number = number
                    .as_f64()
                    .ok_or_else(|| Error::invalid(format!("{number} is not a finite number")))?;
                Some(ModelCell {
                    value: Value::number(number),
                    formula: None,
                    style,
                })
            }
            Some(Scalar::Text(text)) if input == TextInput::Literal && !text.starts_with('=') => {
                check_text(text)?;
                Some(ModelCell {
                    value: Value::text(text.as_str()),
                    formula: None,
                    style: wrap_multiline(wb, style, text),
                })
            }
            Some(Scalar::Text(text)) => input_to_cell(wb, index, at, text)?,
        };
        let sheet = sheet_mut(wb, index)?;
        match cell.filter(|cell| !cell.is_blank()) {
            Some(cell) => sheet.set_cell(at, cell),
            None => {
                sheet.remove_cell(at);
            }
        }
        changed.push((index, at));
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

pub(super) fn paste(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    cells: &[Vec<PasteCell>],
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_size(range, "range.paste")?;
    let (height, width) = (range.height() as usize, range.width() as usize);
    if cells.len() != height || cells.iter().any(|row| row.len() != width) {
        return Err(Error::invalid(format!(
            "cells must hold {height} rows of {width} cells to paste into {}",
            range.a1()
        )));
    }
    for pasted in cells.iter().flatten() {
        if let Some(format) = &pasted.format {
            check_patch(format)?;
        }
    }
    let mut changed = Vec::new();
    for (at, pasted) in range.iter().zip(cells.iter().flatten()) {
        let current = wb
            .sheet(index)
            .map(|sheet| sheet.style_id(at))
            .unwrap_or_default();
        let style = match &pasted.format {
            Some(patch) => wb
                .styles
                .derive(StyleId::default(), |style| apply_patch(style, patch)),
            None => current,
        };
        match &pasted.input {
            Some(input) => {
                let cell = typed_cell(wb, style, input)?;
                let sheet = sheet_mut(wb, index)?;
                match cell.filter(|cell| !cell.is_blank()) {
                    Some(cell) => sheet.set_cell(at, cell),
                    None => {
                        sheet.remove_cell(at);
                    }
                }
                changed.push((index, at));
            }
            None if style != current => sheet_mut(wb, index)?.set_style(at, style),
            None => {}
        }
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

/// What typing `input` into a cell produces, as GridCraft's editor defines it: a formula when it
/// starts with `=` (or reads as a signed function call), otherwise a value parsed like Excel's
/// en-US typed input, with the number format the input implies. The cell keeps its style.
fn input_to_cell(
    wb: &mut Workbook,
    sheet: usize,
    at: CellRef,
    input: &str,
) -> Result<Option<ModelCell>, Error> {
    let style = wb
        .sheet(sheet)
        .map(|sheet| sheet.style_id(at))
        .unwrap_or_default();
    typed_cell(wb, style, input)
}

/// What typing `input` into a cell of style `style` produces; see [`input_to_cell`].
fn typed_cell(wb: &mut Workbook, style: StyleId, input: &str) -> Result<Option<ModelCell>, Error> {
    check_text(input)?;
    if input.is_empty() {
        let cell = ModelCell {
            style,
            ..ModelCell::default()
        };
        return Ok((!cell.is_blank()).then_some(cell));
    }
    if wb.styles.get(style).num_fmt.as_str() == "@" {
        return Ok(Some(ModelCell {
            value: Value::text(input),
            formula: None,
            style,
        }));
    }
    let signed_call = input.len() > 1
        && (input.starts_with('+') || input.starts_with('-'))
        && gridcraft_core::parse::parse_number_text(input).is_none()
        && input
            .chars()
            .nth(1)
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '(');
    if input.starts_with('=') || signed_call {
        return formula_cell(wb, style, input.strip_prefix('=').unwrap_or(input)).map(Some);
    }
    let mut parsed = gridcraft_core::parse::parse_input(input, wb.date_system);
    // A bare number of 1 or more typed into a percentage cell is a percent (3 -> 3%).
    if parsed.format.is_none()
        && !input.contains('%')
        && wb.styles.get(style).num_fmt.as_str().ends_with('%')
        && let Value::Number(number) = parsed.value
        && number.abs() >= 1.0
    {
        parsed.value = Value::Number(number / 100.0);
    }
    let mut style = style;
    if let Some(code) = parsed.format
        && wb.styles.get(style).num_fmt.as_str() == "General"
    {
        style = wb.styles.derive(style, |s| s.num_fmt = NumFmt::new(code));
    }
    Ok(Some(ModelCell {
        value: parsed.value,
        formula: None,
        style: wrap_multiline(wb, style, input),
    }))
}

fn formula_cell(wb: &mut Workbook, style: StyleId, body: &str) -> Result<ModelCell, Error> {
    let expr = gridcraft_formula::parse_closing_parens(body, gridcraft_formula::parse)
        .map_err(|error| Error::invalid(format!("there's a problem with this formula: {error}")))?;
    let expr = wb.name_call_case(expr);
    check_arg_counts(&expr)?;
    let formula = Formula::from_expr(expr);
    // Functions that return dates and times give a General cell their format, as in Excel.
    let mut style = style;
    if wb.styles.get(style).num_fmt.as_str() == "General" {
        let text = formula.text.to_ascii_uppercase();
        let code = if ["TODAY(", "DATE(", "EDATE(", "EOMONTH(", "WORKDAY("]
            .iter()
            .any(|f| text.starts_with(f))
        {
            Some("m/d/yyyy")
        } else if text.starts_with("NOW(") {
            Some("m/d/yyyy h:mm")
        } else if text.starts_with("TIME(") {
            Some("h:mm AM/PM")
        } else {
            None
        };
        if let Some(code) = code {
            style = wb.styles.derive(style, |s| s.num_fmt = NumFmt::new(code));
        }
    }
    Ok(ModelCell {
        value: Value::Empty,
        formula: Some(Arc::new(formula)),
        style,
    })
}

/// Rejects calls of built-in functions with too few or too many arguments, as Excel does when a
/// formula is entered.
fn check_arg_counts(expr: &gridcraft_formula::Expr) -> Result<(), Error> {
    let mut problem = None;
    expr.walk(&mut |e| {
        if problem.is_none()
            && let gridcraft_formula::Expr::Call(name, args) = e
            && let Some(spec) = gridcraft_functions::lookup(name)
            && !spec.accepts(args.len())
        {
            let few = args.len() < spec.min_args;
            problem = Some(format!(
                "{} has too {} arguments; use {}",
                spec.name,
                if few { "few" } else { "many" },
                spec.signature
            ));
        }
    });
    problem.map_or(Ok(()), |message| Err(Error::Invalid(message)))
}

fn check_text(text: &str) -> Result<(), Error> {
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err(Error::invalid(format!(
            "a cell holds at most {MAX_TEXT_CHARS} characters"
        )));
    }
    Ok(())
}

/// Text with line breaks turns on Wrap Text, as typing it does.
fn wrap_multiline(wb: &mut Workbook, style: StyleId, text: &str) -> StyleId {
    if text.contains('\n') && !wb.styles.get(style).align.wrap {
        wb.styles.derive(style, |s| s.align.wrap = true)
    } else {
        style
    }
}

pub(super) fn clear(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    mode: ClearMode,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let mut changed: Vec<Key> = Vec::new();
    match mode {
        ClearMode::Comments => sheet.comments.retain(|cell, _| !range.contains(*cell)),
        ClearMode::Hyperlinks => sheet.hyperlinks.retain(|cell, _| !range.contains(*cell)),
        ClearMode::Contents => {
            let stored: Vec<(CellRef, StyleId)> = sheet
                .cells
                .iter_range(range)
                .map(|(at, cell)| (at, cell.style))
                .collect();
            for (at, style) in stored {
                sheet.set_cell(
                    at,
                    ModelCell {
                        style,
                        ..ModelCell::default()
                    },
                );
                changed.push((index, at));
            }
        }
        ClearMode::Formats => {
            let stored: Vec<CellRef> = sheet.cells.iter_range(range).map(|(at, _)| at).collect();
            for at in stored {
                sheet.set_style(at, StyleId::DEFAULT);
            }
            sheet.merges.retain(|merge| !merge.intersects(&range));
        }
        ClearMode::All => {
            changed.extend(
                sheet
                    .take_cells(range)
                    .into_iter()
                    .map(|(at, _)| (index, at)),
            );
            sheet.comments.retain(|cell, _| !range.contains(*cell));
            sheet.hyperlinks.retain(|cell, _| !range.contains(*cell));
            sheet.merges.retain(|merge| !merge.intersects(&range));
        }
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

pub(super) fn format(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    patch: &FormatPatch,
) -> Result<Outcome, Error> {
    check_patch(patch)?;
    let index = require_sheet(wb, sheet_id)?;
    let mut derived: HashMap<StyleId, StyleId> = HashMap::new();
    let mut restyle = |wb: &mut Workbook, style: StyleId| {
        *derived
            .entry(style)
            .or_insert_with(|| wb.styles.derive(style, |s| apply_patch(s, patch)))
    };
    let (full_rows, full_cols) = (range.is_full_rows(), range.is_full_cols());
    if full_rows || full_cols {
        // Whole lines take a line style, and the cells already stored in them follow it.
        let rows = full_rows && !full_cols;
        let lines = if rows {
            range.start.row..=range.end.row
        } else {
            range.start.col..=range.end.col
        };
        for line in lines {
            let sheet = wb.sheet(index);
            let current = sheet
                .and_then(|s| {
                    if rows {
                        s.rows.get(&line)
                    } else {
                        s.cols.get(&line)
                    }
                })
                .and_then(|info| info.style);
            let style = restyle(wb, current.unwrap_or_default());
            let sheet = sheet_mut(wb, index)?;
            let infos = if rows {
                &mut sheet.rows
            } else {
                &mut sheet.cols
            };
            infos.entry(line).or_default().style = Some(style);
        }
        let stored: Vec<(CellRef, StyleId)> = wb
            .sheet(index)
            .map(|s| {
                s.cells
                    .iter_range(range)
                    .map(|(at, cell)| (at, cell.style))
                    .collect()
            })
            .unwrap_or_default();
        for (at, style) in stored {
            let style = restyle(wb, style);
            sheet_mut(wb, index)?.set_style(at, style);
        }
    } else {
        check_size(range, "range.format")?;
        for at in range.iter() {
            let current = wb
                .sheet(index)
                .map(|sheet| sheet.style_id(at))
                .unwrap_or_default();
            let style = restyle(wb, current);
            if style != current {
                sheet_mut(wb, index)?.set_style(at, style);
            }
        }
    }
    Ok(Outcome::default())
}

/// Excel limits a font name to 31 characters.
const MAX_FONT_NAME_CHARS: usize = 31;

fn check_patch(patch: &FormatPatch) -> Result<(), Error> {
    if patch
        .font_size
        .is_some_and(|size| !(1.0..=409.0).contains(&size))
    {
        return Err(Error::invalid("font_size must be between 1 and 409 points"));
    }
    if patch
        .font_name
        .as_deref()
        .is_some_and(|name| name.trim().is_empty() || name.chars().count() > MAX_FONT_NAME_CHARS)
    {
        return Err(Error::invalid(format!(
            "font_name must hold 1 to {MAX_FONT_NAME_CHARS} characters"
        )));
    }
    if patch.num_fmt.as_deref().is_some_and(|code| {
        code.is_empty() || code.chars().count() > gridcraft_numfmt::MAX_FORMAT_CODE_CHARS
    }) {
        return Err(Error::invalid(format!(
            "num_fmt must hold 1 to {} characters",
            gridcraft_numfmt::MAX_FORMAT_CODE_CHARS
        )));
    }
    Ok(())
}

fn apply_patch(style: &mut Style, patch: &FormatPatch) {
    let font = &mut style.font;
    if let Some(bold) = patch.bold {
        font.bold = bold;
    }
    if let Some(italic) = patch.italic {
        font.italic = italic;
    }
    if let Some(underline) = patch.underline {
        font.underline = if underline {
            Underline::Single
        } else {
            Underline::None
        };
    }
    if let Some(strike) = patch.strike {
        font.strike = strike;
    }
    if let Some(name) = &patch.font_name {
        font.name.clone_from(name);
    }
    if let Some(size) = patch.font_size {
        font.size = size;
    }
    if let Some(color) = patch.font_color {
        font.color = color.map_or(Color::Auto, |color| Color::Rgb(color.0));
    }
    if let Some(fill) = patch.fill_color {
        style.fill = fill.map_or(Fill::default(), |color| Fill::solid(Color::Rgb(color.0)));
    }
    if let Some(h) = patch.h_align {
        style.align.h = h.into();
    }
    if let Some(v) = patch.v_align {
        style.align.v = v.into();
    }
    if let Some(wrap) = patch.wrap {
        style.align.wrap = wrap;
    }
    if let Some(code) = &patch.num_fmt {
        style.num_fmt = NumFmt::new(code);
    }
    if let Some(borders) = patch.borders {
        let sides = [
            (borders.left, &mut style.borders.left),
            (borders.right, &mut style.borders.right),
            (borders.top, &mut style.borders.top),
            (borders.bottom, &mut style.borders.bottom),
        ];
        for (change, line) in sides {
            if let Some(border) = change {
                *line = border.map_or(BorderLine::default(), border_line);
            }
        }
    }
}

fn border_line(border: Border) -> BorderLine {
    use gridcraft_model::BorderStyle as Model;
    let style = match border.style {
        BorderStyle::Thin => Model::Thin,
        BorderStyle::Medium => Model::Medium,
        BorderStyle::Thick => Model::Thick,
        BorderStyle::Dashed => Model::Dashed,
        BorderStyle::Dotted => Model::Dotted,
        BorderStyle::Double => Model::Double,
        BorderStyle::Hair => Model::Hair,
        BorderStyle::MediumDashed => Model::MediumDashed,
        BorderStyle::DashDot => Model::DashDot,
        BorderStyle::MediumDashDot => Model::MediumDashDot,
        BorderStyle::DashDotDot => Model::DashDotDot,
        BorderStyle::MediumDashDotDot => Model::MediumDashDotDot,
        BorderStyle::SlantDashDot => Model::SlantDashDot,
    };
    BorderLine {
        style,
        color: border
            .color
            .map_or(Color::Auto, |color| Color::Rgb(color.0)),
    }
}

pub(super) fn merge(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
    shape: MergeShape,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_size(range, "range.merge")?;
    let areas: Vec<RangeRef> = if shape == MergeShape::EachRow {
        (range.start.row..=range.end.row)
            .map(|row| {
                RangeRef::new(
                    CellRef::new(row, range.start.col),
                    CellRef::new(row, range.end.col),
                )
            })
            .collect()
    } else {
        vec![range]
    };
    if areas.iter().any(RangeRef::is_single) {
        return Err(Error::invalid("a merged area needs at least two cells"));
    }
    let sheet = sheet_mut(wb, index)?;
    if sheet
        .tables
        .iter()
        .any(|table| table.range.intersects(&range))
    {
        return Err(Error::invalid("cells in a table cannot be merged"));
    }
    sheet.merges.retain(|merge| !merge.intersects(&range));
    let mut changed = spill_seeds(sheet, index, range);
    for area in areas {
        sheet.merges.push(area);
        // Only the top-left value of a merged area survives, as Excel warns.
        let others: Vec<(CellRef, StyleId)> = sheet
            .cells
            .iter_range(area)
            .filter(|(at, _)| *at != area.start)
            .map(|(at, cell)| (at, cell.style))
            .collect();
        for (at, style) in others {
            sheet.set_cell(
                at,
                ModelCell {
                    style,
                    ..ModelCell::default()
                },
            );
            changed.push((index, at));
        }
    }
    Ok(Outcome {
        changed,
        structural: false,
    })
}

pub(super) fn unmerge(
    wb: &mut Workbook,
    sheet_id: SheetId,
    range: RangeRef,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let removed: Vec<RangeRef> = sheet
        .merges
        .iter()
        .filter(|merge| merge.intersects(&range))
        .copied()
        .collect();
    sheet.merges.retain(|merge| !merge.intersects(&range));
    let changed = removed
        .into_iter()
        .flat_map(|area| spill_seeds(sheet, index, area))
        .collect();
    Ok(Outcome {
        changed,
        structural: false,
    })
}

/// Dynamic arrays whose spill area a merge change can block or unblock: the anchors that spill
/// over `area`, and the blocked formulas above and left of it.
fn spill_seeds(sheet: &Sheet, index: usize, area: RangeRef) -> Vec<Key> {
    let spilling = sheet
        .spill_ranges
        .iter()
        .filter(|(_, spill)| spill.intersects(&area))
        .map(|(anchor, _)| (index, *anchor));
    let reach = RangeRef::new(CellRef::new(0, 0), area.end);
    let blocked = sheet
        .cells
        .iter_range(reach)
        .filter(|(_, cell)| cell.formula.is_some() && cell.value == Value::Error(CellError::Spill))
        .map(|(at, _)| (index, at));
    spilling.chain(blocked).collect()
}

pub(super) fn resize(
    wb: &mut Workbook,
    sheet_id: SheetId,
    axis: Axis,
    start: u32,
    end: u32,
    size: LineSize,
) -> Result<Outcome, Error> {
    if start > end || end >= axis.limit() {
        return Err(Error::invalid(
            "line.resize needs start <= end within the sheet",
        ));
    }
    let max = if axis == Axis::Rows {
        MAX_ROW_PX
    } else {
        MAX_COL_PX
    };
    if let LineSize::Px(px) = size
        && !(px > 0.0 && px <= max)
    {
        return Err(Error::invalid(format!(
            "size_px must be greater than 0 and at most {max:.0}"
        )));
    }
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let lines = if axis == Axis::Rows {
        &mut sheet.rows
    } else {
        &mut sheet.cols
    };
    for line in start..=end {
        let info = lines.entry(line).or_default();
        match size {
            LineSize::Px(px) => {
                info.size = Some(px);
                info.custom = true;
                info.hidden = false;
            }
            LineSize::Keyword(LineKeyword::Auto) => {
                info.size = None;
                info.custom = false;
            }
            LineSize::Keyword(LineKeyword::Hidden) => info.hidden = true,
            LineSize::Keyword(LineKeyword::Unhide) => info.hidden = false,
        }
        if *info == LineInfo::default() {
            lines.remove(&line);
        }
    }
    Ok(Outcome::default())
}

pub(super) fn freeze(
    wb: &mut Workbook,
    sheet_id: SheetId,
    rows: u32,
    cols: u32,
) -> Result<Outcome, Error> {
    if rows >= gridcraft_core::MAX_ROWS || cols >= gridcraft_core::MAX_COLS {
        return Err(Error::invalid(
            "the frozen panes must leave part of the sheet scrollable",
        ));
    }
    let index = require_sheet(wb, sheet_id)?;
    sheet_mut(wb, index)?.freeze = (rows > 0 || cols > 0).then_some((rows, cols));
    Ok(Outcome::default())
}

pub(super) fn comment(
    wb: &mut Workbook,
    sheet_id: SheetId,
    at: CellRef,
    text: Option<&str>,
    author: Option<&str>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let Some(text) = text else {
        sheet.comments.remove(&at);
        return Ok(Outcome::default());
    };
    check_text(text)?;
    match sheet.comments.get_mut(&at) {
        Some(existing) => {
            existing.text = text.to_string();
            if let Some(author) = author {
                existing.author = author.to_string();
            }
        }
        None => {
            let note = Comment {
                author: author.unwrap_or_default().to_string(),
                text: text.to_string(),
                replies: Vec::new(),
                threaded: false,
                resolved: false,
                visible: false,
                dates: Vec::new(),
                note_box: None,
            };
            sheet.comments.insert(at, note);
        }
    }
    Ok(Outcome::default())
}
