#[derive(Debug)]
struct OpenrouterRerank;

#[derive(Debug)]
struct JinaRerank;

impl ApiProtocol for OpenrouterRerank {
    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        resolve_rerank_body(context, status, body, "OpenRouter rerank")
    }
}

impl ApiProtocol for JinaRerank {
    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        resolve_rerank_body(context, status, body, "Jina rerank")
    }
}

fn resolve_rerank_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
    label: &'static str,
) -> Result<Value, StreamError> {
    if !(200..300).contains(&status) {
        return Err(provider_body_error(status, body));
    }
    reject_provider_body_error(status, &body)?;

    let mut object = provider_object_body(status, body, label)?
        .as_object()
        .cloned()
        .unwrap_or_default();
    let request = context.resolved_request();
    let documents = request
        .get("documents")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    put_default(&mut object, "id", json!(generated_id("rerank")));
    put_default(&mut object, "model", json!(context.model));
    object.insert(
        "results".to_string(),
        normalize_rerank_results(object.get("results").unwrap_or(&Value::Null), &documents),
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

fn normalize_rerank_results(results: &Value, documents: &[Value]) -> Value {
    let Some(results) = results.as_array() else {
        return json!([]);
    };

    Value::Array(
        results
            .iter()
            .enumerate()
            .map(|(fallback_index, result)| {
                let Some(map) = result.as_object() else {
                    return json!({
                        "document": normalize_rerank_document(documents.get(fallback_index).unwrap_or(&Value::Null)),
                        "index": fallback_index,
                        "relevance_score": 0.0
                    });
                };

                let index = integer_value(map.get("index").unwrap_or(&Value::Null))
                    .map(|value| value.max(0) as usize)
                    .unwrap_or(fallback_index);
                let document = rerank_result_document(map)
                    .filter(|document| !document.is_null())
                    .unwrap_or_else(|| documents.get(index).cloned().unwrap_or(Value::Null));
                let score = map
                    .get("relevance_score")
                    .or_else(|| map.get("score"))
                    .cloned()
                    .unwrap_or_else(|| json!(0.0));
                let mut normalized = map.clone();
                normalized.remove("text");
                normalized.remove("image");
                normalized.remove("score");
                normalized.insert(
                    "document".to_string(),
                    normalize_rerank_document(&document),
                );
                normalized.insert("index".to_string(), json!(index));
                put_default(&mut normalized, "relevance_score", score);
                Value::Object(normalized)
            })
            .collect(),
    )
}

fn rerank_result_document(map: &Map<String, Value>) -> Option<Value> {
    if let Some(document) = map.get("document") {
        return Some(document.clone());
    }
    let mut document = Map::new();
    for key in ["text", "image"] {
        if let Some(value) = map.get(key) {
            document.insert(key.to_string(), value.clone());
        }
    }
    (!document.is_empty()).then_some(Value::Object(document))
}

fn normalize_rerank_document(document: &Value) -> Value {
    match document {
        Value::String(text) => json!({ "text": text }),
        Value::Object(_) => document.clone(),
        Value::Null => json!({}),
        value => json!({ "text": value_to_string(value) }),
    }
}
