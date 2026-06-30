fn build_event(sequence: u64, event_type: &str, fields: Value) -> Value {
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

fn terminal_event(status: &str) -> &'static str {
    match status {
        "completed" => "response.completed",
        "incomplete" => "response.incomplete",
        "failed" => "response.failed",
        _status => "response.failed",
    }
}

fn function_call_item(call: &ToolCall, status: &str) -> Value {
    json!({
        "id": call.id,
        "type": "function_call",
        "call_id": call.call_id,
        "name": call.name,
        "arguments": call.arguments,
        "status": status
    })
}

fn failed_response_resource(
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

fn complete_response_resource(context: &ResponseContext, body: Value) -> Value {
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
        json!(string_value(object.get("model").unwrap_or(&Value::Null))
            .unwrap_or_else(|| context.model.clone())),
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
        json!(string_value(preferred(&object, &request, "service_tier"))
            .unwrap_or_else(|| "default".to_string())),
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

fn preferred<'a>(body: &'a Map<String, Value>, request: &'a Value, key: &str) -> &'a Value {
    body.get(key)
        .or_else(|| request.get(key))
        .unwrap_or(&Value::Null)
}

fn put_default(object: &mut Map<String, Value>, key: &str, value: Value) {
    if !object.contains_key(key) || object.get(key).is_some_and(Value::is_null) {
        object.insert(key.to_string(), value);
    }
}

fn reject_provider_body_error(status: u16, body: &Value) -> Result<(), StreamError> {
    match body.get("error") {
        Some(error) if !error.is_null() => Err(provider_body_error(status, body.clone())),
        _error => Ok(()),
    }
}

fn provider_object_body(
    status: u16,
    body: Value,
    label: &'static str,
) -> Result<Value, StreamError> {
    if body.is_object() {
        return Ok(body);
    }

    Err(invalid_upstream_body_error(
        status,
        body,
        format!("{label} response body must be a JSON object"),
    ))
}

fn invalid_upstream_body_error(
    status: u16,
    body: Value,
    message: impl Into<String>,
) -> StreamError {
    let excerpt = sonic_rs::to_vec(&body).unwrap_or_default();
    StreamError::new("invalid_upstream_response", "api_resolver", message)
        .provider_status(status)
        .provider_body_excerpt(excerpt)
}

fn provider_body_error(status: u16, body: Value) -> StreamError {
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

fn upstream_body_error_status(status: u16, body: &Value) -> u16 {
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

fn normalize_input_items(input: &Value) -> Value {
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

fn normalize_input_item(item: &Value) -> Value {
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

fn normalize_output_items(output: &Value) -> Value {
    match output {
        Value::Array(items) => Value::Array(items.iter().map(normalize_output_item).collect()),
        _value => json!([]),
    }
}

fn normalize_output_item(item: &Value) -> Value {
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

fn normalize_message_content_for_role(role: &str, content: &Value) -> Value {
    if matches!(role, "assistant" | "tool") {
        normalize_assistant_content(content)
    } else {
        normalize_user_content(content)
    }
}

fn normalize_user_content(content: &Value) -> Value {
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

fn normalize_assistant_content(content: &Value) -> Value {
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

fn normalize_output_content(content: &Value) -> Value {
    match content {
        Value::String(text) => json!([{ "type": "output_text", "text": text, "annotations": [] }]),
        Value::Array(parts) => {
            Value::Array(parts.iter().map(normalize_output_content_part).collect())
        }
        _value => json!([]),
    }
}

fn normalize_output_content_part(part: &Value) -> Value {
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

fn normalize_tools(tools: &Value) -> Value {
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

fn normalize_tool_choice(choice: &Value) -> Value {
    match choice {
        Value::String(value) if matches!(value.as_str(), "none" | "auto" | "required") => {
            json!(value)
        }
        Value::Object(_) => choice.clone(),
        _value => json!("auto"),
    }
}

fn normalize_truncation(value: &Value) -> Value {
    match value {
        Value::String(value) if matches!(value.as_str(), "auto" | "disabled") => json!(value),
        _value => json!("disabled"),
    }
}

fn normalize_text_field(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut map = map.clone();
            put_default(&mut map, "format", json!({"type": "text"}));
            Value::Object(map)
        }
        _value => json!({"format": {"type": "text"}}),
    }
}

fn normalize_reasoning(value: &Value) -> Value {
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

fn normalize_response_usage(usage: &Value) -> Value {
    let input_tokens = integer_value(
        usage
            .get("input_tokens")
            .or_else(|| usage.get("prompt_tokens"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or(0);
    let output_tokens = integer_value(
        usage
            .get("output_tokens")
            .or_else(|| usage.get("completion_tokens"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or(0);
    let total_tokens = integer_value(usage.get("total_tokens").unwrap_or(&Value::Null))
        .unwrap_or(input_tokens + output_tokens);
    let input_details = usage
        .get("input_tokens_details")
        .or_else(|| usage.get("prompt_tokens_details"))
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}));
    let output_details = usage
        .get("output_tokens_details")
        .or_else(|| usage.get("completion_tokens_details"))
        .filter(|value| value.is_object())
        .cloned()
        .unwrap_or_else(|| json!({}));

    let mut input_details = input_details.as_object().cloned().unwrap_or_default();
    let mut output_details = output_details.as_object().cloned().unwrap_or_default();
    put_default(&mut input_details, "cached_tokens", json!(0));
    put_default(&mut output_details, "reasoning_tokens", json!(0));

    json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
        "input_tokens_details": input_details,
        "output_tokens_details": output_details
    })
}

fn normalize_anthropic_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return json!({});
    }

    let input_tokens =
        integer_value(usage.get("input_tokens").unwrap_or(&Value::Null)).unwrap_or(0);
    let output_tokens =
        integer_value(usage.get("output_tokens").unwrap_or(&Value::Null)).unwrap_or(0);
    json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
        "input_tokens_details": {},
        "output_tokens_details": {}
    })
}

fn normalize_provider_token_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return json!({});
    }

    let input_tokens = integer_value(
        usage
            .get("input_tokens")
            .or_else(|| usage.get("prompt_tokens"))
            .or_else(|| usage.get("inputTokens"))
            .or_else(|| usage.get("promptTokenCount"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or(0);
    let output_tokens = integer_value(
        usage
            .get("output_tokens")
            .or_else(|| usage.get("completion_tokens"))
            .or_else(|| usage.get("outputTokens"))
            .or_else(|| usage.get("candidatesTokenCount"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or(0);
    let total_tokens = integer_value(
        usage
            .get("total_tokens")
            .or_else(|| usage.get("totalTokens"))
            .or_else(|| usage.get("totalTokenCount"))
            .unwrap_or(&Value::Null),
    )
    .unwrap_or(input_tokens + output_tokens);

    json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
        "input_tokens_details": {},
        "output_tokens_details": {}
    })
}

fn merge_anthropic_usage(left: Value, right: &Value) -> Value {
    let mut merged = left.as_object().cloned().unwrap_or_default();
    if let Some(right) = right.as_object() {
        for key in ["input_tokens", "output_tokens"] {
            if let Some(value) = right.get(key) {
                merged.insert(key.to_string(), value.clone());
            }
        }
    }
    let input_tokens =
        integer_value(merged.get("input_tokens").unwrap_or(&Value::Null)).unwrap_or(0);
    let output_tokens =
        integer_value(merged.get("output_tokens").unwrap_or(&Value::Null)).unwrap_or(0);
    merged.insert(
        "total_tokens".to_string(),
        json!(input_tokens + output_tokens),
    );
    Value::Object(merged)
}

fn openresponses_error(error: &StreamError) -> Value {
    json!({
        "message": error.message,
        "type": "server_error",
        "param": null,
        "code": error.code
    })
}

fn normalize_metadata(metadata: &Value) -> Value {
    if metadata.is_object() {
        metadata.clone()
    } else {
        json!({})
    }
}

fn normalize_instructions(instructions: &Value) -> Value {
    match instructions {
        Value::String(_) | Value::Array(_) => instructions.clone(),
        _value => Value::Null,
    }
}

fn normalize_string_list(values: &Value) -> Value {
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

fn normalize_list(values: &Value) -> Value {
    if values.is_array() {
        values.clone()
    } else {
        json!([])
    }
}

fn normalize_prompt_cache_retention(value: &Value) -> Value {
    match value {
        Value::String(value) if matches!(value.as_str(), "in_memory" | "24h") => json!(value),
        _value => Value::Null,
    }
}

fn normalize_conversation(value: &Value) -> Value {
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

fn bool_value(value: &Value, default: bool) -> bool {
    value.as_bool().unwrap_or(default)
}

fn integer_value(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_u64().map(|value| value as i64))
}

fn number_value(value: &Value, default: f64) -> Value {
    value
        .as_f64()
        .and_then(Number::from_f64)
        .map(Value::Number)
        .unwrap_or_else(|| json!(default))
}

fn nullable_string(value: &Value) -> Value {
    string_value(value).map_or(Value::Null, Value::String)
}

fn string_value(value: &Value) -> Option<String> {
    value.as_str().map(ToOwned::to_owned)
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Null => String::new(),
        value => sonic_rs::to_string(value).unwrap_or_else(|_| String::new()),
    }
}

fn generated_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::new_v4().simple())
}

fn now_seconds() -> i64 {
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

fn encode_protocol_json(value: Value) -> Result<String, StreamError> {
    sonic_rs::to_string(&value).map_err(|reason| {
        StreamError::new(
            "request_encode_failed",
            "api_resolver",
            format!("model request body could not be encoded as JSON: {reason}"),
        )
    })
}
