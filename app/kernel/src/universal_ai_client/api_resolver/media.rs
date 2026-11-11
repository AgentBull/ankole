use super::*;

/// OpenRouter video generation at `/videos`. OpenRouter answers a submission
/// and a status request with the same object, so one resolver reads both.
#[derive(Debug)]
pub(super) struct OpenrouterVideo;

/// Cloudflare music generation: partner models behind `ai/run`, which answer
/// once the audio is ready.
#[derive(Debug)]
pub(super) struct CloudflareMusic;

impl APIProtocol for OpenrouterVideo {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "OpenRouter video")?;
        validate_known_request_fields(
            &request,
            &[
                "prompt",
                "duration",
                "resolution",
                "aspect_ratio",
                "size",
                "generate_audio",
                "seed",
                "first_frame",
                "last_frame",
            ],
            strict,
            "OpenRouter video",
        )?;
        let mut body = context.sanitized_provider_options_object();
        body.insert("model".to_string(), json!(context.model));
        for key in [
            "prompt",
            "duration",
            "resolution",
            "aspect_ratio",
            "size",
            "generate_audio",
            "seed",
        ] {
            maybe_put_from(&mut body, &request, key);
        }
        let frames: Vec<Value> = ["first_frame", "last_frame"]
            .into_iter()
            .filter_map(|frame_type| {
                let url = request.get(frame_type).filter(|url| useful_value(url))?;
                Some(json!({
                    "type": "image_url",
                    "image_url": {"url": url},
                    "frame_type": frame_type
                }))
            })
            .collect();
        if !frames.is_empty() {
            body.insert("frame_images".to_string(), json!(frames));
        }
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        // A failed generation carries `error` next to its `status`, so the
        // object is read as a state before it is read as a provider failure.
        let object = match body.get("status") {
            Some(_state) => body,
            None => provider_object_body(status, body, "OpenRouter video")?,
        };
        let state = match object.get("status").and_then(Value::as_str) {
            Some("completed") => "completed",
            Some("failed" | "cancelled" | "expired") => "failed",
            Some(_running) => "in_progress",
            None => {
                return Err(invalid_upstream_body_error(
                    status,
                    object,
                    "video response did not contain a status",
                ));
            }
        };

        let mut result = Map::new();
        result.insert("status".to_string(), json!(state));
        if let Some(id) = object.get("id").filter(|id| id.is_string()) {
            result.insert("job_id".to_string(), id.clone());
        }
        // `unsigned_urls` name OpenRouter's own content endpoint, which stays
        // readable for as long as the generation exists. `urls` expire.
        let url = ["/unsigned_urls/0", "/urls/0"]
            .into_iter()
            .find_map(|pointer| object.pointer(pointer).filter(|url| url.is_string()));
        if let Some(url) = url {
            result.insert("url".to_string(), url.clone());
        }
        if let Some(error) = object.get("error").filter(|error| useful_value(error)) {
            result.insert("error".to_string(), error.clone());
        }
        let usage = object.get("usage").filter(|usage| usage.is_object());
        result.insert(
            "usage".to_string(),
            usage.cloned().unwrap_or_else(|| json!({})),
        );
        Ok(Value::Object(result))
    }
}

impl APIProtocol for CloudflareMusic {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let strict = context.policy() == ConversionPolicy::Strict;
        let mut request = context.canonical_request_object();
        strip_non_streaming_flag(&mut request, strict, "Cloudflare music")?;
        validate_known_request_fields(
            &request,
            &["prompt", "lyrics", "instrumental", "duration"],
            strict,
            "Cloudflare music",
        )?;
        let defaults = context.sanitized_provider_options_object();
        let instrumental = request
            .get("instrumental")
            .and_then(Value::as_bool)
            .or_else(|| defaults.get("instrumental").and_then(Value::as_bool));
        let mut input = Map::new();
        for key in ["prompt", "lyrics"] {
            maybe_put_from(&mut input, &defaults, key);
            maybe_put_from(&mut input, &request, key);
        }

        // Each partner names the instrumental switch and the length its own way.
        if context.model.starts_with("minimax/") {
            let instrumental = instrumental.unwrap_or(false);
            input.insert("is_instrumental".to_string(), json!(instrumental));
            // MiniMax writes the lyrics of a song that comes without them.
            input.insert(
                "lyrics_optimizer".to_string(),
                json!(!instrumental && !input.contains_key("lyrics")),
            );
        } else if context.model.starts_with("elevenlabs/") {
            if let Some(instrumental) = instrumental {
                input.insert("force_instrumental".to_string(), json!(instrumental));
            }
            if let Some(seconds) = request
                .get("duration")
                .and_then(Value::as_u64)
                .or_else(|| defaults.get("duration").and_then(Value::as_u64))
            {
                input.insert("music_length_ms".to_string(), json!(seconds * 1000));
            }
        } else {
            for key in ["instrumental", "duration"] {
                maybe_put_from(&mut input, &defaults, key);
                maybe_put_from(&mut input, &request, key);
            }
        }

        let mut body = Map::new();
        body.insert("model".to_string(), json!(context.model));
        body.insert("input".to_string(), Value::Object(input));
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Cloudflare music")?;
        // The audio link sits in the model's `result`, which the Cloudflare
        // API envelope can wrap in a `result` of its own.
        let url = ["/result/result/audio", "/result/audio", "/audio"]
            .into_iter()
            .find_map(|pointer| object.pointer(pointer).filter(|url| url.is_string()));
        match url {
            Some(url) => Ok(json!({"status": "completed", "url": url, "usage": {}})),
            None => Err(invalid_upstream_body_error(
                status,
                object,
                "music response did not contain an audio link",
            )),
        }
    }
}
