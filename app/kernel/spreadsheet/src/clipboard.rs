//! Copying a block of cells with its formulas and formats, and the `range.paste` operation that
//! puts it back.
//!
//! A copy reads every cell of the block as typed input, as the value it shows, and as its full
//! format. A paste turns that block into one `range.paste` operation for its destination, with
//! each formula's relative references already moved there, so the operation rebases like typed
//! input and means the same thing on every replica.

use gridcraft_core::{CellRef, RangeRef};
use gridcraft_formula::adjust::shift_relative;
use gridcraft_model::{BorderLine, Color, PatternType, Style, Underline, Workbook};
use serde::{Deserialize, Serialize};

use crate::Error;
use crate::doc::{SpreadsheetDoc, sheet_by_id};
use crate::ops::{
    Border, BorderStyle, BordersPatch, FormatPatch, HAlign, HexColor, Op, PasteCell, Range, VAlign,
};
use crate::view::{cell_input_at, display_text, value_input};

/// The most cells one copy may hold.
pub const MAX_CLIPBOARD_CELLS: u64 = 100_000;

/// A copied block of cells.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClipboardBlock {
    /// The A1 cell the block was copied from, so a paste can move relative references.
    pub origin: String,
    /// The cells, row by row.
    pub rows: Vec<Vec<ClipboardCell>>,
}

/// One copied cell.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClipboardCell {
    /// What typing reproduces the cell: a formula, or a constant as the cell editor shows it.
    pub input: String,
    /// What typing reproduces the value the cell shows, for pasting values only.
    pub value: String,
    /// The text the cell shows, for other applications.
    pub text: String,
    /// Every format attribute of the cell, so a paste replaces the destination's format.
    pub format: FormatPatch,
}

/// What a paste writes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PasteMode {
    /// Formulas, values, and formats.
    #[default]
    All,
    /// The values the cells show, keeping the destination's formats.
    Values,
    /// Formulas and values without formats.
    Formulas,
    /// The formats, keeping the destination's content.
    Formats,
}

/// Copies the cells of the A1 range `range`, cut to the part of the sheet that holds content.
pub fn copy_block(
    doc: &SpreadsheetDoc,
    sheet_id: u32,
    range: &str,
) -> Result<ClipboardBlock, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let requested = RangeRef::parse(range)
        .filter(|range| range.end.is_valid())
        .ok_or_else(|| Error::invalid(format!("invalid range reference `{range}`")))?;
    let block = sheet
        .used_range()
        .and_then(|used| requested.intersection(&RangeRef::new(CellRef::new(0, 0), used.end)))
        .unwrap_or(RangeRef::cell(requested.start));
    if block.count() > MAX_CLIPBOARD_CELLS {
        return Err(Error::invalid(format!(
            "a copy holds at most {MAX_CLIPBOARD_CELLS} cells"
        )));
    }
    let rows = (block.start.row..=block.end.row)
        .map(|row| {
            (block.start.col..=block.end.col)
                .map(|col| {
                    let at = CellRef::new(row, col);
                    let input = cell_input_at(wb, sheet, at);
                    let value = match sheet.cell(at) {
                        Some(stored) if stored.formula.is_some() => {
                            value_input(&sheet.value(at), wb.date_system)
                        }
                        _ => input.clone(),
                    };
                    ClipboardCell {
                        input,
                        value,
                        text: display_text(wb, sheet, at),
                        format: full_format(wb, wb.styles.get(sheet.style_id(at))),
                    }
                })
                .collect()
        })
        .collect();
    Ok(ClipboardBlock {
        origin: block.start.a1(),
        rows,
    })
}

/// The `range.paste` operation that pastes `block` with its top-left cell on the A1 cell `cell`.
/// Formulas move their relative references by the distance from the block's origin.
pub fn paste_op(
    block: &ClipboardBlock,
    sheet_id: u32,
    cell: &str,
    mode: PasteMode,
) -> Result<Op, Error> {
    let origin = CellRef::parse(&block.origin)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{}`", block.origin)))?;
    let to = CellRef::parse(cell)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{cell}`")))?;
    let height = u32::try_from(block.rows.len()).unwrap_or(u32::MAX);
    let width = block
        .rows
        .iter()
        .map(Vec::len)
        .max()
        .and_then(|width| u32::try_from(width).ok())
        .unwrap_or(0);
    if height == 0 || width == 0 || block.rows.iter().any(|row| row.len() != width as usize) {
        return Err(Error::invalid(
            "a pasted block must be a rectangle of cells",
        ));
    }
    let end = to
        .offset(i64::from(height) - 1, i64::from(width) - 1)
        .filter(|end| end.is_valid())
        .ok_or_else(|| Error::invalid("the pasted block does not fit on the worksheet"))?;
    let rows = i64::from(to.row) - i64::from(origin.row);
    let cols = i64::from(to.col) - i64::from(origin.col);
    let cells = block
        .rows
        .iter()
        .map(|row| {
            row.iter()
                .map(|copied| PasteCell {
                    input: match mode {
                        PasteMode::All | PasteMode::Formulas => {
                            Some(moved_formula(&copied.input, rows, cols))
                        }
                        PasteMode::Values => Some(copied.value.clone()),
                        PasteMode::Formats => None,
                    },
                    format: matches!(mode, PasteMode::All | PasteMode::Formats)
                        .then(|| copied.format.clone()),
                })
                .collect()
        })
        .collect();
    Ok(Op::RangePaste {
        sheet_id,
        range: Range(RangeRef::new(to, end)),
        cells,
    })
}

/// A formula input with its relative references moved by `(rows, cols)`; other input as it is.
fn moved_formula(input: &str, rows: i64, cols: i64) -> String {
    let Some(body) = input.strip_prefix('=') else {
        return input.to_string();
    };
    match gridcraft_formula::parse_closing_parens(body, gridcraft_formula::parse) {
        Ok(expr) => format!(
            "={}",
            gridcraft_formula::print(&shift_relative(expr, rows, cols))
        ),
        Err(_) => input.to_string(),
    }
}

/// Every attribute of `style` that a format patch can set, so applying the patch to any cell
/// reproduces the style.
fn full_format(wb: &Workbook, style: &Style) -> FormatPatch {
    let hex = |color: Color| {
        color
            .resolve(&wb.theme)
            .map(|[r, g, b]| HexColor(u32::from(r) << 16 | u32::from(g) << 8 | u32::from(b)))
    };
    let border = |line: &BorderLine| {
        Some(border_style(line.style).map(|style| Border {
            style,
            color: hex(line.color),
        }))
    };
    let solid = style.fill.pattern != PatternType::None;
    FormatPatch {
        bold: Some(style.font.bold),
        italic: Some(style.font.italic),
        underline: Some(style.font.underline != Underline::None),
        strike: Some(style.font.strike),
        font_name: (!style.font.name.is_empty()).then(|| style.font.name.clone()),
        font_size: Some(style.font.size),
        font_color: Some(hex(style.font.color)),
        fill_color: Some(if solid { hex(style.fill.fg) } else { None }),
        h_align: Some(HAlign::from(style.align.h)),
        v_align: Some(VAlign::from(style.align.v)),
        wrap: Some(style.align.wrap),
        num_fmt: Some(style.num_fmt.as_str().to_string()),
        borders: Some(BordersPatch {
            left: border(&style.borders.left),
            right: border(&style.borders.right),
            top: border(&style.borders.top),
            bottom: border(&style.borders.bottom),
        }),
    }
}

/// The patch border style of a model border, or `None` when the side has no border.
fn border_style(style: gridcraft_model::BorderStyle) -> Option<BorderStyle> {
    use gridcraft_model::BorderStyle as Model;
    Some(match style {
        Model::None => return None,
        Model::Thin => BorderStyle::Thin,
        Model::Medium => BorderStyle::Medium,
        Model::Thick => BorderStyle::Thick,
        Model::Dashed => BorderStyle::Dashed,
        Model::Dotted => BorderStyle::Dotted,
        Model::Double => BorderStyle::Double,
        Model::Hair => BorderStyle::Hair,
        Model::MediumDashed => BorderStyle::MediumDashed,
        Model::DashDot => BorderStyle::DashDot,
        Model::MediumDashDot => BorderStyle::MediumDashDot,
        Model::DashDotDot => BorderStyle::DashDotDot,
        Model::MediumDashDotDot => BorderStyle::MediumDashDotDot,
        Model::SlantDashDot => BorderStyle::SlantDashDot,
    })
}

#[cfg(test)]
mod tests {
    use super::moved_formula;

    #[test]
    fn a_pasted_formula_moves_only_its_relative_references() {
        assert_eq!(moved_formula("=A1+$B$2+C$3", 2, 1), "=B3+$B$2+D$3");
        assert_eq!(moved_formula("plain", 2, 1), "plain");
        assert_eq!(moved_formula("=A1", -1, 0), "=#REF!");
    }
}
