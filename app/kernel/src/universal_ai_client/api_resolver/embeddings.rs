use super::*;

const KNOWN_EMBEDDINGS_FIELDS: &[&str] = &[
    "model",
    "input",
    "encoding_format",
    "dimensions",
    "user",
    "task",
    "input_type",
    "normalized",
    "embedding_type",
    "late_chunking",
    "truncate",
    "provider",
    "service_tier",
];

#[derive(Debug)]
pub(super) struct OpenrouterEmbeddings;

#[derive(Debug)]
pub(super) struct JinaEmbeddings;

impl APIProtocol for OpenrouterEmbeddings {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_embeddings_body(context)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_embeddings_body(context, status, body)
    }
}

impl APIProtocol for JinaEmbeddings {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_embeddings_body(context)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_jina_embeddings_body(context, status, body)
    }
}

pub(crate) fn build_embeddings_body(
    context: &ResponseContext,
) -> Result<Map<String, Value>, StreamError> {
    let mut request = context.resolved_provider_request_object();
    // Embeddings never stream; the context flag is not a provider parameter.
    request.remove("stream");
    if context.policy() == ConversionPolicy::Strict {
        validate_strict_embeddings_request(&request)?;
    }
    if let Some(task) = request.get("task").and_then(Value::as_str)
        && !task.is_empty()
        && !request.contains_key("input_type")
    {
        request.insert("task".to_string(), Value::String(task.to_string()));
    }
    Ok(request)
}

pub(crate) fn normalize_embeddings_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    normalize_openrouter_embeddings_body(context, status, body)
}

pub(super) fn validate_strict_embeddings_request(
    request: &Map<String, Value>,
) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_EMBEDDINGS_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported embeddings parameter `{key}` under strict conversion policy"),
            )
            .provider_status(400));
        }
    }

    match request.get("input") {
        Some(Value::String(text)) if !text.is_empty() => {}
        Some(Value::Array(items)) if !items.is_empty() && valid_embeddings_array(items) => {}
        Some(Value::Object(map)) if !map.is_empty() => {}
        _ => {
            return Err(StreamError::new(
                "invalid_embeddings_input",
                "api_resolver",
                "embeddings request requires a non-empty `input` string, token list, or batch array",
            )
            .provider_status(400));
        }
    }

    if let Some(format) = request.get("encoding_format") {
        match format.as_str() {
            Some("float" | "base64") => {}
            _ => {
                return Err(StreamError::new(
                    "unsupported_parameter",
                    "api_resolver",
                    "embeddings `encoding_format` must be `float` or `base64`",
                )
                .provider_status(400));
            }
        }
    }

    if let Some(dimensions) = request.get("dimensions") {
        let valid = dimensions.as_u64().is_some_and(|value| value > 0);
        if !valid {
            return Err(StreamError::new(
                "invalid_parameter",
                "api_resolver",
                "embeddings `dimensions` must be a positive integer",
            )
            .provider_status(400));
        }
    }

    Ok(())
}

pub(super) fn valid_embeddings_array(items: &[Value]) -> bool {
    items.iter().all(|item| match item {
        Value::String(text) => !text.is_empty(),
        Value::Number(num) => num.is_i64() || num.is_u64(),
        Value::Array(tokens) => {
            !tokens.is_empty() && tokens.iter().all(|tok| tok.is_i64() || tok.is_u64())
        }
        Value::Object(map) => !map.is_empty(),
        _ => false,
    })
}

fn normalize_openrouter_embeddings_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    normalize_embedding_body(
        context,
        status,
        body,
        "OpenRouter embeddings",
        normalize_openrouter_embedding_data,
    )
}

fn normalize_jina_embeddings_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    normalize_embedding_body(
        context,
        status,
        body,
        "Jina embeddings",
        normalize_jina_embedding_data,
    )
}

fn normalize_embedding_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
    label: &'static str,
    normalize_data: fn(&Value) -> Value,
) -> Result<Value, StreamError> {
    let mut object = provider_object_body(status, body, label)?
        .as_object()
        .cloned()
        .unwrap_or_default();

    if context.policy() == ConversionPolicy::Strict {
        validate_strict_embeddings_response(status, &mut object, context, label)?;
    }

    put_default(&mut object, "object", json!("list"));
    put_default(&mut object, "model", json!(context.model));
    object.insert(
        "data".to_string(),
        normalize_data(object.get("data").unwrap_or(&Value::Null)),
    );
    object.insert(
        "usage".to_string(),
        object
            .get("usage")
            .filter(|value| value.is_object())
            .cloned()
            .unwrap_or_else(|| json!({})),
    );
    Ok(Value::Object(object))
}

pub(super) fn has_valid_embeddings_usage(usage: &Value) -> bool {
    let Some(map) = usage.as_object() else {
        return false;
    };
    let mut found = false;
    for key in ["total_tokens", "prompt_tokens", "input_tokens"] {
        if let Some(val) = map.get(key) {
            if val.as_u64().is_some() {
                found = true
            } else {
                return false;
            }
        }
    }
    found
}

pub(super) fn validate_strict_embeddings_response(
    status: u16,
    object: &mut Map<String, Value>,
    context: &ResponseContext,
    label: &'static str,
) -> Result<(), StreamError> {
    let req = context.resolved_provider_request();
    let expected_format = req
        .get("encoding_format")
        .and_then(Value::as_str)
        .or_else(|| req.get("embedding_type").and_then(Value::as_str))
        .or_else(|| object.get("embedding_type").and_then(Value::as_str))
        .unwrap_or("float")
        .to_string();

    if !object.get("usage").is_some_and(has_valid_embeddings_usage) {
        return Err(invalid_upstream_body_error(
            status.max(502),
            Value::Object(object.clone()),
            format!("{label} response is missing valid numeric `usage`"),
        ));
    }

    let snapshot = Value::Object(object.clone());
    let Some(data) = object.get_mut("data").and_then(Value::as_array_mut) else {
        return Err(invalid_upstream_body_error(
            status.max(502),
            snapshot,
            format!("{label} response is missing the `data` vector array"),
        ));
    };
    if data.is_empty() {
        return Err(invalid_upstream_body_error(
            status.max(502),
            snapshot,
            format!("{label} response returned an empty `data` vector array"),
        ));
    }
    for item in data.iter_mut() {
        let Some(map) = item.as_object_mut() else {
            return Err(invalid_upstream_body_error(
                status.max(502),
                snapshot,
                format!("{label} response `data` item must be an object"),
            ));
        };
        if !map.get("index").is_some_and(Value::is_u64) {
            return Err(invalid_upstream_body_error(
                status.max(502),
                snapshot,
                format!("{label} response `data` item is missing a non-negative integer `index`"),
            ));
        }
        validate_and_coerce_embedding_item(status, &snapshot, map, &expected_format, label)?;
    }
    Ok(())
}

fn validate_and_coerce_embedding_item(
    status: u16,
    snapshot: &Value,
    map: &mut Map<String, Value>,
    expected_format: &str,
    label: &'static str,
) -> Result<(), StreamError> {
    if let Some(emb) = map.get("embedding").cloned() {
        let coerced = coerce_embedding_value(status, snapshot, &emb, expected_format, label)?;
        map.insert("embedding".to_string(), coerced);
        return Ok(());
    }
    if let Some(embs) = map.get("embeddings").and_then(Value::as_array) {
        if embs.is_empty() {
            return Err(invalid_upstream_body_error(
                status.max(502),
                snapshot.clone(),
                format!("{label} response `embeddings` array must not be empty"),
            ));
        }
        return Ok(());
    }
    Err(invalid_upstream_body_error(
        status.max(502),
        snapshot.clone(),
        format!("{label} response `data` item is missing `embedding`"),
    ))
}

fn coerce_embedding_value(
    status: u16,
    snapshot: &Value,
    emb: &Value,
    expected_format: &str,
    label: &'static str,
) -> Result<Value, StreamError> {
    match (expected_format, emb) {
        ("base64", Value::Array(arr)) => {
            let floats = extract_finite_f32_vec(status, snapshot, arr, label)?;
            let mut bytes = Vec::with_capacity(floats.len() * 4);
            for f in floats {
                bytes.extend_from_slice(&f.to_le_bytes());
            }
            Ok(Value::String(
                base64_simd::STANDARD.encode_to_string(&bytes),
            ))
        }
        ("base64", Value::String(b64)) => {
            let decoded = base64_simd::STANDARD
                .decode_to_vec(b64.trim())
                .map_err(|_| {
                    invalid_upstream_body_error(
                        status.max(502),
                        snapshot.clone(),
                        format!("{label} base64 embedding is not valid Base64"),
                    )
                })?;
            if decoded.is_empty() || decoded.len() % 4 != 0 {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    snapshot.clone(),
                    format!("{label} base64 embedding length mismatch"),
                ));
            }
            if !decoded
                .as_chunks::<4>()
                .0
                .iter()
                .all(|c| f32::from_le_bytes(*c).is_finite())
            {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    snapshot.clone(),
                    format!("{label} base64 embedding contains non-finite float"),
                ));
            }
            Ok(Value::String(b64.clone()))
        }
        ("float", Value::Array(arr)) => {
            let _ = extract_finite_f32_vec(status, snapshot, arr, label)?;
            Ok(emb.clone())
        }
        ("float", Value::Object(obj)) if !obj.is_empty() => Ok(emb.clone()),
        _ => Err(invalid_upstream_body_error(
            status.max(502),
            snapshot.clone(),
            format!("{label} embedding format does not match requested `{expected_format}`"),
        )),
    }
}

fn extract_finite_f32_vec(
    status: u16,
    snapshot: &Value,
    arr: &[Value],
    label: &'static str,
) -> Result<Vec<f32>, StreamError> {
    if arr.is_empty() {
        return Err(invalid_upstream_body_error(
            status.max(502),
            snapshot.clone(),
            format!("{label} embedding vector must not be empty"),
        ));
    }
    let mut out = Vec::with_capacity(arr.len());
    for v in arr {
        let Some(f32_val) = v
            .as_f64()
            .filter(|n| n.is_finite())
            .map(|f| f as f32)
            .filter(|f| f.is_finite())
        else {
            return Err(invalid_upstream_body_error(
                status.max(502),
                snapshot.clone(),
                format!("{label} embedding vector contains non-finite number"),
            ));
        };
        out.push(f32_val);
    }
    Ok(out)
}

fn normalize_openrouter_embedding_data(data: &Value) -> Value {
    normalize_embedding_items(data, false)
}

fn normalize_jina_embedding_data(data: &Value) -> Value {
    normalize_embedding_items(data, true)
}

fn normalize_embedding_items(data: &Value, default_object: bool) -> Value {
    let Some(data) = data.as_array() else {
        return json!([]);
    };

    Value::Array(
        data.iter()
            .enumerate()
            .map(|(index, item)| {
                let Some(map) = item.as_object() else {
                    return json!({ "embedding": item, "index": index });
                };

                if map.contains_key("embedding") || map.contains_key("embeddings") {
                    let mut item = map.clone();
                    put_default(&mut item, "index", json!(index));
                    if default_object {
                        put_default(&mut item, "object", json!("embedding"));
                    }
                    Value::Object(item)
                } else {
                    json!({ "embedding": Value::Object(map.clone()), "index": index })
                }
            })
            .collect(),
    )
}
