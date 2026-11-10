use super::*;

#[derive(Debug)]
pub(super) struct CohereRerank;

impl APIProtocol for CohereRerank {
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
    if context.policy() == ConversionPolicy::Strict {
        validate_strict_rerank_request(&request)?;
    }

    if let Some(documents) = request.get("documents").and_then(Value::as_array) {
        let serialized = documents
            .iter()
            .map(serialize_cohere_document)
            .collect::<Vec<_>>();
        request.insert("documents".to_string(), Value::Array(serialized));
    }

    Ok(request)
}

pub(crate) fn on_provider_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let mut object = provider_object_body(status, body, "Cohere rerank")?
        .as_object()
        .cloned()
        .unwrap_or_default();

    let strict = context.policy() == ConversionPolicy::Strict;
    if strict {
        validate_rerank_results_contract(status, &object, "Cohere rerank")?;
    }

    let request = context.resolved_provider_request();
    let documents = request
        .get("documents")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
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
    let usage = normalize_cohere_rerank_usage(status, &object)?;
    if strict && !has_valid_rerank_usage_receipt(Some(&usage)) {
        return Err(invalid_upstream_body_error(
            status.max(502),
            Value::Object(object),
            "Cohere rerank response is missing valid numeric `usage` receipt",
        ));
    }
    object.insert("usage".to_string(), usage);
    Ok(Value::Object(object))
}

fn serialize_cohere_document(document: &Value) -> Value {
    match document {
        Value::String(text) => Value::String(text.clone()),
        Value::Object(map) => {
            if map.len() == 1
                && let Some(text) = map.get("text").and_then(Value::as_str)
            {
                return Value::String(text.to_string());
            }
            let encoded = serde_json::to_string(document).unwrap_or_default();
            Value::String(encoded)
        }
        other => Value::String(value_to_string(other)),
    }
}

fn normalize_cohere_rerank_usage(
    status: u16,
    object: &Map<String, Value>,
) -> Result<Value, StreamError> {
    let mut usage = object
        .get("usage")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();

    let meta = object.get("meta").and_then(Value::as_object);
    let billed_units = meta
        .and_then(|meta| meta.get("billed_units"))
        .and_then(Value::as_object);
    let tokens = meta
        .and_then(|meta| meta.get("tokens"))
        .and_then(Value::as_object);

    if !usage.contains_key("search_units")
        && let Some(search_units) =
            billed_units.and_then(|units| units.get("search_units").cloned())
    {
        usage.insert("search_units".to_string(), search_units);
    }

    let input_tokens = usage
        .get("prompt_tokens")
        .and_then(Value::as_u64)
        .or_else(|| {
            tokens
                .and_then(|tok| tok.get("input_tokens"))
                .and_then(Value::as_u64)
        })
        .or_else(|| {
            billed_units
                .and_then(|units| units.get("input_tokens"))
                .and_then(Value::as_u64)
        });
    let output_tokens = tokens
        .and_then(|tok| tok.get("output_tokens"))
        .and_then(Value::as_u64)
        .or_else(|| {
            billed_units
                .and_then(|units| units.get("output_tokens"))
                .and_then(Value::as_u64)
        })
        .unwrap_or(0);

    if let Some(prompt_tokens) = input_tokens {
        put_default(&mut usage, "prompt_tokens", json!(prompt_tokens));
        let sum = prompt_tokens.checked_add(output_tokens).ok_or_else(|| {
            invalid_upstream_body_error(
                status.max(502),
                Value::Object(object.clone()),
                "Cohere rerank token usage overflowed u64",
            )
        })?;
        let total = match usage.get("total_tokens").and_then(Value::as_u64) {
            Some(explicit) if explicit >= sum => explicit,
            Some(_) => {
                return Err(invalid_upstream_body_error(
                    status.max(502),
                    Value::Object(object.clone()),
                    "Cohere rerank `total_tokens` is smaller than `prompt_tokens + output_tokens`",
                ));
            }
            None => sum,
        };
        put_default(&mut usage, "total_tokens", json!(total));
    } else if let Some(total_tokens) = usage.get("total_tokens").and_then(Value::as_u64) {
        put_default(&mut usage, "prompt_tokens", json!(total_tokens));
    }

    Ok(Value::Object(usage))
}
