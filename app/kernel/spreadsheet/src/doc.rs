//! The spreadsheet document: a shared GridCraft workbook, its calculation state, and what reading
//! the source file reported.

use std::collections::HashSet;
use std::sync::Arc;

use gridcraft_calc::Calc;
use gridcraft_model::{Sheet, Workbook};

use crate::Error;
use crate::autofit;
use crate::ids::SheetId;
use crate::index::SourceReport;
use crate::ops::{self, Op};

/// One immutable version of a workbook.
///
/// Cloning shares the workbook's sheets and cell bands, so a new version costs the bands an edit
/// touches plus a copy of the calculation graph.
#[derive(Clone)]
pub struct SpreadsheetDoc {
    wb: Arc<Workbook>,
    calc: Calc,
    source: Arc<SourceReport>,
}

impl std::fmt::Debug for SpreadsheetDoc {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SpreadsheetDoc")
            .field("sheets", &self.wb.sheets.len())
            .field("formulas", &self.calc.graph.len())
            .finish()
    }
}

impl SpreadsheetDoc {
    pub(crate) fn blank(title: &str) -> Result<Self, Error> {
        let mut wb = Workbook::new();
        wb.props.title = title.to_string();
        Self::from_workbook(wb, SourceReport::default())
    }

    pub(crate) fn read(bytes: &[u8]) -> Result<Self, Error> {
        let (wb, report) =
            gridcraft_xlsx::read_xlsx(bytes).map_err(|error| Error::Read(error.to_string()))?;
        Self::from_workbook(wb, SourceReport::new(bytes, report.warnings))
    }

    /// Every sheet gets a stable id first, then every formula is recalculated, as GridCraft does
    /// when it opens a file. Opening on the server and in the browser therefore yields the same
    /// values even where GridCraft and the file's last writer disagree.
    fn from_workbook(mut wb: Workbook, source: SourceReport) -> Result<Self, Error> {
        normalize_sheet_ids(&mut wb)?;
        let mut calc = Calc::new();
        calc.recalc_all(&mut wb);
        Ok(Self {
            wb: Arc::new(wb),
            calc,
            source: Arc::new(source),
        })
    }

    /// The GridCraft workbook of this version.
    #[must_use]
    pub fn workbook(&self) -> &Workbook {
        &self.wb
    }

    pub(crate) fn source(&self) -> &SourceReport {
        &self.source
    }

    /// Executes an already rebased operation on a copy of this version and recalculates what it
    /// changed. Structural operations recalculate everything because GridCraft keys its
    /// dependency graph by sheet index and cell position.
    pub(crate) fn execute(&self, op: &mut Op) -> Result<Self, Error> {
        let mut wb = (*self.wb).clone();
        let outcome = ops::execute(&mut wb, op)?;
        let calc = if outcome.structural {
            let mut calc = Calc::new();
            calc.recalc_all(&mut wb);
            calc
        } else {
            let mut calc = self.calc.clone();
            if !outcome.changed.is_empty() {
                calc.cells_changed(&mut wb, &outcome.changed);
            }
            calc
        };
        // Rows whose content or fonts changed take their automatic height from the new values.
        let rows = autofit::touched_rows(&wb, op);
        autofit::fit_rows(&mut wb, &rows);
        Ok(Self {
            wb: Arc::new(wb),
            calc,
            source: Arc::clone(&self.source),
        })
    }
}

/// The position of the sheet whose `sheet_id` is `id`.
pub(crate) fn sheet_index(wb: &Workbook, id: SheetId) -> Option<usize> {
    wb.sheets.iter().position(|sheet| sheet.file_id == id.0)
}

/// Like [`sheet_index`], rejecting an unknown id.
pub(crate) fn require_sheet(wb: &Workbook, id: SheetId) -> Result<usize, Error> {
    sheet_index(wb, id).ok_or_else(|| Error::invalid(format!("no sheet has sheet_id {id}")))
}

/// The sheet whose `sheet_id` is `id`, rejecting an unknown id.
pub(crate) fn sheet_by_id(wb: &Workbook, id: SheetId) -> Result<&Sheet, Error> {
    wb.sheets
        .get(require_sheet(wb, id)?)
        .map(AsRef::as_ref)
        .ok_or_else(|| Error::invalid(format!("no sheet has sheet_id {id}")))
}

/// The id a new sheet gets: one past every id in use, including the chart sheets GridCraft keeps
/// for saving. The writer gives a worksheet a fresh id when a kept chart sheet already holds its
/// id, so sharing one would change the worksheet's id at the next compaction.
pub(crate) fn next_sheet_id(wb: &Workbook) -> Result<u32, Error> {
    used_ids(wb)
        .max()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| Error::invalid("the workbook has no sheet ids left"))
}

/// Every nonzero sheet id in use, by worksheets and by kept chart sheets.
pub(crate) fn used_ids(wb: &Workbook) -> impl Iterator<Item = u32> + '_ {
    let worksheets = wb.sheets.iter().map(|sheet| sheet.file_id);
    worksheets.chain(chart_sheet_ids(wb)).filter(|id| *id != 0)
}

fn chart_sheet_ids(wb: &Workbook) -> impl Iterator<Item = u32> + '_ {
    wb.preserved
        .iter()
        .flat_map(|kept| kept.sheets.iter().map(|sheet| sheet.sheet_id))
}

/// Gives every sheet a unique, nonzero `sheet_id`. GridCraft reads the OOXML `sheetId` into
/// `Sheet::file_id` and writes it back, so the id survives every save. A sheet without one, or one
/// that repeats an earlier sheet's id, gets the next free id.
fn normalize_sheet_ids(wb: &mut Workbook) -> Result<(), Error> {
    let mut taken: HashSet<u32> = chart_sheet_ids(wb).collect();
    for index in 0..wb.sheets.len() {
        let id = wb.sheets.get(index).map_or(0, |sheet| sheet.file_id);
        if id != 0 && taken.insert(id) {
            continue;
        }
        let fresh = next_sheet_id(wb)?;
        taken.insert(fresh);
        if let Some(sheet) = wb.sheet_mut(index) {
            sheet.file_id = fresh;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use gridcraft_model::{Preserved, PreservedSheet, Sheet, Workbook};

    use super::normalize_sheet_ids;

    #[test]
    fn missing_and_repeated_ids_get_fresh_ones_past_chart_sheets() -> Result<(), crate::Error> {
        let mut wb = Workbook::new();
        wb.sheets = ["A", "B", "C", "D"]
            .iter()
            .zip([3, 0, 3, 9])
            .map(|(name, id)| {
                let mut sheet = Sheet::new(*name);
                sheet.file_id = id;
                Arc::new(sheet)
            })
            .collect();
        wb.preserved = Some(Arc::new(Preserved {
            sheets: vec![PreservedSheet {
                name: "Chart".into(),
                sheet_id: 12,
                ..PreservedSheet::default()
            }],
            ..Preserved::default()
        }));
        normalize_sheet_ids(&mut wb)?;
        let ids: Vec<u32> = wb.sheets.iter().map(|sheet| sheet.file_id).collect();
        assert_eq!(ids, vec![3, 13, 14, 9]);
        Ok(())
    }
}
