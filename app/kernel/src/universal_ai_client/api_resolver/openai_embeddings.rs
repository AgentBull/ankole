use super::*;

const KNOWN_OPENAI_EMBEDDINGS_FIELDS: &[&str] = &[
    "model",
    "input",
    "encoding_format",
    "dimensions",
    "user",
    "task",
    "service_tier",
];

#[derive(Debug)]
pub(super) struct OpenAIEmbeddings;

impl APIProtocol for OpenAIEmbeddings {
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
    // Embeddings never stream; the context flag is not a provider parameter.
    request.remove("stream");
    if context.policy() == ConversionPolicy::Strict {
        validate_strict_openai_embeddings_request(&request)?;
    }

    let mut body = Map::new();
    if let Some(model) = request.remove("model") {
        body.insert("model".to_string(), model);
    } else if context.include_model && !context.model.is_empty() {
        body.insert("model".to_string(), json!(context.model));
    }

    if let Some(input) = request.remove("input") {
        body.insert("input".to_string(), input);
    }
    if let Some(encoding_format) = request.remove("encoding_format").filter(useful_value) {
        body.insert("encoding_format".to_string(), encoding_format);
    }
    if let Some(dimensions) = request.remove("dimensions").filter(useful_value) {
        body.insert("dimensions".to_string(), dimensions);
    }
    if let Some(user) = request.remove("user").filter(useful_value) {
        body.insert("user".to_string(), user);
    }
    if let Some(task) = request.remove("task").filter(useful_value) {
        body.insert("task".to_string(), task);
    }

    for (key, value) in request {
        body.insert(key, value);
    }

    Ok(body)
}

pub(crate) fn on_provider_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let mut object = provider_object_body(status, body, "OpenAI embeddings")?
        .as_object()
        .cloned()
        .unwrap_or_default();

    if context.policy() == ConversionPolicy::Strict {
        validate_strict_embeddings_response(status, &mut object, context, "OpenAI embeddings")?;
    }

    put_default(&mut object, "object", json!("list"));
    put_default(&mut object, "model", json!(context.model));

    let data = match object.get("data").and_then(Value::as_array) {
        Some(items) => Value::Array(
            items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    let Some(map) = item.as_object() else {
                        return json!({
                            "object": "embedding",
                            "embedding": item,
                            "index": index
                        });
                    };
                    let mut normalized = map.clone();
                    put_default(&mut normalized, "object", json!("embedding"));
                    put_default(&mut normalized, "index", json!(index));
                    Value::Object(normalized)
                })
                .collect(),
        ),
        None => json!([]),
    };
    object.insert("data".to_string(), data);
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

fn validate_strict_openai_embeddings_request(
    request: &Map<String, Value>,
) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_OPENAI_EMBEDDINGS_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported openai_embeddings parameter `{key}` under strict policy"),
            )
            .provider_status(400));
        }
    }

    match request.get("input") {
        Some(Value::String(text)) if !text.is_empty() => {}
        Some(Value::Array(items)) if !items.is_empty() && valid_openai_embedding_inputs(items) => {}
        _ => {
            return Err(StreamError::new(
                "invalid_embeddings_input",
                "api_resolver",
                "openai_embeddings requires a non-empty string, string array, or token array `input`",
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
                    "openai_embeddings `encoding_format` must be `float` or `base64`",
                )
                .provider_status(400));
            }
        }
    }

    if let Some(dimensions) = request.get("dimensions")
        && !dimensions.as_u64().is_some_and(|value| value > 0)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "openai_embeddings `dimensions` must be a positive integer",
        )
        .provider_status(400));
    }

    Ok(())
}

fn valid_openai_embedding_inputs(items: &[Value]) -> bool {
    items.iter().all(|item| match item {
        Value::String(text) => !text.is_empty(),
        Value::Number(num) => num.is_i64() || num.is_u64(),
        Value::Array(tokens) => {
            !tokens.is_empty() && tokens.iter().all(|tok| tok.is_i64() || tok.is_u64())
        }
        _ => false,
    })
}
