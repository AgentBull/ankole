#[derive(Debug)]
struct GoogleEmbeddings;

impl ApiProtocol for GoogleEmbeddings {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(build_google_embeddings_body(context))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_google_embeddings_body(context, status, body)
    }
}

fn build_google_embeddings_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_request_object();
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
            body
        }
        input => {
            let mut body = google_embedding_request(&request, input.unwrap_or(&Value::Null));
            body.insert("model".to_string(), json!(model));
            body
        }
    }
}

fn google_embedding_request(request: &Map<String, Value>, input: &Value) -> Map<String, Value> {
    let mut body = Map::new();
    body.insert("content".to_string(), google_embedding_content(input));

    let mut config = Map::new();
    maybe_put_from(&mut config, request, "taskType");
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

fn normalize_google_embeddings_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    if !(200..300).contains(&status) {
        return Err(provider_body_error(status, body));
    }
    reject_provider_body_error(status, &body)?;

    let object = provider_object_body(status, body, "Google embeddings")?;

    Ok(json!({
        "object": "list",
        "model": context.model,
        "data": normalize_google_embedding_data(&object),
        "usage": {}
    }))
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
