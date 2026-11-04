//! The charts of a sheet as an editor paints them: where each one sits on the grid, and the
//! drawing primitives of one chart at the size the editor shows it.

use gridcraft_chart::{Measure, Prim, render, resolve};
use serde::Serialize;

use crate::Error;
use crate::doc::{SpreadsheetDoc, require_sheet};
use crate::ids::SheetId;

/// The widest or tallest drawing produced; a larger anchor is clamped.
const MAX_SIDE: f32 = 16_384.0;

/// A chart to paint over the grid, anchored like a floating picture.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderChart {
    /// The chart's object id in the workbook.
    pub chart_id: u32,
    /// The A1 cell that holds the chart's top-left corner.
    pub cell: String,
    /// How far the corner sits right of the cell's left edge, in pixels.
    pub dx: f32,
    /// How far the corner sits below the cell's top edge, in pixels.
    pub dy: f32,
    /// The chart's width in pixels.
    pub width: f32,
    /// The chart's height in pixels.
    pub height: f32,
    /// The chart kind, such as `ColumnClustered` or `Pie`.
    pub kind: String,
    /// The chart's title, when it has one.
    pub title: Option<String>,
}

/// The charts of one sheet, in drawing order.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet.
pub fn charts(doc: &SpreadsheetDoc, sheet_id: SheetId) -> Result<Vec<RenderChart>, Error> {
    let wb = doc.workbook();
    let index = require_sheet(wb, sheet_id)?;
    let sheet = wb
        .sheet(index)
        .ok_or_else(|| Error::invalid("the sheet disappeared during the read"))?;
    Ok(sheet
        .charts
        .iter()
        .map(|chart| RenderChart {
            chart_id: chart.id,
            cell: chart.anchor.cell.a1(),
            dx: chart.anchor.dx,
            dy: chart.anchor.dy,
            width: chart.anchor.width,
            height: chart.anchor.height,
            kind: format!("{:?}", chart.kind),
            title: chart.title.clone(),
        })
        .collect())
}

/// The drawing primitives of the chart `chart_id`, laid out for a `width` by `height` box in
/// pixels with the origin at the chart's top-left corner. The series are read from the workbook
/// as it is now. A box narrower or shorter than one pixel draws nothing.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet or chart.
pub fn chart_drawing(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    chart_id: u32,
    width: f32,
    height: f32,
) -> Result<Vec<Prim>, Error> {
    let wb = doc.workbook();
    let index = require_sheet(wb, sheet_id)?;
    let chart = wb
        .sheet(index)
        .and_then(|sheet| sheet.charts.iter().find(|chart| chart.id == chart_id))
        .ok_or_else(|| Error::invalid(format!("no chart has chart_id {chart_id} on this sheet")))?;
    let (width, height) = (width.min(MAX_SIDE), height.min(MAX_SIDE));
    if !(width >= 1.0 && height >= 1.0) {
        return Ok(Vec::new());
    }
    let data = resolve(wb, index, chart);
    Ok(render(chart, &data, width, height, &TextMeasure))
}

/// Text widths for the chart layout: a fixed-width estimate that counts an East Asian wide
/// character as a full em, so Chinese, Japanese, and Korean labels get the room they take on the
/// canvas.
struct TextMeasure;

impl Measure for TextMeasure {
    fn text_width(&self, text: &str, size: f32, bold: bool) -> f32 {
        let ems: f32 = text
            .chars()
            .map(|character| if wide(character) { 1.0 } else { 0.55 })
            .sum();
        ems * size * if bold { 1.1 } else { 1.0 }
    }
}

/// Whether a character takes a full em in East Asian text.
fn wide(character: char) -> bool {
    matches!(
        u32::from(character),
        0x1100..=0x115F
            | 0x2E80..=0xA4CF
            | 0xAC00..=0xD7A3
            | 0xF900..=0xFAFF
            | 0xFE30..=0xFE4F
            | 0xFF00..=0xFF60
            | 0xFFE0..=0xFFE6
            | 0x20000..=0x3FFFD
    )
}

#[cfg(test)]
mod tests {
    use gridcraft_chart::Measure;

    use super::TextMeasure;

    #[test]
    fn east_asian_characters_measure_a_full_em() {
        let measure = TextMeasure;
        assert_eq!(measure.text_width("ab", 10.0, false), 11.0);
        assert_eq!(measure.text_width("上海", 10.0, false), 20.0);
        assert!(measure.text_width("ab", 10.0, true) > measure.text_width("ab", 10.0, false));
    }
}
