use std::collections::BTreeMap;
use std::io::Read as _;

use serde_json::json;
use wordcraft_doc::Block;
use wordcraft_doc::props::VMerge;

use super::from_page_tree;

fn read_docx_document_xml(bytes: &[u8]) -> String {
    let cursor = std::io::Cursor::new(bytes);
    let mut archive = zip::ZipArchive::new(cursor).expect("valid docx zip archive");
    let mut doc_xml = String::new();
    archive
        .by_name("word/document.xml")
        .expect("word/document.xml entry")
        .read_to_string(&mut doc_xml)
        .expect("utf-8 document.xml");
    doc_xml
}

#[test]
fn code_line_preserves_ascii_inter_token_spaces_and_nbsp_indentation() {
    let req = json!({
        "title": "Code Whitespace",
        "root": {
            "type": "element",
            "name": "page",
            "children": [
                {
                    "type": "element",
                    "name": "pre",
                    "children": [
                        {
                            "type": "codeLine",
                            "runs": [
                                { "text": "const", "color": "#CF222E", "bold": true },
                                { "text": " x", "color": "#24292F" },
                                { "text": " =", "color": "#0550AE" },
                                { "text": " 1", "color": "#0550AE" }
                            ]
                        },
                        {
                            "type": "codeLine",
                            "runs": [
                                { "text": "  " },
                                { "text": "return", "bold": true },
                                { "text": " " },
                                { "text": " x", "italic": true }
                            ]
                        }
                    ]
                },
                {
                    "type": "element",
                    "name": "p",
                    "children": [
                        {
                            "type": "codeLine",
                            "runs": [
                                { "text": "kw", "bold": true },
                                { "text": " /* note */", "italic": true }
                            ]
                        }
                    ]
                }
            ]
        }
    });

    let doc = from_page_tree(&req.to_string(), &BTreeMap::new()).expect("compile code lines");

    // Locate the code-box table produced by `<pre>`.
    let code_table = doc
        .document()
        .body
        .iter()
        .find_map(|blk| match blk.as_ref() {
            Block::Table(tbl) if tbl.grid.len() == 1 => Some(tbl),
            _ => None,
        })
        .expect("expected single-column code box table");

    let cell_paras: Vec<_> = code_table.rows[0].cells[0]
        .blocks
        .iter()
        .filter_map(|blk| match blk.as_ref() {
            Block::Para(p) => Some(p),
            _ => None,
        })
        .collect();
    assert_eq!(cell_paras.len(), 2);

    // Single spaces across Shiki token boundaries stay regular ASCII `' '`.
    assert_eq!(cell_paras[0].plain_text(), "const x = 1");
    assert!(
        !cell_paras[0].plain_text().contains('\u{00A0}'),
        "single inter-token spaces must not turn into NBSP"
    );

    // Leading spaces and consecutive spaces across token boundaries become `U+00A0`.
    assert_eq!(
        cell_paras[1].plain_text(),
        "\u{00A0}\u{00A0}return \u{00A0}x"
    );

    // Inline `CodeLine` inside `<p>` forwards `bold` and `italic` flags onto its runs.
    let inline_para = doc
        .document()
        .body
        .iter()
        .filter_map(|blk| match blk.as_ref() {
            Block::Para(p) if p.plain_text().contains("kw /* note */") => Some(p),
            _ => None,
        })
        .next()
        .expect("expected inline codeLine paragraph");
    assert_eq!(inline_para.runs.len(), 2);
    assert_eq!(inline_para.runs[0].len, "kw".len());
    assert_eq!(inline_para.runs[0].props.bold, Some(true));
    assert_eq!(inline_para.runs[1].len, " /* note */".len());
    assert_eq!(inline_para.runs[1].props.italic, Some(true));
}

#[test]
fn table_desired_width_estimation_advances_past_active_rowspans() {
    let req = json!({
        "title": "Rowspan Widths",
        "root": {
            "type": "element",
            "name": "page",
            "children": [
                {
                    "type": "element",
                    "name": "table",
                    "children": [
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "th",
                                    "attrs": { "rowspan": "2" },
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "ID" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "th",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "Summary" }] }]
                                }
                            ]
                        },
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{
                                        "type": "element",
                                        "name": "p",
                                        "children": [{
                                            "type": "text",
                                            "value": "Long cell content belonging to column two underneath the rowspanned header"
                                        }]
                                    }]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    });

    let doc = from_page_tree(&req.to_string(), &BTreeMap::new()).expect("compile rowspan table");
    let data_table = doc
        .document()
        .body
        .iter()
        .find_map(|blk| match blk.as_ref() {
            Block::Table(tbl) if tbl.grid.len() == 2 => Some(tbl),
            _ => None,
        })
        .expect("expected 2-column table");

    assert!(
        data_table.grid[0] <= 50.0,
        "narrow column 0 should keep its compact default width instead of absorbing row 1's width: {:?}",
        data_table.grid
    );
    assert!(
        data_table.grid[1] >= 175.0,
        "column 1 should receive the wide desired width from row 1's cell: {:?}",
        data_table.grid
    );
}

#[test]
fn combined_rowspan_and_colspan_preserves_subsequent_row_cells_in_docx() {
    let req = json!({
        "title": "Combined Merge",
        "root": {
            "type": "element",
            "name": "page",
            "children": [
                {
                    "type": "element",
                    "name": "table",
                    "children": [
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "attrs": { "rowspan": "2", "colspan": "2" },
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "AB12" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "C1" }] }]
                                }
                            ]
                        },
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "C2" }] }]
                                }
                            ]
                        },
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "A3" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "B3" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "C3" }] }]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    });

    let doc = from_page_tree(&req.to_string(), &BTreeMap::new()).expect("compile merged table");
    let table = doc
        .document()
        .body
        .iter()
        .find_map(|blk| match blk.as_ref() {
            Block::Table(tbl) if tbl.grid.len() == 3 => Some(tbl),
            _ => None,
        })
        .expect("expected 3-column table");

    assert_eq!(table.rows.len(), 3);
    assert_eq!(table.rows[0].cells.len(), 2);
    assert_eq!(table.rows[0].cells[0].props.span, 2);
    assert_eq!(table.rows[0].cells[0].props.vmerge, VMerge::Restart);
    assert_eq!(table.rows[1].cells.len(), 2);
    assert_eq!(table.rows[1].cells[0].props.span, 2);
    assert_eq!(table.rows[1].cells[0].props.vmerge, VMerge::Continue);
    assert_eq!(table.rows[2].cells.len(), 3);

    let row2_texts: Vec<String> = table.rows[2]
        .cells
        .iter()
        .map(|cell| {
            cell.blocks
                .iter()
                .filter_map(|b| match b.as_ref() {
                    Block::Para(p) => Some(p.plain_text().to_string()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("")
        })
        .collect();
    assert_eq!(row2_texts, vec!["A3", "B3", "C3"]);

    let docx = crate::export_docx(&doc).expect("export docx");
    let xml = read_docx_document_xml(&docx);
    for expected in ["AB12", "C1", "C2", "A3", "B3", "C3"] {
        assert!(
            xml.contains(expected),
            "expected `{expected}` in exported word/document.xml"
        );
    }
}

#[test]
fn trailing_column_rowspan_expires_before_following_full_row() {
    let req = json!({
        "title": "Trailing Rowspan",
        "root": {
            "type": "element",
            "name": "page",
            "children": [
                {
                    "type": "element",
                    "name": "table",
                    "children": [
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "A1" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "td",
                                    "attrs": { "rowspan": "2" },
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "B12" }] }]
                                }
                            ]
                        },
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "A2" }] }]
                                }
                            ]
                        },
                        {
                            "type": "element",
                            "name": "tr",
                            "children": [
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{ "type": "element", "name": "p", "children": [{ "type": "text", "value": "A3" }] }]
                                },
                                {
                                    "type": "element",
                                    "name": "td",
                                    "children": [{
                                        "type": "element",
                                        "name": "p",
                                        "children": [{
                                            "type": "text",
                                            "value": "B3 wide trailing column content after trailing rowspan ends"
                                        }]
                                    }]
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    });

    let doc = from_page_tree(&req.to_string(), &BTreeMap::new()).expect("compile trailing rowspan");
    let table = doc
        .document()
        .body
        .iter()
        .find_map(|blk| match blk.as_ref() {
            Block::Table(tbl) if tbl.grid.len() == 2 => Some(tbl),
            _ => None,
        })
        .expect("expected 2-column table");

    assert_eq!(table.rows.len(), 3);
    assert_eq!(table.rows[2].cells.len(), 2);
    assert!(
        table.grid[0] <= 50.0 && table.grid[1] >= 175.0,
        "row 2's B3 cell must land in column 1 rather than shifting after an un-expired span: {:?}",
        table.grid
    );

    let docx = crate::export_docx(&doc).expect("export docx");
    let xml = read_docx_document_xml(&docx);
    assert!(xml.contains("A3"));
    assert!(xml.contains("B3 wide trailing column content after trailing rowspan ends"));
}

#[test]
fn inline_and_block_math_unwrap_delimiters_and_round_trip_through_docx() {
    use wordcraft_doc::para::InlineObject;

    let req = json!({
        "title": "Math Delimiters",
        "root": {
            "type": "element",
            "name": "page",
            "children": [
                {
                    "type": "element",
                    "name": "p",
                    "children": [
                        { "type": "text", "value": "Energy " },
                        {
                            "type": "element",
                            "name": "inline-math",
                            "children": [{ "type": "text", "value": "$E = mc^2$" }]
                        },
                        { "type": "text", "value": " and " },
                        {
                            "type": "element",
                            "name": "inline-math",
                            "children": [{ "type": "text", "value": "\\(x + 1\\)" }]
                        },
                        { "type": "text", "value": " fallback " },
                        {
                            "type": "element",
                            "name": "inline-math",
                            "attrs": { "_export_invalid": "true" },
                            "children": [{ "type": "text", "value": "$\\frac{1}{$" }]
                        }
                    ]
                },
                {
                    "type": "element",
                    "name": "math",
                    "children": [{ "type": "text", "value": "$$a^2 + b^2 = c^2$$" }]
                }
            ]
        }
    });

    let doc = from_page_tree(&req.to_string(), &BTreeMap::new()).expect("compile math page");

    let inline_para = doc
        .document()
        .body
        .iter()
        .find_map(|blk| match blk.as_ref() {
            Block::Para(p) if p.plain_text().contains("Energy ") => Some(p),
            _ => None,
        })
        .expect("expected inline math paragraph");

    let inline_eqs: Vec<_> = inline_para
        .objects
        .iter()
        .filter_map(|obj| match obj {
            InlineObject::Equation {
                display, linear, ..
            } => Some((*display, linear.as_str())),
            _ => None,
        })
        .collect();
    assert_eq!(inline_eqs.len(), 2);
    assert!(inline_eqs.iter().all(|(display, _)| !*display));
    assert!(inline_eqs.iter().all(|(_, linear)| !linear.contains('$')));
    assert!(
        inline_para.plain_text().contains("\\frac{1}{")
            && !inline_para.plain_text().contains("$\\frac{1}{$"),
        "invalid inline math fallback should unwrap outer `$` delimiters: {:?}",
        inline_para.plain_text()
    );

    let block_eq = doc
        .document()
        .body
        .iter()
        .filter_map(|blk| match blk.as_ref() {
            Block::Para(p) => p.objects.iter().find_map(|obj| match obj {
                InlineObject::Equation {
                    display: true,
                    linear,
                    ..
                } => Some(linear.as_str()),
                _ => None,
            }),
            _ => None,
        })
        .next()
        .expect("expected display equation paragraph");
    assert!(!block_eq.contains('$'));

    let docx = crate::export_docx(&doc).expect("export math docx");
    let reopened = crate::open(&docx, "[]").expect("reopen math docx");
    let converted = crate::to_document(&reopened).expect("convert reopened docx");
    assert!(
        converted.xml.contains("<inline-math>") && converted.xml.contains("</inline-math>"),
        "expected reopened inline OMML equations to convert to <inline-math>: {}",
        converted.xml
    );
    assert!(
        converted.xml.contains("<math>") && converted.xml.contains("</math>"),
        "expected reopened display OMML equation to convert to <math>: {}",
        converted.xml
    );
    assert!(
        !converted.report.downgraded.contains_key("inline_equations"),
        "inline equations must not report downgrade to <code>: {:?}",
        converted.report
    );
}
