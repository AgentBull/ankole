//! Automatic row heights: a row without a height its author set grows with its largest font and
//! its wrapped text, and shrinks back when they go away.
//!
//! The measurement follows GridCraft's own (`gridcraft-engine`, `auto_row_height`, MIT OR
//! Apache-2.0), which this crate cannot depend on: the engine crate pulls in PDF and image
//! libraries that the WebAssembly build has no use for. Text widths are estimated from average
//! glyph widths, as GridCraft does without font metrics, so the server and every browser compute
//! the same heights.

use std::collections::BTreeSet;

use gridcraft_core::{CellRef, MAX_COLS, RangeRef};
use gridcraft_model::{DEFAULT_FONT_SIZE, DEFAULT_ROW_HEIGHT, LineInfo, Workbook};

use crate::doc::sheet_index;
use crate::ops::{LineKeyword, LineSize, Op};
use crate::view::display_text;

/// The most rows one operation fits; a larger range fits only the rows that hold cells.
const MAX_FITTED_ROWS: u32 = 100_000;
/// Excel's tallest row, in pixels.
const MAX_ROW_PX: f32 = 546.0;

/// The rows whose automatic height an executed operation may have changed, by sheet position.
pub(crate) fn touched_rows(wb: &Workbook, op: &Op) -> Vec<(usize, u32)> {
    let target = match op {
        Op::CellSet { cell, .. } | Op::CellPicture { cell, .. } => Some(RangeRef::cell(cell.0)),
        Op::RangeSetValues { range, .. }
        | Op::RangeClear { range, .. }
        | Op::RangeFormat { range, .. }
        | Op::RangeRestoreFormats { range, .. }
        | Op::RangeMerge { range, .. }
        | Op::RangeUnmerge { range, .. }
        | Op::RangePaste { range, .. }
        | Op::RangeSort { range, .. } => Some(range.0),
        Op::RangeFill { to, .. } => Some(to.0),
        Op::LineResize {
            axis: crate::ops::Axis::Rows,
            start,
            end,
            size_px: LineSize::Keyword(LineKeyword::Auto),
            ..
        } => Some(RangeRef::rows(*start, *end)),
        _ => None,
    };
    let (Some(range), Some(sheet_id)) = (target, op.sheet_id()) else {
        return Vec::new();
    };
    let Some(index) = sheet_index(wb, sheet_id) else {
        return Vec::new();
    };
    let Some(sheet) = wb.sheet(index) else {
        return Vec::new();
    };
    let mut rows = BTreeSet::new();
    if range.height() <= MAX_FITTED_ROWS {
        rows.extend(range.start.row..=range.end.row);
    } else {
        rows.extend(sheet.cells.iter_range(range).map(|(at, _)| at.row));
    }
    rows.into_iter().map(|row| (index, row)).collect()
}

/// Recomputes the automatic height of each row in `rows`. Rows with a height their author set
/// keep it.
pub(crate) fn fit_rows(wb: &mut Workbook, rows: &[(usize, u32)]) {
    for (index, row) in rows {
        let height = needed_height(wb, *index, *row);
        let Some(sheet) = wb.sheet_mut(*index) else {
            continue;
        };
        let Some(height) = height else { continue };
        let default = sheet.default_row_height;
        let info = sheet.rows.entry(*row).or_default();
        info.size = if (height - default).abs() < 0.5 {
            None
        } else {
            Some(height)
        };
        if *info == LineInfo::default() {
            sheet.rows.remove(row);
        }
    }
}

/// The height row `row` needs, or `None` when its author set its height.
fn needed_height(wb: &Workbook, index: usize, row: u32) -> Option<f32> {
    let sheet = wb.sheet(index)?;
    if sheet.rows.get(&row).is_some_and(|info| info.custom) {
        return None;
    }
    let mut need = sheet.default_row_height;
    // Merged cells never fit their rows, as in Excel.
    let merges: Vec<RangeRef> = sheet
        .merges
        .iter()
        .copied()
        .filter(|merge| !merge.is_single() && merge.start.row <= row && row <= merge.end.row)
        .collect();
    for (col, cell) in sheet.cells.row(row, 0, MAX_COLS - 1) {
        let at = CellRef::new(row, col);
        if merges.iter().any(|merge| merge.contains(at)) {
            continue;
        }
        let style = wb.styles.get(cell.style);
        let size = style.font.size;
        let filled = !cell.value.is_empty() || cell.formula.is_some();
        if !filled && size <= DEFAULT_FONT_SIZE {
            continue;
        }
        // Scaled from an 11 pt row rather than the sheet's default, so a sheet whose default
        // already fits a larger font does not scale it twice.
        let single = (size * 1.8)
            .round()
            .max(DEFAULT_ROW_HEIGHT * size / DEFAULT_FONT_SIZE);
        let lines = if filled && style.align.wrap {
            let width = (sheet.col_width(col).max(1.0) - 6.0).max(1.0);
            display_text(wb, sheet, at)
                .lines()
                .map(|line| wrapped_lines(line, width, size, style.font.bold))
                .sum::<f32>()
                .max(1.0)
        } else {
            1.0
        };
        let height = if lines > 1.0 {
            (size * 96.0 / 72.0 * 1.22 * lines + 5.0).ceil()
        } else {
            single
        };
        need = need.max(height.min(MAX_ROW_PX));
    }
    Some(need)
}

/// How many lines `line` takes when its words wrap at `width` pixels; a word wider than the
/// column breaks inside the word.
fn wrapped_lines(line: &str, width: f32, size: f32, bold: bool) -> f32 {
    let space = text_width(" ", size, bold);
    let mut lines = 1.0_f32;
    let mut used = 0.0_f32;
    for word in line.split_whitespace() {
        let word_width = text_width(word, size, bold);
        if word_width > width {
            if used > 0.0 {
                lines += 1.0;
            }
            let chunks = (word_width / width).ceil();
            lines += chunks - 1.0;
            used = word_width - (chunks - 1.0) * width;
            continue;
        }
        let gap = if used > 0.0 { space } else { 0.0 };
        if used + gap + word_width > width {
            lines += 1.0;
            used = word_width;
        } else {
            used += gap + word_width;
        }
    }
    lines
}

/// The estimated width of `text` in pixels, from average glyph widths of the default font; wide
/// characters such as Chinese take a full em.
fn text_width(text: &str, size: f32, bold: bool) -> f32 {
    let ems: f32 = text
        .chars()
        .map(|c| match c {
            'i' | 'l' | 'j' | '\'' | '.' | ',' | ':' | ';' | '!' | '|' => 0.28,
            'f' | 't' | 'r' | 'I' | ' ' | '(' | ')' | '-' => 0.38,
            'm' | 'w' | 'M' | 'W' => 0.85,
            c if c.is_ascii_uppercase() => 0.65,
            c if c.is_ascii_digit() => 0.56,
            c if c.is_ascii() => 0.52,
            _ => 1.0,
        })
        .sum();
    let weight = if bold { 1.07 } else { 1.0 };
    ems * size * weight * 96.0 / 72.0
}

#[cfg(test)]
mod tests {
    use super::{text_width, wrapped_lines};

    #[test]
    fn wrapped_text_breaks_at_words_and_inside_long_words() {
        let width = text_width("abcd", 11.0, false);
        assert_eq!(wrapped_lines("ab cd", width * 2.0, 11.0, false), 1.0);
        assert_eq!(
            wrapped_lines("abcd abcd abcd", width * 1.5, 11.0, false),
            3.0
        );
        assert_eq!(wrapped_lines("abcdabcdabcd", width, 11.0, false), 3.0);
        assert!(text_width("汉字", 11.0, false) > text_width("ab", 11.0, false));
    }
}
