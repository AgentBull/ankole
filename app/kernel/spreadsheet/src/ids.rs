//! Identifiers and areas that operations and reads address, as types of their own so that a sheet
//! id, a picture id, and a coordinate cannot stand in for one another.

use std::fmt;

use serde::{Deserialize, Serialize};

/// The stable id of a worksheet: its `sheetId` in the file. It survives renames, reordering, and
/// compaction, unlike the sheet's name or tab position. On the wire it is a plain number.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SheetId(pub u32);

impl fmt::Display for SheetId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// The id of a floating picture, unique among the drawing objects of a workbook (pictures,
/// charts, shapes, tables, and slicers). On the wire it is a plain number.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ImageId(pub u32);

impl fmt::Display for ImageId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// A rectangle of cells by zero-based, inclusive bounds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CellArea {
    /// The first row.
    pub first_row: u32,
    /// The first column.
    pub first_col: u32,
    /// The last row.
    pub last_row: u32,
    /// The last column.
    pub last_col: u32,
}
