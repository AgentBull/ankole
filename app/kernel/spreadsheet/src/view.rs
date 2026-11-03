//! Read-only views for an editor: sheet tabs, the cells of a viewport ready to paint, and the text
//! a cell editor starts from.

use std::collections::HashMap;

use gridcraft_core::{CellRef, DateSystem, RangeRef, Value};
use gridcraft_engine::cf::CfCache;
use gridcraft_engine::cmd::data::list_items;
use gridcraft_engine::tables::table_cell_style;
use gridcraft_model::{
    BorderLine, BorderStyle, Color, Fill, FilterCriterion, LineInfo, PatternType, Sheet, Style,
    StyleId, Table, Underline, ValidationKind, Visibility, Workbook,
};
use gridcraft_numfmt::{Formatted, NumberFormat, format_value};
use serde::Serialize;

use crate::Error;
use crate::doc::{SpreadsheetDoc, require_sheet, sheet_by_id};
use crate::ids::{CellArea, ImageId, SheetId};
use crate::ops::check_size;

/// The most entries a validation's dropdown list carries.
const MAX_LIST_ITEMS: usize = 1_000;

/// A value formatted with the number format `code`, as the grid shows it.
fn display_as(wb: &Workbook, sheet: &Sheet, at: CellRef, code: &str) -> Formatted {
    let value = sheet.value(at);
    if !sheet.show_zeros && value == Value::Number(0.0) {
        return Formatted::default();
    }
    format_value(&value, &NumberFormat::parse_cached(code), wb.date_system)
}

/// A value formatted with its cell's number format, as the grid shows it.
fn display(wb: &Workbook, sheet: &Sheet, at: CellRef) -> Formatted {
    let code = wb.styles.get(sheet.style_id(at)).num_fmt.as_str();
    display_as(wb, sheet, at, code)
}

fn is_false(value: &bool) -> bool {
    !*value
}

pub(crate) fn display_text(wb: &Workbook, sheet: &Sheet, at: CellRef) -> String {
    display(wb, sheet, at).text
}

/// One sheet tab and what an editor needs before it paints the grid.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SheetInfo {
    /// The sheet's stable id.
    pub sheet_id: SheetId,
    /// The tab's name.
    pub name: String,
    /// Whether the tab is hidden.
    pub hidden: bool,
    /// The tab colour as `#RRGGBB`.
    pub tab_color: Option<String>,
    /// Frozen rows and columns.
    pub freeze: Option<(u32, u32)>,
    /// The height of a row without its own size, in pixels.
    pub default_row_height: f32,
    /// The width of a column without its own size, in pixels.
    pub default_col_width: f32,
    /// Whether the grid draws gridlines.
    pub show_gridlines: bool,
    /// Lines up to the last stored cell.
    pub rows: u32,
    /// Columns up to the last stored cell.
    pub cols: u32,
}

/// The sheets in tab order.
#[must_use]
pub fn sheets(doc: &SpreadsheetDoc) -> Vec<SheetInfo> {
    let wb = doc.workbook();
    wb.sheets
        .iter()
        .map(|sheet| {
            let used = sheet.used_range();
            SheetInfo {
                sheet_id: SheetId(sheet.file_id),
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
    /// The cells that hold something to paint, in row-major order.
    pub cells: Vec<RenderCell>,
    /// Distinct styles; cells and lines refer to them by position.
    pub styles: Vec<RenderStyle>,
    /// Merged areas that intersect the viewport, in A1 form.
    pub merges: Vec<String>,
    /// Dynamic-array spill areas that intersect the viewport, keyed by their anchor cell.
    pub spills: Vec<(String, String)>,
    /// Rows and columns in the viewport whose size, visibility, or style differs from the default.
    pub rows: Vec<RenderLine>,
    /// Columns in the viewport whose size, visibility, or style differs from the default.
    pub cols: Vec<RenderLine>,
    /// The sheet's filter, when it has one.
    pub filter: Option<RenderFilter>,
    /// The tables that intersect the viewport.
    pub tables: Vec<RenderTable>,
    /// The validation rules whose ranges intersect the viewport, one entry per range.
    pub validations: Vec<RenderValidation>,
}

/// A cell to paint. `kind` is `number`, `text`, `bool`, or `error`, which decides the default
/// alignment; `color` is the number format's colour (`[Red]`) when it has one.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderCell {
    /// The zero-based row.
    pub row: u32,
    /// The zero-based column.
    pub col: u32,
    /// The value as the cell's number format shows it.
    pub text: String,
    /// The value's kind, which decides the default alignment.
    pub kind: &'static str,
    /// The position of the cell's own style in [`Viewport::styles`].
    pub style: usize,
    /// The position in [`Viewport::styles`] of the style the cell is painted with when a table
    /// style or a conditional format changes it; `style` stays the cell's own.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub look: Option<usize>,
    /// The colour that the number format gives the value, such as `[Red]`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// The fingerprint of the picture the cell holds, which the editor paints instead of text.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub picture: Option<String>,
    /// The note on the cell.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// The data bar or icon a conditional format adds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cf: Option<RenderCf>,
}

/// What a conditional format draws in a cell besides its style.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderCf {
    /// A data bar.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bar: Option<RenderBar>,
    /// An icon.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<RenderIcon>,
    /// Whether the rule shows the bar or icon in place of the value.
    #[serde(skip_serializing_if = "is_false")]
    pub hide_value: bool,
}

/// A data bar: the fraction of the cell width it fills, its colour, and whether it fades.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderBar {
    /// The filled fraction of the cell width, from 0 to 1.
    pub fraction: f32,
    /// The bar colour as `#RRGGBB`.
    pub color: String,
    /// Whether the bar fades towards its end.
    pub gradient: bool,
}

/// An icon from an icon set.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderIcon {
    /// The icon set's name, such as `3Arrows`.
    pub set: String,
    /// The icon's position in the set, 0 the lowest.
    pub index: usize,
}

/// The sheet's filter: its range with the header row, and the criteria of its filtered columns.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderFilter {
    /// The filtered range, in A1 form.
    pub range: String,
    /// The columns that hold a criterion.
    pub columns: Vec<RenderFilterColumn>,
}

/// The criterion of one filtered column.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderFilterColumn {
    /// The zero-based column.
    pub col: u32,
    /// The displayed values the criterion shows.
    pub values: Vec<String>,
    /// Whether the criterion shows blank cells.
    pub blanks: bool,
    /// Whether the criterion is a custom or top-N filter from the file, which the editor keeps
    /// but does not edit.
    pub custom: bool,
}

/// A table that intersects the viewport.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderTable {
    /// The table's name.
    pub name: String,
    /// The table's range, in A1 form.
    pub range: String,
    /// Whether the first row holds the column names.
    pub header_row: bool,
    /// Whether the last row holds totals.
    pub totals_row: bool,
    /// Whether the header cells show filter buttons.
    pub filter_button: bool,
}

/// One range of a validation rule that intersects the viewport.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderValidation {
    /// The range, in A1 form.
    pub range: String,
    /// The rule's kind: `any`, `whole`, `decimal`, `list`, `date`, `time`, `text_length`, or
    /// `custom`.
    pub kind: &'static str,
    /// Whether the cells offer a dropdown of the list's entries.
    pub dropdown: bool,
    /// The entries of a list with a dropdown, up to the first thousand.
    pub items: Vec<String>,
    /// The title of the message shown while a cell is selected.
    pub input_title: String,
    /// The message shown while a cell is selected.
    pub input_message: String,
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
    /// The font family.
    pub font_name: String,
    /// The font size in points.
    pub font_size: f32,
    /// Whether the text is bold.
    pub bold: bool,
    /// Whether the text is italic.
    pub italic: bool,
    /// Whether the text is underlined.
    pub underline: bool,
    /// Whether a line runs through the text.
    pub strike: bool,
    /// The text colour as `#RRGGBB`, or `None` for automatic.
    pub font_color: Option<String>,
    /// The fill colour as `#RRGGBB`, or `None` without a fill.
    pub fill_color: Option<String>,
    /// The horizontal alignment, such as `general` or `center`.
    pub h_align: &'static str,
    /// The vertical alignment, such as `bottom`.
    pub v_align: &'static str,
    /// Whether text wraps inside the cell.
    pub wrap: bool,
    /// The indent level.
    pub indent: u8,
    /// The text rotation in degrees.
    pub rotation: i16,
    /// The border on each side.
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

/// The cells, styles, merged areas, spills, and line sizes of `area` on one sheet.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet, or for an area that leaves the worksheet or
/// covers too many cells.
pub fn viewport(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    area: CellArea,
) -> Result<Viewport, Error> {
    let wb = doc.workbook();
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_by_id(wb, sheet_id)?;
    let start = CellRef::new(area.first_row, area.first_col);
    let end = CellRef::new(area.last_row, area.last_col);
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
    let noted = sheet
        .comments
        .range(range.start..=range.end)
        .map(|(at, _)| *at)
        .filter(|at| range.contains(*at));
    at_cells.extend(noted);
    // A table style and a conditional format paint blank cells too.
    let tables: Vec<&Table> = sheet
        .tables
        .iter()
        .filter(|table| table.range.intersects(&range))
        .collect();
    for part in tables
        .iter()
        .filter_map(|table| table.range.intersection(&range))
    {
        at_cells.extend(part.iter());
    }
    for part in sheet
        .cond_formats
        .iter()
        .flat_map(|format| format.ranges.iter())
        .filter_map(|area| area.intersection(&range))
    {
        at_cells.extend(part.iter());
    }
    at_cells.sort_unstable();
    at_cells.dedup();
    let mut cf_cache = CfCache::new();
    let cells = at_cells
        .into_iter()
        .map(|at| {
            let own_id = sheet.style_id(at);
            let own = wb.styles.get(own_id);
            let mut effective: Option<Style> = tables
                .iter()
                .find(|table| table.range.contains(at))
                .map(|table| table_cell_style(wb, index, table, at));
            let mut cf = None;
            if let Some(look) = cf_cache.look(wb, index, at) {
                if let Some(upper) = &look.style {
                    layer_over(effective.get_or_insert_with(|| own.clone()), upper);
                }
                if let Some([r, g, b]) = look.scale_fill {
                    effective.get_or_insert_with(|| own.clone()).fill =
                        Fill::solid(Color::rgb(r, g, b));
                }
                let bar = look.bar.map(|(fraction, [r, g, b], gradient)| RenderBar {
                    fraction,
                    color: format!("#{r:02X}{g:02X}{b:02X}"),
                    gradient,
                });
                let icon = look.icon.map(|(set, position)| RenderIcon {
                    set,
                    index: position,
                });
                if bar.is_some() || icon.is_some() {
                    cf = Some(RenderCf {
                        bar,
                        icon,
                        hide_value: look.hide_value,
                    });
                }
            }
            let effective = effective.filter(|style| style != own);
            let code = effective
                .as_ref()
                .map_or(own.num_fmt.as_str(), |style| style.num_fmt.as_str());
            let shown = display_as(wb, sheet, at, code);
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
                style: styles.index(own_id),
                look: effective.as_ref().map(|style| styles.index_style(style)),
                color: shown
                    .color
                    .and_then(|color| color.rgb())
                    .map(|[r, g, b]| format!("#{r:02X}{g:02X}{b:02X}")),
                picture: sheet
                    .cell_pictures
                    .get(&at)
                    .map(|picture| fingerprint(&picture.data)),
                note: sheet.comments.get(&at).map(|note| note.text.clone()),
                cf,
            }
        })
        .collect();
    let filter = sheet.autofilter.as_ref().map(|filter| RenderFilter {
        range: filter.range.a1(),
        columns: filter
            .criteria
            .iter()
            .map(|(offset, criterion)| {
                let (values, blanks, custom) = match criterion {
                    FilterCriterion::Values { values, blanks } => (values.clone(), *blanks, false),
                    _ => (Vec::new(), true, true),
                };
                RenderFilterColumn {
                    col: filter.range.start.col + offset,
                    values,
                    blanks,
                    custom,
                }
            })
            .collect(),
    });
    let validations = sheet
        .validations
        .iter()
        .flat_map(|validation| {
            validation
                .ranges
                .iter()
                .filter(|area| area.intersects(&range))
                .map(move |area| (area, validation))
        })
        .map(|(area, validation)| {
            let dropdown = validation.kind == ValidationKind::List && validation.in_cell_dropdown;
            let mut items = if dropdown {
                list_items(wb, index, validation)
            } else {
                Vec::new()
            };
            items.truncate(MAX_LIST_ITEMS);
            RenderValidation {
                range: area.a1(),
                kind: validation_kind_name(validation.kind),
                dropdown,
                items,
                input_title: validation.input_title.clone(),
                input_message: validation.input_message.clone(),
            }
        })
        .collect();
    let tables = tables
        .iter()
        .map(|table| RenderTable {
            name: table.name.clone(),
            range: table.range.a1(),
            header_row: table.header_row,
            totals_row: table.totals_row,
            filter_button: table.filter_button,
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
        filter,
        tables,
        validations,
    })
}

/// Puts the parts that a differential style sets over `base`: a conditional format's style wins
/// over the cell's own and over a table's.
fn layer_over(base: &mut Style, upper: &Style) {
    if upper.fill.pattern != PatternType::None {
        base.fill = upper.fill;
    }
    if upper.font.color != Color::Auto {
        base.font.color = upper.font.color;
    }
    base.font.bold |= upper.font.bold;
    base.font.italic |= upper.font.italic;
    base.font.strike |= upper.font.strike;
    if upper.font.underline != Underline::None {
        base.font.underline = upper.font.underline;
    }
    for (side, over) in [
        (&mut base.borders.left, upper.borders.left),
        (&mut base.borders.right, upper.borders.right),
        (&mut base.borders.top, upper.borders.top),
        (&mut base.borders.bottom, upper.borders.bottom),
    ] {
        if !over.is_none() {
            *side = over;
        }
    }
    if upper.num_fmt.as_str() != "General" {
        base.num_fmt = upper.num_fmt.clone();
    }
}

fn validation_kind_name(kind: ValidationKind) -> &'static str {
    match kind {
        ValidationKind::Any => "any",
        ValidationKind::Whole => "whole",
        ValidationKind::Decimal => "decimal",
        ValidationKind::List => "list",
        ValidationKind::Date => "date",
        ValidationKind::Time => "time",
        ValidationKind::TextLength => "text_length",
        ValidationKind::Custom => "custom",
    }
}

/// A floating picture to paint over the grid.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct RenderImage {
    /// The picture's object id in the workbook.
    pub image_id: ImageId,
    /// The A1 cell that holds the picture's top-left corner.
    pub cell: String,
    /// The corner's offset into that cell, and the picture's size, in pixels.
    pub dx: f32,
    /// How far the corner sits below the cell's top edge, in pixels.
    pub dy: f32,
    /// The picture's width in pixels.
    pub width: f32,
    /// The picture's height in pixels.
    pub height: f32,
    /// The picture's MIME type.
    pub mime: String,
    /// The alternative text that describes the picture.
    pub alt: String,
    /// A fingerprint of the picture's bytes, so an editor decodes each picture once.
    pub digest: String,
}

/// The floating pictures of one sheet, in drawing order.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet.
pub fn images(doc: &SpreadsheetDoc, sheet_id: SheetId) -> Result<Vec<RenderImage>, Error> {
    let sheet = sheet_by_id(doc.workbook(), sheet_id)?;
    Ok(sheet
        .images
        .iter()
        .map(|image| RenderImage {
            image_id: ImageId(image.id),
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
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet or picture.
pub fn image_data(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    image_id: ImageId,
) -> Result<Vec<u8>, Error> {
    sheet_by_id(doc.workbook(), sheet_id)?
        .images
        .iter()
        .find(|image| image.id == image_id.0)
        .map(|image| image.data.as_ref().clone())
        .ok_or_else(|| Error::invalid(format!("no picture has image_id {image_id} on this sheet")))
}

/// The encoded bytes of a cell picture and their MIME type.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CellPictureData {
    /// The encoded PNG or JPEG bytes.
    pub bytes: Vec<u8>,
    /// The bytes' MIME type, such as `image/png`.
    pub mime: String,
}

/// The encoded bytes and MIME type of the picture in the A1 cell `cell`.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet, an invalid cell, or a cell without a picture.
pub fn cell_picture(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
    cell: &str,
) -> Result<CellPictureData, Error> {
    let at = CellRef::parse(cell)
        .ok_or_else(|| Error::invalid(format!("invalid cell reference `{cell}`")))?;
    sheet_by_id(doc.workbook(), sheet_id)?
        .cell_pictures
        .get(&at)
        .map(|picture| CellPictureData {
            bytes: picture.data.clone(),
            mime: picture.mime.clone(),
        })
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
    let head = data.iter().take(edge);
    let tail = data.iter().skip(data.len() - edge);
    for byte in head.chain(tail).chain(data.iter().step_by(997)) {
        feed(*byte);
    }
    format!("{hash:016x}")
}

/// Statistics of a selection, as a status bar shows them.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct SelectionStats {
    /// Cells that show a value.
    pub count: u64,
    /// Cells whose value is a number.
    pub numbers: u64,
    /// The sum of the numbers.
    pub sum: f64,
    /// `None` when no cell holds a number, and likewise for `min` and `max`.
    pub average: Option<f64>,
    /// The smallest number.
    pub min: Option<f64>,
    /// The largest number.
    pub max: Option<f64>,
}

/// Counts the values of `range` on one sheet and sums, averages, and bounds its numbers. Only
/// stored and spilled cells are visited, so a whole-column range costs what the column holds.
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet or an invalid range.
pub fn selection_stats(
    doc: &SpreadsheetDoc,
    sheet_id: SheetId,
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

/// The distinct styles of one viewport: the workbook's by id, and computed ones (a table's or a
/// conditional format's look) by value.
struct StyleIndex<'a> {
    wb: &'a Workbook,
    positions: HashMap<StyleId, usize>,
    values: HashMap<Style, usize>,
    styles: Vec<RenderStyle>,
}

impl<'a> StyleIndex<'a> {
    fn new(wb: &'a Workbook) -> Self {
        Self {
            wb,
            positions: HashMap::new(),
            values: HashMap::new(),
            styles: Vec::new(),
        }
    }

    fn index(&mut self, id: StyleId) -> usize {
        if let Some(position) = self.positions.get(&id) {
            return *position;
        }
        let style = self.wb.styles.get(id).clone();
        let position = self.index_style(&style);
        self.positions.insert(id, position);
        position
    }

    fn index_style(&mut self, style: &Style) -> usize {
        if let Some(position) = self.values.get(style) {
            return *position;
        }
        let position = self.styles.len();
        self.styles.push(render_style(self.wb, style));
        self.values.insert(style.clone(), position);
        position
    }
}

/// The paintable form of a style, its colours resolved through the workbook's theme.
fn render_style(wb: &Workbook, style: &Style) -> RenderStyle {
    let theme = &wb.theme;
    let hex = |color: Color| color.hex(theme);
    let border = |line: &BorderLine| {
        (!line.is_none()).then(|| RenderBorder {
            style: border_name(line.style),
            color: hex(line.color),
        })
    };
    RenderStyle {
        font_name: style.font.name.clone(),
        font_size: style.font.size,
        bold: style.font.bold,
        italic: style.font.italic,
        underline: style.font.underline != Underline::None,
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
///
/// # Errors
///
/// Returns [`Error::Invalid`] for an unknown sheet or an invalid cell.
pub fn cell_input(doc: &SpreadsheetDoc, sheet_id: SheetId, cell: &str) -> Result<String, Error> {
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
