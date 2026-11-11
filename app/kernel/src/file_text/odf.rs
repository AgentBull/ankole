use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};
use serde::Serialize;
use serde_json::json;

use super::{
    BoundedZip, FileSubtype, FileTextResult, Outline, PLAIN_TEXT_LIMIT, ZipOpenError,
    append_xml_entity, attr_value_by_local, local_name, push_newline_once, push_tab_once,
    sanitize_nfkc, table_cell, truncate_utf8, zip_error_to_result,
};

/// The widest sheet LibreOffice and Excel open. Cells beyond this column are left out, so a
/// repeat count in the file cannot ask for a wider row than a real sheet has.
const MAX_SHEET_COLUMNS: usize = 16_384;

/// The most lines written for one `table:number-rows-repeated` row that has text. The rows after
/// it keep their real numbers.
const MAX_REPEATED_ROW_LINES: usize = 1_000;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SheetTextSpan {
    sheet_name: String,
    start_byte: usize,
    end_byte: usize,
}

fn check_odf_encrypted(zip: &mut BoundedZip<'_>) -> Result<bool, ZipOpenError> {
    if let Some(manifest) = zip.read_utf8("META-INF/manifest.xml")? {
        return Ok(manifest.contains("encryption-data"));
    }
    Ok(false)
}

pub(super) fn extract_odt(bytes: &[u8]) -> FileTextResult {
    let mut zip = match BoundedZip::open(bytes) {
        Ok(z) => z,
        Err(err) => return zip_error_to_result("odt", err),
    };
    match check_odf_encrypted(&mut zip) {
        Ok(true) => {
            return FileTextResult::skipped(FileSubtype::Document, "odt", "encrypted_document");
        }
        Ok(false) => {}
        Err(err) => return zip_error_to_result("odt", err),
    }

    let Some(content_xml) = (match zip.read_utf8("content.xml") {
        Ok(xml) => xml,
        Err(err) => return zip_error_to_result("odt", err),
    }) else {
        return FileTextResult::failed(FileSubtype::Document, "odt", "missing_odf_content_xml");
    };

    let mut out = String::new();
    let mut sheets = Vec::new();
    let stopped = match parse_odf_xml(&content_xml, false, &mut out, &mut sheets) {
        Ok(stopped) => stopped,
        Err(reason) => return FileTextResult::failed(FileSubtype::Document, "odt", reason),
    };

    let clean = sanitize_nfkc(&out);
    let truncated = stopped || clean.len() > PLAIN_TEXT_LIMIT;
    FileTextResult::ok(
        FileSubtype::Document,
        "odt",
        truncate_utf8(clean, PLAIN_TEXT_LIMIT),
        json!({ "truncated": truncated }),
    )
}

pub(super) fn extract_ods(bytes: &[u8]) -> FileTextResult {
    let mut zip = match BoundedZip::open(bytes) {
        Ok(z) => z,
        Err(err) => return zip_error_to_result("ods", err),
    };
    match check_odf_encrypted(&mut zip) {
        Ok(true) => {
            return FileTextResult::skipped(FileSubtype::Document, "ods", "encrypted_document");
        }
        Ok(false) => {}
        Err(err) => return zip_error_to_result("ods", err),
    }

    let Some(content_xml) = (match zip.read_utf8("content.xml") {
        Ok(xml) => xml,
        Err(err) => return zip_error_to_result("ods", err),
    }) else {
        return FileTextResult::failed(FileSubtype::Document, "ods", "missing_odf_content_xml");
    };

    let mut leading = String::new();
    let mut raw_sheets: Vec<(String, String)> = Vec::new();
    let mut truncated = match parse_odf_xml(&content_xml, true, &mut leading, &mut raw_sheets) {
        Ok(stopped) => stopped,
        Err(reason) => return FileTextResult::failed(FileSubtype::Document, "ods", reason),
    };

    let mut out = sanitize_nfkc(&leading);
    let mut sheets = Vec::with_capacity(raw_sheets.len());
    let mut sheet_spans = Vec::with_capacity(raw_sheets.len());

    for (raw_name, raw_body) in raw_sheets {
        if out.len() >= PLAIN_TEXT_LIMIT {
            truncated = true;
            sheets.push(raw_name);
            continue;
        }
        let trimmed_name = raw_name.trim().to_owned();
        let marker = sanitize_nfkc(&format!("[Sheet: {}]", table_cell(&trimmed_name)));
        let clean_body = sanitize_nfkc(raw_body.trim_end_matches('\n'));

        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        let start_byte = out.len();
        out.push_str(&marker);
        out.push('\n');
        if !clean_body.is_empty() {
            out.push_str(&clean_body);
            out.push('\n');
        }
        if out.len() > PLAIN_TEXT_LIMIT {
            out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
            truncated = true;
        }
        let end_byte = out.len();
        if end_byte > start_byte {
            sheet_spans.push(SheetTextSpan {
                sheet_name: trimmed_name,
                start_byte,
                end_byte,
            });
        }
        sheets.push(raw_name);
    }

    truncated |= out.len() > PLAIN_TEXT_LIMIT;
    FileTextResult::ok(
        FileSubtype::Document,
        "ods",
        truncate_utf8(out, PLAIN_TEXT_LIMIT),
        json!({
            "sheets": sheets,
            "sheet_spans": sheet_spans,
            "truncated": truncated,
        }),
    )
}

/// Reads the text of `content.xml` into `leading` and, per named table of a spreadsheet, into
/// `sheets`. Returns whether the text budget stopped the read before the end of the document.
///
/// In spreadsheet mode every row with text becomes one `R<row>\t<cell>\t<cell>...` line. A
/// `table:number-columns-repeated` cell and a `table:number-rows-repeated` row take up as many
/// columns and row numbers as they stand for; blank ones only move the position on.
fn parse_odf_xml(
    xml: &str,
    spreadsheet_mode: bool,
    leading: &mut String,
    sheets: &mut Vec<(String, String)>,
) -> Result<bool, String> {
    const BUDGET: usize = PLAIN_TEXT_LIMIT + 4096;
    let mut reader = Reader::from_str(xml);
    let mut text_depth = 0usize;
    let mut ignored_depth = 0usize;
    let mut cell_buf = String::new();
    let mut in_cell = false;
    let mut total_bytes = 0usize;
    // The row being read: its 1-based number, how many rows it stands for, the column of its
    // next cell, how many columns the open cell stands for, and its cells up to the last one
    // with text.
    let mut row_number = 1usize;
    let mut row_repeat = 1usize;
    let mut column = 0usize;
    let mut cell_repeat = 1usize;
    let mut row_cells: Vec<String> = Vec::new();
    let mut row_bytes = 0usize;
    // The open heading of a text document: where its text starts and its outline level.
    let mut heading: Option<(usize, u8)> = None;
    let mut outline = Outline::default();

    fn push_bounded_cell_str(cell_buf: &mut String, text: &str, budget: usize) {
        let remaining = budget.saturating_sub(cell_buf.len());
        if remaining == 0 {
            return;
        }
        if text.len() <= remaining {
            cell_buf.push_str(text);
        } else {
            let mut end = remaining;
            while end > 0 && !text.is_char_boundary(end) {
                end -= 1;
            }
            cell_buf.push_str(&text[..end]);
        }
    }

    fn repeat(start: &BytesStart<'_>, attr: &str) -> usize {
        attr_value_by_local(start, attr)
            .and_then(|count| count.parse::<u32>().ok())
            .map_or(1, |count| count.max(1) as usize)
    }

    fn active_out<'a>(
        leading: &'a mut String,
        sheets: &'a mut [(String, String)],
    ) -> &'a mut String {
        if let Some((_, body)) = sheets.last_mut() {
            body
        } else {
            leading
        }
    }

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                if ignored_depth > 0 {
                    ignored_depth += 1;
                    continue;
                }
                match local_name(e.name().as_ref()) {
                    "tracked-changes" => {
                        ignored_depth = 1;
                    }
                    "table" if spreadsheet_mode => {
                        if let Some(name) = attr_value_by_local(&e, "name")
                            && !name.trim().is_empty()
                        {
                            sheets.push((name, String::new()));
                        }
                        row_number = 1;
                    }
                    "table-row" if spreadsheet_mode => {
                        row_repeat = repeat(&e, "number-rows-repeated");
                        column = 0;
                        row_cells.clear();
                        row_bytes = 0;
                    }
                    "table-cell" | "covered-table-cell" if spreadsheet_mode => {
                        in_cell = true;
                        cell_buf.clear();
                        cell_repeat = repeat(&e, "number-columns-repeated");
                    }
                    name @ ("p" | "h") => {
                        if name == "h" && !spreadsheet_mode && text_depth == 0 {
                            let level = attr_value_by_local(&e, "outline-level")
                                .and_then(|level| level.parse::<u8>().ok())
                                .unwrap_or(1);
                            heading = Some((leading.len(), level));
                        }
                        text_depth += 1;
                    }
                    "tab" => {
                        if in_cell {
                            push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                        } else if text_depth > 0 {
                            active_out(leading, sheets).push('\t');
                        }
                    }
                    "line-break" => {
                        if in_cell {
                            push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                        } else if text_depth > 0 {
                            active_out(leading, sheets).push('\n');
                        }
                    }
                    "s" => {
                        let count = attr_value_by_local(&e, "c")
                            .and_then(|v| v.parse::<usize>().ok())
                            .unwrap_or(1)
                            .min(16);
                        if in_cell {
                            for _ in 0..count {
                                push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                            }
                        } else if text_depth > 0 {
                            let target = active_out(leading, sheets);
                            for _ in 0..count {
                                target.push(' ');
                            }
                        }
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(e)) => {
                if ignored_depth == 0 {
                    match local_name(e.name().as_ref()) {
                        "table-row" if spreadsheet_mode => {
                            row_number =
                                row_number.saturating_add(repeat(&e, "number-rows-repeated"));
                        }
                        "table-cell" | "covered-table-cell" if spreadsheet_mode => {
                            column = column.saturating_add(repeat(&e, "number-columns-repeated"));
                        }
                        "tab" => {
                            if in_cell {
                                push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                            } else if text_depth > 0 {
                                active_out(leading, sheets).push('\t');
                            }
                        }
                        "line-break" => {
                            if in_cell {
                                push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                            } else if text_depth > 0 {
                                active_out(leading, sheets).push('\n');
                            }
                        }
                        "s" => {
                            let count = attr_value_by_local(&e, "c")
                                .and_then(|v| v.parse::<usize>().ok())
                                .unwrap_or(1)
                                .min(16);
                            if in_cell {
                                for _ in 0..count {
                                    push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                                }
                            } else if text_depth > 0 {
                                let target = active_out(leading, sheets);
                                for _ in 0..count {
                                    target.push(' ');
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            Ok(Event::End(e)) => {
                if ignored_depth > 0 {
                    ignored_depth -= 1;
                    continue;
                }
                match local_name(e.name().as_ref()) {
                    "p" | "h" => {
                        text_depth = text_depth.saturating_sub(1);
                        if in_cell {
                            if !cell_buf.is_empty() && !cell_buf.ends_with(' ') {
                                push_bounded_cell_str(&mut cell_buf, " ", BUDGET);
                            }
                        } else if text_depth == 0 {
                            match heading.take() {
                                Some((start, level)) => outline.mark(leading, start, level),
                                None => push_newline_once(active_out(leading, sheets)),
                            }
                        }
                    }
                    "table-cell" | "covered-table-cell" if spreadsheet_mode => {
                        in_cell = false;
                        let text = table_cell(&cell_buf);
                        if !text.is_empty()
                            && column < MAX_SHEET_COLUMNS
                            && total_bytes.saturating_add(row_bytes) < BUDGET
                        {
                            let gap = column.saturating_sub(row_cells.len());
                            let remaining =
                                BUDGET.saturating_sub(total_bytes.saturating_add(row_bytes));
                            if gap < remaining {
                                row_cells.resize(column, String::new());
                                row_bytes = row_bytes.saturating_add(gap);
                                let rem_after_gap =
                                    BUDGET.saturating_sub(total_bytes.saturating_add(row_bytes));
                                let per_copy = text.len().saturating_add(1);
                                let max_copies_by_budget = (rem_after_gap / per_copy).max(1);
                                let copies = cell_repeat
                                    .min(MAX_SHEET_COLUMNS - column)
                                    .min(max_copies_by_budget);
                                row_bytes =
                                    row_bytes.saturating_add(copies.saturating_mul(per_copy));
                                row_cells.extend(std::iter::repeat_n(text, copies));
                            }
                        }
                        column = column.saturating_add(cell_repeat);
                        cell_buf.clear();
                    }
                    "table-row" if spreadsheet_mode => {
                        if !row_cells.is_empty() {
                            let cells = row_cells.join("\t");
                            let out = active_out(leading, sheets);
                            for copy in 0..row_repeat.min(MAX_REPEATED_ROW_LINES) {
                                if total_bytes >= BUDGET {
                                    break;
                                }
                                let line =
                                    format!("R{}\t{cells}\n", row_number.saturating_add(copy));
                                total_bytes += line.len();
                                out.push_str(&line);
                            }
                            row_cells.clear();
                            row_bytes = 0;
                        }
                        row_number = row_number.saturating_add(row_repeat);
                    }
                    "table-row" => push_newline_once(active_out(leading, sheets)),
                    "table-cell" => push_tab_once(active_out(leading, sheets)),
                    _ => {}
                }
            }
            Ok(Event::Text(e)) => {
                if ignored_depth == 0 && text_depth > 0 {
                    let text = e.xml10_content();
                    if in_cell {
                        push_bounded_cell_str(&mut cell_buf, &text, BUDGET);
                    } else {
                        total_bytes += text.len();
                        active_out(leading, sheets).push_str(&text);
                    }
                }
            }
            Ok(Event::CData(e)) => {
                if ignored_depth == 0 && text_depth > 0 {
                    let text = e.xml10_content();
                    if in_cell {
                        push_bounded_cell_str(&mut cell_buf, &text, BUDGET);
                    } else {
                        total_bytes += text.len();
                        active_out(leading, sheets).push_str(&text);
                    }
                }
            }
            Ok(Event::GeneralRef(e)) => {
                if ignored_depth == 0 && text_depth > 0 {
                    if in_cell {
                        if cell_buf.len() < BUDGET {
                            append_xml_entity(&e, &mut cell_buf);
                        }
                    } else {
                        append_xml_entity(&e, active_out(leading, sheets));
                    }
                }
            }
            Ok(Event::Eof) => return Ok(false),
            Err(err) => return Err(format!("odf_xml_error: {err}")),
            _ => {}
        }
        if total_bytes >= BUDGET {
            return Ok(true);
        }
    }
}
