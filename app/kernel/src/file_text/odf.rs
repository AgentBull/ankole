use quick_xml::Reader;
use quick_xml::events::Event;
use serde::Serialize;
use serde_json::json;

use super::{
    BoundedZip, FileSubtype, FileTextResult, PLAIN_TEXT_LIMIT, ZipOpenError, append_xml_entity,
    attr_value_by_local, local_name, push_newline_once, push_tab_once, sanitize_nfkc,
    truncate_utf8, zip_error_to_result,
};

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
    if let Err(reason) = parse_odf_xml(&content_xml, false, &mut out, &mut sheets) {
        return FileTextResult::failed(FileSubtype::Document, "odt", reason);
    }

    let clean = truncate_utf8(sanitize_nfkc(&out), PLAIN_TEXT_LIMIT);
    FileTextResult::ok(FileSubtype::Document, "odt", clean, json!({}))
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
    if let Err(reason) = parse_odf_xml(&content_xml, true, &mut leading, &mut raw_sheets) {
        return FileTextResult::failed(FileSubtype::Document, "ods", reason);
    }

    let mut out = sanitize_nfkc(&leading);
    let mut sheets = Vec::with_capacity(raw_sheets.len());
    let mut sheet_spans = Vec::with_capacity(raw_sheets.len());

    for (raw_name, raw_body) in raw_sheets {
        if out.len() >= PLAIN_TEXT_LIMIT {
            sheets.push(raw_name);
            continue;
        }
        let trimmed_name = raw_name.trim().to_owned();
        let clean_header = sanitize_nfkc(&trimmed_name);
        let clean_body = sanitize_nfkc(raw_body.trim_end_matches('\n'));

        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        let start_byte = out.len();
        out.push_str(&clean_header);
        out.push('\n');
        if !clean_body.is_empty() {
            out.push_str(&clean_body);
            out.push('\n');
        }
        if out.len() > PLAIN_TEXT_LIMIT {
            out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
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

    let clean = truncate_utf8(out, PLAIN_TEXT_LIMIT);
    FileTextResult::ok(
        FileSubtype::Document,
        "ods",
        clean,
        json!({
            "sheets": sheets,
            "sheet_spans": sheet_spans,
        }),
    )
}

fn parse_odf_xml(
    xml: &str,
    spreadsheet_mode: bool,
    leading: &mut String,
    sheets: &mut Vec<(String, String)>,
) -> Result<(), String> {
    let mut reader = Reader::from_str(xml);
    let mut text_depth = 0usize;
    let mut ignored_depth = 0usize;
    let mut cell_buf = String::new();
    let mut in_cell = false;
    let mut total_bytes = 0usize;

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
                    }
                    "table-cell" if spreadsheet_mode => {
                        in_cell = true;
                        cell_buf.clear();
                    }
                    "p" | "h" => {
                        text_depth += 1;
                    }
                    "tab" => {
                        if in_cell {
                            cell_buf.push(' ');
                        } else if text_depth > 0 {
                            active_out(leading, sheets).push('\t');
                        }
                    }
                    "line-break" => {
                        if in_cell {
                            cell_buf.push(' ');
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
                                cell_buf.push(' ');
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
                        "tab" => {
                            if in_cell {
                                cell_buf.push(' ');
                            } else if text_depth > 0 {
                                active_out(leading, sheets).push('\t');
                            }
                        }
                        "line-break" => {
                            if in_cell {
                                cell_buf.push(' ');
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
                                    cell_buf.push(' ');
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
                                cell_buf.push(' ');
                            }
                        } else if text_depth == 0 {
                            push_newline_once(active_out(leading, sheets));
                        }
                    }
                    "table-cell" if spreadsheet_mode => {
                        in_cell = false;
                        let trimmed = cell_buf.trim();
                        if !trimmed.is_empty() {
                            let out = active_out(leading, sheets);
                            if !out.is_empty() && !out.ends_with(['\n', '\t']) {
                                out.push('\t');
                            }
                            out.push_str(trimmed);
                            total_bytes += trimmed.len() + 1;
                        }
                        cell_buf.clear();
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
                        cell_buf.push_str(&text);
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
                        cell_buf.push_str(&text);
                    } else {
                        total_bytes += text.len();
                        active_out(leading, sheets).push_str(&text);
                    }
                }
            }
            Ok(Event::GeneralRef(e)) => {
                if ignored_depth == 0 && text_depth > 0 {
                    if in_cell {
                        append_xml_entity(&e, &mut cell_buf);
                    } else {
                        append_xml_entity(&e, active_out(leading, sheets));
                    }
                }
            }
            Ok(Event::Eof) => break,
            Err(err) => return Err(format!("odf_xml_error: {err}")),
            _ => {}
        }
        if total_bytes >= PLAIN_TEXT_LIMIT + 4096 {
            break;
        }
    }
    Ok(())
}
