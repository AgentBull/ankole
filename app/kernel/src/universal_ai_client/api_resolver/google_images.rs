use super::*;

const KNOWN_GOOGLE_IMAGES_FIELDS: &[&str] = &[
    "model",
    "prompt",
    "n",
    "size",
    "aspect_ratio",
    "aspectRatio",
    "quality",
    "background",
    "output_format",
    "output_compression",
    "person_generation",
    "personGeneration",
    "input_references",
    "input_image_mask",
    "image",
    "images",
    "mask",
    "stream",
    "partial_images",
    "service_tier",
];

#[derive(Debug)]
pub(super) struct GoogleImages;

impl APIProtocol for GoogleImages {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_body(context)
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        if context.policy() == ConversionPolicy::Strict {
            return Err(StreamError::new(
                "unsupported_stream_resolver",
                "api_resolver",
                "google_images does not support streaming partial_images under strict policy",
            )
            .provider_status(400));
        }
        normalize_image_stream_event(context, event, "Google Images")
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        on_provider_body(context, status, body)
    }
}

pub(crate) fn build_body(context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
    let request = context.resolved_provider_request_object();
    let strict = context.policy() == ConversionPolicy::Strict;
    if strict {
        validate_strict_google_images_request(&request)?;
    }
    let prompt = request
        .get("prompt")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let count = request.get("n").and_then(Value::as_u64).unwrap_or(1).max(1);
    let aspect_ratio = resolve_google_aspect_ratio(&request);

    if context.model.to_ascii_lowercase().contains("imagen") {
        if strict && has_image_inputs(&request) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                "Imagen models do not support reference images",
            )
            .provider_status(400));
        }

        return Ok(build_imagen_body(&request, prompt, count, aspect_ratio));
    }
    build_gemini_image_body(&request, prompt, count, aspect_ratio, strict)
}

fn resolve_google_aspect_ratio(request: &Map<String, Value>) -> Option<String> {
    request
        .get("aspectRatio")
        .or_else(|| request.get("aspect_ratio"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| {
            request
                .get("size")
                .and_then(Value::as_str)
                .and_then(size_to_aspect_ratio)
                .map(ToOwned::to_owned)
        })
}

fn build_imagen_body(
    request: &Map<String, Value>,
    prompt: &str,
    count: u64,
    aspect_ratio: Option<String>,
) -> Map<String, Value> {
    let mut parameters = Map::new();
    parameters.insert("sampleCount".to_string(), json!(count));
    if let Some(ratio) = aspect_ratio {
        parameters.insert("aspectRatio".to_string(), json!(ratio));
    }
    if let Some(format) = request.get("output_format").and_then(Value::as_str) {
        parameters.insert(
            "outputOptions".to_string(),
            json!({ "mimeType": output_format_to_mime(format) }),
        );
    }
    let mut body = Map::new();
    body.insert("instances".to_string(), json!([{ "prompt": prompt }]));
    body.insert("parameters".to_string(), Value::Object(parameters));
    body
}

fn build_gemini_image_body(
    request: &Map<String, Value>,
    prompt: &str,
    count: u64,
    aspect_ratio: Option<String>,
    strict: bool,
) -> Result<Map<String, Value>, StreamError> {
    let mut parts = collect_google_reference_images(request, strict)?;
    parts.push(json!({ "text": prompt }));

    let mut generation_config = Map::new();
    generation_config.insert("responseModalities".to_string(), json!(["IMAGE"]));
    if count > 1 {
        generation_config.insert("candidateCount".to_string(), json!(count));
    }
    if let Some(ratio) = aspect_ratio {
        generation_config.insert("imageConfig".to_string(), json!({ "aspectRatio": ratio }));
    }

    let mut body = Map::new();
    body.insert(
        "contents".to_string(),
        json!([{ "role": "user", "parts": parts }]),
    );
    body.insert(
        "generationConfig".to_string(),
        Value::Object(generation_config),
    );
    Ok(body)
}

pub(crate) fn on_provider_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = provider_object_body(status, body, "Google Images")?;
    let default_mime = default_image_mime_type(context);
    let normalized_data = extract_google_images_data(&object, default_mime);
    if normalized_data.is_empty() {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object,
            "Google Images response did not contain any generated images",
        ));
    }
    let requested_n = requested_image_count(context);
    if normalized_data.len() < requested_n {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object,
            format!(
                "Google Images response returned {} images, fewer than requested n={requested_n}",
                normalized_data.len()
            ),
        ));
    }
    let first = &normalized_data[0];
    let created = object
        .get("created")
        .and_then(Value::as_i64)
        .unwrap_or_else(now_seconds);
    let usage = normalize_google_images_usage(
        status,
        &object,
        normalized_data.len(),
        context.policy() == ConversionPolicy::Strict,
    )?;

    Ok(json!({
        "created": created,
        "data": normalized_data,
        "result": first.get("b64_json").cloned().unwrap_or(Value::Null),
        "mime_type": first.get("media_type").cloned().unwrap_or_else(|| json!(default_mime)),
        "revised_prompt": first.get("revised_prompt").cloned().unwrap_or(Value::Null),
        "usage": usage
    }))
}

fn has_image_inputs(request: &Map<String, Value>) -> bool {
    ["image", "images", "input_references"]
        .iter()
        .any(|key| request.get(*key).is_some_and(|value| !value.is_null()))
}

fn validate_strict_google_images_request(request: &Map<String, Value>) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_GOOGLE_IMAGES_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported google_images parameter `{key}` under strict policy"),
            )
            .provider_status(400));
        }
    }
    if !request
        .get("prompt")
        .and_then(Value::as_str)
        .is_some_and(|p| !p.trim().is_empty())
    {
        return Err(StreamError::new(
            "invalid_image_prompt",
            "api_resolver",
            "google_images requires a non-empty `prompt`",
        )
        .provider_status(400));
    }
    if let Some(count) = request.get("n")
        && !count
            .as_u64()
            .is_some_and(|count| (1..=10).contains(&count))
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "google_images `n` must be an integer between 1 and 10",
        )
        .provider_status(400));
    }
    if let Some(compression) = request.get("output_compression")
        && !compression.as_u64().is_some_and(|value| value <= 100)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "google_images `output_compression` must be an integer between 0 and 100",
        )
        .provider_status(400));
    }
    if request.get("background").and_then(Value::as_str) == Some("transparent") {
        return Err(StreamError::new(
            "unsupported_parameter",
            "api_resolver",
            "google_images does not support `background: transparent`",
        )
        .provider_status(400));
    }
    if request
        .get("input_image_mask")
        .is_some_and(|v| !v.is_null())
        || request.get("mask").is_some_and(|v| !v.is_null())
    {
        return Err(StreamError::new(
            "unsupported_parameter",
            "api_resolver",
            "google_images does not support image masks",
        )
        .provider_status(400));
    }
    if request.get("stream").and_then(Value::as_bool) == Some(true)
        || request
            .get("partial_images")
            .and_then(Value::as_u64)
            .is_some_and(|c| c > 0)
    {
        return Err(StreamError::new(
            "unsupported_parameter",
            "api_resolver",
            "google_images does not support streaming or `partial_images`",
        )
        .provider_status(400));
    }
    Ok(())
}

fn collect_google_reference_images(
    request: &Map<String, Value>,
    strict: bool,
) -> Result<Vec<Value>, StreamError> {
    let mut parts = Vec::new();
    let Some(sources) = resolve_normalized_image_references(request, strict)? else {
        return Ok(parts);
    };
    for source in sources {
        if let Some(raw) = source.as_str() {
            if !raw.starts_with("data:") && raw.contains("://") {
                return Err(StreamError::new(
                    "invalid_image_reference",
                    "api_resolver",
                    "google_images requires inline data URL or base64 reference images, remote URLs are not supported",
                )
                .provider_status(400));
            }
            let (mime_type, data) = split_data_url_or_base64(raw);
            parts.push(json!({ "inlineData": { "mimeType": mime_type, "data": data } }));
        }
    }
    Ok(parts)
}

fn split_data_url_or_base64(input: &str) -> (&str, &str) {
    if let Some(rest) = input.strip_prefix("data:")
        && let Some((header, b64)) = rest.split_once(";base64,")
    {
        return (
            if header.is_empty() {
                "image/png"
            } else {
                header
            },
            b64,
        );
    }
    ("image/png", input)
}

fn size_to_aspect_ratio(size: &str) -> Option<&'static str> {
    match size {
        "1024x1024" | "512x512" | "256x256" | "1:1" => Some("1:1"),
        "1536x1024" | "1792x1024" | "3:2" | "16:9" => Some("16:9"),
        "1024x1536" | "1024x1792" | "2:3" | "9:16" => Some("9:16"),
        "4:3" => Some("4:3"),
        "3:4" => Some("3:4"),
        _ => None,
    }
}

fn output_format_to_mime(format: &str) -> &'static str {
    match format {
        "jpeg" | "jpg" => "image/jpeg",
        "webp" => "image/webp",
        _ => "image/png",
    }
}

fn extract_google_images_data(object: &Value, default_mime: &str) -> Vec<Value> {
    let mut results = extract_candidate_images(object, default_mime);
    if results.is_empty() {
        results = extract_prediction_images(object, default_mime);
    }
    if results.is_empty() {
        results = extract_data_images(object, default_mime);
    }
    results
}

fn extract_candidate_images(object: &Value, default_mime: &str) -> Vec<Value> {
    let mut results = Vec::new();
    let Some(candidates) = object.get("candidates").and_then(Value::as_array) else {
        return results;
    };
    for candidate in candidates {
        let Some(parts) = candidate
            .get("content")
            .and_then(|c| c.get("parts"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        let revised_prompt = parts
            .iter()
            .find_map(|p| p.get("text").and_then(Value::as_str))
            .map(ToOwned::to_owned);
        for part in parts {
            let Some(inline) = part
                .get("inlineData")
                .or_else(|| part.get("inline_data"))
                .and_then(Value::as_object)
            else {
                continue;
            };
            if let Some(data) = inline
                .get("data")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
            {
                let mime = inline
                    .get("mimeType")
                    .or_else(|| inline.get("mime_type"))
                    .and_then(Value::as_str)
                    .unwrap_or(default_mime);
                results.push(json!({ "b64_json": data, "media_type": mime, "revised_prompt": revised_prompt }));
            }
        }
    }
    results
}

fn extract_prediction_images(object: &Value, default_mime: &str) -> Vec<Value> {
    let mut results = Vec::new();
    let Some(predictions) = object.get("predictions").and_then(Value::as_array) else {
        return results;
    };
    for pred in predictions {
        if let Some(b64) = pred
            .get("bytesBase64Encoded")
            .or_else(|| pred.get("b64_json"))
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        {
            let mime = pred
                .get("mimeType")
                .or_else(|| pred.get("media_type"))
                .and_then(Value::as_str)
                .unwrap_or(default_mime);
            let revised_prompt = pred
                .get("prompt")
                .or_else(|| pred.get("revised_prompt"))
                .and_then(Value::as_str);
            results.push(
                json!({ "b64_json": b64, "media_type": mime, "revised_prompt": revised_prompt }),
            );
        }
    }
    results
}

fn extract_data_images(object: &Value, default_mime: &str) -> Vec<Value> {
    let mut results = Vec::new();
    let Some(data) = object.get("data").and_then(Value::as_array) else {
        return results;
    };
    for item in data {
        if let Some(b64) = item
            .get("b64_json")
            .and_then(Value::as_str)
            .filter(|v| !v.is_empty())
        {
            let mime = item
                .get("media_type")
                .or_else(|| item.get("mime_type"))
                .and_then(Value::as_str)
                .unwrap_or(default_mime);
            results.push(json!({ "b64_json": b64, "media_type": mime, "revised_prompt": item.get("revised_prompt").and_then(Value::as_str) }));
        }
    }
    results
}

fn normalize_google_images_usage(
    status: u16,
    object: &Value,
    image_count: usize,
    strict: bool,
) -> Result<Value, StreamError> {
    if let Some(usage) = object.get("usage").and_then(Value::as_object) {
        if has_valid_image_usage_receipt(usage) {
            return Ok(Value::Object(usage.clone()));
        }
        if strict {
            return Err(invalid_upstream_body_error(
                status.max(502),
                object.clone(),
                "Google Images response contains invalid `usage`",
            ));
        }
    }
    if let Some(meta) = object.get("usageMetadata").and_then(Value::as_object) {
        if strict && !has_valid_image_usage_receipt(meta) {
            return Err(invalid_upstream_body_error(
                status.max(502),
                object.clone(),
                "Google Images response contains empty or invalid `usageMetadata`",
            ));
        }
        let prompt_tokens = meta
            .get("promptTokenCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let completion_tokens = meta
            .get("candidatesTokenCount")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let sum = prompt_tokens
            .checked_add(completion_tokens)
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status.max(502),
                    object.clone(),
                    "Google Images usage token sum overflowed u64",
                )
            })?;
        let total_tokens = match meta.get("totalTokenCount").and_then(Value::as_u64) {
            Some(total) if total >= sum => total,
            Some(_) => {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    object.clone(),
                    "Google Images totalTokenCount is smaller than prompt + completion tokens",
                ));
            }
            None => sum,
        };
        return Ok(json!({
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total_tokens,
            "images": image_count
        }));
    }
    if strict
        && object
            .get("predictions")
            .and_then(Value::as_array)
            .is_some_and(|predictions| !predictions.is_empty())
    {
        // Imagen bills per generated image and returns no token usage.
        return Ok(json!({ "images": image_count }));
    }
    if strict {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object.clone(),
            "Google Images response is missing `usage` or `usageMetadata`",
        ));
    }
    Ok(json!({ "images": image_count }))
}
