use super::*;

/// Mistral OCR at `/ocr`: a PDF or an image in, Markdown per page out.
#[derive(Debug)]
pub(super) struct MistralOcr;

impl APIProtocol for MistralOcr {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Mistral OCR")?;
        validate_known_request_fields(&request, &["document", "pages"], strict, "Mistral OCR")?;

        let document = request
            .get("document")
            .and_then(Value::as_str)
            .unwrap_or_default();

        // Mistral takes a PDF as a document link and an image as an image
        // link. Both links can be base64 data URLs.
        let chunk = if document.starts_with("data:application/pdf") {
            json!({"type": "document_url", "document_url": document})
        } else {
            json!({"type": "image_url", "image_url": document})
        };

        let mut body = context.sanitized_provider_options_object();
        body.insert("model".to_string(), json!(context.model));
        body.insert("document".to_string(), chunk);
        maybe_put_from(&mut body, &request, "pages");
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Mistral OCR")?;
        let Some(pages) = object.get("pages").and_then(Value::as_array) else {
            return Err(invalid_upstream_body_error(
                status,
                object,
                "Mistral OCR response did not contain pages",
            ));
        };

        let pages: Vec<Value> = pages
            .iter()
            .map(|page| json!({"index": page.get("index"), "markdown": page_markdown(page)}))
            .collect();
        let processed = object
            .pointer("/usage_info/pages_processed")
            .and_then(Value::as_u64)
            .unwrap_or(pages.len() as u64);

        Ok(json!({
            "model": object.get("model"),
            "pages": pages,
            "usage": {"pages": processed}
        }))
    }
}

/// Mistral puts a placeholder such as `![img-0.jpeg](img-0.jpeg)` where a page
/// holds a picture and returns the picture under `images`. The gateway returns
/// the text only, so a placeholder would be a link to nothing.
fn page_markdown(page: &Value) -> String {
    let mut markdown = page
        .get("markdown")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let image_ids = page
        .get("images")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|image| image.get("id").and_then(Value::as_str));
    for id in image_ids {
        markdown = markdown.replace(&format!("![{id}]({id})"), "");
    }
    // A placeholder on its own line leaves its two blank lines side by side.
    collapse_blank_lines(&markdown)
}

fn collapse_blank_lines(markdown: &str) -> String {
    let mut collapsed = String::with_capacity(markdown.len());
    let mut consecutive_newlines = 0usize;
    for ch in markdown.chars() {
        if ch == '\n' {
            consecutive_newlines += 1;
            if consecutive_newlines <= 2 {
                collapsed.push(ch);
            }
        } else {
            consecutive_newlines = 0;
            collapsed.push(ch);
        }
    }
    collapsed.trim().to_string()
}
