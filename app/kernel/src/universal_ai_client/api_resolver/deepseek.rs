use base64_simd::STANDARD;
use uuid::Uuid as UUID;

use super::core::RawWireBody;
use super::*;

/// DeepSeek speech synthesis at `/v1/tools/tts`.
#[derive(Debug)]
pub(super) struct DeepseekSpeech;

/// DeepSeek speech transcription at `/v1/tools/asr` (`multipart/form-data`).
#[derive(Debug)]
pub(super) struct DeepseekTranscription;

/// DeepSeek document OCR at `/v1/tools/ocr` (`multipart/form-data`).
#[derive(Debug)]
pub(super) struct DeepseekOcr;

impl APIProtocol for DeepseekSpeech {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "DeepSeek speech")?;
        validate_known_request_fields(
            &request,
            &["input", "voice", "response_format"],
            strict,
            "DeepSeek speech",
        )?;

        let defaults = context.sanitized_provider_options_object();
        let voice_id = request
            .get("voice")
            .filter(|v| useful_value(v))
            .or_else(|| defaults.get("voice").filter(|v| useful_value(v)))
            .cloned()
            .unwrap_or_else(|| json!("stella"));
        let format = request
            .get("response_format")
            .filter(|v| useful_value(v))
            .or_else(|| defaults.get("response_format").filter(|v| useful_value(v)))
            .cloned()
            .unwrap_or_else(|| json!("wav"));

        let mut body = Map::new();
        if let Some(text) = request.get("input") {
            body.insert("text".to_string(), text.clone());
        }
        body.insert("voice_id".to_string(), voice_id);
        body.insert("format".to_string(), format);
        if let Some(filter_markdown) = defaults.get("filter_markdown").and_then(Value::as_bool) {
            body.insert("filter_markdown".to_string(), json!(filter_markdown));
        }
        Ok(body)
    }

    fn on_provider_response(
        &mut self,
        context: &ResponseContext,
        status: u16,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<Option<Value>, StreamError> {
        let raw = binary_speech_response(status, headers, body)?;
        self.on_provider_body(context, status, raw).map(Some)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        _status: u16,
        mut body: Value,
    ) -> Result<Value, StreamError> {
        if body.get("content_type").and_then(Value::as_str) == Some("application/octet-stream")
            && let Some(object) = body.as_object_mut()
        {
            let format = context
                .request
                .get("response_format")
                .and_then(Value::as_str)
                .or_else(|| {
                    context
                        .provider_options
                        .get("response_format")
                        .and_then(Value::as_str)
                })
                .unwrap_or("wav");
            let content_type = match format {
                "pcm" => "audio/pcm",
                _ => "audio/wav",
            };
            object.insert("content_type".to_string(), json!(content_type));
        }
        Ok(body)
    }
}

impl APIProtocol for DeepseekTranscription {
    fn build_raw_body(
        &self,
        context: &ResponseContext,
    ) -> Result<Option<RawWireBody>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "DeepSeek transcription")?;
        validate_known_request_fields(
            &request,
            &["input_audio", "language", "vad_filter", "response_format"],
            strict,
            "DeepSeek transcription",
        )?;

        let input_audio = request.get("input_audio").and_then(Value::as_object);
        let data = input_audio
            .and_then(|audio| audio.get("data"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let format = input_audio
            .and_then(|audio| audio.get("format"))
            .and_then(Value::as_str)
            .unwrap_or("wav")
            .trim()
            .to_ascii_lowercase();
        let bytes = STANDARD.decode_to_vec(data).map_err(|_| {
            StreamError::new(
                "invalid_parameter",
                "api_resolver",
                "DeepSeek transcription input_audio.data must be valid base64",
            )
            .provider_status(400)
        })?;

        let (filename, content_type) = match format.as_str() {
            "wav" => ("audio.wav".to_string(), "audio/wav".to_string()),
            "ogg" | "opus" | "ogg_opus" => ("audio.ogg".to_string(), "audio/ogg".to_string()),
            "mp3" => ("audio.mp3".to_string(), "audio/mpeg".to_string()),
            other => (format!("audio.{other}"), format!("audio/{other}")),
        };

        let mut form = MultipartForm::new();
        form.file_part("file", &filename, &content_type, &bytes);
        Ok(Some(form.finish()))
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "DeepSeek transcription")?;
        let seconds = object
            .get("duration_ms")
            .and_then(Value::as_f64)
            .map(|ms| ms / 1000.0)
            .or_else(|| object.get("duration").and_then(Value::as_f64));
        let duration = seconds.map(|secs| json!(secs));
        let usage = match seconds {
            Some(secs) => json!({"seconds": secs}),
            None => object
                .get("usage")
                .filter(|usage| usage.is_object())
                .cloned()
                .unwrap_or_else(|| json!({})),
        };

        transcription(
            status,
            &object,
            object.get("language"),
            duration.as_ref(),
            usage,
        )
    }
}

impl APIProtocol for DeepseekOcr {
    fn build_raw_body(
        &self,
        context: &ResponseContext,
    ) -> Result<Option<RawWireBody>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "DeepSeek OCR")?;
        validate_known_request_fields(&request, &["document", "pages"], strict, "DeepSeek OCR")?;

        let defaults = context.sanitized_provider_options_object();
        let document = request
            .get("document")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (mime, base64_data) = document
            .strip_prefix("data:")
            .and_then(|rest| rest.split_once(";base64,"))
            .unwrap_or(("application/octet-stream", document));

        let bytes = STANDARD.decode_to_vec(base64_data).map_err(|_| {
            StreamError::new(
                "invalid_parameter",
                "api_resolver",
                "DeepSeek OCR document must contain valid base64 bytes",
            )
            .provider_status(400)
        })?;

        let (filename, content_type) = match mime {
            "application/pdf" => ("document.pdf", "application/pdf"),
            "image/png" => ("document.png", "image/png"),
            "image/jpeg" => ("document.jpg", "image/jpeg"),
            "image/webp" => ("document.webp", "image/webp"),
            _ => ("document.bin", "application/octet-stream"),
        };

        let purpose = defaults
            .get("purpose")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| {
                if context.model.trim() == "rich_layout_recognition" {
                    "rich_layout_recognition"
                } else {
                    "text_recognition"
                }
            });

        let mut form = MultipartForm::new();
        form.text_part("purpose", purpose);
        form.file_part("file", filename, content_type, &bytes);
        Ok(Some(form.finish()))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "DeepSeek OCR")?;
        let Some(raw_pages) = object.get("pages").and_then(Value::as_array) else {
            return Err(invalid_upstream_body_error(
                status,
                object,
                "DeepSeek OCR response did not contain pages",
            ));
        };

        let pages: Vec<Value> = raw_pages
            .iter()
            .enumerate()
            .map(|(idx, page)| {
                let index = page
                    .get("index")
                    .and_then(Value::as_u64)
                    .unwrap_or(idx as u64);
                let text = page
                    .get("text")
                    .or_else(|| page.get("markdown"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                json!({
                    "index": index,
                    "markdown": collapse_blank_lines(text)
                })
            })
            .collect();

        let page_count = object
            .get("page_count")
            .and_then(Value::as_u64)
            .or_else(|| object.pointer("/usage/pages").and_then(Value::as_u64))
            .unwrap_or(pages.len() as u64)
            .max(pages.len() as u64);

        Ok(json!({
            "model": object.get("model").filter(|m| m.is_string()).cloned().unwrap_or_else(|| json!(context.model)),
            "pages": pages,
            "usage": {"pages": page_count}
        }))
    }
}

struct MultipartForm {
    boundary: String,
    bytes: Vec<u8>,
}

impl MultipartForm {
    fn new() -> Self {
        Self {
            boundary: format!("----AnkoleBoundary{}", UUID::new_v4().simple()),
            bytes: Vec::new(),
        }
    }

    fn text_part(&mut self, name: &str, value: &str) {
        self.bytes
            .extend_from_slice(format!("--{}\r\n", self.boundary).as_bytes());
        self.bytes.extend_from_slice(
            format!("Content-Disposition: form-data; name=\"{name}\"\r\n\r\n").as_bytes(),
        );
        self.bytes.extend_from_slice(value.as_bytes());
        self.bytes.extend_from_slice(b"\r\n");
    }

    fn file_part(&mut self, name: &str, filename: &str, content_type: &str, data: &[u8]) {
        self.bytes
            .extend_from_slice(format!("--{}\r\n", self.boundary).as_bytes());
        self.bytes.extend_from_slice(
            format!(
                "Content-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: {content_type}\r\n\r\n"
            )
            .as_bytes(),
        );
        self.bytes.extend_from_slice(data);
        self.bytes.extend_from_slice(b"\r\n");
    }

    fn finish(mut self) -> RawWireBody {
        self.bytes
            .extend_from_slice(format!("--{}--\r\n", self.boundary).as_bytes());
        RawWireBody {
            content_type: format!("multipart/form-data; boundary={}", self.boundary),
            bytes: self.bytes,
        }
    }
}
