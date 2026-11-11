use super::*;

const KNOWN_OPENROUTER_IMAGES_FIELDS: &[&str] = &[
    "model",
    "prompt",
    "messages",
    "n",
    "size",
    "aspect_ratio",
    "aspectRatio",
    "quality",
    "background",
    "output_format",
    "output_compression",
    "response_format",
    "moderation",
    "user",
    "stream",
    "partial_images",
    "input_fidelity",
    "input_references",
    "input_image_mask",
    "image",
    "images",
    "mask",
    "service_tier",
    "provider",
];

#[derive(Debug)]
pub(super) struct OpenrouterImages;

impl APIProtocol for OpenrouterImages {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_body(context)
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        normalize_image_stream_event(context, event, "OpenRouter Images")
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let enforce_count = context.policy() == ConversionPolicy::Strict;
        normalize_openai_compatible_image_response(
            context,
            status,
            body,
            enforce_count,
            "OpenRouter Images",
        )
    }
}

pub(crate) fn build_body(context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
    let mut request = context.resolved_provider_request_object();
    let strict = context.policy() == ConversionPolicy::Strict;
    if strict {
        validate_strict_openrouter_images_request(&request)?;
    }

    let had_input_references = request
        .get("input_references")
        .is_some_and(|v| !v.is_null())
        && request.get("images").is_none_or(Value::is_null)
        && request.get("image").is_none_or(Value::is_null);
    let had_input_image_mask = request
        .get("input_image_mask")
        .is_some_and(|v| !v.is_null())
        && request.get("mask").is_none_or(Value::is_null);
    let normalized_refs = resolve_normalized_image_references(&request, strict)?;
    let normalized_mask = resolve_normalized_image_mask(&request, strict)?;

    request.remove("images");
    request.remove("image");
    if let Some(mapped) = normalized_refs {
        if strict && mapped.len() > 16 {
            return Err(StreamError::new(
                "invalid_parameter",
                "api_resolver",
                "openrouter_images supports at most 16 reference images",
            )
            .provider_status(400));
        }
        if !had_input_references {
            request.insert("input_references".to_string(), Value::Array(mapped));
        }
    }

    request.remove("mask");
    if let Some(mask_url) = normalized_mask
        && !had_input_image_mask
    {
        request.insert("input_image_mask".to_string(), Value::String(mask_url));
    }

    Ok(request)
}

fn validate_strict_openrouter_images_request(
    request: &Map<String, Value>,
) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_OPENROUTER_IMAGES_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported openrouter_images parameter `{key}` under strict policy"),
            )
            .provider_status(400));
        }
    }
    let has_prompt = request
        .get("prompt")
        .and_then(Value::as_str)
        .is_some_and(|p| !p.trim().is_empty());
    let has_messages = request
        .get("messages")
        .and_then(Value::as_array)
        .is_some_and(|m| !m.is_empty());
    if !has_prompt && !has_messages {
        return Err(StreamError::new(
            "invalid_image_prompt",
            "api_resolver",
            "openrouter_images requires a non-empty `prompt` or `messages`",
        )
        .provider_status(400));
    }
    if let Some(n) = request.get("n")
        && !n.as_u64().is_some_and(|count| (1..=10).contains(&count))
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openrouter_images `n` must be between 1 and 10",
        )
        .provider_status(400));
    }
    if let Some(compression) = request.get("output_compression")
        && !compression.as_u64().is_some_and(|val| val <= 100)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openrouter_images `output_compression` must be between 0 and 100",
        )
        .provider_status(400));
    }
    let ref_count = request
        .get("input_references")
        .or_else(|| request.get("images"))
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    if ref_count > 16 {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openrouter_images supports at most 16 reference images",
        )
        .provider_status(400));
    }
    Ok(())
}

pub(super) fn normalize_openai_compatible_image_response(
    context: &ResponseContext,
    status: u16,
    body: Value,
    enforce_count: bool,
    label: &'static str,
) -> Result<Value, StreamError> {
    let object = provider_object_body(status, body, label)?;
    let images = object
        .get("data")
        .and_then(Value::as_array)
        .filter(|items| !items.is_empty())
        .ok_or_else(|| {
            invalid_upstream_body_error(
                status.max(502),
                object.clone(),
                format!("{label} response did not contain a non-empty `data` array"),
            )
        })?;

    let requested_n = requested_image_count(context);
    if enforce_count && images.len() < requested_n {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object.clone(),
            format!(
                "{label} response returned {} images, fewer than requested n={requested_n}",
                images.len()
            ),
        ));
    }

    let default_mime_type = default_image_mime_type(context);
    let strict = context.policy() == ConversionPolicy::Strict;
    let normalized_data =
        normalize_image_data_items(images, status, &object, default_mime_type, strict, label)?;
    let first = &normalized_data[0];
    let created = object
        .get("created")
        .and_then(Value::as_i64)
        .unwrap_or_else(now_seconds);
    let usage_obj = object
        .get("usage")
        .and_then(Value::as_object)
        .or_else(|| object.get("usageMetadata").and_then(Value::as_object));
    if strict && !usage_obj.is_some_and(has_valid_image_usage_receipt) {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object,
            format!("{label} response is missing a valid `usage` receipt"),
        ));
    }
    let usage = usage_obj.map_or_else(|| json!({}), |u| Value::Object(u.clone()));

    Ok(json!({
        "created": created,
        "data": normalized_data,
        "result": first.get("b64_json").cloned().unwrap_or(Value::Null),
        "mime_type": first.get("media_type").cloned().unwrap_or_else(|| json!(default_mime_type)),
        "revised_prompt": first.get("revised_prompt").cloned().unwrap_or(Value::Null),
        "usage": usage
    }))
}

pub(super) fn has_valid_image_usage_receipt(usage: &Map<String, Value>) -> bool {
    const INT_KEYS: &[&str] = &[
        "total_tokens",
        "prompt_tokens",
        "completion_tokens",
        "input_tokens",
        "output_tokens",
        "images",
        "totalTokenCount",
        "promptTokenCount",
        "candidatesTokenCount",
    ];
    let mut found = false;
    for key in INT_KEYS {
        if let Some(val) = usage.get(*key).filter(|v| !v.is_null()) {
            if val.as_u64().is_none() {
                return false;
            }
            found = true;
        }
    }
    if let Some(cost) = usage.get("cost").filter(|v| !v.is_null()) {
        if !cost.as_f64().is_some_and(|c| c.is_finite() && c >= 0.0) {
            return false;
        }
        found = true;
    }
    let prompt = usage
        .get("prompt_tokens")
        .or_else(|| usage.get("input_tokens"))
        .or_else(|| usage.get("promptTokenCount"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let completion = usage
        .get("completion_tokens")
        .or_else(|| usage.get("output_tokens"))
        .or_else(|| usage.get("candidatesTokenCount"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let Some(sum) = prompt.checked_add(completion) else {
        return false;
    };
    if let Some(total) = usage
        .get("total_tokens")
        .or_else(|| usage.get("totalTokenCount"))
        .and_then(Value::as_u64)
        && total < sum
    {
        return false;
    }
    found
}

fn normalize_image_data_items(
    images: &[Value],
    status: u16,
    object: &Value,
    default_mime_type: &str,
    strict: bool,
    label: &'static str,
) -> Result<Vec<Value>, StreamError> {
    let mut normalized_data = Vec::with_capacity(images.len());
    for item in images {
        let image = item.as_object().ok_or_else(|| {
            invalid_upstream_body_error(
                status.max(502),
                object.clone(),
                format!("{label} response `data` item must be an object"),
            )
        })?;
        let b64_json = image
            .get("b64_json")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status.max(502),
                    object.clone(),
                    format!("{label} response item did not contain `b64_json` bytes"),
                )
            })?;
        if strict && base64_simd::STANDARD.check(b64_json.as_bytes()).is_err() {
            return Err(invalid_upstream_body_error(
                status.max(502),
                object.clone(),
                format!("{label} response `b64_json` is not valid Base64"),
            ));
        }
        let media_type = resolve_image_media_type(image, default_mime_type);
        let revised_prompt = image
            .get("revised_prompt")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty());

        normalized_data.push(json!({
            "b64_json": b64_json,
            "media_type": media_type,
            "revised_prompt": revised_prompt
        }));
    }
    Ok(normalized_data)
}

pub(super) fn requested_image_count(context: &ResponseContext) -> usize {
    context
        .resolved_provider_request_object()
        .get("n")
        .and_then(Value::as_u64)
        .unwrap_or(1)
        .max(1) as usize
}

pub(super) fn output_format_to_mime(format: &str) -> &'static str {
    match format.trim().to_ascii_lowercase().as_str() {
        "jpeg" | "jpg" | "image/jpeg" | "image/jpg" => "image/jpeg",
        "webp" | "image/webp" => "image/webp",
        _ => "image/png",
    }
}

fn resolve_image_media_type<'a>(
    map: &'a Map<String, Value>,
    default_mime_type: &'a str,
) -> &'a str {
    if let Some(mime) = map
        .get("media_type")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| {
            map.get("mime_type")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        })
    {
        if mime.contains('/') {
            return mime;
        }
        return output_format_to_mime(mime);
    }
    if let Some(fmt) = map
        .get("output_format")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    {
        return output_format_to_mime(fmt);
    }
    default_mime_type
}

pub(super) fn default_image_mime_type(context: &ResponseContext) -> &'static str {
    context
        .resolved_provider_request_object()
        .get("output_format")
        .and_then(Value::as_str)
        .map_or("image/png", output_format_to_mime)
}

pub(super) fn normalize_image_stream_event(
    context: &ResponseContext,
    event: Value,
    label: &'static str,
) -> Result<Vec<Value>, StreamError> {
    let Some(map) = event.as_object() else {
        return Err(invalid_upstream_body_error(
            502,
            event,
            format!("{label} stream event must be a JSON object"),
        ));
    };
    match map.get("type").and_then(Value::as_str) {
        Some("image_generation.partial_image" | "image_edit.partial_image") => {
            normalize_partial_image_event(context, map, &event, label)
        }
        Some("image_generation.completed" | "image_edit.completed") => {
            normalize_completed_image_event(context, map, &event, label)
        }
        Some("image_generation.text_chunk") => Ok(vec![event]),
        Some("error") => {
            let err_obj = map.get("error").unwrap_or(&event);
            let message = err_obj
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Upstream image stream returned an error");
            let code = err_obj
                .get("code")
                .and_then(Value::as_str)
                .unwrap_or("image_generation_failed");
            Err(StreamError::new(code, "api_resolver", message).provider_status(502))
        }
        _ => Ok(vec![event]),
    }
}

fn normalize_partial_image_event(
    context: &ResponseContext,
    map: &Map<String, Value>,
    event: &Value,
    label: &'static str,
) -> Result<Vec<Value>, StreamError> {
    let b64_json = map
        .get("b64_json")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| {
            invalid_upstream_body_error(
                502,
                event.clone(),
                format!("{label} partial_image event is missing `b64_json`"),
            )
        })?;
    if context.policy() == ConversionPolicy::Strict
        && base64_simd::STANDARD.check(b64_json.as_bytes()).is_err()
    {
        return Err(invalid_upstream_body_error(
            502,
            event.clone(),
            format!("{label} partial_image `b64_json` is not valid Base64"),
        ));
    }
    let index = map
        .get("partial_image_index")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let default_mime = default_image_mime_type(context);
    let media_type = resolve_image_media_type(map, default_mime);
    Ok(vec![json!({
        "type": "image_generation.partial_image",
        "partial_image_index": index,
        "b64_json": b64_json,
        "media_type": media_type
    })])
}

fn normalize_completed_image_event(
    context: &ResponseContext,
    map: &Map<String, Value>,
    event: &Value,
    label: &'static str,
) -> Result<Vec<Value>, StreamError> {
    let strict = context.policy() == ConversionPolicy::Strict;
    let b64_opt = map
        .get("b64_json")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty());
    let url_opt = map
        .get("url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|v| !v.is_empty());
    if b64_opt.is_none() && url_opt.is_none() {
        return Err(invalid_upstream_body_error(
            502,
            event.clone(),
            format!("{label} completed event is missing `b64_json` or `url`"),
        ));
    }
    if strict
        && let Some(b64) = b64_opt
        && base64_simd::STANDARD.check(b64.as_bytes()).is_err()
    {
        return Err(invalid_upstream_body_error(
            502,
            event.clone(),
            format!("{label} completed `b64_json` is not valid Base64"),
        ));
    }
    if strict
        && !map
            .get("usage")
            .and_then(Value::as_object)
            .is_some_and(has_valid_image_usage_receipt)
    {
        return Err(invalid_upstream_body_error(
            502,
            event.clone(),
            format!("{label} completed event is missing non-empty `usage`"),
        ));
    }
    let default_mime = default_image_mime_type(context);
    let media_type = resolve_image_media_type(map, default_mime);
    let mut normalized = json!({
        "type": "image_generation.completed",
        "b64_json": b64_opt.map_or(Value::Null, |value| json!(value)),
        "media_type": media_type,
        "revised_prompt": map.get("revised_prompt").cloned().unwrap_or(Value::Null),
        "usage": map.get("usage").cloned().unwrap_or_else(|| json!({}))
    });
    if let Some(url) = url_opt {
        normalized["url"] = json!(url);
    }
    Ok(vec![normalized])
}
