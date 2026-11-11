use std::collections::BTreeMap;

use serde_json::json;

use super::{
    FileSubtype, FileTextResult, MAX_DOCUMENT_INPUT_BYTES, MAX_PDF_PAGES, PLAIN_TEXT_LIMIT,
    PageTextSpan, sanitize_nfkc, truncate_utf8,
};

/// A page whose text is shorter than this many characters counts as having no text layer, which
/// is how a scanned page reads.
const TEXTLESS_PAGE_CHARS: usize = 10;

/// Extracts the text layer page by page. Each page with text starts with a `[Page N]` line, and
/// its entry in `pages` spans that line and the text. `extracted_pages` counts the pages read
/// before a limit stopped the extraction, and `textless_pages` lists the ones among them that
/// have no text layer to speak of.
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
    let mut extracted_pages = 0usize;
    let mut textless_pages = Vec::new();
    let mut cut = false;

    for &page_num in page_map.keys().take(MAX_PDF_PAGES) {
        if out.len() >= PLAIN_TEXT_LIMIT {
            break;
        }
        extracted_pages += 1;
        let page = doc.extract_text(&[page_num]);
        let cleaned = page.as_deref().map(clean_page).unwrap_or_default();
        if cleaned.chars().count() < TEXTLESS_PAGE_CHARS {
            textless_pages.push(page_num);
        }
        match page {
            Ok(_) => {
                any_page_ok = true;
                if cleaned.is_empty() {
                    continue;
                }
                if !out.is_empty() && !out.ends_with('\n') {
                    out.push('\n');
                }
                let start_byte = out.len();
                out.push_str(&format!("[Page {page_num}]\n{cleaned}\n"));
                if out.len() > PLAIN_TEXT_LIMIT {
                    out = truncate_utf8(out, PLAIN_TEXT_LIMIT);
                    cut = true;
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
            "truncated": cut || extracted_pages < total_pages,
            "extracted_pages": extracted_pages,
            "textless_pages": textless_pages,
        }),
    )
}

/// The text of one page: normalized, without the invisible characters PDF producers scatter
/// through a text layer (soft hyphens, zero-width and directional marks, byte-order marks, and
/// the U+FFFE and U+FFFF noncharacters), and trimmed.
pub(super) fn clean_page(raw: &str) -> String {
    let visible: String = sanitize_nfkc(raw)
        .chars()
        .filter(|ch| {
            !matches!(
                *ch,
                '\u{00AD}' | '\u{200B}'..='\u{200F}' | '\u{FEFF}' | '\u{FFFE}' | '\u{FFFF}'
            )
        })
        .collect();
    visible.trim().to_owned()
}
