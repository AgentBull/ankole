use super::*;

/// OpenRouter text to speech at `/audio/speech`.
#[derive(Debug)]
pub(super) struct OpenrouterSpeech;

/// Cloudflare text to speech: the Deepgram Aura models on Workers AI.
#[derive(Debug)]
pub(super) struct CloudflareSpeech;

/// OpenRouter speech to text at `/audio/transcriptions`.
#[derive(Debug)]
pub(super) struct OpenrouterTranscription;

/// Cloudflare speech to text: Workers AI models that take base64 audio, such
/// as `@cf/openai/whisper-large-v3-turbo`.
#[derive(Debug)]
pub(super) struct CloudflareTranscription;

impl APIProtocol for OpenrouterSpeech {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut body = Map::new();
        body.insert("model".to_string(), json!(context.model));
        for key in ["input", "voice", "response_format", "speed", "instructions"] {
            maybe_put_from(&mut body, &request, key);
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

impl APIProtocol for CloudflareSpeech {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut body = Map::new();
        if let Some(text) = request.get("input") {
            body.insert("text".to_string(), text.clone());
        }
        if let Some(voice) = request.get("voice").filter(|voice| useful_value(voice)) {
            body.insert("speaker".to_string(), voice.clone());
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

impl APIProtocol for OpenrouterTranscription {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut body = Map::new();
        body.insert("model".to_string(), json!(context.model));
        for key in ["input_audio", "language", "response_format"] {
            maybe_put_from(&mut body, &request, key);
        }
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "OpenRouter transcription")?;
        let usage = object.get("usage").filter(|usage| usage.is_object());
        transcription(
            status,
            &object,
            object.get("language"),
            object.get("duration"),
            usage.cloned().unwrap_or_else(|| json!({})),
        )
    }
}

impl APIProtocol for CloudflareTranscription {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut body = Map::new();
        if let Some(audio) = request
            .get("input_audio")
            .and_then(|audio| audio.get("data"))
        {
            body.insert("audio".to_string(), audio.clone());
        }
        for key in ["language", "vad_filter"] {
            maybe_put_from(&mut body, &request, key);
        }
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Cloudflare transcription")?;
        let payload = cloudflare_result(object);
        let duration = payload.pointer("/transcription_info/duration");
        let usage = match duration.and_then(Value::as_f64) {
            Some(seconds) => json!({"seconds": seconds}),
            None => json!({}),
        };
        transcription(
            status,
            &payload,
            payload.pointer("/transcription_info/language"),
            duration,
            usage,
        )
    }
}

/// Builds the transcription that every provider's response becomes: the text,
/// the language and duration when the provider reports them, and the segments
/// with their start and end in seconds.
fn transcription(
    status: u16,
    payload: &Value,
    language: Option<&Value>,
    duration: Option<&Value>,
    usage: Value,
) -> Result<Value, StreamError> {
    let Some(text) = payload.get("text").and_then(Value::as_str) else {
        return Err(invalid_upstream_body_error(
            status,
            payload.clone(),
            "transcription response did not contain text",
        ));
    };

    let mut result = Map::new();
    result.insert("text".to_string(), json!(text));
    if let Some(language) = language.filter(|language| language.is_string()) {
        result.insert("language".to_string(), language.clone());
    }
    if let Some(duration) = duration.filter(|duration| duration.is_number()) {
        result.insert("duration".to_string(), duration.clone());
    }
    if let Some(segments) = payload.get("segments").and_then(Value::as_array) {
        let segments: Vec<Value> = segments
            .iter()
            .map(|segment| {
                json!({
                    "start": segment.get("start"),
                    "end": segment.get("end"),
                    "text": segment.get("text")
                })
            })
            .collect();
        result.insert("segments".to_string(), Value::Array(segments));
    }
    result.insert("usage".to_string(), usage);
    Ok(Value::Object(result))
}
