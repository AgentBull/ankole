//! Canonical spreadsheet operations: the JSON wire shape, parsing, and execution.
//!
//! Every operation names its sheet by the stable `sheet_id` and its cells by absolute A1
//! coordinates, so it means the same thing on every replica and never depends on a selection,
//! a clipboard, or the active sheet. The `type` field selects the operation.

use gridcraft_calc::Key;
use gridcraft_core::{CellRef, MAX_COLS, MAX_ROWS, RangeRef};
use gridcraft_model::Workbook;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::Error;
use crate::ids::{ImageId, SheetId};

mod data;
pub(crate) mod edit;
mod fill;
mod images;
mod sheets;

pub use fill::FillMode;
pub use images::MAX_PICTURE_BYTES;

/// One canonical operation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum Op {
    /// Types `input` into a cell: a value, or a formula when it starts with `=`. `array` stores a
    /// formula as a one-cell legacy array formula.
    #[serde(rename = "cell.set")]
    CellSet {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cell, in A1 form.
        cell: Cell,
        /// What the author typed.
        input: String,
        /// How the formula is stored.
        #[serde(default, skip_serializing_if = "is_default")]
        array: FormulaStorage,
    },
    /// Writes a block of values whose shape matches `range`. Strings are read as typed input
    /// unless `parse` is false; `null` clears a cell's content and keeps its format.
    #[serde(rename = "range.set_values")]
    RangeSetValues {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The values, row by row, in the shape of `range`.
        values: Vec<Vec<Option<Scalar>>>,
        /// How strings are read.
        #[serde(default, skip_serializing_if = "is_default")]
        parse: TextInput,
    },
    /// Removes what `mode` names from the cells of `range`.
    #[serde(rename = "range.clear")]
    RangeClear {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// What to remove from the cells.
        mode: ClearMode,
    },
    /// Applies the same format patch to every cell of the range.
    #[serde(rename = "range.format")]
    RangeFormat {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The format fields to change.
        patch: FormatPatch,
    },
    /// Merges the range, or each of its rows when `across` is set. Merged areas that intersect the
    /// range are replaced, and only the top-left value of each new area survives.
    #[serde(rename = "range.merge")]
    RangeMerge {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// Whether the range merges whole or row by row.
        #[serde(default, skip_serializing_if = "is_default")]
        across: MergeShape,
    },
    /// Removes every merged area that intersects the range.
    #[serde(rename = "range.unmerge")]
    RangeUnmerge {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
    },
    /// Sizes, hides, or shows the zero-based lines `start..=end`.
    #[serde(rename = "line.resize")]
    LineResize {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The zero-based first line.
        start: u32,
        /// The zero-based last line.
        end: u32,
        /// The new size in pixels, or a keyword.
        size_px: LineSize,
    },
    /// Freezes the top `rows` and left `cols`; zero for both unfreezes.
    #[serde(rename = "sheet.freeze")]
    SheetFreeze {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// How many top rows stay in place; zero freezes none.
        rows: u32,
        /// How many left columns stay in place; zero freezes none.
        cols: u32,
    },
    /// Inserts `count` lines before the zero-based line `at`.
    #[serde(rename = "line.insert")]
    LineInsert {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The zero-based index of the first line.
        at: u32,
        /// How many lines.
        count: u32,
    },
    /// Deletes `count` lines starting at the zero-based line `at`.
    #[serde(rename = "line.delete")]
    LineDelete {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The zero-based index of the first line.
        at: u32,
        /// How many lines.
        count: u32,
    },
    /// Inserts blank cells over `range`, shifting the cells there `down` or `right`.
    #[serde(rename = "cells.insert")]
    CellsInsert {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// Which way the cells there move.
        shift: Shift,
    },
    /// Deletes the cells of `range`, shifting the cells after them `up` or `left`.
    #[serde(rename = "cells.delete")]
    CellsDelete {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// Which way the cells after the range move.
        shift: Shift,
    },
    /// Cut and paste: moves the block `from` so that its top-left cell lands on `to_cell` of
    /// `to_sheet_id`, and points references to the block at its new place.
    #[serde(rename = "range.move")]
    RangeMove {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The block to move.
        from: Range,
        /// The sheet the block moves to.
        to_sheet_id: SheetId,
        /// Where the block's top-left cell lands, in A1 form.
        to_cell: Cell,
    },
    /// Pastes a block of cells: each cell's `input` (typed input, with formulas already moved to
    /// their new place) and its full `format`. A cell without `input` keeps its content, and a
    /// cell without `format` keeps its format.
    #[serde(rename = "range.paste")]
    RangePaste {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The pasted cells, row by row, in the shape of `range`.
        cells: Vec<Vec<PasteCell>>,
    },
    /// Places a picture over the grid. The editor names the new image with an `image_id` that no
    /// object of the workbook uses, so later operations can address it before the commit returns;
    /// without one, the committed operation carries the assigned id.
    #[serde(rename = "image.insert")]
    ImageInsert {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The floating picture, by its object id in the workbook.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_id: Option<ImageId>,
        /// Where the picture sits.
        anchor: ImageAnchor,
        /// The picture's encoded bytes and type.
        picture: Picture,
    },
    /// Moves or resizes a floating picture.
    #[serde(rename = "image.update")]
    ImageUpdate {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The floating picture, by its object id in the workbook.
        image_id: ImageId,
        /// Where the picture sits.
        anchor: ImageAnchor,
    },
    /// Removes a floating picture.
    #[serde(rename = "image.delete")]
    ImageDelete {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The floating picture, by its object id in the workbook.
        image_id: ImageId,
    },
    /// Puts a picture into a cell in place of its content, or removes the cell's picture with
    /// `null`.
    #[serde(rename = "cell.picture")]
    CellPicture {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cell, in A1 form.
        cell: Cell,
        /// The picture; `null` removes the cell's picture.
        picture: Option<Picture>,
    },
    /// Moves the floating picture `image_id` into `cell`, in place of the cell's content.
    #[serde(rename = "image.to_cell")]
    ImageToCell {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The floating picture, by its object id in the workbook.
        image_id: ImageId,
        /// The cell the picture moves into, in A1 form.
        cell: Cell,
    },
    /// Lifts the picture of `cell` out of the cell into a floating picture at `anchor`, named
    /// like a new image of `image.insert`.
    #[serde(rename = "image.from_cell")]
    ImageFromCell {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cell whose picture is lifted out, in A1 form.
        cell: Cell,
        /// The floating picture, by its object id in the workbook.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image_id: Option<ImageId>,
        /// Where the picture sits.
        anchor: ImageAnchor,
    },
    /// Puts back the formats that [`format_snapshot`](crate::format_snapshot) read from `range`,
    /// as undo does. Whole rows or columns take back their line formats, and lines left out of
    /// `lines` lose theirs. Cells listed in `cells` take back their own formats; any other cell
    /// in the range loses its own format, and a cell that holds nothing then disappears.
    #[serde(rename = "range.restore_formats")]
    RangeRestoreFormats {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The line formats of whole rows or columns, by offset from the range's first line.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lines: Vec<LineFormat>,
        /// The formats of the cells that held their own, by offset from the range's first cell.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        cells: Vec<CellFormat>,
    },
    /// Fills `to` from the cells of `range` at its start, as dragging the fill handle does. `to`
    /// holds `range` and reaches past exactly one of its edges.
    #[serde(rename = "range.fill")]
    RangeFill {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The source cells at the start of `to`.
        range: Range,
        /// The range to fill, which holds `range`.
        to: Range,
        /// How the fill continues its source.
        #[serde(default, skip_serializing_if = "is_default")]
        mode: FillMode,
    },
    /// Adds an empty sheet at `index` (the end by default). The committed operation always carries
    /// the assigned `sheet_id` and name.
    #[serde(rename = "sheet.insert")]
    SheetInsert {
        /// The new sheet's id; the committed operation always carries it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sheet_id: Option<SheetId>,
        /// The new sheet's name; the committed operation always carries it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        /// The zero-based tab position; the sheet goes last without one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index: Option<usize>,
    },
    /// Deletes a sheet. The committed operation records the deleted sheet's `name` so that
    /// concurrent formulas can be rebased.
    #[serde(rename = "sheet.delete")]
    SheetDelete {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The deleted sheet's name, which the committed operation records.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    /// Renames a sheet. The committed operation records `old_name` so that concurrent formulas can
    /// be rebased.
    #[serde(rename = "sheet.rename")]
    SheetRename {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The new name.
        name: String,
        /// The previous name, which the committed operation records.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_name: Option<String>,
    },
    /// Moves a sheet to the zero-based tab position `index`.
    #[serde(rename = "sheet.reorder")]
    SheetReorder {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The new zero-based tab position.
        index: usize,
    },
    /// Sets the tab colour, or clears it with `null`.
    #[serde(rename = "sheet.tab_color")]
    SheetTabColor {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The tab colour; `null` removes it.
        color: Option<HexColor>,
    },
    /// Sorts the rows of `range` by the key columns, which must lie inside the range. `header`
    /// keeps the first row in place.
    #[serde(rename = "range.sort")]
    RangeSort {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The key columns, the most significant first.
        keys: Vec<SortKey>,
        /// Whether the first row stays in place as a header.
        #[serde(default, skip_serializing_if = "is_default")]
        header: SortHeader,
    },
    /// Sets the sheet's AutoFilter over `range` (first row = header) and hides the data rows that
    /// fail any column's value list, or removes the filter with `range: null`.
    #[serde(rename = "filter.set")]
    FilterSet {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The filtered range with its header row; `null` removes the filter.
        range: Option<Range>,
        /// The value lists of the filtered columns.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        columns: Vec<FilterColumn>,
    },
    /// Replaces the data validation of `range`, or removes it with `rule: null`.
    #[serde(rename = "validation.set")]
    ValidationSet {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// The rule; `null` removes validation from the range.
        rule: Option<ValidationRule>,
    },
    /// Sets the note on a cell, or removes it with `text: null`.
    #[serde(rename = "comment.set")]
    CommentSet {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cell, in A1 form.
        cell: Cell,
        /// The note's text; `null` removes the note.
        text: Option<String>,
        /// The note's author, which the control plane writes.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        author: Option<String>,
    },
    /// Formats `range` as a table (first row = headers) when `enabled`, or converts the table that
    /// intersects `range` back to a plain range. The committed operation records the table name.
    #[serde(rename = "table.toggle")]
    TableToggle {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The cells, in A1 form.
        range: Range,
        /// Whether the table is created or converted back to a plain range.
        enabled: TableChange,
        /// The table's name, which the committed operation records.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn is_default<T: Default + PartialEq>(value: &T) -> bool {
    *value == T::default()
}

fn is_true(value: &bool) -> bool {
    *value
}

fn yes() -> bool {
    true
}

/// An absolute A1 cell reference such as `C5`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell(pub CellRef);

impl Serialize for Cell {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0.a1())
    }
}

impl<'de> Deserialize<'de> for Cell {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        CellRef::parse(&text)
            .map(Cell)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid cell reference `{text}`")))
    }
}

/// An absolute A1 range: `B2:D10`, a single cell, whole columns `A:C`, or whole rows `3:5`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Range(pub RangeRef);

impl Serialize for Range {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.0.a1())
    }
}

impl<'de> Deserialize<'de> for Range {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        RangeRef::parse(&text)
            .filter(|range| range.end.is_valid())
            .map(Range)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid range reference `{text}`")))
    }
}

/// A column named by its letters, such as `B`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Column(pub u32);

impl Serialize for Column {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&gridcraft_core::col_to_letters(self.0))
    }
}

impl<'de> Deserialize<'de> for Column {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        gridcraft_core::letters_to_col(&text)
            .filter(|col| *col < MAX_COLS)
            .map(Column)
            .ok_or_else(|| serde::de::Error::custom(format!("invalid column `{text}`")))
    }
}

/// A colour written as `#RRGGBB`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HexColor(pub u32);

impl Serialize for HexColor {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&format!("#{:06X}", self.0))
    }
}

impl<'de> Deserialize<'de> for HexColor {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        let hex = text.strip_prefix('#').filter(|hex| hex.len() == 6);
        hex.and_then(|hex| u32::from_str_radix(hex, 16).ok())
            .map(HexColor)
            .ok_or_else(|| {
                serde::de::Error::custom(format!("invalid colour `{text}`; expected #RRGGBB"))
            })
    }
}

/// Where a floating picture sits: its top-left corner `dx`, `dy` pixels into `cell`, and its
/// size in pixels. The picture moves with its cell when lines are inserted or deleted.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImageAnchor {
    /// The cell that holds the picture's top-left corner, in A1 form.
    pub cell: Cell,
    /// How far the top-left corner sits right of the cell's left edge, in pixels.
    #[serde(default)]
    pub dx: f32,
    /// How far the top-left corner sits below the cell's top edge, in pixels.
    #[serde(default)]
    pub dy: f32,
    /// The picture's width in pixels.
    pub width: f32,
    /// The picture's height in pixels.
    pub height: f32,
}

/// An encoded PNG or JPEG picture.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Picture {
    /// The encoding.
    pub mime: PictureMime,
    /// The encoded bytes.
    pub data: Base64,
    /// The alternative text that describes the picture.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub alt: String,
}

/// The encodings a picture may use; Excel shows both in floating and in-cell pictures.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PictureMime {
    /// A PNG picture.
    #[serde(rename = "image/png")]
    Png,
    /// A JPEG picture.
    #[serde(rename = "image/jpeg")]
    Jpeg,
}

impl PictureMime {
    /// The MIME type of the encoding.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            PictureMime::Png => "image/png",
            PictureMime::Jpeg => "image/jpeg",
        }
    }
}

/// Bytes written as standard base64 text.
#[derive(Clone, PartialEq, Eq)]
pub struct Base64(pub Vec<u8>);

impl std::fmt::Debug for Base64 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Base64({} bytes)", self.0.len())
    }
}

impl Serialize for Base64 {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&base64_simd::STANDARD.encode_to_string(&self.0))
    }
}

impl<'de> Deserialize<'de> for Base64 {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        base64_simd::STANDARD
            .decode_to_vec(text.as_bytes())
            .map(Base64)
            .map_err(|_| serde::de::Error::custom("data must be standard base64"))
    }
}

/// How `cell.set` stores a formula; on the wire it is the boolean `array`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "bool", into = "bool")]
pub enum FormulaStorage {
    /// An ordinary formula.
    #[default]
    Ordinary,
    /// A one-cell legacy array formula, as Ctrl+Shift+Enter enters it.
    LegacyArray,
}

impl From<bool> for FormulaStorage {
    fn from(array: bool) -> Self {
        if array {
            Self::LegacyArray
        } else {
            Self::Ordinary
        }
    }
}

impl From<FormulaStorage> for bool {
    fn from(storage: FormulaStorage) -> Self {
        storage == FormulaStorage::LegacyArray
    }
}

/// How `range.set_values` reads strings; on the wire it is the boolean `parse`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "bool", into = "bool")]
pub enum TextInput {
    /// As typed input: numbers, dates, and formulas become what they read as.
    #[default]
    Typed,
    /// As text, exactly as given.
    Literal,
}

impl From<bool> for TextInput {
    fn from(parse: bool) -> Self {
        if parse { Self::Typed } else { Self::Literal }
    }
}

impl From<TextInput> for bool {
    fn from(input: TextInput) -> Self {
        input == TextInput::Typed
    }
}

/// What `range.merge` merges; on the wire it is the boolean `across`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "bool", into = "bool")]
pub enum MergeShape {
    /// The whole range into one area.
    #[default]
    Whole,
    /// Each row of the range into an area of its own.
    EachRow,
}

impl From<bool> for MergeShape {
    fn from(across: bool) -> Self {
        if across { Self::EachRow } else { Self::Whole }
    }
}

impl From<MergeShape> for bool {
    fn from(shape: MergeShape) -> Self {
        shape == MergeShape::EachRow
    }
}

/// Whether `range.sort` keeps a header row; on the wire it is the boolean `header`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "bool", into = "bool")]
pub enum SortHeader {
    /// Every row of the range is sorted.
    #[default]
    None,
    /// The first row stays in place as a header.
    FirstRow,
}

impl From<bool> for SortHeader {
    fn from(header: bool) -> Self {
        if header { Self::FirstRow } else { Self::None }
    }
}

impl From<SortHeader> for bool {
    fn from(header: SortHeader) -> Self {
        header == SortHeader::FirstRow
    }
}

/// What `table.toggle` does; on the wire it is the boolean `enabled`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "bool", into = "bool")]
pub enum TableChange {
    /// Formats the range as a table.
    Create,
    /// Converts the table back to a plain range.
    Remove,
}

impl From<bool> for TableChange {
    fn from(enabled: bool) -> Self {
        if enabled { Self::Create } else { Self::Remove }
    }
}

impl From<TableChange> for bool {
    fn from(change: TableChange) -> Self {
        change == TableChange::Create
    }
}

/// The format of one whole row or column in a format snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LineFormat {
    /// The line's offset from the first line of the range.
    pub offset: u32,
    /// The line's full format.
    pub format: FormatPatch,
}

/// The format of one cell in a format snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CellFormat {
    /// The cell's row offset from the first row of the range.
    pub row: u32,
    /// The cell's column offset from the first column of the range.
    pub col: u32,
    /// The cell's full format.
    pub format: FormatPatch,
}

/// One cell of `range.paste`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasteCell {
    /// Typed input, with formulas already moved to the destination; absent keeps the content.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input: Option<String>,
    /// Replaces the cell's whole format: attributes the patch leaves out take their defaults.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<FormatPatch>,
}

/// A JSON scalar written into one cell by `range.set_values`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Scalar {
    Bool(bool),
    Number(serde_json::Number),
    Text(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Axis {
    Rows,
    Cols,
}

impl Axis {
    pub(crate) fn grid(self) -> gridcraft_formula::adjust::Axis {
        match self {
            Axis::Rows => gridcraft_formula::adjust::Axis::Rows,
            Axis::Cols => gridcraft_formula::adjust::Axis::Cols,
        }
    }

    pub(crate) fn limit(self) -> u32 {
        match self {
            Axis::Rows => MAX_ROWS,
            Axis::Cols => MAX_COLS,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Shift {
    Down,
    Right,
    Up,
    Left,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClearMode {
    All,
    Contents,
    Formats,
    Comments,
    Hyperlinks,
}

/// A line size in pixels, or a keyword: `auto` returns the lines to their default size, and
/// `hidden` / `unhide` hide or show them without changing their size.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum LineSize {
    Px(f32),
    Keyword(LineKeyword),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LineKeyword {
    Auto,
    Hidden,
    Unhide,
}

/// Format fields to change; absent fields keep their current value. For colours and borders,
/// `null` removes the setting.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FormatPatch {
    /// Bold text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bold: Option<bool>,
    /// Italic text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub italic: Option<bool>,
    /// A single underline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub underline: Option<bool>,
    /// A line through the text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub strike: Option<bool>,
    /// The font family, such as `Calibri` or `微软雅黑`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_name: Option<String>,
    /// The font size in points, from 1 to 409.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_size: Option<f32>,
    /// The text colour; `null` restores the automatic colour.
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub font_color: Option<Option<HexColor>>,
    /// A solid fill; `null` removes the fill.
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub fill_color: Option<Option<HexColor>>,
    /// The horizontal alignment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub h_align: Option<HAlign>,
    /// The vertical alignment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v_align: Option<VAlign>,
    /// Whether text wraps inside the cell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wrap: Option<bool>,
    /// The indent level, from 0 to 250.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub indent: Option<u8>,
    /// The text rotation in degrees from -90 to 90, or 255 for stacked vertical text.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotation: Option<i16>,
    /// The number format code, such as `#,##0.00`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_fmt: Option<String>,
    /// The border sides to change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub borders: Option<BordersPatch>,
}

/// Border sides to change; `null` removes a side.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BordersPatch {
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub left: Option<Option<Border>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub right: Option<Option<Border>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub top: Option<Option<Border>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub bottom: Option<Option<Border>>,
}

/// Tells a present `null` (`Some(None)`) apart from an absent field (`None`).
fn present<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Option<Option<T>>, D::Error> {
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Border {
    pub style: BorderStyle,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<HexColor>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BorderStyle {
    Thin,
    Medium,
    Thick,
    Dashed,
    Dotted,
    Double,
    Hair,
    MediumDashed,
    DashDot,
    MediumDashDot,
    DashDotDot,
    MediumDashDotDot,
    SlantDashDot,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HAlign {
    General,
    Left,
    Center,
    Right,
    Fill,
    Justify,
    CenterAcross,
    Distributed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VAlign {
    Top,
    Center,
    Bottom,
    Justify,
    Distributed,
}

impl From<gridcraft_model::HAlign> for HAlign {
    fn from(align: gridcraft_model::HAlign) -> Self {
        use gridcraft_model::HAlign as Model;
        match align {
            Model::General => HAlign::General,
            Model::Left => HAlign::Left,
            Model::Center => HAlign::Center,
            Model::Right => HAlign::Right,
            Model::Fill => HAlign::Fill,
            Model::Justify => HAlign::Justify,
            Model::CenterAcross => HAlign::CenterAcross,
            Model::Distributed => HAlign::Distributed,
        }
    }
}

impl From<HAlign> for gridcraft_model::HAlign {
    fn from(align: HAlign) -> Self {
        match align {
            HAlign::General => Self::General,
            HAlign::Left => Self::Left,
            HAlign::Center => Self::Center,
            HAlign::Right => Self::Right,
            HAlign::Fill => Self::Fill,
            HAlign::Justify => Self::Justify,
            HAlign::CenterAcross => Self::CenterAcross,
            HAlign::Distributed => Self::Distributed,
        }
    }
}

impl From<gridcraft_model::VAlign> for VAlign {
    fn from(align: gridcraft_model::VAlign) -> Self {
        use gridcraft_model::VAlign as Model;
        match align {
            Model::Top => VAlign::Top,
            Model::Center => VAlign::Center,
            Model::Bottom => VAlign::Bottom,
            Model::Justify => VAlign::Justify,
            Model::Distributed => VAlign::Distributed,
        }
    }
}

impl From<VAlign> for gridcraft_model::VAlign {
    fn from(align: VAlign) -> Self {
        match align {
            VAlign::Top => Self::Top,
            VAlign::Center => Self::Center,
            VAlign::Bottom => Self::Bottom,
            VAlign::Justify => Self::Justify,
            VAlign::Distributed => Self::Distributed,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SortKey {
    pub col: Column,
    #[serde(default, skip_serializing_if = "is_false")]
    pub descending: bool,
}

/// Keeps the data rows whose displayed text in `col` is one of `values` (case-insensitive), plus
/// empty cells when `blanks` is set.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FilterColumn {
    pub col: Column,
    pub values: Vec<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub blanks: bool,
}

/// A data-validation rule. For `list`, `formula1` is either a range formula such as `=$A$1:$A$5`
/// or comma-separated literal items. For the other kinds, each formula is a constant or a formula
/// starting with `=`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ValidationRule {
    pub kind: ValidationKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub operator: Option<ValidationOperator>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub formula1: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub formula2: Option<String>,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub allow_blank: bool,
    #[serde(default = "yes", skip_serializing_if = "is_true")]
    pub show_dropdown: bool,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub input_message: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error_message: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ValidationKind {
    Any,
    Whole,
    Decimal,
    List,
    Date,
    Time,
    TextLength,
    Custom,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ValidationOperator {
    Between,
    NotBetween,
    Equal,
    NotEqual,
    Greater,
    Less,
    GreaterOrEqual,
    LessOrEqual,
}

/// How an operation moved rows, columns, or a block of cells on one sheet. The control plane
/// stores it beside the committed operation, and editors use it to move what they show (an open
/// cell editor, a selection) without re-reading the workbook.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum StructuralEdit {
    /// Lines were inserted.
    InsertLines {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The zero-based index of the first line.
        at: u32,
        /// How many lines.
        count: u32,
    },
    /// Lines were deleted.
    DeleteLines {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The zero-based index of the first line.
        at: u32,
        /// How many lines.
        count: u32,
    },
    /// Cells were inserted, and the cells there moved along `axis`.
    InsertCells {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The cells, in A1 form.
        range: Range,
    },
    /// Cells were deleted, and the cells after them moved along `axis`.
    DeleteCells {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// Whether rows or columns.
        axis: Axis,
        /// The cells, in A1 form.
        range: Range,
    },
    /// A block of cells moved.
    Move {
        /// The sheet, by its stable `sheet_id`.
        sheet_id: SheetId,
        /// The block that moved.
        from: Range,
        /// The sheet the block moves to.
        to_sheet_id: SheetId,
        /// Where the block's top-left cell lands, in A1 form.
        to_cell: Cell,
    },
}

impl Op {
    /// The sheet the operation addresses; `None` for `sheet.insert`, which creates one.
    #[must_use]
    pub fn sheet_id(&self) -> Option<SheetId> {
        match self {
            Op::SheetInsert { .. } => None,
            Op::CellSet { sheet_id, .. }
            | Op::RangeSetValues { sheet_id, .. }
            | Op::RangeClear { sheet_id, .. }
            | Op::RangeFormat { sheet_id, .. }
            | Op::RangeMerge { sheet_id, .. }
            | Op::RangeUnmerge { sheet_id, .. }
            | Op::LineResize { sheet_id, .. }
            | Op::SheetFreeze { sheet_id, .. }
            | Op::LineInsert { sheet_id, .. }
            | Op::LineDelete { sheet_id, .. }
            | Op::CellsInsert { sheet_id, .. }
            | Op::CellsDelete { sheet_id, .. }
            | Op::RangeMove { sheet_id, .. }
            | Op::RangeFill { sheet_id, .. }
            | Op::RangePaste { sheet_id, .. }
            | Op::RangeRestoreFormats { sheet_id, .. }
            | Op::ImageInsert { sheet_id, .. }
            | Op::ImageUpdate { sheet_id, .. }
            | Op::ImageDelete { sheet_id, .. }
            | Op::CellPicture { sheet_id, .. }
            | Op::ImageToCell { sheet_id, .. }
            | Op::ImageFromCell { sheet_id, .. }
            | Op::SheetDelete { sheet_id, .. }
            | Op::SheetRename { sheet_id, .. }
            | Op::SheetReorder { sheet_id, .. }
            | Op::SheetTabColor { sheet_id, .. }
            | Op::RangeSort { sheet_id, .. }
            | Op::FilterSet { sheet_id, .. }
            | Op::ValidationSet { sheet_id, .. }
            | Op::CommentSet { sheet_id, .. }
            | Op::TableToggle { sheet_id, .. } => Some(*sheet_id),
        }
    }

    /// The descriptor of a committed structural operation.
    #[must_use]
    pub fn structural_edit(&self) -> Option<StructuralEdit> {
        Some(match *self {
            Op::LineInsert {
                sheet_id,
                axis,
                at,
                count,
            } => StructuralEdit::InsertLines {
                sheet_id,
                axis,
                at,
                count,
            },
            Op::LineDelete {
                sheet_id,
                axis,
                at,
                count,
            } => StructuralEdit::DeleteLines {
                sheet_id,
                axis,
                at,
                count,
            },
            Op::CellsInsert {
                sheet_id,
                range,
                shift,
            } => StructuralEdit::InsertCells {
                sheet_id,
                axis: shift_axis(shift),
                range,
            },
            Op::CellsDelete {
                sheet_id,
                range,
                shift,
            } => StructuralEdit::DeleteCells {
                sheet_id,
                axis: shift_axis(shift),
                range,
            },
            Op::RangeMove {
                sheet_id,
                from,
                to_sheet_id,
                to_cell,
            } => StructuralEdit::Move {
                sheet_id,
                from,
                to_sheet_id,
                to_cell,
            },
            _ => return None,
        })
    }
}

/// The axis along which a cell shift moves cells: `down`/`up` move rows, `right`/`left` columns.
pub(crate) fn shift_axis(shift: Shift) -> Axis {
    match shift {
        Shift::Down | Shift::Up => Axis::Rows,
        Shift::Right | Shift::Left => Axis::Cols,
    }
}

pub(crate) fn parse(json: &str) -> Result<Op, Error> {
    serde_json::from_str(json)
        .map_err(|error| Error::invalid(format!("invalid operation: {error}")))
}

pub(crate) fn parse_list(json: &str) -> Result<Vec<Op>, Error> {
    serde_json::from_str(json)
        .map_err(|error| Error::invalid(format!("invalid operation list: {error}")))
}

/// What executing an operation changed, for recalculation.
#[derive(Debug, Default)]
pub(crate) struct Outcome {
    /// Cells whose content changed, by sheet index.
    pub changed: Vec<Key>,
    /// The operation moved cells or sheets, so the dependency graph must be rebuilt.
    pub structural: bool,
}

impl Outcome {
    fn structural() -> Self {
        Outcome {
            changed: Vec::new(),
            structural: true,
        }
    }
}

/// The most cells one operation may visit cell by cell. Operations over whole rows or columns
/// visit only stored cells and are not limited by it.
const MAX_CELLS: u64 = 1_000_000;

pub(crate) fn check_size(range: RangeRef, what: &str) -> Result<(), Error> {
    if range.count() > MAX_CELLS {
        return Err(Error::invalid(format!(
            "{what} covers more than {MAX_CELLS} cells"
        )));
    }
    Ok(())
}

/// Executes `op` on `wb` and normalizes it in place to its committed form.
pub(crate) fn execute(wb: &mut Workbook, op: &mut Op) -> Result<Outcome, Error> {
    match op {
        Op::CellSet {
            sheet_id,
            cell,
            input,
            array,
        } => edit::cell_set(wb, *sheet_id, cell.0, input, *array),
        Op::RangeSetValues {
            sheet_id,
            range,
            values,
            parse,
        } => edit::set_values(wb, *sheet_id, range.0, values, *parse),
        Op::RangeClear {
            sheet_id,
            range,
            mode,
        } => edit::clear(wb, *sheet_id, range.0, *mode),
        Op::RangeFormat {
            sheet_id,
            range,
            patch,
        } => edit::format(wb, *sheet_id, range.0, patch),
        Op::RangeMerge {
            sheet_id,
            range,
            across,
        } => edit::merge(wb, *sheet_id, range.0, *across),
        Op::RangeUnmerge { sheet_id, range } => edit::unmerge(wb, *sheet_id, range.0),
        Op::LineResize {
            sheet_id,
            axis,
            start,
            end,
            size_px,
        } => edit::resize(wb, *sheet_id, *axis, *start, *end, *size_px),
        Op::SheetFreeze {
            sheet_id,
            rows,
            cols,
        } => edit::freeze(wb, *sheet_id, *rows, *cols),
        Op::CommentSet {
            sheet_id,
            cell,
            text,
            author,
        } => edit::comment(wb, *sheet_id, cell.0, text.as_deref(), author.as_deref()),
        Op::LineInsert {
            sheet_id,
            axis,
            at,
            count,
        } => crate::structure::insert_lines(wb, *sheet_id, *axis, *at, *count),
        Op::LineDelete {
            sheet_id,
            axis,
            at,
            count,
        } => crate::structure::delete_lines(wb, *sheet_id, *axis, *at, *count),
        Op::CellsInsert {
            sheet_id,
            range,
            shift,
        } => crate::structure::insert_cells(wb, *sheet_id, range.0, *shift),
        Op::CellsDelete {
            sheet_id,
            range,
            shift,
        } => crate::structure::delete_cells(wb, *sheet_id, range.0, *shift),
        Op::RangeMove {
            sheet_id,
            from,
            to_sheet_id,
            to_cell,
        } => crate::structure::move_range(wb, *sheet_id, from.0, *to_sheet_id, to_cell.0),
        Op::RangeFill {
            sheet_id,
            range,
            to,
            mode,
        } => fill::fill(wb, *sheet_id, range.0, to.0, *mode),
        Op::RangePaste {
            sheet_id,
            range,
            cells,
        } => edit::paste(wb, *sheet_id, range.0, cells),
        Op::RangeRestoreFormats {
            sheet_id,
            range,
            lines,
            cells,
        } => edit::restore_formats(wb, *sheet_id, range.0, lines, cells),
        Op::ImageInsert {
            sheet_id,
            image_id,
            anchor,
            picture,
        } => images::insert(wb, *sheet_id, image_id, anchor, picture),
        Op::ImageUpdate {
            sheet_id,
            image_id,
            anchor,
        } => images::update(wb, *sheet_id, *image_id, anchor),
        Op::ImageDelete { sheet_id, image_id } => images::delete(wb, *sheet_id, *image_id),
        Op::CellPicture {
            sheet_id,
            cell,
            picture,
        } => images::set_cell_picture(wb, *sheet_id, cell.0, picture.as_ref()),
        Op::ImageToCell {
            sheet_id,
            image_id,
            cell,
        } => images::to_cell(wb, *sheet_id, *image_id, cell.0),
        Op::ImageFromCell {
            sheet_id,
            cell,
            image_id,
            anchor,
        } => images::from_cell(wb, *sheet_id, cell.0, image_id, anchor),
        Op::SheetInsert {
            sheet_id,
            name,
            index,
        } => sheets::insert(wb, sheet_id, name, index),
        Op::SheetDelete { sheet_id, name } => sheets::delete(wb, *sheet_id, name),
        Op::SheetRename {
            sheet_id,
            name,
            old_name,
        } => sheets::rename(wb, *sheet_id, name, old_name),
        Op::SheetReorder { sheet_id, index } => sheets::reorder(wb, *sheet_id, *index),
        Op::SheetTabColor { sheet_id, color } => sheets::tab_color(wb, *sheet_id, *color),
        Op::RangeSort {
            sheet_id,
            range,
            keys,
            header,
        } => data::sort(wb, *sheet_id, range.0, keys, *header),
        Op::FilterSet {
            sheet_id,
            range,
            columns,
        } => data::filter(wb, *sheet_id, range.map(|range| range.0), columns),
        Op::ValidationSet {
            sheet_id,
            range,
            rule,
        } => data::validation(wb, *sheet_id, range.0, rule.as_ref()),
        Op::TableToggle {
            sheet_id,
            range,
            enabled,
            name,
        } => data::table(wb, *sheet_id, range.0, *enabled, name),
    }
}

#[cfg(test)]
mod tests {
    use super::{FormulaStorage, MergeShape, Op, SortHeader, TableChange, TextInput, parse};
    use crate::ids::{ImageId, SheetId};

    /// The typed fields read and write the same JSON as before: booleans that default to their
    /// usual value are left out, and ids are plain numbers.
    #[test]
    fn typed_flags_and_ids_keep_the_wire_shape() -> Result<(), Box<dyn std::error::Error>> {
        let cases = [
            r#"{"type":"cell.set","sheet_id":2,"cell":"A1","input":"=1","array":true}"#,
            r#"{"type":"cell.set","sheet_id":2,"cell":"A1","input":"=1"}"#,
            r#"{"type":"range.set_values","sheet_id":2,"range":"A1","values":[["1"]],"parse":false}"#,
            r#"{"type":"range.merge","sheet_id":2,"range":"A1:B1","across":true}"#,
            r#"{"type":"range.sort","sheet_id":2,"range":"A1:A3","keys":[{"col":"A"}],"header":true}"#,
            r#"{"type":"table.toggle","sheet_id":2,"range":"A1:B3","enabled":false}"#,
            r#"{"type":"image.delete","sheet_id":2,"image_id":9}"#,
        ];
        for json in cases {
            let op = parse(json)?;
            assert_eq!(serde_json::to_string(&op)?, json);
        }
        let explicit =
            parse(r#"{"type":"cell.set","sheet_id":2,"cell":"A1","input":"1","array":false}"#)?;
        assert!(matches!(
            explicit,
            Op::CellSet {
                sheet_id: SheetId(2),
                array: FormulaStorage::Ordinary,
                ..
            }
        ));
        assert!(matches!(
            parse(r#"{"type":"range.set_values","sheet_id":1,"range":"A1","values":[[1]]}"#)?,
            Op::RangeSetValues {
                parse: TextInput::Typed,
                ..
            }
        ));
        assert!(matches!(
            parse(r#"{"type":"range.merge","sheet_id":1,"range":"A1:B2"}"#)?,
            Op::RangeMerge {
                across: MergeShape::Whole,
                ..
            }
        ));
        assert!(matches!(
            parse(r#"{"type":"range.sort","sheet_id":1,"range":"A1:A2","keys":[]}"#)?,
            Op::RangeSort {
                header: SortHeader::None,
                ..
            }
        ));
        assert!(matches!(
            parse(r#"{"type":"table.toggle","sheet_id":1,"range":"A1:B3","enabled":true}"#)?,
            Op::TableToggle {
                enabled: TableChange::Create,
                ..
            }
        ));
        assert!(matches!(
            parse(r#"{"type":"image.delete","sheet_id":1,"image_id":4}"#)?,
            Op::ImageDelete {
                image_id: ImageId(4),
                ..
            }
        ));
        Ok(())
    }

    #[test]
    fn wire_shape_round_trips_and_rejects_unknown_fields() -> Result<(), Box<dyn std::error::Error>>
    {
        let json = r##"{"type":"range.format","sheet_id":1,"range":"A1:F1","patch":{"bold":true,"fill_color":null,"borders":{"top":{"style":"thin","color":"#FF0000"}}}}"##;
        let op = parse(json)?;
        assert_eq!(serde_json::to_string(&op)?, json);
        assert!(
            parse(r#"{"type":"cell.set","sheet_id":1,"cell":"A1","input":"1","extra":1}"#).is_err()
        );
        assert!(parse(r#"{"type":"cell.set","sheet_id":1,"cell":"A0","input":"1"}"#).is_err());
        assert!(parse(r#"{"type":"cell.select","sheet_id":1}"#).is_err());
        let insert = parse(r#"{"type":"sheet.insert"}"#)?;
        assert_eq!(
            insert,
            Op::SheetInsert {
                sheet_id: None,
                name: None,
                index: None
            }
        );
        Ok(())
    }
}
