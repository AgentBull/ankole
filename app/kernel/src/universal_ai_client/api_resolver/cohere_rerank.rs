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
    let strict = context.policy() == ConversionPolicy::Strict;
    strip_non_streaming_flag(&mut request, strict, "cohere_rerank")?;
    if strict {
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
    resolve_rerank_body_with_usage(
        context,
        status,
        body,
        "Cohere rerank",
        normalize_cohere_rerank_usage,
    )
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
        other => Value::String(value_to_text(other)),
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
