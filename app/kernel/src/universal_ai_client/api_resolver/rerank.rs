use super::*;

pub(super) const KNOWN_RERANK_FIELDS: &[&str] = &[
    "model",
    "query",
    "documents",
    "top_n",
    "return_documents",
    "max_tokens_per_doc",
    "provider",
    "rank_fields",
    "service_tier",
];

#[derive(Debug)]
pub(super) struct OpenrouterRerank;

#[derive(Debug)]
pub(super) struct JinaRerank;

impl APIProtocol for OpenrouterRerank {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_rerank_body(context)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_rerank_body(context, status, body)
    }
}

impl APIProtocol for JinaRerank {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_rerank_body(context)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        resolve_rerank_body(context, status, body, "Jina rerank")
    }
}

pub(crate) fn build_rerank_body(
    context: &ResponseContext,
) -> Result<Map<String, Value>, StreamError> {
    let request = context.resolved_provider_request_object();
    if context.policy() == ConversionPolicy::Strict {
        validate_strict_rerank_request(&request)?;
    }
    Ok(request)
}

pub(crate) fn normalize_rerank_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    resolve_rerank_body(context, status, body, "Rerank")
}

pub(super) fn validate_strict_rerank_request(
    request: &Map<String, Value>,
) -> Result<(), StreamError> {
    for key in request.keys() {
        if !KNOWN_RERANK_FIELDS.contains(&key.as_str()) {
            return Err(StreamError::new(
                "unsupported_parameter",
                "api_resolver",
                format!("unsupported rerank parameter `{key}` under strict conversion policy"),
            )
            .provider_status(400));
        }
    }

    match request.get("query") {
        Some(Value::String(query)) if !query.trim().is_empty() => {}
        Some(Value::Object(map)) if !map.is_empty() => {}
        _ => {
            return Err(StreamError::new(
                "invalid_rerank_query",
                "api_resolver",
                "rerank request requires a non-empty `query`",
            )
            .provider_status(400));
        }
    }

    let Some(documents) = request.get("documents").and_then(Value::as_array) else {
        return Err(StreamError::new(
            "invalid_rerank_documents",
            "api_resolver",
            "rerank request requires a non-empty `documents` array",
        )
        .provider_status(400));
    };

    if documents.is_empty() || !documents.iter().all(valid_rerank_document) {
        return Err(StreamError::new(
            "invalid_rerank_documents",
            "api_resolver",
            "rerank `documents` must be a non-empty array of strings or document objects",
        )
        .provider_status(400));
    }

    validate_strict_rerank_options(request)
}

fn validate_strict_rerank_options(request: &Map<String, Value>) -> Result<(), StreamError> {
    if let Some(top_n) = request.get("top_n")
        && !top_n.as_u64().is_some_and(|value| value > 0)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "rerank `top_n` must be a positive integer",
        )
        .provider_status(400));
    }

    if let Some(return_docs) = request.get("return_documents")
        && !return_docs.is_boolean()
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "rerank `return_documents` must be a boolean",
        )
        .provider_status(400));
    }

    if let Some(max_tokens) = request.get("max_tokens_per_doc")
        && !max_tokens.as_u64().is_some_and(|value| value > 0)
    {
        return Err(StreamError::new(
            "invalid_parameter",
            "api_resolver",
            "rerank `max_tokens_per_doc` must be a positive integer",
        )
        .provider_status(400));
    }

    Ok(())
}

fn valid_rerank_document(doc: &Value) -> bool {
    match doc {
        Value::String(text) => !text.is_empty(),
        Value::Object(map) => {
            !map.is_empty()
                && (map
                    .get("text")
                    .and_then(Value::as_str)
                    .is_some_and(|text| !text.is_empty())
                    || map
                        .get("image")
                        .and_then(Value::as_str)
                        .is_some_and(|img| !img.is_empty()))
        }
        _ => false,
    }
}

pub(super) fn validate_rerank_results_contract(
    status: u16,
    object: &Map<String, Value>,
    label: &'static str,
) -> Result<(), StreamError> {
    let Some(results) = object.get("results").and_then(Value::as_array) else {
        return Err(invalid_upstream_body_error(
            status.max(502),
            Value::Object(object.clone()),
            format!("{label} response is missing a `results` array"),
        ));
    };

    for item in results {
        let Some(map) = item.as_object() else {
            return Err(invalid_upstream_body_error(
                status.max(502),
                Value::Object(object.clone()),
                format!("{label} response `results` entry must be an object"),
            ));
        };
        if !map.get("index").is_some_and(Value::is_u64) {
            return Err(invalid_upstream_body_error(
                status.max(502),
                Value::Object(object.clone()),
                format!("{label} response `results` entry is missing non-negative integer `index`"),
            ));
        }
        let valid_score = map
            .get("relevance_score")
            .or_else(|| map.get("score"))
            .and_then(Value::as_f64)
            .is_some_and(f64::is_finite);
        if !valid_score {
            return Err(invalid_upstream_body_error(
                status.max(502),
                Value::Object(object.clone()),
                format!("{label} response `results` entry is missing finite `relevance_score`"),
            ));
        }
    }

    Ok(())
}

fn resolve_rerank_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
    label: &'static str,
) -> Result<Value, StreamError> {
    let mut object = provider_object_body(status, body, label)?
        .as_object()
        .cloned()
        .unwrap_or_default();

    if context.policy() == ConversionPolicy::Strict {
        validate_rerank_results_contract(status, &object, label)?;
        if !has_valid_rerank_usage_receipt(object.get("usage")) {
            return Err(invalid_upstream_body_error(
                status.max(502),
                Value::Object(object),
                format!("{label} response is missing valid numeric `usage` receipt"),
            ));
        }
    }

    let request = context.resolved_provider_request();
    let documents = request
        .get("documents")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let strict = context.policy() == ConversionPolicy::Strict;
    let return_documents = if strict {
        request
            .get("return_documents")
            .and_then(Value::as_bool)
            .unwrap_or(true)
    } else {
        true
    };

    put_default(&mut object, "id", json!(generated_id("rerank")));
    put_default(&mut object, "model", json!(context.model));
    object.insert(
        "results".to_string(),
        normalize_rerank_results(
            object.get("results").unwrap_or(&Value::Null),
            &documents,
            return_documents,
            strict,
        ),
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

pub(super) fn normalize_rerank_results(
    results: &Value,
    documents: &[Value],
    return_documents: bool,
    sort_by_score: bool,
) -> Value {
    let Some(results) = results.as_array() else {
        return json!([]);
    };

    let mut normalized_items: Vec<Value> = results
        .iter()
        .enumerate()
        .map(|(fallback_index, result)| {
            normalize_rerank_result_item(fallback_index, result, documents, return_documents)
        })
        .collect();

    if sort_by_score {
        normalized_items.sort_by(|a, b| {
            let a_score = a
                .get("relevance_score")
                .and_then(Value::as_f64)
                .unwrap_or(0.0);
            let b_score = b
                .get("relevance_score")
                .and_then(Value::as_f64)
                .unwrap_or(0.0);
            b_score.total_cmp(&a_score)
        });
    }

    Value::Array(normalized_items)
}

fn normalize_rerank_result_item(
    fallback_index: usize,
    result: &Value,
    documents: &[Value],
    return_documents: bool,
) -> Value {
    let Some(map) = result.as_object() else {
        let mut item = Map::new();
        if return_documents {
            item.insert(
                "document".to_string(),
                normalize_rerank_document(documents.get(fallback_index).unwrap_or(&Value::Null)),
            );
        }
        item.insert("index".to_string(), json!(fallback_index));
        item.insert("relevance_score".to_string(), json!(0.0));
        return Value::Object(item);
    };

    let index = integer_value(map.get("index").unwrap_or(&Value::Null))
        .map(|value| value.max(0) as usize)
        .unwrap_or(fallback_index);
    let score = map
        .get("relevance_score")
        .or_else(|| map.get("score"))
        .cloned()
        .unwrap_or_else(|| json!(0.0));
    let mut normalized = map.clone();
    normalized.remove("text");
    normalized.remove("image");
    normalized.remove("score");
    if return_documents {
        let document = rerank_result_document(map)
            .filter(|document| !document.is_null())
            .unwrap_or_else(|| documents.get(index).cloned().unwrap_or(Value::Null));
        normalized.insert("document".to_string(), normalize_rerank_document(&document));
    } else {
        normalized.remove("document");
    }
    normalized.insert("index".to_string(), json!(index));
    put_default(&mut normalized, "relevance_score", score);
    Value::Object(normalized)
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

pub(super) fn has_valid_rerank_usage_receipt(usage: Option<&Value>) -> bool {
    let Some(map) = usage.and_then(Value::as_object) else {
        return false;
    };
    const COUNTER_KEYS: &[&str] = &[
        "total_tokens",
        "prompt_tokens",
        "input_tokens",
        "search_units",
    ];
    let mut found_counter = false;
    for key in COUNTER_KEYS {
        if let Some(val) = map.get(*key) {
            if val.as_u64().is_some() {
                found_counter = true;
            } else {
                return false;
            }
        }
    }
    found_counter
}

pub(super) fn normalize_rerank_document(document: &Value) -> Value {
    match document {
        Value::String(text) => json!({ "text": text }),
        Value::Object(_) => document.clone(),
        Value::Null => json!({}),
        value => json!({ "text": value_to_string(value) }),
    }
}
