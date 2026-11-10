use super::*;

const KNOWN_OPENAI_IMAGES_FIELDS: &[&str] = &[
    "model",
    "prompt",
    "n",
    "size",
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
];

#[derive(Debug)]
pub(super) struct OpenAIImages;

impl APIProtocol for OpenAIImages {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_body(context)
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        normalize_image_stream_event(context, event, "OpenAI Images")
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
    let mut request = context.resolved_provider_request_object();
    let strict = context.policy() == ConversionPolicy::Strict;
    if strict {
        validate_strict_openai_images_request(&request)?;
    }

    let had_only_single_image = request.get("image").is_some_and(|v| !v.is_null())
        && request.get("images").is_none_or(Value::is_null)
        && request.get("input_references").is_none_or(Value::is_null);
    let normalized_refs = resolve_normalized_image_references(&request, strict)?;
    let normalized_mask = resolve_normalized_image_mask(&request, strict)?;

    request.remove("input_references");
    if let Some(mapped) = normalized_refs
        && !had_only_single_image
    {
        request.remove("image");
        request.insert(
            "images".to_string(),
            Value::Array(
                mapped
                    .into_iter()
                    .map(|url| json!({ "image_url": url }))
                    .collect(),
            ),
        );
    }

    request.remove("input_image_mask");
    if let Some(mask_url) = normalized_mask {
        request.insert("mask".to_string(), json!({ "image_url": mask_url }));
    }

    Ok(request)
}

pub(crate) fn on_provider_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    normalize_openai_compatible_image_response(context, status, body, true, "OpenAI Images")
}

fn validate_strict_openai_images_request(request: &Map<String, Value>) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_OPENAI_IMAGES_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported openai_images parameter `{key}` under strict policy"),
            )
            .provider_status(400));
        }
    }

    if !request
        .get("prompt")
        .and_then(Value::as_str)
        .is_some_and(|prompt| !prompt.trim().is_empty())
    {
        return Err(StreamError::new(
            "invalid_image_prompt",
            "api_resolver",
            "openai_images requires a non-empty `prompt`",
        )
        .provider_status(400));
    }

    if let Some(n) = request.get("n")
        && !n.as_u64().is_some_and(|count| (1..=10).contains(&count))
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openai_images `n` must be an integer between 1 and 10",
        )
        .provider_status(400));
    }

    if let Some(compression) = request.get("output_compression")
        && !compression.as_u64().is_some_and(|val| val <= 100)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openai_images `output_compression` must be between 0 and 100",
        )
        .provider_status(400));
    }

    Ok(())
}

pub(super) fn extract_reference_image_url(value: &Value) -> Option<String> {
    match value {
        Value::String(text) if !text.trim().is_empty() => Some(text.trim().to_string()),
        Value::Object(map) => map
            .get("image_url")
            .and_then(|url| {
                url.as_str()
                    .or_else(|| url.get("url").and_then(Value::as_str))
            })
            .or_else(|| map.get("url").and_then(Value::as_str))
            .or_else(|| map.get("b64_json").and_then(Value::as_str))
            .map(str::trim)
            .filter(|text| !text.is_empty())
            .map(ToOwned::to_owned),
        _ => None,
    }
}

pub(super) fn resolve_normalized_image_references(
    request: &Map<String, Value>,
    strict: bool,
) -> Result<Option<Vec<Value>>, StreamError> {
    let mut active: Option<Vec<String>> = None;
    for key in ["input_references", "images"] {
        let Some(val) = request.get(key).filter(|v| !v.is_null()) else {
            continue;
        };
        let list = match val.as_array() {
            Some(items) => {
                let parsed: Option<Vec<String>> =
                    items.iter().map(extract_reference_image_url).collect();
                match parsed.filter(|l| !l.is_empty()) {
                    Some(valid) => valid,
                    None if strict => {
                        return Err(StreamError::new(
                            "invalid_image_reference",
                            "api_resolver",
                            format!("`{key}` must be a non-empty array of valid image references"),
                        )
                        .provider_status(400));
                    }
                    None => items
                        .iter()
                        .filter_map(extract_reference_image_url)
                        .collect(),
                }
            }
            None if strict => {
                return Err(StreamError::new(
                    "invalid_image_reference",
                    "api_resolver",
                    format!("`{key}` must be an array under strict policy"),
                )
                .provider_status(400));
            }
            None => extract_reference_image_url(val).into_iter().collect(),
        };
        if let Some(ref prev) = active
            && prev != &list
        {
            if strict {
                return Err(StreamError::new(
                    "invalid_image_reference",
                    "api_resolver",
                    "conflicting image reference fields `input_references` and `images`",
                )
                .provider_status(400));
            }
            continue;
        }
        if !list.is_empty() {
            active = Some(list);
        }
    }
    if let Some(val) = request.get("image").filter(|v| !v.is_null()) {
        match extract_reference_image_url(val) {
            Some(single) => {
                let list = vec![single];
                if let Some(ref prev) = active
                    && prev != &list
                    && strict
                {
                    return Err(StreamError::new(
                        "invalid_image_reference",
                        "api_resolver",
                        "conflicting `image` and `input_references`/`images`",
                    )
                    .provider_status(400));
                }
                if active.is_none() {
                    active = Some(list);
                }
            }
            None if strict => {
                return Err(StreamError::new(
                    "invalid_image_reference",
                    "api_resolver",
                    "invalid `image` reference",
                )
                .provider_status(400));
            }
            None => {}
        }
    }
    Ok(active.map(|list| list.into_iter().map(Value::String).collect()))
}

pub(super) fn resolve_normalized_image_mask(
    request: &Map<String, Value>,
    strict: bool,
) -> Result<Option<String>, StreamError> {
    let mut active: Option<String> = None;
    for key in ["input_image_mask", "mask"] {
        let Some(val) = request.get(key).filter(|v| !v.is_null()) else {
            continue;
        };
        match extract_reference_image_url(val) {
            Some(url) => {
                if let Some(ref prev) = active
                    && prev != &url
                    && strict
                {
                    return Err(StreamError::new(
                        "invalid_image_mask",
                        "api_resolver",
                        "conflicting `mask` and `input_image_mask`",
                    )
                    .provider_status(400));
                }
                if active.is_none() {
                    active = Some(url);
                }
            }
            None if strict => {
                return Err(StreamError::new(
                    "invalid_image_mask",
                    "api_resolver",
                    format!("invalid `{key}` field"),
                )
                .provider_status(400));
            }
            None => {}
        }
    }
    Ok(active)
}
