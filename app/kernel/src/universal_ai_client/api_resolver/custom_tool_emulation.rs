use super::*;

/// Custom-tool emulation for OpenAI Responses upstreams that only implement
/// plain function calling.
///
/// The Elixir provider layer marks a request with
/// `__ankole_emulate_custom_tools` when the connection declares that the
/// upstream does not support the official OpenAI tool surface. The resolver
/// then keeps two spaces consistent: the upstream space carries only function
/// tools, and the client space keeps the official custom-tool shapes. The
/// chat-completions resolver applies the same emulation unconditionally,
/// because that wire has no custom tools at all; both resolvers share the
/// field builders below.
pub(super) const EMULATE_CUSTOM_TOOLS_MARKER: &str = "__ankole_emulate_custom_tools";

pub(super) fn custom_tool_emulation_requested(context: &ResponseContext) -> bool {
    context
        .request
        .get(EMULATE_CUSTOM_TOOLS_MARKER)
        .and_then(Value::as_bool)
        == Some(true)
}

/// Returns whether the caller's request declares `name` as a top-level custom
/// tool. Responses tool names reach the upstream unflattened, so the lookup
/// does not consider namespaces.
pub(super) fn emulated_custom_tool(context: &ResponseContext, name: &str) -> bool {
    context
        .request
        .get("tools")
        .or_else(|| context.provider_options.get("tools"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .any(|tool| {
            tool.get("type").and_then(Value::as_str) == Some("custom")
                && tool.get("name").and_then(Value::as_str) == Some(name)
        })
}

/// Builds the `description` and `parameters` fields of the emulating function
/// tool. A grammar definition survives as prose inside the input description.
pub(super) fn custom_tool_function_fields(tool: &Map<String, Value>) -> (Value, Value) {
    let format = tool.get("format").and_then(Value::as_object);
    let input_description = format
        .and_then(|format| format.get("definition"))
        .and_then(Value::as_str)
        .map(|definition| format!("Raw tool input. It must match this grammar:\n{definition}"))
        .unwrap_or_else(|| "Raw tool input.".to_string());

    let description = tool.get("description").cloned().unwrap_or(Value::Null);
    let parameters = json!({
        "type": "object",
        "properties": {
            "input": {
                "type": "string",
                "description": input_description
            }
        },
        "required": ["input"],
        "additionalProperties": false
    });

    (description, parameters)
}

pub(super) fn encode_custom_tool_arguments(input: &str) -> Result<String, StreamError> {
    serde_json::to_string(&json!({ "input": input })).map_err(|error| {
        StreamError::new("custom_tool_encode_failed", "request", error.to_string())
    })
}

/// Rewrites one prepared Responses body into the upstream function-tool space.
pub(super) fn lower_custom_tools(body: &mut Map<String, Value>) -> Result<(), StreamError> {
    if let Some(tools) = body.get_mut("tools").and_then(Value::as_array_mut) {
        for tool in tools.iter_mut() {
            let Some(map) = tool.as_object() else {
                continue;
            };
            if map.get("type").and_then(Value::as_str) != Some("custom") {
                continue;
            }

            let (description, parameters) = custom_tool_function_fields(map);
            let name = map.get("name").cloned().unwrap_or(Value::Null);
            *tool = json!({
                "type": "function",
                "name": name,
                "description": description,
                "parameters": parameters,
                "strict": false
            });
        }

        reject_duplicate_emulated_tool_names(tools.iter().filter_map(|tool| {
            matches!(
                tool.get("type").and_then(Value::as_str),
                Some("function" | "custom")
            )
            .then(|| tool.get("name").and_then(Value::as_str))
            .flatten()
        }))?;
    }

    if let Some(choice) = body.get_mut("tool_choice")
        && choice.get("type").and_then(Value::as_str) == Some("custom")
        && let Some(choice) = choice.as_object_mut()
    {
        choice.insert("type".to_string(), json!("function"));
    }

    if let Some(input) = body.get_mut("input").and_then(Value::as_array_mut) {
        for item in input.iter_mut() {
            match item.get("type").and_then(Value::as_str) {
                Some("custom_tool_call") => {
                    let input_text = item.get("input").map(value_to_text).unwrap_or_default();
                    let arguments = encode_custom_tool_arguments(&input_text)?;
                    let Some(map) = item.as_object_mut() else {
                        continue;
                    };
                    map.insert("type".to_string(), json!("function_call"));
                    map.insert("arguments".to_string(), json!(arguments));
                    map.remove("input");
                }
                Some("custom_tool_call_output") => {
                    if let Some(map) = item.as_object_mut() {
                        map.insert("type".to_string(), json!("function_call_output"));
                    }
                }
                _type => {}
            }
        }
    }

    Ok(())
}

/// Restores one output item from the upstream function space. Returns the
/// item id when the item became a `custom_tool_call`, so the stream state can
/// route later argument events for it.
pub(super) fn lift_custom_tool_item(context: &ResponseContext, item: &mut Value) -> Option<String> {
    if item.get("type").and_then(Value::as_str) != Some("function_call") {
        return None;
    }
    let name = item.get("name").and_then(Value::as_str)?;
    if !emulated_custom_tool(context, name) {
        return None;
    }

    let input = item
        .get("arguments")
        .and_then(Value::as_str)
        .map(custom_tool_input)
        .unwrap_or_default();
    let item_id = item.get("id").and_then(Value::as_str).map(str::to_string);
    let map = item.as_object_mut()?;
    map.insert("type".to_string(), json!("custom_tool_call"));
    map.insert("input".to_string(), json!(input));
    map.remove("arguments");
    item_id
}

/// Restores every output item embedded in one response resource.
pub(super) fn lift_custom_tool_response(context: &ResponseContext, response: &mut Value) {
    if let Some(output) = response.get_mut("output").and_then(Value::as_array_mut) {
        for item in output.iter_mut() {
            lift_custom_tool_item(context, item);
        }
    }
}
