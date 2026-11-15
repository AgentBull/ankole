use base64_simd::STANDARD;

use super::core::RawWireBody;
use super::*;

/// Volcengine Doubao Speech V3 unidirectional HTTP synthesis at
/// `/api/v3/tts/unidirectional`.
#[derive(Debug)]
pub(super) struct VolcengineSpeech;

/// Volcengine Doubao Speech V3 synchronous file recognition at
/// `/api/v3/auc/bigmodel/recognize/flash`.
#[derive(Debug)]
pub(super) struct VolcengineTranscription;

/// Volcengine Visual Intelligence OpenAPI OCR (`OCRNormal` / `OCRPdf`) at
/// `visual.volcengineapi.com`.
#[derive(Debug)]
pub(super) struct VolcengineVisualOcr;

impl APIProtocol for VolcengineSpeech {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Volcengine speech")?;
        validate_known_request_fields(
            &request,
            &["input", "voice", "response_format", "speed"],
            strict,
            "Volcengine speech",
        )?;

        let defaults = context.sanitized_provider_options_object();
        let format = request
            .get("response_format")
            .and_then(Value::as_str)
            .filter(|fmt| !fmt.is_empty())
            .or_else(|| {
                defaults
                    .get("response_format")
                    .and_then(Value::as_str)
                    .filter(|fmt| !fmt.is_empty())
            })
            .unwrap_or("mp3");

        let mut audio_params = Map::new();
        audio_params.insert("format".to_string(), json!(format));
        audio_params.insert("sample_rate".to_string(), json!(24000));
        if let Some(speed) = request
            .get("speed")
            .and_then(Value::as_f64)
            .or_else(|| defaults.get("speed").and_then(Value::as_f64))
        {
            let speech_rate = ((speed - 1.0) * 100.0).round().clamp(-50.0, 100.0) as i64;
            if speech_rate != 0 {
                audio_params.insert("speech_rate".to_string(), json!(speech_rate));
            }
        }

        let mut req_params = Map::new();
        if let Some(text) = request.get("input") {
            req_params.insert("text".to_string(), text.clone());
        }
        if let Some(speaker) = request
            .get("voice")
            .filter(|v| useful_value(v))
            .or_else(|| defaults.get("voice").filter(|v| useful_value(v)))
        {
            req_params.insert("speaker".to_string(), speaker.clone());
        }
        req_params.insert("audio_params".to_string(), Value::Object(audio_params));

        let mut body = Map::new();
        body.insert("user".to_string(), json!({"uid": "ankole"}));
        body.insert("req_params".to_string(), Value::Object(req_params));
        Ok(body)
    }

    fn on_provider_response(
        &mut self,
        context: &ResponseContext,
        status: u16,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<Option<Value>, StreamError> {
        check_volcengine_status_header(headers, body)?;
        let frames = decode_volcengine_ndjson_body(status, body)?;
        self.on_provider_body(context, status, frames).map(Some)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        if !(200..300).contains(&status) {
            return Err(provider_body_error(status, body));
        }

        let frames: Vec<Value> = match &body {
            Value::Array(items) => items.clone(),
            Value::Object(_) => vec![body.clone()],
            _ => {
                return Err(invalid_upstream_body_error(
                    status,
                    body,
                    "Volcengine speech response must be JSON lines or a JSON object",
                ));
            }
        };

        let mut audio_bytes = Vec::new();
        for frame in &frames {
            reject_provider_body_error(status, frame)?;
            if let Some(code) = frame.get("code").and_then(integer_value)
                && !matches!(code, 0 | 3000 | 20_000_000)
            {
                return Err(volcengine_code_error(code, frame));
            }
            if let Some(chunk) = frame
                .get("data")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|chunk| !chunk.is_empty())
            {
                let decoded = STANDARD.decode_to_vec(chunk).map_err(|_| {
                    invalid_upstream_body_error(
                        status,
                        frame.clone(),
                        "Volcengine speech chunk contained invalid base64 audio",
                    )
                })?;
                audio_bytes.extend_from_slice(&decoded);
            }
        }

        if audio_bytes.is_empty() {
            return Err(invalid_upstream_body_error(
                status,
                body,
                "Volcengine speech response did not contain audio",
            ));
        }

        let requested_format = context
            .request
            .get("response_format")
            .and_then(Value::as_str)
            .or_else(|| {
                context
                    .provider_options
                    .get("response_format")
                    .and_then(Value::as_str)
            })
            .unwrap_or("mp3");
        let content_type = match requested_format {
            "pcm" => "audio/pcm",
            _ => "audio/mpeg",
        };

        Ok(json!({
            "audio": STANDARD.encode_to_string(&audio_bytes),
            "content_type": content_type,
            "usage": {}
        }))
    }
}

impl APIProtocol for VolcengineTranscription {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Volcengine transcription")?;
        validate_known_request_fields(
            &request,
            &["input_audio", "language", "vad_filter", "response_format"],
            strict,
            "Volcengine transcription",
        )?;

        let defaults = context.sanitized_provider_options_object();
        let input_audio = request.get("input_audio").and_then(Value::as_object);
        let data = input_audio
            .and_then(|audio| audio.get("data"))
            .and_then(Value::as_str)
            .unwrap_or_default();
        let format = input_audio
            .and_then(|audio| audio.get("format"))
            .and_then(Value::as_str)
            .unwrap_or("wav")
            .to_ascii_lowercase();

        let model_name = if context.model.is_empty() || context.model.starts_with("volc.") {
            "bigmodel"
        } else {
            context.model.as_str()
        };

        let mut req = Map::new();
        req.insert("model_name".to_string(), json!(model_name));
        req.insert("enable_itn".to_string(), json!(true));
        req.insert("enable_punc".to_string(), json!(true));
        req.insert("show_utterances".to_string(), json!(true));
        if let Some(language) = request
            .get("language")
            .filter(|v| useful_value(v))
            .or_else(|| defaults.get("language").filter(|v| useful_value(v)))
        {
            req.insert("language".to_string(), language.clone());
        }

        let mut body = Map::new();
        body.insert("user".to_string(), json!({"uid": "ankole"}));
        body.insert("audio".to_string(), json!({"data": data, "format": format}));
        body.insert("request".to_string(), Value::Object(req));
        Ok(body)
    }

    fn on_provider_response(
        &mut self,
        _context: &ResponseContext,
        _status: u16,
        headers: &[(String, String)],
        body: &[u8],
    ) -> Result<Option<Value>, StreamError> {
        check_volcengine_status_header(headers, body)?;
        Ok(None)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Volcengine transcription")?;
        if let Some(code) = object.get("code").and_then(integer_value)
            && !matches!(code, 0 | 1000 | 20_000_000)
        {
            return Err(volcengine_code_error(code, &object));
        }

        let Some(result_obj) = object.get("result") else {
            return Err(invalid_upstream_body_error(
                status,
                object,
                "Volcengine transcription response did not contain result",
            ));
        };

        let duration_ms = [
            "/audio_info/duration",
            "/result/additions/duration",
            "/addition/duration",
        ]
        .into_iter()
        .find_map(|pointer| object.pointer(pointer).and_then(ms_value));
        let duration = duration_ms.map(|ms| json!(ms / 1000.0));
        let usage = match duration_ms {
            Some(ms) => json!({"seconds": ms / 1000.0}),
            None => json!({}),
        };

        let mut payload = Map::new();
        if let Some(text) = result_obj.get("text") {
            payload.insert("text".to_string(), text.clone());
        }
        if let Some(utterances) = result_obj.get("utterances").and_then(Value::as_array) {
            let segments: Vec<Value> = utterances
                .iter()
                .map(|utt| {
                    let start = utt
                        .get("start_time")
                        .and_then(ms_value)
                        .map(|ms| json!(ms / 1000.0))
                        .unwrap_or(Value::Null);
                    let end = utt
                        .get("end_time")
                        .and_then(ms_value)
                        .map(|ms| json!(ms / 1000.0))
                        .unwrap_or(Value::Null);
                    json!({
                        "start": start,
                        "end": end,
                        "text": utt.get("text")
                    })
                })
                .collect();
            payload.insert("segments".to_string(), Value::Array(segments));
        }

        let language = result_obj
            .pointer("/additions/language")
            .or_else(|| object.pointer("/addition/language"));

        transcription(
            status,
            &Value::Object(payload),
            language,
            duration.as_ref(),
            usage,
        )
    }
}

impl APIProtocol for VolcengineVisualOcr {
    fn build_raw_body(
        &self,
        context: &ResponseContext,
    ) -> Result<Option<RawWireBody>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Volcengine Visual OCR")?;
        validate_known_request_fields(
            &request,
            &["document", "pages"],
            strict,
            "Volcengine Visual OCR",
        )?;

        let document = request
            .get("document")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (mime, base64_bytes) = split_data_url(document);
        let encoded_base64 = form_urlencode(base64_bytes);

        let form = if mime == "application/pdf" || is_pdf_ocr_model(&context.model) {
            let file_type = if mime == "application/pdf" {
                "pdf"
            } else {
                "image"
            };
            format!("image_base64={encoded_base64}&file_type={file_type}&version=v3")
        } else {
            format!("image_base64={encoded_base64}")
        };

        Ok(Some(RawWireBody {
            content_type: "application/x-www-form-urlencoded".to_string(),
            bytes: form.into_bytes(),
        }))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Volcengine Visual OCR")?;
        if object.pointer("/ResponseMetadata/Error").is_some() {
            return Err(provider_body_error(status, object));
        }
        if let Some(code) = object.get("code").and_then(integer_value)
            && code != 10_000
        {
            return Err(volcengine_code_error(code, &object));
        }

        let Some(data) = object.get("data").or_else(|| object.get("Result")) else {
            return Err(invalid_upstream_body_error(
                status,
                object,
                "Volcengine Visual OCR response did not contain data",
            ));
        };

        if let Some(page_infos) = data
            .get("page_infos")
            .or_else(|| data.get("detail"))
            .and_then(Value::as_array)
            .filter(|items| {
                !items.is_empty()
                    && items
                        .iter()
                        .any(|item| item.get("markdown").is_some() || item.get("text").is_some())
            })
        {
            let pages: Vec<Value> = page_infos
                .iter()
                .enumerate()
                .map(|(idx, item)| {
                    let index = item
                        .get("index")
                        .and_then(Value::as_u64)
                        .or_else(|| {
                            item.get("page_id")
                                .or_else(|| item.get("page_num"))
                                .and_then(Value::as_u64)
                                .map(|page| page.saturating_sub(1))
                        })
                        .unwrap_or(idx as u64);
                    let md = item
                        .get("markdown")
                        .or_else(|| item.get("text"))
                        .and_then(Value::as_str)
                        .unwrap_or_default();
                    json!({
                        "index": index,
                        "markdown": collapse_blank_lines(md)
                    })
                })
                .collect();
            let count = pages.len() as u64;
            return Ok(json!({
                "model": context.model,
                "pages": pages,
                "usage": {"pages": count}
            }));
        }

        if let Some(markdown) = data.get("markdown").and_then(Value::as_str) {
            let page_count = data
                .get("total_page")
                .or_else(|| data.get("page_count"))
                .and_then(Value::as_u64)
                .unwrap_or(1)
                .max(1);
            return Ok(json!({
                "model": context.model,
                "pages": [{"index": 0, "markdown": collapse_blank_lines(markdown)}],
                "usage": {"pages": page_count}
            }));
        }

        if let Some(lines) = data.get("line_texts").and_then(Value::as_array) {
            let joined = lines
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n");
            return Ok(json!({
                "model": context.model,
                "pages": [{"index": 0, "markdown": collapse_blank_lines(&joined)}],
                "usage": {"pages": 1}
            }));
        }

        Err(invalid_upstream_body_error(
            status,
            object,
            "Volcengine Visual OCR response did not contain recognized text",
        ))
    }
}

fn is_pdf_ocr_model(model: &str) -> bool {
    let normalized = model.trim().to_ascii_lowercase();
    normalized == "ocr-pdf" || normalized == "ocr_pdf" || normalized == "ocrpdf"
}

fn split_data_url(document: &str) -> (&str, &str) {
    if let Some(rest) = document.strip_prefix("data:")
        && let Some((mime, data)) = rest.split_once(";base64,")
    {
        return (mime, data);
    }
    ("", document)
}

fn form_urlencode(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len() + 16);
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(byte as char);
            }
            b' ' => encoded.push('+'),
            _ => encoded.push_str(&format!("%{byte:02X}")),
        }
    }
    encoded
}

fn ms_value(value: &Value) -> Option<f64> {
    value.as_f64().or_else(|| {
        value
            .as_str()
            .and_then(|text| text.trim().parse::<f64>().ok())
    })
}

fn volcengine_status_for_code(code: i64) -> u16 {
    match code {
        40_100_000..=40_199_999 | 45_000_010 => 401,
        40_300_000..=40_399_999 => 403,
        40_429_000..=40_429_999 | 45_000_292 | 50_429 => 429,
        40_000_000..=49_999_999 | 50_400 => 400,
        _ => 502,
    }
}

fn check_volcengine_status_header(
    headers: &[(String, String)],
    body: &[u8],
) -> Result<(), StreamError> {
    let Some(code_str) = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("x-api-status-code"))
        .map(|(_, value)| value.trim())
        .filter(|value| !value.is_empty())
    else {
        return Ok(());
    };
    if matches!(code_str, "0" | "20000000") {
        return Ok(());
    }

    let status = code_str
        .parse::<i64>()
        .ok()
        .map_or(502, volcengine_status_for_code);
    let message = headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("x-api-message"))
        .map(|(_, value)| value.trim())
        .filter(|value| !value.is_empty())
        .map(|msg| format!("Volcengine status {code_str}: {msg}"))
        .unwrap_or_else(|| format!("Volcengine status {code_str}"));

    let excerpt = if body.is_empty() {
        message.as_bytes().to_vec()
    } else {
        body.to_vec()
    };

    Err(
        StreamError::new("provider_status_rejected", "api_resolver", message)
            .provider_status(status)
            .provider_body_excerpt(excerpt)
            .provider_headers(headers),
    )
}

fn decode_volcengine_ndjson_body(status: u16, bytes: &[u8]) -> Result<Value, StreamError> {
    let text = std::str::from_utf8(bytes).map_err(|_| {
        StreamError::new(
            "invalid_upstream_response",
            "api_resolver",
            "upstream NDJSON response was not valid UTF-8",
        )
        .provider_status(status)
        .provider_body_excerpt(bytes)
    })?;

    let mut items = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let value: Value = sonic_rs::from_str(trimmed).map_err(|_| {
            StreamError::new(
                "invalid_upstream_response",
                "api_resolver",
                "upstream NDJSON line was not valid JSON",
            )
            .provider_status(status)
            .provider_body_excerpt(bytes)
        })?;
        items.push(value);
    }

    if items.is_empty() {
        return Err(StreamError::new(
            "invalid_upstream_response",
            "api_resolver",
            "upstream NDJSON response was empty",
        )
        .provider_status(status)
        .provider_body_excerpt(bytes));
    }

    Ok(Value::Array(items))
}

fn volcengine_code_error(code: i64, body: &Value) -> StreamError {
    let status = volcengine_status_for_code(code);
    let excerpt = sonic_rs::to_vec(body).unwrap_or_default();
    StreamError::new(
        "provider_status_rejected",
        "api_resolver",
        format!("Volcengine upstream rejected request with code {code}"),
    )
    .provider_status(status)
    .provider_body_excerpt(excerpt)
}
