use std::collections::{BTreeMap, HashSet};

use serde_json::json;

use super::{
    FileSubtype, FileTextResult, MAX_DOCUMENT_INPUT_BYTES, MAX_PDF_PAGES, PLAIN_TEXT_LIMIT,
    PageTextSpan, sanitize_nfkc, truncate_utf8,
};

/// A page whose text is shorter than this many characters counts as having no text layer, which
/// is how a scanned page reads.
const TEXTLESS_PAGE_CHARS: usize = 10;
const MAX_PDF_STREAM_UNCOMPRESSED_BYTES: usize = 16 * 1024 * 1024;
const MAX_PDF_TOTAL_UNCOMPRESSED_BYTES: usize = 64 * 1024 * 1024;

fn is_stream_limit_exceeded(err: &lopdf::Error) -> bool {
    matches!(
        err,
        lopdf::Error::Decompress(lopdf::DecompressError::MemoryLimitExceeded { .. })
    )
}

/// Extracts the text page by page. Each page with text starts with a `[Page N]` line, and its
/// entry in `pages` spans that line and the text. A page without a text layer to speak of takes
/// the text that OCR read from it when `recognized` holds one. `extracted_pages` counts the pages
/// read before a limit stopped the extraction, and `textless_pages` lists the ones among them
/// that still have no text. `ocr_pages` lists the pages whose text came from OCR, and it is
/// present whenever `recognized` is given, so an OCR run that found nothing is still on record.
pub(super) fn extract_pdf(
    bytes: &[u8],
    recognized: Option<&BTreeMap<u32, String>>,
) -> FileTextResult {
    if bytes.len() > MAX_DOCUMENT_INPUT_BYTES {
        return FileTextResult::skipped(FileSubtype::Document, "pdf", "file_too_large");
    }
    let header_window = &bytes[..bytes.len().min(1024)];
    if !header_window.windows(5).any(|w| w == b"%PDF-") {
        return FileTextResult::failed(FileSubtype::Document, "pdf", "invalid_pdf_header");
    }

    let load_options = lopdf::LoadOptions {
        max_decompressed_size: Some(MAX_PDF_STREAM_UNCOMPRESSED_BYTES),
        ..Default::default()
    };
    let mut doc = match lopdf::Document::load_mem_with_options(bytes, load_options) {
        Ok(doc) => doc,
        Err(err) if is_stream_limit_exceeded(&err) => {
            return FileTextResult::skipped(
                FileSubtype::Document,
                "pdf",
                "pdf_stream_limit_exceeded",
            );
        }
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
    let mut ocr_pages = Vec::new();
    let mut cut = false;
    let mut seen_streams: HashSet<lopdf::ObjectId> = HashSet::new();
    let mut total_uncompressed_bytes = 0usize;

    for (&page_num, &page_id) in page_map.iter().take(MAX_PDF_PAGES) {
        // A cut can land inside a character and leave the text a few bytes short of the limit.
        // The pages after it are not read, so none of them is listed as waiting for OCR.
        if cut || out.len() >= PLAIN_TEXT_LIMIT {
            break;
        }

        for stream_id in doc.get_page_contents(page_id) {
            if !seen_streams.insert(stream_id) {
                continue;
            }
            let remaining =
                MAX_PDF_TOTAL_UNCOMPRESSED_BYTES.saturating_sub(total_uncompressed_bytes);
            if remaining == 0 {
                return FileTextResult::skipped(
                    FileSubtype::Document,
                    "pdf",
                    "pdf_stream_limit_exceeded",
                );
            }
            let stream_limit = MAX_PDF_STREAM_UNCOMPRESSED_BYTES.min(remaining);
            if let Ok(lopdf::Object::Stream(stream)) = doc.get_object_mut(stream_id) {
                if stream.is_compressed() {
                    match stream.decompress_with_limit(stream_limit) {
                        Ok(()) => {
                            total_uncompressed_bytes =
                                total_uncompressed_bytes.saturating_add(stream.content.len());
                        }
                        Err(err) if is_stream_limit_exceeded(&err) => {
                            return FileTextResult::skipped(
                                FileSubtype::Document,
                                "pdf",
                                "pdf_stream_limit_exceeded",
                            );
                        }
                        Err(_) => {}
                    }
                } else {
                    if stream.content.len() > stream_limit {
                        return FileTextResult::skipped(
                            FileSubtype::Document,
                            "pdf",
                            "pdf_stream_limit_exceeded",
                        );
                    }
                    total_uncompressed_bytes =
                        total_uncompressed_bytes.saturating_add(stream.content.len());
                }
            }
        }

        let remaining_font_limit = MAX_PDF_STREAM_UNCOMPRESSED_BYTES.min(
            MAX_PDF_TOTAL_UNCOMPRESSED_BYTES
                .saturating_sub(total_uncompressed_bytes)
                .max(1),
        );
        extracted_pages += 1;
        let mut text = match doc.extract_text_with_limit(&[page_num], remaining_font_limit) {
            Ok(page) => {
                any_page_ok = true;
                clean_page(&page)
            }
            Err(err) if is_stream_limit_exceeded(&err) => {
                return FileTextResult::skipped(
                    FileSubtype::Document,
                    "pdf",
                    "pdf_stream_limit_exceeded",
                );
            }
            Err(err) => {
                first_err.get_or_insert_with(|| err.to_string());
                String::new()
            }
        };
        if text.chars().count() < TEXTLESS_PAGE_CHARS {
            let read = recognized
                .and_then(|pages| pages.get(&page_num))
                .map(|page| clean_page(page))
                .filter(|page| !page.is_empty());
            match read {
                Some(page) => {
                    text = page;
                    ocr_pages.push(page_num);
                }
                None => textless_pages.push(page_num),
            }
        }
        if text.is_empty() {
            continue;
        }
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        let start_byte = out.len();
        out.push_str(&format!("[Page {page_num}]\n{text}\n"));
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

    let mut metadata = json!({
        "page_count": total_pages,
        "pages": spans,
        "truncated": cut || extracted_pages < total_pages,
        "extracted_pages": extracted_pages,
        "textless_pages": textless_pages,
    });
    if recognized.is_some() {
        metadata["ocr_pages"] = json!(ocr_pages);
    }

    if out.trim().is_empty() {
        if any_page_ok {
            // The metadata names the pages that OCR could still read.
            return FileTextResult {
                metadata,
                ..FileTextResult::skipped(FileSubtype::Document, "pdf", "empty_text_layer")
            };
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

    FileTextResult::ok(FileSubtype::Document, "pdf", out, metadata)
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
