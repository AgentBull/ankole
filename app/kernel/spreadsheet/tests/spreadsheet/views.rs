//! What the viewport reports for the data tools, and the reads an editor makes around them.

use std::sync::Arc;

use ankole_spreadsheet::{CellArea, ChartPrim, FindOptions, SheetId};
use gridcraft_core::{CellRef, RangeRef, Value};
use gridcraft_model::{
    Anchor, AnchorMode, CfOperator, CfRule, CfValueKind, Chart, ChartKind, Color, CondFormat, Fill,
    LegendPos, Series, Style, Workbook,
};
use serde_json::json;

use crate::support::{apply_all, blank, corpus_file};

fn area(first_row: u32, first_col: u32, last_row: u32, last_col: u32) -> CellArea {
    CellArea {
        first_row,
        first_col,
        last_row,
        last_col,
    }
}

#[test]
fn the_viewport_reports_notes_filters_validations_and_tables() {
    let doc = apply_all(
        &blank(),
        &[
            json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:B4", "values": [["地区", "金额"], ["上海", 1], ["北京", 2], ["上海", 3]]}),
            json!({"type": "comment.set", "sheet_id": 1, "cell": "D1", "text": "核对", "author": "张三"}),
            json!({"type": "filter.set", "sheet_id": 1, "range": "A1:B4", "columns": [{"col": "A", "values": ["上海"]}]}),
            json!({"type": "validation.set", "sheet_id": 1, "range": "C1:C10", "rule": {"kind": "list", "formula1": "是,否", "input_message": "选择一项"}}),
            json!({"type": "table.toggle", "sheet_id": 1, "range": "E1:F3", "enabled": true}),
        ],
    );
    let view = ankole_spreadsheet::viewport(&doc, SheetId(1), area(0, 0, 9, 9)).expect("viewport");
    let at = |row: u32, col: u32| {
        view.cells
            .iter()
            .find(|cell| cell.row == row && cell.col == col)
            .unwrap_or_else(|| panic!("no cell at row {row} col {col}"))
    };
    assert_eq!(at(0, 3).note.as_deref(), Some("核对"));
    assert_eq!(at(0, 3).text, "");

    let filter = view.filter.as_ref().expect("the sheet's filter");
    assert_eq!(filter.range, "A1:B4");
    assert_eq!(filter.columns.len(), 1);
    assert_eq!(
        (filter.columns[0].col, filter.columns[0].values.as_slice()),
        (0, &["上海".to_string()][..])
    );
    assert!(!filter.columns[0].blanks && !filter.columns[0].custom);
    assert!(view.rows.iter().any(|row| row.index == 2 && row.hidden));

    assert_eq!(view.validations.len(), 1);
    let validation = &view.validations[0];
    assert_eq!(
        (
            validation.range.as_str(),
            validation.kind,
            validation.dropdown
        ),
        ("C1:C10", "list", true)
    );
    assert_eq!(validation.items, vec!["是", "否"]);
    assert_eq!(validation.input_message, "选择一项");

    assert_eq!(view.tables.len(), 1);
    assert_eq!(
        (view.tables[0].name.as_str(), view.tables[0].range.as_str()),
        ("Table1", "E1:F3")
    );
    assert!(view.tables[0].header_row && view.tables[0].filter_button);
    // The header and a blank body cell take the table's look; the cell's own style stays plain.
    let header = at(0, 4);
    assert!(view.styles[header.look.expect("a table look")].bold);
    assert!(!view.styles[header.style].bold);
    // The first data row is banded; the second is not, so it keeps its own style.
    let banded = at(1, 5);
    assert_eq!(banded.text, "");
    assert!(
        view.styles[banded.look.expect("a banded look")]
            .fill_color
            .is_some()
    );
    assert!(at(2, 5).look.is_none());
    // Outside every table and rule, a blank cell is not reported.
    assert!(!view.cells.iter().any(|cell| cell.row == 8 && cell.col == 8));
}

#[test]
fn conditional_formats_from_the_file_paint_fills_bars_and_icons() {
    let mut wb = Workbook::new();
    {
        let sheet = Arc::make_mut(wb.sheets.first_mut().expect("the blank sheet"));
        for (row, number) in [10.0, 20.0, 30.0].into_iter().enumerate() {
            sheet.set_value(CellRef::new(row as u32, 0), Value::Number(number));
        }
        let column = RangeRef::parse("A1:A3").expect("a range");
        let red = Style {
            fill: Fill::solid(Color::rgb(255, 0, 0)),
            ..Style::default()
        };
        sheet.cond_formats.push(CondFormat {
            ranges: vec![column],
            rule: CfRule::CellIs {
                op: CfOperator::Greater,
                a: "15".into(),
                b: None,
                style: Box::new(red),
            },
            priority: 1,
            stop_if_true: false,
        });
        sheet.cond_formats.push(CondFormat {
            ranges: vec![column],
            rule: CfRule::DataBar {
                min: CfValueKind::Min,
                max: CfValueKind::Max,
                color: Color::rgb(0, 0, 255),
                gradient: true,
                show_value: true,
            },
            priority: 2,
            stop_if_true: false,
        });
        sheet.cond_formats.push(CondFormat {
            ranges: vec![RangeRef::parse("B1:B3").expect("a range")],
            rule: CfRule::IconSet {
                set: "3Arrows".into(),
                thresholds: Vec::new(),
                reverse: false,
                show_value: false,
            },
            priority: 3,
            stop_if_true: false,
        });
        sheet.set_value(CellRef::new(0, 1), Value::Number(1.0));
        sheet.set_value(CellRef::new(1, 1), Value::Number(2.0));
        sheet.set_value(CellRef::new(2, 1), Value::Number(3.0));
    }
    let bytes = gridcraft_xlsx::write_xlsx(&wb).expect("xlsx bytes");
    let doc = ankole_spreadsheet::open(&bytes, "[]").expect("the workbook opens");
    let view = ankole_spreadsheet::viewport(&doc, SheetId(1), area(0, 0, 2, 1)).expect("viewport");
    let at = |row: u32, col: u32| {
        view.cells
            .iter()
            .find(|cell| cell.row == row && cell.col == col)
            .unwrap_or_else(|| panic!("no cell at row {row} col {col}"))
    };
    assert!(at(0, 0).look.is_none(), "10 is not greater than 15");
    let fill = |cell: &ankole_spreadsheet::RenderCell| {
        cell.look
            .and_then(|look| view.styles[look].fill_color.clone())
    };
    assert_eq!(fill(at(1, 0)).as_deref(), Some("#FF0000"));
    assert_eq!(fill(at(2, 0)).as_deref(), Some("#FF0000"));
    let bar = |row: u32| {
        at(row, 0)
            .cf
            .as_ref()
            .and_then(|cf| cf.bar.clone())
            .expect("a data bar")
    };
    assert_eq!(bar(2).fraction, 1.0);
    assert!(bar(0).fraction < bar(1).fraction && bar(1).fraction < bar(2).fraction);
    assert_eq!((bar(0).color.as_str(), bar(0).gradient), ("#0000FF", true));
    let icon = at(2, 1).cf.as_ref().expect("an icon").clone();
    assert_eq!(
        icon.icon.map(|icon| (icon.set, icon.index)),
        Some(("3Arrows".to_string(), 2))
    );
    assert!(icon.hide_value);
}

#[test]
fn filter_values_list_distinct_texts_with_their_selection() {
    let doc = apply_all(
        &blank(),
        &[
            json!({"type": "range.set_values", "sheet_id": 1, "range": "A1:A5", "values": [["地区"], ["上海"], ["北京"], ["上海"], [null]]}),
            json!({"type": "filter.set", "sheet_id": 1, "range": "A1:A5", "columns": [{"col": "A", "values": ["上海"]}]}),
        ],
    );
    let values = ankole_spreadsheet::filter_values(&doc, SheetId(1), 0).expect("filter values");
    assert_eq!(
        values
            .iter()
            .map(|value| (value.text.as_str(), value.blank, value.selected))
            .collect::<Vec<_>>(),
        vec![
            ("上海", false, true),
            ("北京", false, false),
            ("", true, false)
        ]
    );
    let error =
        ankole_spreadsheet::filter_values(&doc, SheetId(1), 3).expect_err("outside the range");
    assert!(error.to_string().contains("outside"));
}

#[test]
fn typed_input_is_checked_against_the_cell_validation() {
    let doc = apply_all(
        &blank(),
        &[
            json!({"type": "validation.set", "sheet_id": 1, "range": "A1:A3", "rule": {"kind": "list", "formula1": "是,否", "error_message": "请选择"}}),
        ],
    );
    let check = |cell: &str, input: &str| {
        ankole_spreadsheet::validate_input(&doc, SheetId(1), cell, input).expect("a check")
    };
    assert_eq!(check("A2", "是"), None);
    assert_eq!(check("A2", ""), None, "blanks are allowed");
    assert_eq!(check("B2", "也许"), None, "no rule");
    assert_eq!(check("A2", "=A1"), None, "a formula is not checked");
    let failure = check("A2", "也许").expect("a failure");
    assert_eq!(
        (failure.message.as_str(), failure.style),
        ("请选择", "stop")
    );
}

#[test]
fn find_reports_matching_cells_in_order_and_searches_formulas_on_request() {
    let doc = apply_all(
        &blank(),
        &[
            json!({"type": "cell.set", "sheet_id": 1, "cell": "A1", "input": "Total"}),
            json!({"type": "cell.set", "sheet_id": 1, "cell": "B2", "input": "=SUM(1,2)"}),
            json!({"type": "cell.set", "sheet_id": 1, "cell": "C3", "input": "total cost"}),
            json!({"type": "sheet.insert", "sheet_id": 2, "name": "Other"}),
            json!({"type": "cell.set", "sheet_id": 2, "cell": "A1", "input": "grand total"}),
        ],
    );
    let cells = |sheet: Option<SheetId>, query: &str, options: FindOptions| {
        ankole_spreadsheet::find(&doc, sheet, query, options)
            .expect("a search")
            .into_iter()
            .map(|found| format!("{}!{}", found.sheet_id, found.cell))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        cells(Some(SheetId(1)), "total", FindOptions::default()),
        vec!["1!A1", "1!C3"]
    );
    assert_eq!(
        cells(None, "total", FindOptions::default()),
        vec!["1!A1", "1!C3", "2!A1"]
    );
    assert_eq!(
        cells(
            Some(SheetId(1)),
            "total",
            FindOptions {
                match_case: true,
                ..FindOptions::default()
            }
        ),
        vec!["1!C3"]
    );
    assert_eq!(
        cells(
            Some(SheetId(1)),
            "total",
            FindOptions {
                whole_cell: true,
                ..FindOptions::default()
            }
        ),
        vec!["1!A1"]
    );
    assert_eq!(
        cells(Some(SheetId(1)), "SUM", FindOptions::default()),
        Vec::<String>::new()
    );
    assert_eq!(
        cells(
            Some(SheetId(1)),
            "SUM",
            FindOptions {
                formulas: true,
                ..FindOptions::default()
            }
        ),
        vec!["1!B2"]
    );
    assert!(ankole_spreadsheet::find(&doc, None, "", FindOptions::default()).is_err());
}

#[test]
fn charts_from_the_file_are_listed_with_their_anchors_and_drawn_as_primitives() {
    let doc = ankole_spreadsheet::open(&corpus_file("14_门店经营.xlsx"), "[]")
        .expect("the workbook opens");
    let sheet = doc
        .workbook()
        .sheets
        .iter()
        .find(|sheet| !sheet.charts.is_empty())
        .expect("a sheet with a chart");
    let id = SheetId(sheet.file_id);
    let charts = ankole_spreadsheet::charts(&doc, id).expect("charts");
    assert_eq!(charts.len(), 1);
    let chart = &charts[0];
    assert!(chart.width > 0.0 && chart.height > 0.0);
    assert!(CellRef::parse(&chart.cell).is_some());
    let prims =
        ankole_spreadsheet::chart_drawing(&doc, id, chart.chart_id, chart.width, chart.height)
            .expect("a drawing");
    assert!(
        prims
            .iter()
            .any(|prim| matches!(prim, ChartPrim::Text { .. }))
    );
    assert!(
        prims
            .iter()
            .any(|prim| !matches!(prim, ChartPrim::Text { .. }))
    );
    assert!(
        ankole_spreadsheet::chart_drawing(&doc, id, chart.chart_id, 0.5, 100.0)
            .expect("a degenerate box")
            .is_empty()
    );
    assert!(ankole_spreadsheet::chart_drawing(&doc, id, 999_999, 100.0, 100.0).is_err());
}

#[test]
fn a_chart_over_cell_values_draws_its_title_and_categories() {
    let mut wb = Workbook::new();
    let id = wb.next_object_id();
    {
        let sheet = Arc::make_mut(wb.sheets.first_mut().expect("the blank sheet"));
        let name = sheet.name.clone();
        for (row, (region, amount)) in [("地区", None), ("上海", Some(10.0)), ("北京", Some(20.0))]
            .into_iter()
            .enumerate()
        {
            sheet.set_value(CellRef::new(row as u32, 0), Value::text(region));
            match amount {
                Some(amount) => sheet.set_value(CellRef::new(row as u32, 1), Value::Number(amount)),
                None => sheet.set_value(CellRef::new(row as u32, 1), Value::text("金额")),
            }
        }
        sheet.charts.push(Chart {
            id,
            kind: ChartKind::ColumnClustered,
            anchor: Anchor {
                cell: CellRef::new(5, 0),
                dx: 4.0,
                dy: 2.0,
                width: 320.0,
                height: 200.0,
                mode: AnchorMode::default(),
            },
            title: Some("按地区".into()),
            series: vec![Series {
                name: Some(format!("{name}!$B$1")),
                categories: Some(format!("{name}!$A$2:$A$3")),
                values: format!("{name}!$B$2:$B$3"),
                ..Series::default()
            }],
            legend: LegendPos::Bottom,
            data_labels: false,
            gridlines: true,
            style: 2,
            x_title: None,
            y_title: None,
            source: None,
            by_rows: false,
            pivot: None,
        });
    }
    let bytes = gridcraft_xlsx::write_xlsx(&wb).expect("xlsx bytes");
    let doc = ankole_spreadsheet::open(&bytes, "[]").expect("the workbook opens");
    let charts = ankole_spreadsheet::charts(&doc, SheetId(1)).expect("charts");
    assert_eq!(charts.len(), 1);
    assert_eq!(
        (
            charts[0].cell.as_str(),
            charts[0].dx,
            charts[0].width,
            charts[0].title.as_deref()
        ),
        ("A6", 4.0, 320.0, Some("按地区"))
    );
    let prims =
        ankole_spreadsheet::chart_drawing(&doc, SheetId(1), charts[0].chart_id, 320.0, 200.0)
            .expect("a drawing");
    let texts: Vec<&str> = prims
        .iter()
        .filter_map(|prim| match prim {
            ChartPrim::Text { text, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    for wanted in ["按地区", "上海", "北京", "金额"] {
        assert!(
            texts.contains(&wanted),
            "{wanted} is missing from {texts:?}"
        );
    }
}
