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

mod data;
pub(crate) mod edit;
mod sheets;

/// One canonical operation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum Op {
    /// Types `input` into a cell: a value, or a formula when it starts with `=`. `array` stores a
    /// formula as a one-cell legacy array formula.
    #[serde(rename = "cell.set")]
    CellSet {
        sheet_id: u32,
        cell: Cell,
        input: String,
        #[serde(default, skip_serializing_if = "is_false")]
        array: bool,
    },
    /// Writes a block of values whose shape matches `range`. Strings are read as typed input
    /// unless `parse` is false; `null` clears a cell's content and keeps its format.
    #[serde(rename = "range.set_values")]
    RangeSetValues {
        sheet_id: u32,
        range: Range,
        values: Vec<Vec<Option<Scalar>>>,
        #[serde(default = "yes", skip_serializing_if = "is_true")]
        parse: bool,
    },
    #[serde(rename = "range.clear")]
    RangeClear {
        sheet_id: u32,
        range: Range,
        mode: ClearMode,
    },
    /// Applies the same format patch to every cell of the range.
    #[serde(rename = "range.format")]
    RangeFormat {
        sheet_id: u32,
        range: Range,
        patch: FormatPatch,
    },
    /// Merges the range, or each of its rows when `across` is set. Merged areas that intersect the
    /// range are replaced, and only the top-left value of each new area survives.
    #[serde(rename = "range.merge")]
    RangeMerge {
        sheet_id: u32,
        range: Range,
        #[serde(default, skip_serializing_if = "is_false")]
        across: bool,
    },
    /// Removes every merged area that intersects the range.
    #[serde(rename = "range.unmerge")]
    RangeUnmerge { sheet_id: u32, range: Range },
    /// Sizes, hides, or shows the zero-based lines `start..=end`.
    #[serde(rename = "line.resize")]
    LineResize {
        sheet_id: u32,
        axis: Axis,
        start: u32,
        end: u32,
        size_px: LineSize,
    },
    /// Freezes the top `rows` and left `cols`; zero for both unfreezes.
    #[serde(rename = "sheet.freeze")]
    SheetFreeze { sheet_id: u32, rows: u32, cols: u32 },
    /// Inserts `count` lines before the zero-based line `at`.
    #[serde(rename = "line.insert")]
    LineInsert {
        sheet_id: u32,
        axis: Axis,
        at: u32,
        count: u32,
    },
    /// Deletes `count` lines starting at the zero-based line `at`.
    #[serde(rename = "line.delete")]
    LineDelete {
        sheet_id: u32,
        axis: Axis,
        at: u32,
        count: u32,
    },
    /// Inserts blank cells over `range`, shifting the cells there `down` or `right`.
    #[serde(rename = "cells.insert")]
    CellsInsert {
        sheet_id: u32,
        range: Range,
        shift: Shift,
    },
    /// Deletes the cells of `range`, shifting the cells after them `up` or `left`.
    #[serde(rename = "cells.delete")]
    CellsDelete {
        sheet_id: u32,
        range: Range,
        shift: Shift,
    },
    /// Cut and paste: moves the block `from` so that its top-left cell lands on `to_cell` of
    /// `to_sheet_id`, and points references to the block at its new place.
    #[serde(rename = "range.move")]
    RangeMove {
        sheet_id: u32,
        from: Range,
        to_sheet_id: u32,
        to_cell: Cell,
    },
    /// Adds an empty sheet at `index` (the end by default). The committed operation always carries
    /// the assigned `sheet_id` and name.
    #[serde(rename = "sheet.insert")]
    SheetInsert {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sheet_id: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        index: Option<usize>,
    },
    /// Deletes a sheet. The committed operation records the deleted sheet's `name` so that
    /// concurrent formulas can be rebased.
    #[serde(rename = "sheet.delete")]
    SheetDelete {
        sheet_id: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
    /// Renames a sheet. The committed operation records `old_name` so that concurrent formulas can
    /// be rebased.
    #[serde(rename = "sheet.rename")]
    SheetRename {
        sheet_id: u32,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        old_name: Option<String>,
    },
    /// Moves a sheet to the zero-based tab position `index`.
    #[serde(rename = "sheet.reorder")]
    SheetReorder { sheet_id: u32, index: usize },
    /// Sets the tab colour, or clears it with `null`.
    #[serde(rename = "sheet.tab_color")]
    SheetTabColor {
        sheet_id: u32,
        color: Option<HexColor>,
    },
    /// Sorts the rows of `range` by the key columns, which must lie inside the range. `header`
    /// keeps the first row in place.
    #[serde(rename = "range.sort")]
    RangeSort {
        sheet_id: u32,
        range: Range,
        keys: Vec<SortKey>,
        #[serde(default, skip_serializing_if = "is_false")]
        header: bool,
    },
    /// Sets the sheet's AutoFilter over `range` (first row = header) and hides the data rows that
    /// fail any column's value list, or removes the filter with `range: null`.
    #[serde(rename = "filter.set")]
    FilterSet {
        sheet_id: u32,
        range: Option<Range>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        columns: Vec<FilterColumn>,
    },
    /// Replaces the data validation of `range`, or removes it with `rule: null`.
    #[serde(rename = "validation.set")]
    ValidationSet {
        sheet_id: u32,
        range: Range,
        rule: Option<ValidationRule>,
    },
    /// Sets the note on a cell, or removes it with `text: null`.
    #[serde(rename = "comment.set")]
    CommentSet {
        sheet_id: u32,
        cell: Cell,
        text: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        author: Option<String>,
    },
    /// Formats `range` as a table (first row = headers) when `enabled`, or converts the table that
    /// intersects `range` back to a plain range. The committed operation records the table name.
    #[serde(rename = "table.toggle")]
    TableToggle {
        sheet_id: u32,
        range: Range,
        enabled: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
    },
}

fn is_false(value: &bool) -> bool {
    !*value
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bold: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub italic: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub underline: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub font_size: Option<f32>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub font_color: Option<Option<HexColor>>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub fill_color: Option<Option<HexColor>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub h_align: Option<HAlign>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub v_align: Option<VAlign>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wrap: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub num_fmt: Option<String>,
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
    InsertLines {
        sheet_id: u32,
        axis: Axis,
        at: u32,
        count: u32,
    },
    DeleteLines {
        sheet_id: u32,
        axis: Axis,
        at: u32,
        count: u32,
    },
    InsertCells {
        sheet_id: u32,
        axis: Axis,
        range: Range,
    },
    DeleteCells {
        sheet_id: u32,
        axis: Axis,
        range: Range,
    },
    Move {
        sheet_id: u32,
        from: Range,
        to_sheet_id: u32,
        to_cell: Cell,
    },
}

impl Op {
    /// The sheet the operation addresses; `None` for `sheet.insert`, which creates one.
    pub fn sheet_id(&self) -> Option<u32> {
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
    use super::{Op, parse};

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
