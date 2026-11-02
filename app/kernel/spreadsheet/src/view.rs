//! Read-only views for an editor: sheet tabs, the cells of a viewport ready to paint, and the text
//! a cell editor starts from.

use std::collections::HashMap;

use gridcraft_core::{CellRef, DateSystem, RangeRef, Value};
use gridcraft_model::{
    BorderLine, BorderStyle, Color, LineInfo, PatternType, Sheet, StyleId, Visibility, Workbook,
};
use gridcraft_numfmt::{Formatted, NumberFormat, format_value};
use serde::Serialize;

use crate::Error;
use crate::doc::{SpreadsheetDoc, sheet_by_id};
use crate::ops::check_size;

/// A value formatted with its cell's number format, as the grid shows it.
fn display(wb: &Workbook, sheet: &Sheet, at: CellRef) -> Formatted {
    let value = sheet.value(at);
    if !sheet.show_zeros && value == Value::Number(0.0) {
        return Formatted::default();
    }
    let code = wb.styles.get(sheet.style_id(at)).num_fmt.as_str();
    format_value(&value, &NumberFormat::parse_cached(code), wb.date_system)
}

pub(crate) fn display_text(wb: &Workbook, sheet: &Sheet, at: CellRef) -> String {
    display(wb, sheet, at).text
}

/// One sheet tab and what an editor needs before it paints the grid.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SheetInfo {
    pub sheet_id: u32,
    pub name: String,
    pub hidden: bool,
    pub tab_color: Option<String>,
    /// Frozen rows and columns.
    pub freeze: Option<(u32, u32)>,
    pub default_row_height: f32,
    pub default_col_width: f32,
    pub show_gridlines: bool,
    /// Lines up to the last stored cell.
    pub rows: u32,
    pub cols: u32,
}

/// The sheets in tab order.
pub fn sheets(doc: &SpreadsheetDoc) -> Vec<SheetInfo> {
    let wb = doc.workbook();
    wb.sheets
        .iter()
        .map(|sheet| {
            let used = sheet.used_range();
            SheetInfo {
                sheet_id: sheet.file_id,
                name: sheet.name.clone(),
                hidden: sheet.visibility != Visibility::Visible,
                tab_color: sheet.tab_color.and_then(|color| color.hex(&wb.theme)),
                freeze: sheet.freeze,
                default_row_height: sheet.default_row_height,
                default_col_width: sheet.default_col_width,
                show_gridlines: sheet.show_gridlines,
                rows: used.map_or(0, |range| range.end.row + 1),
                cols: used.map_or(0, |range| range.end.col + 1),
            }
        })
        .collect()
}

/// The paintable content of a rectangle of one sheet.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Viewport {
    pub cells: Vec<RenderCell>,
    /// Distinct styles; cells and lines refer to them by position.
    pub styles: Vec<RenderStyle>,
    /// Merged areas that intersect the viewport, in A1 form.
    pub merges: Vec<String>,
    /// Dynamic-array spill areas that intersect the viewport, keyed by their anchor cell.
    pub spills: Vec<(String, String)>,
    /// Rows and columns in the viewport whose size, visibility, or style differs from the default.
    pub rows: Vec<RenderLine>,
    pub cols: Vec<RenderLine>,
}

/// A cell to paint. `kind` is `number`, `text`, `bool`, or `error`, which decides the default
/// alignment; `color` is the number format's colour (`[Red]`) when it has one.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderCell {
    pub row: u32,
    pub col: u32,
    pub text: String,
    pub kind: &'static str,
    pub style: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// The fingerprint of the picture the cell holds, which the editor paints instead of text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub picture: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderLine {
    pub index: u32,
    pub size: Option<f32>,
    pub hidden: bool,
    pub style: Option<usize>,
}

/// The part of a cell style a canvas needs: colours resolved to `#RRGGBB` through the theme.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderStyle {
    pub font_name: String,
    pub font_size: f32,
    pub bold: bool,
    pub italic: bool,
    pub underline: bool,
    pub strike: bool,
    pub font_color: Option<String>,
    pub fill_color: Option<String>,
    pub h_align: &'static str,
    pub v_align: &'static str,
    pub wrap: bool,
    pub indent: u8,
    pub rotation: i16,
    pub borders: RenderBorders,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderBorders {
    pub left: Option<RenderBorder>,
    pub right: Option<RenderBorder>,
    pub top: Option<RenderBorder>,
    pub bottom: Option<RenderBorder>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderBorder {
    pub style: &'static str,
    pub color: Option<String>,
}

/// The cells, styles, merged areas, spills, and line sizes of the zero-based rectangle from
/// `(r0, c0)` to `(r1, c1)` on one sheet.
pub fn viewport(
    doc: &SpreadsheetDoc,
    sheet_id: u32,
    r0: u32,
    c0: u32,
    r1: u32,
    c1: u32,
) -> Result<Viewport, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let (start, end) = (CellRef::new(r0, c0), CellRef::new(r1, c1));
    if !start.is_valid() || !end.is_valid() {
        return Err(Error::invalid("the viewport must lie on the worksheet"));
    }
    let range = RangeRef::new(start, end);
    check_size(range, "a viewport")?;
    let mut styles = StyleIndex::new(wb);
    let mut at_cells: Vec<CellRef> = sheet.cells.iter_range(range).map(|(at, _)| at).collect();
    let spilled = sheet
        .spill
        .range(range.start..=range.end)
        .map(|(at, _)| *at)
        .filter(|at| range.contains(*at) && sheet.cell(*at).is_none());
    at_cells.extend(spilled);
    let pictured = sheet
        .cell_pictures
        .range(range.start..=range.end)
        .map(|(at, _)| *at)
        .filter(|at| range.contains(*at) && sheet.cell(*at).is_none());
    at_cells.extend(pictured);
    at_cells.sort_unstable();
    at_cells.dedup();
    let cells = at_cells
        .into_iter()
        .map(|at| {
            let shown = display(wb, sheet, at);
            let kind = match sheet.value(at) {
                Value::Number(_) => "number",
                Value::Bool(_) => "bool",
                Value::Error(_) => "error",
                _ => "text",
            };
            RenderCell {
                row: at.row,
                col: at.col,
                text: shown.text,
                kind,
                style: styles.index(sheet.style_id(at)),
                color: shown
                    .color
                    .and_then(|color| color.rgb())
                    .map(|[r, g, b]| format!("#{r:02X}{g:02X}{b:02X}")),
                picture: sheet
                    .cell_pictures
                    .get(&at)
                    .map(|picture| fingerprint(&picture.data)),
            }
        })
        .collect();
    let lines = |infos: &std::collections::BTreeMap<u32, LineInfo>,
                 from: u32,
                 to: u32,
                 styles: &mut StyleIndex|
     -> Vec<RenderLine> {
        infos
            .range(from..=to)
            .map(|(index, info)| RenderLine {
                index: *index,
                size: info.size,
                hidden: info.hidden,
                style: info.style.map(|style| styles.index(style)),
            })
            .collect()
    };
    let rows = lines(&sheet.rows, range.start.row, range.end.row, &mut styles);
    let cols = lines(&sheet.cols, range.start.col, range.end.col, &mut styles);
    Ok(Viewport {
        cells,
        styles: styles.styles,
        merges: sheet
            .merges
            .iter()
            .filter(|merge| merge.intersects(&range))
            .map(RangeRef::a1)
            .collect(),
        spills: sheet
            .spill_ranges
            .iter()
            .filter(|(_, spill)| spill.intersects(&range))
            .map(|(anchor, spill)| (anchor.a1(), spill.a1()))
            .collect(),
        rows,
        cols,
    })
}

/// A floating picture to paint over the grid.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderImage {
    pub image_id: u32,
    /// The A1 cell that holds the picture's top-left corner.
    pub cell: String,
    /// The corner's offset into that cell, and the picture's size, in pixels.
    pub dx: f32,
    pub dy: f32,
    pub width: f32,
    pub height: f32,
    pub mime: String,
    pub alt: String,
    /// A fingerprint of the picture's bytes, so an editor decodes each picture once.
    pub digest: String,
}

/// The floating pictures of one sheet, in drawing order.
pub fn images(doc: &SpreadsheetDoc, sheet_id: u32) -> Result<Vec<RenderImage>, Error> {
    let sheet = sheet_by_id(doc.workbook(), sheet_id)?;
    Ok(sheet
        .images
        .iter()
        .map(|image| RenderImage {
            image_id: image.id,
            cell: image.anchor.cell.a1(),
            dx: image.anchor.dx,
            dy: image.anchor.dy,
            width: image.anchor.width,
            height: image.anchor.height,
            mime: image.mime.clone(),
            alt: image.alt.clone(),
            digest: fingerprint(&image.data),
        })
        .collect())
}

/// The encoded bytes of the floating picture `image_id`.
pub fn image_data(doc: &SpreadsheetDoc, sheet_id: u32, image_id: u32) -> Result<Vec<u8>, Error> {
    sheet_by_id(doc.workbook(), sheet_id)?
        .images
        .iter()
        .find(|image| image.id == image_id)
        .map(|image| image.data.as_ref().clone())
        .ok_or_else(|| Error::invalid(format!("no picture has image_id {image_id} on this sheet")))
}

/// The encoded bytes and MIME type of the picture in the A1 cell `cell`.
pub fn cell_picture(
    doc: &SpreadsheetDoc,
    sheet_id: u32,
    cell: &str,
) -> Result<(Vec<u8>, String), Error> {
    let at = CellRef::parse(cell)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{cell}`")))?;
    sheet_by_id(doc.workbook(), sheet_id)?
        .cell_pictures
        .get(&at)
        .map(|picture| (picture.data.clone(), picture.mime.clone()))
        .ok_or_else(|| Error::invalid(format!("{cell} holds no picture")))
}

/// A cache key for picture bytes: FNV-1a over the length, both ends, and a sample of the middle,
/// so a multi-megabyte picture costs a few hundred steps per viewport.
fn fingerprint(data: &[u8]) -> String {
    const PRIME: u64 = 0x0100_0000_01b3;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut feed = |byte: u8| {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(PRIME);
    };
    for byte in (data.len() as u64).to_le_bytes() {
        feed(byte);
    }
    let edge = data.len().min(512);
    data.iter().take(edge).for_each(|byte| feed(*byte));
    data.iter()
        .skip(data.len() - edge)
        .for_each(|byte| feed(*byte));
    data.iter().step_by(997).for_each(|byte| feed(*byte));
    format!("{hash:016x}")
}

/// Statistics of a selection, as a status bar shows them.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SelectionStats {
    /// Cells that show a value.
    pub count: u64,
    /// Cells whose value is a number.
    pub numbers: u64,
    pub sum: f64,
    /// `None` when no cell holds a number, and likewise for `min` and `max`.
    pub average: Option<f64>,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

/// Counts the values of `range` on one sheet and sums, averages, and bounds its numbers. Only
/// stored and spilled cells are visited, so a whole-column range costs what the column holds.
pub fn selection_stats(
    doc: &SpreadsheetDoc,
    sheet_id: u32,
    range: &str,
) -> Result<SelectionStats, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let range = RangeRef::parse(range)
        .filter(|range| range.end.is_valid())
        .ok_or_else(|| Error::invalid(format!("invalid range reference `{range}`")))?;
    let spilled = sheet
        .spill
        .range(range.start..=range.end)
        .map(|(at, _)| *at)
        .filter(|at| range.contains(*at) && sheet.cell(*at).is_none());
    let mut stats = SelectionStats::default();
    for at in sheet
        .cells
        .iter_range(range)
        .map(|(at, _)| at)
        .chain(spilled)
    {
        match sheet.value(at) {
            Value::Empty => {}
            Value::Text(text) if text.is_empty() => {}
            Value::Number(number) => {
                stats.count += 1;
                stats.numbers += 1;
                stats.sum += number;
                stats.min = Some(stats.min.map_or(number, |min| min.min(number)));
                stats.max = Some(stats.max.map_or(number, |max| max.max(number)));
            }
            _ => stats.count += 1,
        }
    }
    if stats.numbers > 0 {
        #[allow(
            clippy::cast_precision_loss,
            reason = "a selection holds far fewer than 2^52 cells"
        )]
        let average = stats.sum / stats.numbers as f64;
        stats.average = Some(average);
    }
    Ok(stats)
}

struct StyleIndex<'a> {
    wb: &'a Workbook,
    positions: HashMap<StyleId, usize>,
    styles: Vec<RenderStyle>,
}

impl<'a> StyleIndex<'a> {
    fn new(wb: &'a Workbook) -> Self {
        Self {
            wb,
            positions: HashMap::new(),
            styles: Vec::new(),
        }
    }

    fn index(&mut self, id: StyleId) -> usize {
        if let Some(position) = self.positions.get(&id) {
            return *position;
        }
        let style = self.wb.styles.get(id);
        let theme = &self.wb.theme;
        let hex = |color: Color| color.hex(theme);
        let border = |line: &BorderLine| {
            (!line.is_none()).then(|| RenderBorder {
                style: border_name(line.style),
                color: hex(line.color),
            })
        };
        let render = RenderStyle {
            font_name: style.font.name.clone(),
            font_size: style.font.size,
            bold: style.font.bold,
            italic: style.font.italic,
            underline: style.font.underline != gridcraft_model::Underline::None,
            strike: style.font.strike,
            font_color: hex(style.font.color),
            fill_color: (style.fill.pattern != PatternType::None)
                .then(|| hex(style.fill.fg))
                .flatten(),
            h_align: h_align_name(style.align.h),
            v_align: v_align_name(style.align.v),
            wrap: style.align.wrap,
            indent: style.align.indent,
            rotation: style.align.rotation,
            borders: RenderBorders {
                left: border(&style.borders.left),
                right: border(&style.borders.right),
                top: border(&style.borders.top),
                bottom: border(&style.borders.bottom),
            },
        };
        let position = self.styles.len();
        self.styles.push(render);
        self.positions.insert(id, position);
        position
    }
}

fn h_align_name(align: gridcraft_model::HAlign) -> &'static str {
    use gridcraft_model::HAlign;
    match align {
        HAlign::General => "general",
        HAlign::Left => "left",
        HAlign::Center => "center",
        HAlign::Right => "right",
        HAlign::Fill => "fill",
        HAlign::Justify => "justify",
        HAlign::CenterAcross => "center_across",
        HAlign::Distributed => "distributed",
    }
}

fn v_align_name(align: gridcraft_model::VAlign) -> &'static str {
    use gridcraft_model::VAlign;
    match align {
        VAlign::Top => "top",
        VAlign::Center => "center",
        VAlign::Bottom => "bottom",
        VAlign::Justify => "justify",
        VAlign::Distributed => "distributed",
    }
}

fn border_name(style: BorderStyle) -> &'static str {
    match style {
        BorderStyle::None => "none",
        BorderStyle::Thin => "thin",
        BorderStyle::Medium => "medium",
        BorderStyle::Thick => "thick",
        BorderStyle::Dashed => "dashed",
        BorderStyle::Dotted => "dotted",
        BorderStyle::Double => "double",
        BorderStyle::Hair => "hair",
        BorderStyle::MediumDashed => "medium_dashed",
        BorderStyle::DashDot => "dash_dot",
        BorderStyle::MediumDashDot => "medium_dash_dot",
        BorderStyle::DashDotDot => "dash_dot_dot",
        BorderStyle::MediumDashDotDot => "medium_dash_dot_dot",
        BorderStyle::SlantDashDot => "slant_dash_dot",
    }
}

/// The text a cell editor starts from, as GridCraft's editor shows it. Text that would read back
/// as something else gets a leading `'`, and a constant date shows as a date that reads back as
/// the same serial rather than as the serial itself.
pub fn cell_input(doc: &SpreadsheetDoc, sheet_id: u32, cell: &str) -> Result<String, Error> {
    let wb = doc.workbook();
    let sheet = sheet_by_id(wb, sheet_id)?;
    let at = CellRef::parse(cell)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{cell}`")))?;
    Ok(cell_input_at(wb, sheet, at))
}

/// [`cell_input`] for a resolved sheet and cell.
pub(crate) fn cell_input_at(wb: &Workbook, sheet: &Sheet, at: CellRef) -> String {
    let raw = sheet.input_text(at);
    let Some(stored) = sheet.cell(at).filter(|stored| stored.formula.is_none()) else {
        return raw;
    };
    let code = wb.styles.get(stored.style).num_fmt.as_str();
    let reads_as = |text: &str| gridcraft_core::parse::parse_input(text, wb.date_system).value;
    match &stored.value {
        Value::Text(text) if code != "@" && needs_quote(text, &reads_as) => format!("'{raw}"),
        Value::Number(number) if NumberFormat::parse_cached(code).is_date() => {
            let reads_back = |text: &str| matches!(reads_as(text), Value::Number(n) if (n - number).abs() < 1e-9);
            let shown = display_text(wb, sheet, at);
            if reads_back(&shown) {
                return shown;
            }
            let Some(dt) = gridcraft_core::date::datetime_from_serial(wb.date_system, *number)
            else {
                return raw;
            };
            let time = format!("{:02}:{:02}:{:02}", dt.hour, dt.minute, dt.second);
            let date = format!("{:04}-{:02}-{:02}", dt.year, dt.month, dt.day);
            let iso = if *number < 1.0 {
                time
            } else if number.fract() == 0.0 {
                date
            } else {
                format!("{date} {time}")
            };
            if reads_back(&iso) { iso } else { raw }
        }
        _ => raw,
    }
}

/// What typing reproduces `value` in a General cell: numbers to 15 significant digits, booleans
/// and errors by name, and text with a leading `'` when it would read back as something else.
pub(crate) fn value_input(value: &Value, date_system: DateSystem) -> String {
    match value {
        Value::Empty => String::new(),
        Value::Number(number) => gridcraft_core::number_to_text(*number),
        Value::Bool(true) => "TRUE".to_string(),
        Value::Bool(false) => "FALSE".to_string(),
        Value::Error(error) => error.as_str().to_string(),
        Value::Text(text) => {
            let reads_as = |text: &str| gridcraft_core::parse::parse_input(text, date_system).value;
            if needs_quote(text, &reads_as) {
                format!("'{text}")
            } else {
                text.to_string()
            }
        }
        Value::Array(_) => {
            format_value(value, &NumberFormat::parse_cached("General"), date_system).text
        }
    }
}

/// Whether typing `text` back into a General cell would not give the same text.
fn needs_quote(text: &str, reads_as: &impl Fn(&str) -> Value) -> bool {
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (None, _) => false,
        (Some('=' | '\''), _) => true,
        (Some('+' | '-'), Some(second)) if second.is_ascii_alphabetic() || second == '(' => true,
        _ => !matches!(reads_as(text), Value::Text(ref read) if read.as_ref() == text),
    }
}
