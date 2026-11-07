use std::collections::BTreeMap;

use serde_json::json;

use super::{
    FileSubtype, FileTextResult, MAX_DOCUMENT_INPUT_BYTES, MAX_PDF_PAGES, PLAIN_TEXT_LIMIT,
    PageTextSpan, sanitize_nfkc, truncate_utf8,
};

pub(super) fn extract_pdf(bytes: &[u8]) -> FileTextResult {
    if bytes.len() > MAX_DOCUMENT_INPUT_BYTES {
        return FileTextResult::skipped(FileSubtype::Document, "pdf", "file_too_large");
    }
    let header_window = &bytes[..bytes.len().min(1024)];
    if !header_window.windows(5).any(|w| w == b"%PDF-") {
        return FileTextResult::failed(FileSubtype::Document, "pdf", "invalid_pdf_header");
    }

    let mut doc = match lopdf::Document::load_mem(bytes) {
        Ok(doc) => doc,
        Err(err) => {
            let msg = err.to_string();
            if msg.to_ascii_lowercase().contains("encrypt")
                || bytes.windows(8).any(|w| w == b"/Encrypt")
            {
                return FileTextResult::skipped(FileSubtype::Document, "pdf", "encrypted_pdf");
            }
            return FileTextResult::failed(
                FileSubtype::Document,
                "pdf",
                format!("pdf_parse_error: {msg}"),
            );
        }
    };

    if doc.is_encrypted() && doc.decrypt("").is_err() {
        return FileTextResult::skipped(FileSubtype::Document, "pdf", "encrypted_pdf");
    }

    let page_map: BTreeMap<u32, lopdf::ObjectId> = doc.get_pages();
    if page_map.is_empty() {
        return FileTextResult::skipped(FileSubtype::Document, "pdf", "empty_pdf");
    }

    let total_pages = page_map.len();
    let mut out = String::new();
    let mut spans = Vec::with_capacity(total_pages.min(MAX_PDF_PAGES));
    let mut any_page_ok = false;
    let mut first_err: Option<String> = None;

    for &page_num in page_map.keys().take(MAX_PDF_PAGES) {
        if out.len() >= PLAIN_TEXT_LIMIT {
            break;
        }
        match doc.extract_text(&[page_num]) {
            Ok(raw_page) => {
                any_page_ok = true;
                let cleaned = sanitize_nfkc(raw_page.trim());
                if cleaned.is_empty() {
                    continue;
                }
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                let start_byte = out.len();
                out.push_str(&cleaned);
                out.push('\n');
                if out.len() > PLAIN_TEXT_LIMIT {
                    out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
                }
                let end_byte = out.len();
                if end_byte > start_byte {
                    spans.push(PageTextSpan {
                        page: page_num,
                        start_byte,
                        end_byte,
                    });
                }
            }
            Err(err) => {
                if first_err.is_none() {
                    first_err = Some(err.to_string());
                }
            }
        }
    }

    if out.trim().is_empty() {
        if any_page_ok {
            return FileTextResult::skipped(FileSubtype::Document, "pdf", "empty_text_layer");
        }
        return FileTextResult::failed(
            FileSubtype::Document,
            "pdf",
            format!(
                "pdf_extract_error: {}",
                first_err.unwrap_or_else(|| "unknown".to_owned())
            ),
        );
    }

    FileTextResult::ok(
        FileSubtype::Document,
        "pdf",
        out,
        json!({
            "page_count": total_pages,
            "pages": spans,
        }),
    )
}
