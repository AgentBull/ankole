use super::*;

const KNOWN_GOOGLE_EMBEDDINGS_FIELDS: &[&str] = &[
    "model",
    "input",
    "encoding_format",
    "dimensions",
    "outputDimensionality",
    "output_dimensionality",
    "task",
    "taskType",
    "title",
    "autoTruncate",
    "user",
    "service_tier",
];

#[derive(Debug)]
pub(super) struct GoogleEmbeddings;

impl APIProtocol for GoogleEmbeddings {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_body(context)
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
    strip_non_streaming_flag(&mut request, strict, "google_embeddings")?;
    if strict {
        validate_strict_google_embeddings_request(&request)?;
    }

    let model = google_embedding_model_name(&context.model);

    match request.get("input") {
        Some(Value::Array(items)) if !items.is_empty() && !items.iter().all(Value::is_i64) => {
            let requests = Value::Array(
                items
                    .iter()
                    .map(|item| {
                        let mut entry = google_embedding_request(&request, item);
                        entry.insert("model".to_string(), json!(model));
                        Value::Object(entry)
                    })
                    .collect(),
            );

            let mut body = Map::new();
            body.insert("requests".to_string(), requests);
            Ok(body)
        }
        input => {
            let mut body = google_embedding_request(&request, input.unwrap_or(&Value::Null));
            body.insert("model".to_string(), json!(model));
            Ok(body)
        }
    }
}

pub(crate) fn on_provider_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = provider_object_body(status, body, "Google embeddings")?;
    let mut data = normalize_google_embedding_data(&object);

    if context.policy() == ConversionPolicy::Strict {
        if data.as_array().is_none_or(Vec::is_empty) {
            return Err(invalid_upstream_body_error(
                status.max(502),
                object,
                "Google embeddings response did not contain any embedding vectors",
            ));
        }
        let requested_dims = requested_google_dimensions(&context.resolved_provider_request());
        normalize_and_validate_google_vectors(status, &object, &mut data, requested_dims)?;
    }

    let usage = normalize_google_embedding_usage(&object);
    if context.policy() == ConversionPolicy::Strict && !has_valid_google_embeddings_usage(&usage) {
        return Err(invalid_upstream_body_error(
            status.max(502),
            object,
            "Google embeddings response did not contain valid `usage` or `usageMetadata`",
        ));
    }

    Ok(json!({
        "object": "list",
        "model": context.model,
        "data": data,
        "usage": usage
    }))
}

fn validate_strict_google_embeddings_request(
    request: &Map<String, Value>,
) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_GOOGLE_EMBEDDINGS_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported google_embeddings parameter `{key}` under strict policy"),
            )
            .provider_status(400));
        }
    }

    if let Some(format) = request.get("encoding_format")
        && format.as_str() != Some("float")
    {
        return Err(StreamError::new(
            "unsupported_parameter",
            "api_resolver",
            "google_embeddings only supports `float` encoding_format",
        )
        .provider_status(400));
    }

    match request.get("input") {
        Some(Value::String(text)) if !text.is_empty() => {}
        Some(Value::Array(items)) if !items.is_empty() && valid_google_embeddings_array(items) => {}
        Some(Value::Object(map)) if !map.is_empty() => {}
        _ => {
            return Err(StreamError::new(
                "invalid_embeddings_input",
                "api_resolver",
                "google_embeddings requires a non-empty string, multimodal content object, or batch array `input`",
            )
            .provider_status(400));
        }
    }

    if let Some(dimensions) = request
        .get("outputDimensionality")
        .or_else(|| request.get("output_dimensionality"))
        .or_else(|| request.get("dimensions"))
        && !dimensions.as_u64().is_some_and(|value| value > 0)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "google_embeddings dimensionality must be a positive integer",
        )
        .provider_status(400));
    }

    Ok(())
}

fn google_embedding_request(request: &Map<String, Value>, input: &Value) -> Map<String, Value> {
    let mut body = Map::new();
    body.insert("content".to_string(), google_embedding_content(input));

    let mut config = Map::new();
    if let Some(task_type) = request
        .get("taskType")
        .or_else(|| request.get("task"))
        .cloned()
        .filter(useful_value)
    {
        config.insert("taskType".to_string(), task_type);
    }
    maybe_put_from(&mut config, request, "title");
    maybe_put_from(&mut config, request, "autoTruncate");

    if let Some(dimensions) = request
        .get("outputDimensionality")
        .or_else(|| request.get("output_dimensionality"))
        .or_else(|| request.get("dimensions"))
        .cloned()
        .filter(useful_value)
    {
        config.insert("outputDimensionality".to_string(), dimensions);
    }

    if !config.is_empty() {
        body.insert("embedContentConfig".to_string(), Value::Object(config));
    }

    body
}

fn google_embedding_content(input: &Value) -> Value {
    if let Some(map) = input.as_object() {
        if let Some(parts) = map.get("parts").and_then(Value::as_array) {
            return json!({ "parts": parts.iter().map(google_embedding_part).collect::<Vec<_>>() });
        }

        if let Some(content) = map.get("content") {
            return match content {
                Value::Array(parts) => {
                    json!({ "parts": parts.iter().map(google_embedding_part).collect::<Vec<_>>() })
                }
                Value::Object(content_map) if content_map.get("parts").is_some() => {
                    google_embedding_content(content)
                }
                value => json!({ "parts": [{ "text": value_to_text(value) }] }),
            };
        }

        if let Some(text) = map.get("text") {
            return json!({ "parts": [{ "text": value_to_text(text) }] });
        }
    }

    json!({ "parts": [{ "text": value_to_text(input) }] })
}

fn google_embedding_part(part: &Value) -> Value {
    let Some(map) = part.as_object() else {
        return json!({ "text": value_to_text(part) });
    };

    if map.get("text").is_some() {
        return json!({ "text": map.get("text").map(value_to_text).unwrap_or_default() });
    }

    if let Some(inline_data) = map.get("inline_data").or_else(|| map.get("inlineData")) {
        return json!({ "inline_data": inline_data });
    }

    if let Some(file_data) = map.get("file_data").or_else(|| map.get("fileData")) {
        return json!({ "file_data": file_data });
    }

    match map.get("type").and_then(Value::as_str) {
        Some("input_text" | "output_text" | "text") => {
            json!({ "text": map.get("text").map(value_to_text).unwrap_or_default() })
        }
        _type => json!({ "text": value_to_text(part) }),
    }
}

fn google_embedding_model_name(model: &str) -> String {
    if model.starts_with("models/") {
        model.to_string()
    } else {
        format!("models/{model}")
    }
}

fn normalize_google_embedding_data(body: &Value) -> Value {
    if let Some(embedding) = body.get("embedding") {
        return Value::Array(vec![google_embedding_item(0, embedding)]);
    }

    if let Some(embeddings) = body.get("embeddings").and_then(Value::as_array) {
        return Value::Array(
            embeddings
                .iter()
                .enumerate()
                .map(|(index, embedding)| google_embedding_item(index, embedding))
                .collect(),
        );
    }

    json!([])
}

fn google_embedding_item(index: usize, embedding: &Value) -> Value {
    let values = embedding
        .get("values")
        .or_else(|| embedding.get("value"))
        .cloned()
        .unwrap_or_else(|| embedding.clone());

    json!({
        "object": "embedding",
        "embedding": values,
        "index": index
    })
}

fn requested_google_dimensions(request: &Value) -> Option<usize> {
    request
        .get("outputDimensionality")
        .or_else(|| request.get("output_dimensionality"))
        .or_else(|| request.get("dimensions"))
        .and_then(Value::as_u64)
        .and_then(|v| usize::try_from(v).ok())
}

fn normalize_and_validate_google_vectors(
    status: u16,
    raw_object: &Value,
    data: &mut Value,
    requested_dims: Option<usize>,
) -> Result<(), StreamError> {
    let Some(items) = data.as_array_mut() else {
        return Ok(());
    };
    for item in items {
        let Some(vec_arr) = item.get("embedding").and_then(Value::as_array) else {
            return Err(invalid_upstream_body_error(
                status.max(502),
                raw_object.clone(),
                "Google embeddings `embedding` must be a numeric float array",
            ));
        };
        if vec_arr.is_empty() {
            return Err(invalid_upstream_body_error(
                status.max(502),
                raw_object.clone(),
                "Google embeddings `embedding` vector must not be empty",
            ));
        }
        let mut floats = Vec::with_capacity(vec_arr.len());
        for val in vec_arr {
            let Some(num) = val.as_f64().filter(|n| n.is_finite()) else {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    raw_object.clone(),
                    "Google embeddings vector contains non-finite number",
                ));
            };
            floats.push(num);
        }
        if requested_dims.is_some() {
            let norm_sq: f64 = floats.iter().map(|v| v * v).sum();
            let norm = norm_sq.sqrt();
            if !norm.is_finite() || norm <= f64::EPSILON {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    raw_object.clone(),
                    "Google embeddings sub-dimension vector has zero or non-finite L2 norm",
                ));
            }
            let normalized: Vec<Value> = floats.into_iter().map(|v| json!(v / norm)).collect();
            if let Some(map) = item.as_object_mut() {
                map.insert("embedding".to_string(), Value::Array(normalized));
            }
        }
    }
    Ok(())
}

fn valid_google_embeddings_array(items: &[Value]) -> bool {
    items.iter().all(|item| match item {
        Value::String(text) => !text.is_empty(),
        Value::Object(map) => !map.is_empty(),
        _ => false,
    })
}

fn has_valid_google_embeddings_usage(usage: &Value) -> bool {
    has_valid_embeddings_usage(usage)
        || usage
            .as_object()
            .and_then(|map| map.get("billable_characters"))
            .is_some_and(|v| v.as_u64().is_some())
}

fn normalize_google_embedding_usage(body: &Value) -> Value {
    if let Some(usage) = body.get("usage").filter(|value| value.is_object()) {
        return usage.clone();
    }

    if let Some(metadata) = body.get("usageMetadata").and_then(Value::as_object) {
        let mut has_valid = false;
        for key in [
            "promptTokenCount",
            "billableCharacterCount",
            "totalTokenCount",
        ] {
            if let Some(val) = metadata.get(key) {
                if val.as_u64().is_some() {
                    has_valid = true;
                } else {
                    return json!({});
                }
            }
        }
        if !has_valid {
            return json!({});
        }
        let prompt_tokens = metadata.get("promptTokenCount").and_then(Value::as_u64);
        let total_tokens = metadata
            .get("totalTokenCount")
            .and_then(Value::as_u64)
            .or(prompt_tokens);
        let billable_chars = metadata
            .get("billableCharacterCount")
            .and_then(Value::as_u64);

        let mut usage = Map::new();
        if let Some(prompt) = prompt_tokens {
            usage.insert("prompt_tokens".to_string(), json!(prompt));
        }
        if let Some(total) = total_tokens {
            usage.insert("total_tokens".to_string(), json!(total));
        }
        if let Some(chars) = billable_chars {
            usage.insert("billable_characters".to_string(), json!(chars));
        }
        return Value::Object(usage);
    }

    json!({})
}
