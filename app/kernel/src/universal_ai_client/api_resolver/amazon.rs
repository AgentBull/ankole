use super::*;

/// Amazon Polly text to speech at `/v1/speech`. The model is the Polly engine,
/// such as `neural` or `generative`.
#[derive(Debug)]
pub(super) struct AmazonPollySpeech;

/// Amazon Textract `DetectDocumentText`, which reads one image or one PDF
/// page and reports the lines that it found.
#[derive(Debug)]
pub(super) struct AmazonTextractOcr;

impl APIProtocol for AmazonPollySpeech {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Amazon Polly")?;
        validate_known_request_fields(
            &request,
            &["input", "voice", "response_format"],
            strict,
            "Amazon Polly",
        )?;
        let defaults = context.sanitized_provider_options_object();
        let mut body = Map::new();
        body.insert("Engine".to_string(), json!(context.model));
        for (field, key) in [
            ("Text", "input"),
            ("VoiceId", "voice"),
            ("OutputFormat", "response_format"),
        ] {
            if let Some(value) = request
                .get(key)
                .filter(|value| useful_value(value))
                .or_else(|| defaults.get(key).filter(|value| useful_value(value)))
            {
                body.insert(field.to_string(), value.clone());
            }
        }
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        _status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        Ok(body)
    }
}

impl APIProtocol for AmazonTextractOcr {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Amazon Textract")?;
        validate_known_request_fields(&request, &["document", "pages"], strict, "Amazon Textract")?;
        // Textract takes the bytes as bare base64, without the data URL's head.
        let bytes = request
            .get("document")
            .and_then(Value::as_str)
            .and_then(|document| document.split_once(";base64,"))
            .map_or("", |(_head, bytes)| bytes);

        let mut body = Map::new();
        body.insert("Document".to_string(), json!({"Bytes": bytes}));
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Amazon Textract")?;
        let Some(blocks) = object.get("Blocks").and_then(Value::as_array) else {
            return Err(invalid_upstream_body_error(
                status,
                object,
                "Amazon Textract response did not contain blocks",
            ));
        };

        // A LINE block holds one line of text and the page that it is on,
        // numbered from 1. Textract returns the lines in reading order.
        let page_count = object
            .pointer("/DocumentMetadata/Pages")
            .and_then(Value::as_u64)
            .unwrap_or(1)
            .max(1);
        let mut pages_by_number: std::collections::BTreeMap<u64, Vec<&str>> =
            std::collections::BTreeMap::new();
        for block in blocks {
            let page = block
                .get("Page")
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .max(1);
            match block.get("BlockType").and_then(Value::as_str) {
                Some("PAGE") => {
                    pages_by_number.entry(page).or_default();
                }
                Some("LINE") => {
                    if let Some(text) = block.get("Text").and_then(Value::as_str) {
                        pages_by_number.entry(page).or_default().push(text);
                    }
                }
                _ => {}
            }
        }
        if pages_by_number.is_empty() {
            pages_by_number.insert(1, Vec::new());
        }

        let pages: Vec<Value> = pages_by_number
            .into_iter()
            .map(|(page, lines)| {
                json!({"index": page.saturating_sub(1), "markdown": lines.join("\n")})
            })
            .collect();

        Ok(json!({
            "model": object.get("DetectDocumentTextModelVersion"),
            "pages": pages,
            "usage": {"pages": page_count}
        }))
    }
}
