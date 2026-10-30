//! Phase-0 timings for a 100,000-cell workbook. Run in release mode:
//! `cargo test -p ankole_spreadsheet --release --test spreadsheet perf -- --ignored --nocapture`.

use std::time::{Duration, Instant};

use gridcraft_core::{CellRef, Value, col_to_letters};
use gridcraft_model::{Cell, Formula, Sheet, Workbook};
use serde_json::json;

use crate::support::{TestResult, sheet_id};

/// 5,000 rows by 20 columns: 16 number columns and 4 formula columns, so 20% of the cells are
/// formulas.
fn generated() -> Vec<u8> {
    let mut sheet = Sheet::new("明细");
    for row in 0..5_000u32 {
        for col in 0..16u32 {
            sheet.set_value(
                CellRef::new(row, col),
                Value::number(f64::from(row * 16 + col) * 0.25),
            );
        }
        let r = row + 1;
        for (offset, text) in [
            format!("A{r}*B{r}"),
            format!("SUM(A{r}:P{r})"),
            format!("Q{r}-R{r}"),
            format!("IF(S{r}>0,S{r}/2,0)"),
        ]
        .iter()
        .enumerate()
        {
            sheet.set_cell(
                CellRef::new(row, 16 + offset as u32),
                Cell::formula(Formula::new(text)),
            );
        }
    }
    let mut wb = Workbook::new();
    wb.sheets = vec![std::sync::Arc::new(sheet)];
    gridcraft_xlsx::write_xlsx(&wb).expect("generated workbook")
}

fn median(mut samples: Vec<Duration>) -> f64 {
    samples.sort_unstable();
    samples
        .get(samples.len() / 2)
        .map_or(0.0, |d| d.as_secs_f64() * 1000.0)
}

#[allow(clippy::print_stderr, reason = "the measurement reports its timings")]
fn measure(label: &str, bytes: &[u8], sheet: &str, edit_cell: &str) -> TestResult {
    let opens: Vec<Duration> = (0..5)
        .map(|_| {
            let started = Instant::now();
            let doc = ankole_spreadsheet::open(bytes, "[]").expect("open");
            let elapsed = started.elapsed();
            drop(doc);
            elapsed
        })
        .collect();
    let doc = ankole_spreadsheet::open(bytes, "[]")?;
    let id = sheet_id(&doc, sheet);
    let cells: usize = doc.workbook().sheets.iter().map(|s| s.cells.len()).sum();
    let time_set = |at: &str| {
        let edit =
            json!({"type": "cell.set", "sheet_id": id, "cell": at, "input": "7"}).to_string();
        let samples = (0..20).map(|_| {
            let started = Instant::now();
            let applied = ankole_spreadsheet::apply(&doc, &edit, "[]").expect("apply");
            let elapsed = started.elapsed();
            drop(applied);
            elapsed
        });
        median(samples.collect())
    };
    let (dependent, unreferenced) = (time_set(edit_cell), time_set("AZ90000"));
    let insert =
        json!({"type": "line.insert", "sheet_id": id, "axis": "rows", "at": 10, "count": 1})
            .to_string();
    let structural: Vec<Duration> = (0..5)
        .map(|_| {
            let started = Instant::now();
            let applied = ankole_spreadsheet::apply(&doc, &insert, "[]").expect("apply");
            let elapsed = started.elapsed();
            drop(applied);
            elapsed
        })
        .collect();
    let exports: Vec<Duration> = (0..5)
        .map(|_| {
            let started = Instant::now();
            let exported = ankole_spreadsheet::export_xlsx(&doc).expect("export");
            let elapsed = started.elapsed();
            drop(exported);
            elapsed
        })
        .collect();
    eprintln!(
        "{label}: {} bytes, {cells} stored cells; open + full recalc {:.1} ms; cell.set apply {dependent:.2} ms (an unreferenced cell {unreferenced:.2} ms); line.insert apply {:.1} ms; export_xlsx {:.1} ms",
        bytes.len(),
        median(opens),
        median(structural),
        median(exports)
    );
    Ok(())
}

#[test]
#[ignore = "a release-mode measurement, not a check"]
fn perf_100k_cells() -> TestResult {
    measure(
        &format!("generated 5000x20 ({} formulas)", 5_000 * 4),
        &generated(),
        "明细",
        &format!("{}1", col_to_letters(0)),
    )
}
