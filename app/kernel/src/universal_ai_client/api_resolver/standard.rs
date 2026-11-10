use super::*;
use uuid::Uuid as UUID;
pub(super) fn build_event(sequence: u64, event_type: &str, fields: Value) -> Value {
    let mut event = json!({
        "type": event_type,
        "sequence_number": sequence
    });

    if let Value::Object(fields) = fields {
        for (key, value) in fields {
            event[key] = value;
        }
    }

    event
}

pub(super) fn terminal_event(status: &str) -> &'static str {
    match status {
        "completed" => "response.completed",
        "incomplete" => "response.incomplete",
        "failed" => "response.failed",
        _status => "response.failed",
    }
}

pub(super) fn function_call_item(call: &ToolCall, status: &str) -> Value {
    json!({
        "id": call.id,
        "type": "function_call",
        "call_id": call.call_id,
        "name": call.name,
        "arguments": call.arguments,
        "status": status
    })
}

pub(super) fn failed_response_resource(
    context: &ResponseContext,
    error: &StreamError,
    last_response: Option<Value>,
) -> Value {
    let mut body = last_response.unwrap_or_else(|| json!({}));
    body["status"] = json!("failed");
    body["completed_at"] = Value::Null;
    body["error"] = openresponses_error(error);
    complete_response_resource(context, body)
}

pub(crate) fn complete_response_resource(context: &ResponseContext, body: Value) -> Value {
    let request = context.resolved_request();
    let mut object = body.as_object().cloned().unwrap_or_default();
    let created_at = integer_value(
        object
            .get("created_at")
            .or_else(|| object.get("created"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or_else(now_seconds);
    let status = string_value(object.get("status").unwrap_or(&Value::Null))
        .unwrap_or_else(|| "completed".to_string());
    let completed_at = if object.contains_key("completed_at") {
        object.get("completed_at").cloned().unwrap_or(Value::Null)
    } else if status == "completed" {
        json!(now_seconds())
    } else {
        Value::Null
    };

    object.insert("object".to_string(), json!("response"));
    put_default(&mut object, "id", json!(generated_id("resp")));
    object.insert("created_at".to_string(), json!(created_at));
    object.insert("completed_at".to_string(), completed_at);
    object.insert("status".to_string(), json!(status));
    object.insert(
        "incomplete_details".to_string(),
        object
            .get("incomplete_details")
            .cloned()
            .unwrap_or(Value::Null),
    );
    object.insert(
        "model".to_string(),
        json!(
            string_value(object.get("model").unwrap_or(&Value::Null))
                .unwrap_or_else(|| context.model.clone())
        ),
    );
    object.insert("previous_response_id".to_string(), Value::Null);
    object.insert(
        "next_response_ids".to_string(),
        normalize_string_list(object.get("next_response_ids").unwrap_or(&Value::Null)),
    );
    object.insert(
        "instructions".to_string(),
        normalize_instructions(preferred(&object, &request, "instructions")),
    );
    object.insert(
        "input".to_string(),
        normalize_input_items(preferred(&object, &request, "input")),
    );
    object.insert(
        "output".to_string(),
        normalize_output_items(object.get("output").unwrap_or(&Value::Null)),
    );
    object.insert(
        "error".to_string(),
        object.get("error").cloned().unwrap_or(Value::Null),
    );
    object.insert(
        "tools".to_string(),
        normalize_tools(preferred(&object, &request, "tools")),
    );
    object.insert(
        "tool_choice".to_string(),
        normalize_tool_choice(preferred(&object, &request, "tool_choice")),
    );
    object.insert(
        "truncation".to_string(),
        normalize_truncation(preferred(&object, &request, "truncation")),
    );
    object.insert(
        "parallel_tool_calls".to_string(),
        json!(bool_value(
            preferred(&object, &request, "parallel_tool_calls"),
            true
        )),
    );
    object.insert(
        "text".to_string(),
        normalize_text_field(preferred(&object, &request, "text")),
    );
    object.insert(
        "top_p".to_string(),
        number_value(preferred(&object, &request, "top_p"), 1.0),
    );
    object.insert(
        "presence_penalty".to_string(),
        number_value(preferred(&object, &request, "presence_penalty"), 0.0),
    );
    object.insert(
        "frequency_penalty".to_string(),
        number_value(preferred(&object, &request, "frequency_penalty"), 0.0),
    );
    object.insert(
        "top_logprobs".to_string(),
        integer_value(preferred(&object, &request, "top_logprobs"))
            .map_or(json!(0), |value| json!(value)),
    );
    object.insert(
        "temperature".to_string(),
        number_value(preferred(&object, &request, "temperature"), 1.0),
    );
    object.insert(
        "reasoning".to_string(),
        normalize_reasoning(preferred(&object, &request, "reasoning")),
    );
    object.insert(
        "user".to_string(),
        nullable_string(preferred(&object, &request, "user")),
    );
    object.insert(
        "usage".to_string(),
        normalize_response_usage(object.get("usage").unwrap_or(&Value::Null)),
    );
    if let Some(cost_token) =
        nullable_string(object.get("cost_token").unwrap_or(&Value::Null)).as_str()
    {
        object.insert("cost_token".to_string(), json!(cost_token));
    }
    object.insert(
        "max_output_tokens".to_string(),
        integer_value(preferred(&object, &request, "max_output_tokens"))
            .map_or(Value::Null, |value| json!(value)),
    );
    object.insert(
        "max_tool_calls".to_string(),
        integer_value(preferred(&object, &request, "max_tool_calls"))
            .map_or(Value::Null, |value| json!(value)),
    );
    object.insert(
        "store".to_string(),
        json!(bool_value(preferred(&object, &request, "store"), false)),
    );
    object.insert(
        "background".to_string(),
        json!(bool_value(
            preferred(&object, &request, "background"),
            false
        )),
    );
    object.insert(
        "service_tier".to_string(),
        nullable_string(preferred(&object, &request, "service_tier")),
    );
    object.insert(
        "metadata".to_string(),
        normalize_metadata(preferred(&object, &request, "metadata")),
    );
    object.insert(
        "safety_identifier".to_string(),
        nullable_string(preferred(&object, &request, "safety_identifier")),
    );
    object.insert(
        "prompt_cache_key".to_string(),
        nullable_string(preferred(&object, &request, "prompt_cache_key")),
    );
    object.insert(
        "prompt_cache_retention".to_string(),
        normalize_prompt_cache_retention(preferred(&object, &request, "prompt_cache_retention")),
    );
    object.insert(
        "context_edits".to_string(),
        normalize_list(object.get("context_edits").unwrap_or(&Value::Null)),
    );
    object.insert(
        "conversation".to_string(),
        normalize_conversation(preferred(&object, &request, "conversation")),
    );

    Value::Object(object)
}

pub(super) fn preferred<'a>(
    body: &'a Map<String, Value>,
    request: &'a Value,
    key: &str,
) -> &'a Value {
    body.get(key)
        .or_else(|| request.get(key))
        .unwrap_or(&Value::Null)
}

pub(super) fn put_default(object: &mut Map<String, Value>, key: &str, value: Value) {
    if !object.contains_key(key) || object.get(key).is_some_and(Value::is_null) {
        object.insert(key.to_string(), value);
    }
}

pub(super) fn reject_provider_body_error(status: u16, body: &Value) -> Result<(), StreamError> {
    match body.get("error") {
        Some(error) if !error.is_null() => Err(provider_body_error(status, body.clone())),
        _error => Ok(()),
    }
}

pub(super) fn provider_object_body(
    status: u16,
    body: Value,
    label: &'static str,
) -> Result<Value, StreamError> {
    if !(200..300).contains(&status) {
        return Err(provider_body_error(status, body));
    }
    reject_provider_body_error(status, &body)?;
    if body.is_object() {
        return Ok(body);
    }

    Err(invalid_upstream_body_error(
        status,
        body,
        format!("{label} response body must be a JSON object"),
    ))
}

pub(super) fn invalid_upstream_body_error(
    status: u16,
    body: Value,
    message: impl Into<String>,
) -> StreamError {
    let excerpt = sonic_rs::to_vec(&body).unwrap_or_default();
    StreamError::new("invalid_upstream_response", "api_resolver", message)
        .provider_status(status)
        .provider_body_excerpt(excerpt)
}

pub(super) fn provider_body_error(status: u16, body: Value) -> StreamError {
    let provider_status = upstream_body_error_status(status, &body);
    let excerpt = sonic_rs::to_vec(&body).unwrap_or_default();
    StreamError::new(
        "provider_status_rejected",
        "api_resolver",
        format!("upstream returned HTTP status {provider_status}"),
    )
    .provider_status(provider_status)
    .provider_body_excerpt(excerpt)
}

pub(super) fn upstream_body_error_status(status: u16, body: &Value) -> u16 {
    let body_code = body
        .get("error")
        .and_then(|error| error.get("code"))
        .and_then(integer_value)
        .filter(|code| (400..=599).contains(code))
        .map(|code| code as u16);

    body_code
        .or_else(|| ((400..=599).contains(&status)).then_some(status))
        .unwrap_or(502)
}

pub(super) enum ProviderTerminal {
    Completed,
    Incomplete(&'static str),
    Failed(StreamError),
}

pub(super) fn provider_terminal_rejected(provider: &str, reason: &str) -> StreamError {
    StreamError::new(
        StreamErrorCode::ProviderTerminalRejected,
        "api_resolver",
        format!("{provider} rejected the response with terminal reason {reason}"),
    )
}

pub(super) fn normalize_input_items(input: &Value) -> Value {
    match input {
        Value::String(text) => json!([{
            "id": generated_id("msg"),
            "type": "message",
            "status": "completed",
            "role": "user",
            "content": [{"type": "input_text", "text": text}]
        }]),
        Value::Array(items) => Value::Array(items.iter().map(normalize_input_item).collect()),
        _value => json!([]),
    }
}

pub(super) fn normalize_input_item(item: &Value) -> Value {
    let Some(map) = item.as_object() else {
        return item.clone();
    };
    let mut item = map.clone();
    let item_type = item.get("type").and_then(Value::as_str).unwrap_or_default();
    match item_type {
        "message" => {
            let role = string_value(item.get("role").unwrap_or(&Value::Null))
                .unwrap_or_else(|| "user".to_string());
            put_default(&mut item, "id", json!(generated_id("msg")));
            put_default(&mut item, "status", json!("completed"));
            item.insert("role".to_string(), json!(role.clone()));
            item.insert(
                "content".to_string(),
                normalize_message_content_for_role(
                    &role,
                    item.get("content").unwrap_or(&Value::Null),
                ),
            );
        }
        "function_call" => {
            put_default(&mut item, "id", json!(generated_id("fc")));
            put_default(&mut item, "call_id", json!(generated_id("call")));
            put_default(&mut item, "name", json!("unknown"));
            put_default(&mut item, "arguments", json!("{}"));
            put_default(&mut item, "status", json!("completed"));
        }
        "function_call_output" => {
            put_default(&mut item, "id", json!(generated_id("fco")));
            put_default(&mut item, "call_id", json!(generated_id("call")));
            put_default(&mut item, "output", json!(""));
            put_default(&mut item, "status", json!("completed"));
        }
        _item => {
            if item.get("role").and_then(Value::as_str).is_some() && item.get("content").is_some() {
                item.insert("type".to_string(), json!("message"));
                return normalize_input_item(&Value::Object(item));
            }
        }
    }
    Value::Object(item)
}

pub(super) fn normalize_output_items(output: &Value) -> Value {
    match output {
        Value::Array(items) => Value::Array(items.iter().map(normalize_output_item).collect()),
        _value => json!([]),
    }
}

pub(crate) fn normalize_output_item(item: &Value) -> Value {
    let Some(map) = item.as_object() else {
        return item.clone();
    };
    let mut item = map.clone();
    match item.get("type").and_then(Value::as_str) {
        Some("message") => {
            put_default(&mut item, "id", json!(generated_id("msg")));
            put_default(&mut item, "status", json!("completed"));
            put_default(&mut item, "role", json!("assistant"));
            item.insert(
                "content".to_string(),
                normalize_output_content(item.get("content").unwrap_or(&Value::Null)),
            );
        }
        Some("function_call") => {
            put_default(&mut item, "id", json!(generated_id("fc")));
            put_default(&mut item, "call_id", json!(generated_id("call")));
            put_default(&mut item, "name", json!("unknown"));
            put_default(&mut item, "arguments", json!("{}"));
            put_default(&mut item, "status", json!("completed"));
        }
        _item => {}
    }
    Value::Object(item)
}

pub(super) fn normalize_message_content_for_role(role: &str, content: &Value) -> Value {
    if matches!(role, "assistant" | "tool") {
        normalize_assistant_content(content)
    } else {
        normalize_user_content(content)
    }
}

pub(super) fn normalize_user_content(content: &Value) -> Value {
    match content {
        Value::String(text) => json!([{ "type": "input_text", "text": text }]),
        Value::Array(parts) => Value::Array(
            parts
                .iter()
                .map(|part| match part {
                    Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("input_text") => {
                        let mut map = map.clone();
                        put_default(&mut map, "text", json!(""));
                        Value::Object(map)
                    }
                    Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("text") => {
                        json!({"type": "input_text", "text": value_to_string(map.get("text").unwrap_or(&Value::Null))})
                    }
                    Value::Object(map) if map.get("text").is_some() => {
                        json!({"type": "input_text", "text": value_to_string(map.get("text").unwrap_or(&Value::Null))})
                    }
                    Value::Object(_) => part.clone(),
                    value => json!({"type": "input_text", "text": value_to_string(value)}),
                })
                .collect(),
        ),
        value => json!([{ "type": "input_text", "text": value_to_string(value) }]),
    }
}

pub(super) fn normalize_assistant_content(content: &Value) -> Value {
    match content {
        Value::String(text) => json!([{ "type": "output_text", "text": text, "annotations": [] }]),
        Value::Array(parts) => {
            Value::Array(parts.iter().map(normalize_output_content_part).collect())
        }
        value => {
            json!([{ "type": "output_text", "text": value_to_string(value), "annotations": [] }])
        }
    }
}

pub(super) fn normalize_output_content(content: &Value) -> Value {
    match content {
        Value::String(text) => json!([{ "type": "output_text", "text": text, "annotations": [] }]),
        Value::Array(parts) => {
            Value::Array(parts.iter().map(normalize_output_content_part).collect())
        }
        _value => json!([]),
    }
}

pub(super) fn normalize_output_content_part(part: &Value) -> Value {
    match part {
        Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("output_text") => {
            let mut map = map.clone();
            put_default(&mut map, "text", json!(""));
            put_default(&mut map, "annotations", json!([]));
            Value::Object(map)
        }
        Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("refusal") => {
            let mut map = map.clone();
            put_default(&mut map, "refusal", json!(""));
            Value::Object(map)
        }
        Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("text") => {
            json!({"type": "output_text", "text": value_to_string(map.get("text").unwrap_or(&Value::Null)), "annotations": []})
        }
        Value::Object(map) if map.get("text").is_some() => {
            json!({"type": "output_text", "text": value_to_string(map.get("text").unwrap_or(&Value::Null)), "annotations": []})
        }
        value => json!({"type": "output_text", "text": value_to_string(value), "annotations": []}),
    }
}

pub(super) fn normalize_tools(tools: &Value) -> Value {
    match tools {
        Value::Array(tools) => Value::Array(
            tools
                .iter()
                .map(|tool| {
                    let Some(map) = tool.as_object() else {
                        return tool.clone();
                    };
                    let mut map = map.clone();
                    if map.get("type").and_then(Value::as_str) == Some("function") {
                        put_default(&mut map, "description", Value::Null);
                        put_default(&mut map, "parameters", Value::Null);
                        put_default(&mut map, "strict", Value::Null);
                    }
                    Value::Object(map)
                })
                .collect(),
        ),
        _value => json!([]),
    }
}

pub(super) fn normalize_tool_choice(choice: &Value) -> Value {
    match choice {
        Value::String(value) if matches!(value.as_str(), "none" | "auto" | "required") => {
            json!(value)
        }
        Value::Object(_) => choice.clone(),
        _value => json!("auto"),
    }
}

pub(super) fn normalize_truncation(value: &Value) -> Value {
    match value {
        Value::String(value) if matches!(value.as_str(), "auto" | "disabled") => json!(value),
        _value => json!("disabled"),
    }
}

pub(super) fn normalize_text_field(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut map = map.clone();
            put_default(&mut map, "format", json!({"type": "text"}));
            Value::Object(map)
        }
        _value => json!({"format": {"type": "text"}}),
    }
}

pub(super) fn normalize_reasoning(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut map = map.clone();
            put_default(&mut map, "effort", Value::Null);
            put_default(&mut map, "summary", Value::Null);
            Value::Object(map)
        }
        _value => json!({"effort": null, "summary": null}),
    }
}

// A count the Provider did not report stays `null`, so callers can tell it
// apart from a reported zero. A usage that is not an object is `null` as a
// whole.
pub(crate) fn normalize_response_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }
    let input_tokens = usage_count(usage, &["input_tokens", "prompt_tokens"]);
    let output_tokens = usage_count(usage, &["output_tokens", "completion_tokens"]);
    let total_tokens = usage_count(usage, &["total_tokens"])
        .or_else(|| Some(input_tokens?.saturating_add(output_tokens?)));
    let mut input_details = usage_details(usage, "input_tokens_details", "prompt_tokens_details");
    let mut output_details =
        usage_details(usage, "output_tokens_details", "completion_tokens_details");
    // Some OpenAI-compatible Providers report the cache read outside the
    // details object: DeepSeek as `prompt_cache_hit_tokens` and Kimi as a flat
    // `cached_tokens`. Both already count it in `prompt_tokens`.
    if !input_details
        .get("cached_tokens")
        .is_some_and(Value::is_number)
    {
        let cached_tokens = usage_count(usage, &["prompt_cache_hit_tokens", "cached_tokens"]);
        input_details.insert("cached_tokens".to_string(), json!(cached_tokens));
    }
    // OpenRouter and Kimi name the cache write `cache_write_tokens`, and
    // DashScope names it `cache_creation_input_tokens`.
    for alias in ["cache_write_tokens", "cache_creation_input_tokens"] {
        if let Some(cache_write_tokens) = input_details.remove(alias) {
            input_details
                .entry("cache_creation_tokens")
                .or_insert(cache_write_tokens);
        }
    }
    put_default(&mut output_details, "reasoning_tokens", Value::Null);

    json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
        "input_tokens_details": input_details,
        "output_tokens_details": output_details
    })
}

pub(super) fn normalize_anthropic_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }

    // Anthropic counts uncached input, cache reads, and cache writes as
    // disjoint fields; the OpenResponses shape counts them all as input and
    // keeps the cache portions in `input_tokens_details`.
    let cache_read_tokens = usage_count(usage, &["cache_read_input_tokens"]);
    let ephemeral_creation = usage
        .get("cache_creation")
        .and_then(Value::as_object)
        .and_then(|cc| {
            let m5 = cc.get("ephemeral_5m_input_tokens").and_then(integer_value);
            let h1 = cc.get("ephemeral_1h_input_tokens").and_then(integer_value);
            if m5.is_some() || h1.is_some() {
                Some(m5.unwrap_or(0).saturating_add(h1.unwrap_or(0)))
            } else {
                None
            }
        });
    let cache_creation_tokens = match (
        usage_count(usage, &["cache_creation_input_tokens"]),
        ephemeral_creation,
    ) {
        (Some(top), Some(eph)) => Some(top.max(eph)),
        (Some(top), None) => Some(top),
        (None, Some(eph)) => Some(eph),
        (None, None) => None,
    };
    let input_tokens = usage_count(usage, &["input_tokens"]).map(|input| {
        input
            .saturating_add(cache_read_tokens.unwrap_or(0))
            .saturating_add(cache_creation_tokens.unwrap_or(0))
    });
    let output_tokens = usage_count(usage, &["output_tokens"]);
    let mut input_details = usage_details(usage, "input_tokens_details", "prompt_tokens_details");
    input_details.insert(
        "cached_tokens".to_string(),
        cache_read_tokens.map_or(Value::Null, Value::from),
    );
    input_details.insert(
        "cache_creation_tokens".to_string(),
        cache_creation_tokens.map_or(Value::Null, Value::from),
    );
    if let Some(cc) = usage.get("cache_creation").filter(|v| v.is_object()) {
        input_details.insert("cache_creation".to_string(), cc.clone());
    }
    let mut output_details =
        usage_details(usage, "output_tokens_details", "completion_tokens_details");
    if let Some(thinking) =
        usage_count(usage, &["thinking_tokens", "reasoning_tokens"]).or_else(|| {
            output_details
                .get("thinking_tokens")
                .or_else(|| output_details.get("reasoning_tokens"))
                .and_then(integer_value)
        })
    {
        output_details
            .entry("thinking_tokens".to_string())
            .or_insert_with(|| Value::from(thinking));
        output_details
            .entry("reasoning_tokens".to_string())
            .or_insert_with(|| Value::from(thinking));
    }
    let mut out = json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens.zip(output_tokens).map(|(input, output)| input.saturating_add(output)),
        "input_tokens_details": input_details,
        "output_tokens_details": output_details
    });
    if let (Some(cc), Some(obj)) = (
        usage.get("cache_creation").filter(|v| v.is_object()),
        out.as_object_mut(),
    ) {
        obj.insert("cache_creation".to_string(), cc.clone());
    }
    out
}

// Bedrock Converse counts uncached input, cache reads, and cache writes as
// disjoint fields, as Anthropic does, so its usage takes the same conversion.
pub(super) fn normalize_bedrock_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }
    normalize_anthropic_usage(&json!({
        "input_tokens": usage.get("inputTokens"),
        "output_tokens": usage.get("outputTokens"),
        "cache_read_input_tokens": usage.get("cacheReadInputTokens"),
        "cache_creation_input_tokens": usage.get("cacheWriteInputTokens")
    }))
}

// `keys` lists the canonical name first; the first key present decides the count.
fn usage_count(usage: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter()
        .find_map(|key| usage.get(*key))
        .and_then(integer_value)
}

fn usage_details(usage: &Value, key: &str, legacy_key: &str) -> Map<String, Value> {
    usage
        .get(key)
        .or_else(|| usage.get(legacy_key))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

// Accumulates raw Anthropic usage counters across stream events. The result
// stays in Anthropic shape; `normalize_anthropic_usage` converts it when a
// response body is built.
pub(super) fn merge_anthropic_usage(left: Value, right: &Value) -> Value {
    let mut merged = left.as_object().cloned().unwrap_or_default();
    if let Some(right) = right.as_object() {
        for key in [
            "input_tokens",
            "output_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
            "thinking_tokens",
            "reasoning_tokens",
        ] {
            if let Some(value) = right.get(key).filter(|v| !v.is_null()) {
                merged.insert(key.to_string(), value.clone());
            }
        }
        for nested_key in [
            "cache_creation",
            "input_tokens_details",
            "output_tokens_details",
        ] {
            if let Some(sub_right) = right.get(nested_key).and_then(Value::as_object) {
                let mut sub_merged = merged
                    .get(nested_key)
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();
                for (k, v) in sub_right {
                    if !v.is_null() {
                        sub_merged.insert(k.clone(), v.clone());
                    }
                }
                if !sub_merged.is_empty() {
                    merged.insert(nested_key.to_string(), Value::Object(sub_merged));
                }
            }
        }
    }
    Value::Object(merged)
}

pub(super) fn openresponses_error(error: &StreamError) -> Value {
    error.to_openai_error_json()
}

pub(super) fn normalize_metadata(metadata: &Value) -> Value {
    if metadata.is_object() {
        metadata.clone()
    } else {
        json!({})
    }
}

pub(super) fn normalize_instructions(instructions: &Value) -> Value {
    match instructions {
        Value::String(_) | Value::Array(_) => instructions.clone(),
        _value => Value::Null,
    }
}

pub(super) fn normalize_string_list(values: &Value) -> Value {
    match values {
        Value::Array(values) => Value::Array(
            values
                .iter()
                .filter(|value| value.is_string())
                .cloned()
                .collect(),
        ),
        _value => json!([]),
    }
}

pub(super) fn normalize_list(values: &Value) -> Value {
    if values.is_array() {
        values.clone()
    } else {
        json!([])
    }
}

pub(super) fn normalize_prompt_cache_retention(value: &Value) -> Value {
    match value {
        Value::String(value) if matches!(value.as_str(), "in_memory" | "24h") => json!(value),
        _value => Value::Null,
    }
}

pub(super) fn normalize_conversation(value: &Value) -> Value {
    match value {
        Value::String(id) if !id.is_empty() => json!({ "id": id }),
        Value::Object(map)
            if map
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| !id.is_empty()) =>
        {
            value.clone()
        }
        _value => Value::Null,
    }
}

pub(super) fn bool_value(value: &Value, default: bool) -> bool {
    value.as_bool().unwrap_or(default)
}

pub(super) fn integer_value(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        value
            .as_u64()
            .map(|value| i64::try_from(value).unwrap_or(i64::MAX))
    })
}

pub(super) fn number_value(value: &Value, default: f64) -> Value {
    value
        .as_f64()
        .and_then(Number::from_f64)
        .map(Value::Number)
        .unwrap_or_else(|| json!(default))
}

pub(super) fn nullable_string(value: &Value) -> Value {
    string_value(value).map_or(Value::Null, Value::String)
}

pub(super) fn string_value(value: &Value) -> Option<String> {
    value.as_str().map(ToOwned::to_owned)
}

pub(super) fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Null => String::new(),
        value => sonic_rs::to_string(value).unwrap_or_else(|_| String::new()),
    }
}

pub(crate) fn generated_id(prefix: &str) -> String {
    format!("{prefix}_{}", UUID::new_v4().simple())
}

pub(super) fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

pub(super) fn maybe_put_from(
    target: &mut Map<String, Value>,
    source: &Map<String, Value>,
    key: &str,
) {
    if let Some(value) = source.get(key).cloned().filter(useful_value) {
        target.insert(key.to_string(), value);
    }
}

pub(super) fn useful_value(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::String(text) => !text.is_empty(),
        _value => true,
    }
}

pub(super) fn value_to_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        value => sonic_rs::to_string(value).unwrap_or_else(|_| value.to_string()),
    }
}

pub(super) fn provider_options_object(context: &ResponseContext) -> Map<String, Value> {
    context
        .provider_options
        .as_object()
        .cloned()
        .unwrap_or_default()
}

pub(super) fn merge_object(target: &mut Map<String, Value>, source: &Map<String, Value>) {
    for (key, value) in source {
        target.insert(key.clone(), value.clone());
    }
}

pub(super) fn put_default_if_useful(map: &mut Map<String, Value>, key: &str, value: Value) {
    if !map.get(key).is_some_and(useful_value) {
        map.insert(key.to_string(), value);
    }
}

pub(super) fn encode_protocol_json(value: Value) -> Result<String, StreamError> {
    sonic_rs::to_string(&value).map_err(|reason| {
        StreamError::new(
            "request_encode_failed",
            "api_resolver",
            format!("model request body could not be encoded as JSON: {reason}"),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_numbers_saturate_instead_of_wrapping() {
        assert_eq!(integer_value(&json!(u64::MAX)), Some(i64::MAX));

        let response = normalize_response_usage(&json!({
            "input_tokens": i64::MAX,
            "output_tokens": 1
        }));
        assert_eq!(response["total_tokens"], json!(i64::MAX));

        let anthropic = normalize_anthropic_usage(&json!({
            "input_tokens": i64::MAX,
            "cache_read_input_tokens": 1,
            "cache_creation_input_tokens": 1,
            "output_tokens": 1
        }));
        assert_eq!(anthropic["input_tokens"], json!(i64::MAX));
        assert_eq!(anthropic["total_tokens"], json!(i64::MAX));

        let bedrock = normalize_bedrock_usage(&json!({
            "inputTokens": i64::MAX,
            "cacheReadInputTokens": 1,
            "outputTokens": 1
        }));
        assert_eq!(bedrock["input_tokens"], json!(i64::MAX));
        assert_eq!(bedrock["total_tokens"], json!(i64::MAX));
    }

    #[test]
    fn provider_specific_cache_counts_use_the_canonical_details() {
        let deepseek = normalize_response_usage(&json!({
            "prompt_tokens": 100,
            "completion_tokens": 5,
            "prompt_cache_hit_tokens": 60,
            "prompt_cache_miss_tokens": 40
        }));
        assert_eq!(deepseek["input_tokens"], json!(100));
        assert_eq!(deepseek["input_tokens_details"]["cached_tokens"], json!(60));

        let kimi = normalize_response_usage(&json!({
            "prompt_tokens": 19,
            "completion_tokens": 13,
            "cached_tokens": 12
        }));
        assert_eq!(kimi["input_tokens_details"]["cached_tokens"], json!(12));

        // The canonical detail wins over a flat count, including a reported zero.
        let canonical = normalize_response_usage(&json!({
            "prompt_tokens": 19,
            "cached_tokens": 12,
            "prompt_tokens_details": {"cached_tokens": 0}
        }));
        assert_eq!(canonical["input_tokens_details"]["cached_tokens"], json!(0));

        let openrouter = normalize_response_usage(&json!({
            "prompt_tokens": 100,
            "prompt_tokens_details": {"cached_tokens": 60, "cache_write_tokens": 30}
        }));
        let details = &openrouter["input_tokens_details"];
        assert_eq!(details["cached_tokens"], json!(60));
        assert_eq!(details["cache_creation_tokens"], json!(30));
        assert_eq!(details.get("cache_write_tokens"), None);
        assert_eq!(normalize_response_usage(&openrouter), openrouter);

        let dashscope = normalize_response_usage(&json!({
            "prompt_tokens": 3019,
            "prompt_tokens_details": {"cached_tokens": 0, "cache_creation_input_tokens": 3013}
        }));
        let details = &dashscope["input_tokens_details"];
        assert_eq!(details["cache_creation_tokens"], json!(3013));
        assert_eq!(details.get("cache_creation_input_tokens"), None);

        // A Bedrock usage that reports no cache counts keeps them unreported.
        let bedrock = normalize_bedrock_usage(&json!({"inputTokens": 3, "outputTokens": 5}));
        assert_eq!(bedrock["input_tokens"], json!(3));
        assert_eq!(bedrock["total_tokens"], json!(8));
        assert_eq!(
            bedrock["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
        assert_eq!(normalize_bedrock_usage(&Value::Null), Value::Null);
    }

    #[test]
    fn unreported_usage_counts_stay_null() {
        assert_eq!(normalize_response_usage(&Value::Null), Value::Null);
        assert_eq!(normalize_anthropic_usage(&Value::Null), Value::Null);

        let partial = normalize_response_usage(&json!({"prompt_tokens": 0}));
        assert_eq!(partial["input_tokens"], json!(0));
        assert_eq!(partial["output_tokens"], Value::Null);
        assert_eq!(partial["total_tokens"], Value::Null);
        assert_eq!(
            partial["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
        assert_eq!(
            partial["output_tokens_details"]["reasoning_tokens"],
            Value::Null
        );
        assert_eq!(normalize_response_usage(&partial), partial);

        let anthropic = normalize_anthropic_usage(&json!({"output_tokens": 4}));
        assert_eq!(anthropic["input_tokens"], Value::Null);
        assert_eq!(anthropic["output_tokens"], json!(4));
        assert_eq!(
            anthropic["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
    }
}
