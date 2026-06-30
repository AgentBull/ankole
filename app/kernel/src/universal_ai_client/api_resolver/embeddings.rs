#[derive(Debug)]
struct OpenaiEmbeddings;

#[derive(Debug)]
struct OpenrouterEmbeddings;

#[derive(Debug)]
struct JinaEmbeddings;

impl ApiProtocol for OpenaiEmbeddings {
    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_openai_embeddings_body(context, status, body)
    }
}

impl ApiProtocol for OpenrouterEmbeddings {
    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_openrouter_embeddings_body(context, status, body)
    }
}

impl ApiProtocol for JinaEmbeddings {
    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_jina_embeddings_body(context, status, body)
    }
}

fn normalize_openai_embeddings_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    normalize_embedding_body(
        context,
        status,
        body,
        "OpenAI embeddings",
        normalize_openai_embedding_data,
    )
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
    if !(200..300).contains(&status) {
        return Err(provider_body_error(status, body));
    }
    reject_provider_body_error(status, &body)?;

    let mut object = provider_object_body(status, body, label)?
        .as_object()
        .cloned()
        .unwrap_or_default();
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

fn normalize_openai_embedding_data(data: &Value) -> Value {
    normalize_embedding_items(data, false)
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
