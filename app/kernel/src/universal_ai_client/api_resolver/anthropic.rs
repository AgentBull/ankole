use super::*;

/// Marks private reasoning envelopes so foreign provider text cannot enter replay.
const ANTHROPIC_REASONING_PREFIX: &str = "ankole-aigateway-anthropic-reasoning:";

#[derive(Debug)]
pub(super) struct AnthropicState {
    sequence: u64,
    response_id: Option<String>,
    model: Option<String>,
    message_item_id: Option<String>,
    message_output_index: Option<usize>,
    text: String,
    text_started: bool,
    text_done: bool,
    tool_calls: BTreeMap<usize, ToolCall>,
    tool_done_indices: BTreeSet<usize>,
    active_blocks: BTreeMap<usize, String>,
    thinking_blocks: BTreeMap<usize, Value>,
    reasoning_item_id: Option<String>,
    reasoning_output_index: Option<usize>,
    usage: Value,
    stop_reason: Option<String>,
    terminal: bool,
    next_output_index: usize,
}

impl AnthropicState {
    pub(super) fn new(model: String) -> Self {
        Self {
            sequence: 0,
            response_id: None,
            model: (!model.is_empty()).then_some(model),
            message_item_id: None,
            message_output_index: None,
            text: String::new(),
            text_started: false,
            text_done: false,
            tool_calls: BTreeMap::new(),
            tool_done_indices: BTreeSet::new(),
            active_blocks: BTreeMap::new(),
            thinking_blocks: BTreeMap::new(),
            reasoning_item_id: None,
            reasoning_output_index: None,
            usage: Value::Null,
            stop_reason: None,
            terminal: false,
            next_output_index: 0,
        }
    }

    fn ingest(
        &mut self,
        context: &ResponseContext,
        value: Value,
    ) -> Result<Vec<Value>, StreamError> {
        let events = match value.get("type").and_then(Value::as_str) {
            Some("message_start") => self.message_start(context, &value),
            Some("content_block_start") => self.content_block_start(context, &value),
            Some("content_block_delta") => self.content_block_delta(context, &value),
            Some("content_block_stop") => self.content_block_stop(context, &value)?,
            Some("message_delta") => {
                self.message_delta(&value);
                Vec::new()
            }
            Some("message_stop") => {
                let (status, reason) = self
                    .stop_reason
                    .as_deref()
                    .map(anthropic_terminal)
                    .unwrap_or(("completed", None));
                self.finish(context, status, reason)?
            }
            Some("error") => return Err(anthropic_stream_error(&value)),
            Some("ping") | None => Vec::new(),
            Some(_event) => Vec::new(),
        };
        Ok(events)
    }

    fn message_start(&mut self, context: &ResponseContext, value: &Value) -> Vec<Value> {
        let message = value.get("message").unwrap_or(&Value::Null);
        self.response_id = message
            .get("id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| Some(generated_id("resp")));
        if let Some(model) = message.get("model").and_then(Value::as_str) {
            self.model = Some(model.to_string());
        }
        if let Some(usage) = message.get("usage").filter(|value| value.is_object()) {
            self.usage = usage.clone();
        }

        vec![self.event(
            "response.created",
            json!({ "response": self.response_body(context, "in_progress", None, None) }),
        )]
    }

    fn content_block_start(&mut self, context: &ResponseContext, value: &Value) -> Vec<Value> {
        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        let block = value.get("content_block").unwrap_or(&Value::Null);

        match block.get("type").and_then(Value::as_str) {
            Some("thinking" | "redacted_thinking") => {
                self.active_blocks.insert(index, "reasoning".to_string());
                self.thinking_blocks.insert(index, block.clone());
                self.ensure_reasoning_item()
            }
            Some("text") => {
                self.active_blocks.insert(index, "text".to_string());
                let mut events = Vec::new();
                self.ensure_text_part(&mut events);
                events
            }
            Some("tool_use") => {
                self.active_blocks.insert(index, "tool_use".to_string());
                let output_index = self.next_output_index;
                self.next_output_index += 1;
                let call = ToolCall {
                    id: generated_id("fc"),
                    call_id: block
                        .get("id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| generated_id("call")),
                    name: block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_string(),
                    arguments: String::new(),
                    output_index,
                };
                let event = self.event(
                    "response.output_item.added",
                    json!({
                        "output_index": output_index,
                        "item": anthropic_function_call_item(context, &call, "in_progress")
                    }),
                );
                self.tool_calls.insert(index, call);
                vec![event]
            }
            _block => Vec::new(),
        }
    }

    fn content_block_delta(&mut self, context: &ResponseContext, value: &Value) -> Vec<Value> {
        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        let delta = value.get("delta").unwrap_or(&Value::Null);

        match delta.get("type").and_then(Value::as_str) {
            Some("thinking_delta") => {
                let text = delta
                    .get("thinking")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.append_block_text(index, "thinking", text);
                Vec::new()
            }
            Some("signature_delta") => {
                let signature = delta
                    .get("signature")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.append_block_text(index, "signature", signature);
                Vec::new()
            }
            Some("text_delta") => delta
                .get("text")
                .and_then(Value::as_str)
                .map(|text| self.text_delta(text, index))
                .unwrap_or_default(),
            Some("input_json_delta") => {
                let partial = delta
                    .get("partial_json")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                self.tool_arguments_delta(context, index, partial)
            }
            _delta => Vec::new(),
        }
    }

    fn text_delta(&mut self, text: &str, index: usize) -> Vec<Value> {
        self.active_blocks.insert(index, "text".to_string());
        let mut events = Vec::new();
        self.ensure_text_part(&mut events);
        self.text.push_str(text);
        let item_id = self
            .message_item_id
            .clone()
            .unwrap_or_else(|| generated_id("msg"));
        let output_index = self.message_output_index.unwrap_or(0);
        events.push(self.event(
            "response.output_text.delta",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "delta": text
            }),
        ));
        events
    }

    fn ensure_text_part(&mut self, events: &mut Vec<Value>) {
        let (item_id, output_index) = self.ensure_message_item(events);
        if self.text_started {
            return;
        }

        self.text_started = true;
        events.push(self.event(
            "response.content_part.added",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []}
            }),
        ));
    }

    fn ensure_message_item(&mut self, events: &mut Vec<Value>) -> (String, usize) {
        if let (Some(item_id), Some(output_index)) =
            (self.message_item_id.clone(), self.message_output_index)
        {
            return (item_id, output_index);
        }

        let item_id = generated_id("msg");
        let output_index = self.next_output_index;
        self.next_output_index += 1;
        self.message_item_id = Some(item_id.clone());
        self.message_output_index = Some(output_index);
        events.push(self.event(
            "response.output_item.added",
            json!({
                "output_index": output_index,
                "item": {
                    "id": item_id,
                    "type": "message",
                    "status": "in_progress",
                    "role": "assistant",
                    "content": []
                }
            }),
        ));
        (item_id, output_index)
    }

    fn tool_arguments_delta(
        &mut self,
        context: &ResponseContext,
        index: usize,
        partial: &str,
    ) -> Vec<Value> {
        let (item_id, output_index) = {
            let Some(call) = self.tool_calls.get_mut(&index) else {
                return Vec::new();
            };

            call.arguments.push_str(partial);
            // The provider streams a JSON wrapper. Publish the decoded custom
            // input when complete, as the Chat Completions adapter does.
            if provider_custom_tool(context, &call.name) {
                return Vec::new();
            }
            (call.id.clone(), call.output_index)
        };

        let event = self.event(
            "response.function_call_arguments.delta",
            json!({
                "item_id": item_id,
                "output_index": output_index,
                "delta": partial
            }),
        );
        vec![event]
    }

    fn content_block_stop(
        &mut self,
        context: &ResponseContext,
        value: &Value,
    ) -> Result<Vec<Value>, StreamError> {
        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        match self.active_blocks.get(&index).map(String::as_str) {
            Some("text") => Ok(self.finish_text_part()),
            Some("tool_use") => self.finish_tool_call(context, index),
            Some("reasoning") => Ok(Vec::new()),
            _block => Ok(Vec::new()),
        }
    }

    fn ensure_reasoning_item(&mut self) -> Vec<Value> {
        if self.reasoning_item_id.is_some() {
            return Vec::new();
        }

        let item_id = generated_id("rs");
        let output_index = self.next_output_index;
        self.next_output_index += 1;
        self.reasoning_item_id = Some(item_id.clone());
        self.reasoning_output_index = Some(output_index);

        vec![self.event(
            "response.output_item.added",
            json!({
                "output_index": output_index,
                "item": {
                    "id": item_id,
                    "type": "reasoning",
                    "status": "in_progress",
                    "summary": []
                }
            }),
        )]
    }

    fn append_block_text(&mut self, index: usize, key: &str, delta: &str) {
        let Some(block) = self
            .thinking_blocks
            .get_mut(&index)
            .and_then(Value::as_object_mut)
        else {
            return;
        };

        if let Some(Value::String(current)) = block.get_mut(key) {
            current.push_str(delta);
        } else {
            block.insert(key.to_string(), Value::String(delta.to_string()));
        }
    }

    fn finish_text_part(&mut self) -> Vec<Value> {
        if self.text_done {
            return Vec::new();
        }

        let Some(item_id) = self.message_item_id.clone() else {
            return Vec::new();
        };
        let output_index = self.message_output_index.unwrap_or(0);
        self.text_done = true;
        vec![
            self.event(
                "response.output_text.done",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": 0,
                    "text": self.text
                }),
            ),
            self.event(
                "response.content_part.done",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": self.text, "annotations": []}
                }),
            ),
        ]
    }

    fn validate_strict_tool_call(
        &mut self,
        context: &ResponseContext,
        index: usize,
    ) -> Result<(), StreamError> {
        if self.tool_done_indices.contains(&index) {
            return Ok(());
        }

        if context.policy() == ConversionPolicy::Strict
            && let Some(call) = self.tool_calls.get_mut(&index)
            && !provider_custom_tool(context, &call.name)
        {
            if call.arguments.is_empty() {
                call.arguments = "{}".to_string();
            } else {
                let parsed = sonic_rs::from_str::<Value>(&call.arguments).map_err(|reason| {
                    StreamError::new(
                        "invalid_tool_arguments",
                        "api_resolver",
                        format!("Anthropic tool_use arguments are not valid JSON: {reason}"),
                    )
                })?;
                if !parsed.is_object() {
                    return Err(StreamError::new(
                        "invalid_tool_arguments",
                        "api_resolver",
                        "Anthropic tool_use arguments must be a JSON object",
                    ));
                }
            }
        }
        Ok(())
    }

    fn finish_tool_call(
        &mut self,
        context: &ResponseContext,
        index: usize,
    ) -> Result<Vec<Value>, StreamError> {
        if self.tool_done_indices.contains(&index) {
            return Ok(Vec::new());
        }

        self.validate_strict_tool_call(context, index)?;

        let Some(call) = self.tool_calls.get(&index).cloned() else {
            return Ok(Vec::new());
        };
        self.tool_done_indices.insert(index);
        let custom = provider_custom_tool(context, &call.name);
        let (event_type, payload) = if custom {
            (
                "response.custom_tool_call_input.done",
                json!({
                    "item_id": call.id,
                    "output_index": call.output_index,
                    "input": custom_tool_input(&call.arguments)
                }),
            )
        } else {
            (
                "response.function_call_arguments.done",
                json!({
                    "item_id": call.id,
                    "output_index": call.output_index,
                    "arguments": call.arguments
                }),
            )
        };
        Ok(vec![
            self.event(event_type, payload),
            self.event(
                "response.output_item.done",
                json!({
                    "output_index": call.output_index,
                    "item": anthropic_function_call_item(context, &call, "completed")
                }),
            ),
        ])
    }

    fn message_delta(&mut self, value: &Value) {
        if let Some(usage) = value.get("usage").filter(|value| value.is_object()) {
            self.usage = merge_anthropic_usage(self.usage.clone(), usage);
        }
        if let Some(reason) = value
            .get("delta")
            .and_then(|delta| delta.get("stop_reason"))
            .and_then(Value::as_str)
        {
            self.stop_reason = Some(reason.to_string());
        }
    }

    fn finish(
        &mut self,
        context: &ResponseContext,
        status: &str,
        incomplete_reason: Option<&str>,
    ) -> Result<Vec<Value>, StreamError> {
        if self.terminal {
            return Ok(Vec::new());
        }

        if context.policy() == ConversionPolicy::Strict
            && status == "completed"
            && self.reasoning_item_id.is_none()
            && self.message_item_id.is_none()
            && self.tool_calls.is_empty()
        {
            return Err(StreamError::new(
                "empty_upstream_stream",
                "api_resolver",
                "Anthropic stream completed without emitting any output blocks",
            ));
        }

        let tool_indices = self.tool_calls.keys().copied().collect::<Vec<_>>();
        if status == "completed" {
            for &index in &tool_indices {
                self.validate_strict_tool_call(context, index)?;
            }
        }

        self.terminal = true;
        let mut events = Vec::new();
        if status == "completed" {
            if let (Some(item), Some(output_index)) = (
                self.reasoning_item(context, "completed"),
                self.reasoning_output_index,
            ) {
                events.push(self.event(
                    "response.output_item.done",
                    json!({"output_index": output_index, "item": item}),
                ));
            }
            if self.text_started {
                events.extend(self.finish_text_part());
            }
            for index in tool_indices {
                events.extend(self.finish_tool_call(context, index)?);
            }
            if let Some(item_id) = self.message_item_id.clone() {
                events.push(self.event(
                    "response.output_item.done",
                    json!({
                        "output_index": self.message_output_index.unwrap_or(0),
                        "item": {
                            "id": item_id,
                            "type": "message",
                            "status": "completed",
                            "role": "assistant",
                            "content": [{
                                "type": "output_text",
                                "text": self.text,
                                "annotations": []
                            }]
                        }
                    }),
                ));
            }
        }
        events.push(self.event(
            terminal_event(status),
            json!({ "response": self.response_body(context, status, incomplete_reason, None) }),
        ));
        Ok(events)
    }

    fn fail(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
        if self.terminal {
            return Vec::new();
        }

        let response = self.response_body(context, "failed", None, Some(error));
        self.terminal = true;
        let failed = self.event("response.failed", json!({ "response": response }));
        vec![failed]
    }

    fn response_body(
        &self,
        context: &ResponseContext,
        status: &str,
        incomplete_reason: Option<&str>,
        error: Option<&StreamError>,
    ) -> Value {
        let item_status = response_item_status(status);
        let mut indexed_output = Vec::new();
        if let (Some(item), Some(output_index)) = (
            self.reasoning_item(context, item_status),
            self.reasoning_output_index,
        ) {
            indexed_output.push((output_index, item));
        }
        if let Some(item_id) = &self.message_item_id {
            indexed_output.push((
                self.message_output_index.unwrap_or(0),
                json!({
                    "id": item_id,
                    "type": "message",
                    "status": item_status,
                    "role": "assistant",
                    "content": [{
                        "type": "output_text",
                        "text": self.text,
                        "annotations": []
                    }]
                }),
            ));
        }
        indexed_output.extend(self.tool_calls.values().map(|call| {
            (
                call.output_index,
                anthropic_function_call_item(context, call, item_status),
            )
        }));
        indexed_output.sort_by_key(|(output_index, _item)| *output_index);
        let output = indexed_output
            .into_iter()
            .map(|(_output_index, item)| item)
            .collect::<Vec<_>>();

        complete_response_resource(
            context,
            json!({
                "id": self.response_id.clone().unwrap_or_else(|| generated_id("resp")),
                "object": "response",
                "created_at": now_seconds(),
                "completed_at": if status == "completed" { json!(now_seconds()) } else { Value::Null },
                "status": status,
                "incomplete_details": incomplete_reason.map(|reason| json!({"reason": reason})).unwrap_or(Value::Null),
                "model": self.model.clone().unwrap_or_else(|| context.model.clone()),
                "output": output,
                "usage": normalize_anthropic_usage(&self.usage),
                "error": error.map(openresponses_error).unwrap_or(Value::Null),
                "metadata": {}
            }),
        )
    }

    fn reasoning_item(&self, context: &ResponseContext, status: &str) -> Option<Value> {
        let item_id = self.reasoning_item_id.as_ref()?;
        let content = self.thinking_blocks.values().cloned().collect::<Vec<_>>();
        let encrypted_content = encode_anthropic_reasoning(context, &content)?;

        Some(json!({
            "id": item_id,
            "type": "reasoning",
            "status": status,
            "encrypted_content": encrypted_content,
            "summary": []
        }))
    }

    fn event(&mut self, event_type: &str, fields: Value) -> Value {
        let sequence = self.next_sequence();
        build_event(sequence, event_type, fields)
    }

    fn next_sequence(&mut self) -> u64 {
        let sequence = self.sequence;
        self.sequence = self.sequence.saturating_add(1);
        sequence
    }
}

impl APIProtocol for AnthropicState {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_anthropic_body(context)
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        self.ingest(context, event)
    }

    fn on_upstream_close(&mut self, context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        if self.terminal {
            return Ok(Vec::new());
        }
        if context.policy() == ConversionPolicy::Strict {
            return Err(StreamError::new(
                "upstream_stream_truncated",
                "api_resolver",
                "Anthropic stream closed before message_stop",
            ));
        }
        self.finish(context, "incomplete", Some("upstream_stream_closed"))
    }

    fn on_transport_error(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
        self.fail(context, error)
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        anthropic_body_to_response(
            context,
            provider_object_body(status, body, "Anthropic Messages")?,
        )
    }

    fn is_terminal(&self) -> bool {
        self.terminal
    }
}

// `model_context_window_exceeded` maps like `max_tokens`, matching
// `bedrock_terminal` for the same Claude stop reason.
fn anthropic_terminal(stop_reason: &str) -> (&'static str, Option<&'static str>) {
    match stop_reason {
        "max_tokens" | "model_context_window_exceeded" => ("incomplete", Some("max_output_tokens")),
        _reason => ("completed", None),
    }
}

// Anthropic can send an `error` event after the HTTP 200 response starts. The
// event has the same error object as a non-streaming error response, so the
// failure reports the event as the Provider error body and the HTTP status that
// Anthropic documents for its error type. An undocumented type has no status.
fn anthropic_stream_error(event: &Value) -> StreamError {
    let error = event.get("error");
    let error_type = error
        .and_then(|error| error.get("type"))
        .and_then(Value::as_str);
    let message = error
        .and_then(|error| error.get("message"))
        .and_then(Value::as_str)
        .or(error_type)
        .unwrap_or("Anthropic Messages stream failed");
    let failure = StreamError::new("provider_status_rejected", "api_resolver", message)
        .provider_body_excerpt(sonic_rs::to_vec(event).unwrap_or_default());

    match error_type.and_then(anthropic_error_status) {
        Some(status) => failure.provider_status(status),
        None => failure,
    }
}

fn anthropic_error_status(error_type: &str) -> Option<u16> {
    match error_type {
        "invalid_request_error" => Some(400),
        "authentication_error" => Some(401),
        "billing_error" => Some(402),
        "permission_error" => Some(403),
        "not_found_error" => Some(404),
        "conflict_error" => Some(409),
        "request_too_large" => Some(413),
        "rate_limit_error" => Some(429),
        "api_error" => Some(500),
        "timeout_error" => Some(504),
        "overloaded_error" => Some(529),
        _error_type => None,
    }
}

fn anthropic_body_to_response(
    context: &ResponseContext,
    body: Value,
) -> Result<Value, StreamError> {
    let mut output = Vec::new();
    let mut text = String::new();
    let content = body
        .get("content")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for block in &content {
        match block.get("type").and_then(Value::as_str) {
            Some("text") => {
                if let Some(delta) = block.get("text").and_then(Value::as_str) {
                    text.push_str(delta);
                }
            }
            Some("tool_use") => {
                let arguments = if context.policy() == ConversionPolicy::Strict {
                    let input = block.get("input").ok_or_else(|| {
                        StreamError::new(
                            "invalid_tool_arguments",
                            "api_resolver",
                            "Anthropic tool_use block is missing input object",
                        )
                    })?;
                    if !input.is_object() {
                        return Err(StreamError::new(
                            "invalid_tool_arguments",
                            "api_resolver",
                            "Anthropic tool_use input must be a JSON object",
                        ));
                    }
                    sonic_rs::to_string(input).map_err(|reason| {
                        StreamError::new(
                            "invalid_tool_arguments",
                            "api_resolver",
                            format!("Anthropic tool_use input could not be encoded: {reason}"),
                        )
                    })?
                } else {
                    block
                        .get("input")
                        .map(|input| {
                            sonic_rs::to_string(input).unwrap_or_else(|_| "{}".to_string())
                        })
                        .unwrap_or_else(|| "{}".to_string())
                };
                let mut item = json!({
                    "id": generated_id("fc"),
                    "type": "function_call",
                    "call_id": block.get("id").and_then(Value::as_str).unwrap_or("call"),
                    "name": block.get("name").and_then(Value::as_str).unwrap_or("unknown"),
                    "arguments": arguments,
                    "status": "completed"
                });
                restore_tool_namespace(context, &mut item);
                restore_custom_tool(context, &mut item);
                output.push(item);
            }
            _block => {}
        }
    }

    if !text.is_empty() {
        output.insert(
            0,
            json!({
                "id": generated_id("msg"),
                "type": "message",
                "status": "completed",
                "role": "assistant",
                "content": [{"type": "output_text", "text": text, "annotations": []}]
            }),
        );
    }

    if let Some(encrypted_content) = encode_anthropic_reasoning(context, &content) {
        output.insert(
            0,
            json!({
                "id": generated_id("rs"),
                "type": "reasoning",
                "status": "completed",
                "encrypted_content": encrypted_content,
                "summary": []
            }),
        );
    }

    let (status, incomplete_reason) = body
        .get("stop_reason")
        .and_then(Value::as_str)
        .map(anthropic_terminal)
        .unwrap_or(("completed", None));

    Ok(complete_response_resource(
        context,
        json!({
            "id": body.get("id").and_then(Value::as_str).map(ToOwned::to_owned).unwrap_or_else(|| generated_id("resp")),
            "object": "response",
            "created_at": now_seconds(),
            "completed_at": if status == "completed" { json!(now_seconds()) } else { Value::Null },
            "status": status,
            "incomplete_details": incomplete_reason.map(|reason| json!({"reason": reason})).unwrap_or(Value::Null),
            "model": body.get("model").and_then(Value::as_str).map(ToOwned::to_owned).unwrap_or_else(|| context.model.clone()),
            "output": output,
            "usage": normalize_anthropic_usage(body.get("usage").unwrap_or(&Value::Null)),
            "metadata": {}
        }),
    ))
}

// Claude requires the original `thinking` blocks, with their signatures, at the
// front of the assistant turn that produced a tool call. Only those blocks travel
// in the envelope: the visible text and `tool_use` blocks are already public
// Responses items, and replay rebuilds the turn from them.
fn encode_anthropic_reasoning(context: &ResponseContext, content: &[Value]) -> Option<String> {
    let thinking = thinking_blocks(content);
    if thinking.is_empty() {
        return None;
    }

    let mut payload = Map::new();
    payload.insert("thinking".to_string(), Value::Array(thinking));

    reasoning_envelope::encode(ANTHROPIC_REASONING_PREFIX, context, payload)
}

fn decode_anthropic_reasoning(context: &ResponseContext, encoded: &str) -> Option<Vec<Value>> {
    let object = reasoning_envelope::decode(ANTHROPIC_REASONING_PREFIX, context, encoded)?;
    let thinking = thinking_blocks(object.get("thinking").and_then(Value::as_array)?);

    if thinking.is_empty() {
        None
    } else {
        Some(thinking)
    }
}

fn thinking_blocks(content: &[Value]) -> Vec<Value> {
    content
        .iter()
        .filter(|block| {
            matches!(
                block.get("type").and_then(Value::as_str),
                Some("thinking" | "redacted_thinking")
            )
        })
        .cloned()
        .collect()
}

fn build_anthropic_body(context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
    let strict = context.policy() == ConversionPolicy::Strict;
    if strict
        && context
            .request
            .as_object()
            .and_then(|raw| raw.get("previous_response_id"))
            .is_some_and(|v| !v.is_null())
    {
        return Err(unexpressible_anthropic_field("previous_response_id"));
    }
    let request = context.resolved_provider_request_object();
    let mut consumed = BTreeSet::new();
    let mut body = provider_options_object(context);

    if let Some(instructions) = request.get("instructions").cloned().filter(useful_value) {
        if strict
            && let Some(sys) = request.get("system").filter(|v| !v.is_null())
            && sys != &instructions
        {
            return Err(unexpressible_anthropic_field("system"));
        }
        body.insert("system".to_string(), instructions);
        consumed.insert("instructions");
        if request.get("system").is_some_and(useful_value) {
            consumed.insert("system");
        }
    } else if let Some(system) = request.get("system").cloned().filter(useful_value) {
        body.insert("system".to_string(), system);
        consumed.insert("system");
    }

    for empty_sys in ["instructions", "system"] {
        if request.get(empty_sys).is_some_and(|v| {
            v.as_str().is_some_and(str::is_empty) || v.as_array().is_some_and(Vec::is_empty)
        }) {
            consumed.insert(empty_sys);
        }
    }

    let max_tokens_val = ["max_output_tokens", "max_tokens"]
        .iter()
        .find_map(|key| request.get(*key).filter(|value| useful_value(value)))
        .cloned();
    if let Some(ref val) = max_tokens_val {
        if strict
            && let Some(other) = request.get("max_tokens").filter(|v| !v.is_null())
            && other != val
        {
            return Err(unexpressible_anthropic_field("max_tokens"));
        }
        for k in ["max_output_tokens", "max_tokens"] {
            if request.get(k).is_some_and(useful_value) {
                consumed.insert(k);
            }
        }
    }
    body.insert(
        "max_tokens".to_string(),
        max_tokens_val.unwrap_or_else(|| json!(4096)),
    );

    for key in [
        "temperature",
        "top_p",
        "top_k",
        "stop_sequences",
        "service_tier",
        "metadata",
        "thinking",
    ] {
        if let Some(value) = request.get(key).cloned().filter(useful_value) {
            body.insert(key.to_string(), value);
            consumed.insert(key);
        }
    }
    if request
        .get("stop_sequences")
        .is_some_and(|v| v.as_array().is_some_and(Vec::is_empty))
    {
        consumed.insert("stop_sequences");
    }
    if let Some(stop) = request.get("stop").filter(|v| !v.is_null()) {
        match stop {
            Value::Array(arr) if arr.is_empty() => {
                consumed.insert("stop");
            }
            Value::String(s) if !s.is_empty() && !body.contains_key("stop_sequences") => {
                body.insert("stop_sequences".to_string(), json!([s]));
                consumed.insert("stop");
            }
            Value::Array(arr)
                if !arr.is_empty()
                    && !body.contains_key("stop_sequences")
                    && (!strict
                        || arr
                            .iter()
                            .all(|v| v.as_str().is_some_and(|s| !s.is_empty()))) =>
            {
                body.insert("stop_sequences".to_string(), Value::Array(arr.clone()));
                consumed.insert("stop");
            }
            _ => {}
        }
    }

    if strict {
        consume_strict_anthropic_text_and_format(&request, &mut consumed)?;
    }

    if let Some(raw_tools) = request.get("tools").filter(|v| !v.is_null()) {
        if let Some(tools) = anthropic_tools(Some(raw_tools), strict)? {
            body.insert("tools".to_string(), tools);
            consumed.insert("tools");
        } else if raw_tools.as_array().is_some_and(Vec::is_empty) {
            consumed.insert("tools");
        }
    }

    let thinking_enabled = anthropic_thinking_enabled(body.get("thinking"));
    if let Some(tool_choice) =
        anthropic_tool_choice(request.get("tool_choice"), thinking_enabled, strict)?
    {
        body.insert("tool_choice".to_string(), tool_choice);
        consumed.insert("tool_choice");
    }

    if context.include_model {
        body.insert("model".to_string(), json!(context.model));
        if request.get("model").is_some_and(useful_value) {
            consumed.insert("model");
        }
    }
    let stream = match request.get("stream") {
        Some(Value::Bool(flag)) => {
            consumed.insert("stream");
            Value::Bool(*flag)
        }
        Some(other) if !strict => other.clone(),
        _ => Value::Bool(false),
    };
    body.insert("stream".to_string(), stream);
    if matches!(
        request.get("input"),
        Some(Value::String(_) | Value::Array(_))
    ) {
        consumed.insert("input");
        body.insert(
            "messages".to_string(),
            anthropic_messages(context, request.get("input"))?,
        );
    } else if let Some(messages) = request.get("messages").filter(|v| v.is_array()).cloned() {
        consumed.insert("messages");
        body.insert("messages".to_string(), messages);
    } else if !body.get("messages").is_some_and(Value::is_array) {
        body.insert(
            "messages".to_string(),
            anthropic_messages(context, request.get("input"))?,
        );
    }
    enforce_anthropic_v2026_boundary(context, &request, &mut body, &mut consumed)?;
    if strict {
        verify_strict_consumed(&request, &consumed, "Anthropic Messages")?;
    }
    Ok(body)
}

pub(super) fn unexpressible_anthropic_field(field: impl std::fmt::Display) -> StreamError {
    StreamError::new(
        "unexpressible_field",
        "api_resolver",
        format!("Anthropic Messages cannot express request field `{field}`"),
    )
    .provider_status(400)
}

fn consume_strict_anthropic_text_and_format(
    request: &Map<String, Value>,
    consumed: &mut BTreeSet<&'static str>,
) -> Result<(), StreamError> {
    if let Some(rf) = request.get("response_format").filter(|v| !v.is_null()) {
        let Some(obj) = rf.as_object() else {
            return Err(unexpressible_anthropic_field("response_format"));
        };
        if obj.get("type").and_then(Value::as_str) != Some("text")
            || obj.iter().any(|(k, v)| !v.is_null() && k != "type")
        {
            return Err(unexpressible_anthropic_field("response_format"));
        }
        consumed.insert("response_format");
    }
    if let Some(text) = request.get("text").filter(|v| !v.is_null()) {
        let Some(text_obj) = text.as_object() else {
            return Err(unexpressible_anthropic_field("text"));
        };
        let Some(fmt_obj) = text_obj.get("format").and_then(Value::as_object) else {
            return Err(unexpressible_anthropic_field("text"));
        };
        if text_obj.iter().any(|(k, v)| !v.is_null() && k != "format")
            || fmt_obj.get("type").and_then(Value::as_str) != Some("text")
            || fmt_obj.iter().any(|(k, v)| !v.is_null() && k != "type")
        {
            return Err(unexpressible_anthropic_field("text.format"));
        }
        consumed.insert("text");
    }
    Ok(())
}

// One Anthropic assistant turn arrives back as several Responses items: a
// `reasoning` item, an assistant `message`, and one `function_call` for each tool
// use. Replay merges each run of assistant items into one message and puts the
// decoded `thinking` blocks in front, which is the order Claude requires. Merging
// by adjacency needs no count of derived items, so a history that lost or
// reordered items degrades into a turn without private reasoning instead of a
// failed request.
fn anthropic_messages(
    context: &ResponseContext,
    input: Option<&Value>,
) -> Result<Value, StreamError> {
    let strict = context.policy() == ConversionPolicy::Strict;
    match input {
        Some(Value::String(text)) => Ok(json!([
            {"role": "user", "content": [{"type": "text", "text": text}]}
        ])),
        Some(Value::Array(items)) => {
            let mut replay = AnthropicReplay::default();

            for item in items {
                let Some(map) = item.as_object() else {
                    if strict {
                        return Err(StreamError::new(
                            "invalid_input_item",
                            "api_resolver",
                            "Anthropic input item must be a JSON object",
                        ));
                    }
                    replay.push_user(json!([{"type": "text", "text": value_to_text(item)}]));
                    continue;
                };

                match map.get("type").and_then(Value::as_str) {
                    Some("reasoning") => {
                        replay.pending_thinking = map
                            .get("encrypted_content")
                            .and_then(Value::as_str)
                            .and_then(|encoded| decode_anthropic_reasoning(context, encoded))
                            .unwrap_or_default();
                    }
                    Some("function_call" | "custom_tool_call") => {
                        replay.push_assistant(vec![anthropic_tool_use(map, strict)?]);
                    }
                    Some("function_call_output" | "custom_tool_call_output") => {
                        let call_id = if strict {
                            map.get("call_id")
                                .and_then(Value::as_str)
                                .filter(|id| !id.is_empty())
                                .map(ToOwned::to_owned)
                                .ok_or_else(|| {
                                    StreamError::new(
                                        "invalid_tool_arguments",
                                        "api_resolver",
                                        "Anthropic tool_result item requires a non-empty call_id",
                                    )
                                })?
                        } else {
                            map.get("call_id").map(value_to_text).unwrap_or_default()
                        };
                        replay.push_tool_result(json!({
                            "type": "tool_result",
                            "tool_use_id": call_id,
                            "content": map.get("output").map(value_to_text).unwrap_or_default()
                        }));
                    }
                    _type => replay.push_item(map, strict)?,
                }
            }

            Ok(Value::Array(replay.finish()))
        }
        _input => Ok(json!([])),
    }
}

#[derive(Debug, Default)]
struct AnthropicReplay {
    messages: Vec<Value>,
    assistant_blocks: Vec<Value>,
    tool_result_blocks: Vec<Value>,
    pending_thinking: Vec<Value>,
}

impl AnthropicReplay {
    fn push_assistant(&mut self, mut blocks: Vec<Value>) {
        self.flush_tool_results();
        if self.assistant_blocks.is_empty() {
            self.assistant_blocks.append(&mut self.pending_thinking);
        }
        self.assistant_blocks.append(&mut blocks);
    }

    fn push_tool_result(&mut self, block: Value) {
        self.flush_assistant();
        self.pending_thinking.clear();
        self.tool_result_blocks.push(block);
    }

    fn push_user(&mut self, content: Value) {
        self.flush_assistant();
        self.flush_tool_results();
        self.pending_thinking.clear();
        self.messages
            .push(json!({"role": "user", "content": content}));
    }

    // Anthropic rejects an empty content array.
    fn push_item(&mut self, map: &Map<String, Value>, strict: bool) -> Result<(), StreamError> {
        let item_type = map.get("type").and_then(Value::as_str);
        if strict
            && let Some(item_type) = item_type
            && !matches!(item_type, "message" | "agent_message")
        {
            return Err(StreamError::new(
                "invalid_input_item",
                "api_resolver",
                format!("unsupported Anthropic input item type `{item_type}`"),
            ));
        }
        let Some(content) = map.get("content") else {
            if strict {
                return Err(StreamError::new(
                    "invalid_input_item",
                    "api_resolver",
                    "Anthropic message item is missing content",
                ));
            }
            return Ok(());
        };
        let role_name = if item_type == Some("agent_message") {
            Some("user")
        } else {
            map.get("role").and_then(Value::as_str)
        };
        let role = anthropic_role(role_name, strict)?;
        match role {
            "assistant" => match anthropic_content(Some(content), strict)? {
                Value::Array(blocks) => self.push_assistant(blocks),
                _content => {}
            },
            _role => self.push_user(anthropic_content(Some(content), strict)?),
        }
        Ok(())
    }

    fn flush_assistant(&mut self) {
        if self.assistant_blocks.is_empty() {
            return;
        }
        let content = std::mem::take(&mut self.assistant_blocks);
        self.messages
            .push(json!({"role": "assistant", "content": content}));
    }

    fn flush_tool_results(&mut self) {
        if self.tool_result_blocks.is_empty() {
            return;
        }
        let content = std::mem::take(&mut self.tool_result_blocks);
        self.messages
            .push(json!({"role": "user", "content": content}));
    }

    fn finish(mut self) -> Vec<Value> {
        self.flush_assistant();
        self.flush_tool_results();
        self.messages
    }
}

fn anthropic_tool_use(call: &Map<String, Value>, strict: bool) -> Result<Value, StreamError> {
    let call_id = if strict {
        call.get("call_id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(ToOwned::to_owned)
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_tool_arguments",
                    "api_resolver",
                    "Anthropic tool_use item requires a non-empty call_id",
                )
            })?
    } else {
        call.get("call_id").map(value_to_text).unwrap_or_default()
    };

    let raw_name = if strict {
        call.get("name")
            .and_then(Value::as_str)
            .filter(|name| !name.is_empty())
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_tool_arguments",
                    "api_resolver",
                    "Anthropic tool_use item requires a non-empty name",
                )
            })?
    } else {
        call.get("name").and_then(Value::as_str).unwrap_or_default()
    };

    let input = if call.get("type").and_then(Value::as_str) == Some("custom_tool_call") {
        json!({"input": call.get("input").map(value_to_text).unwrap_or_default()})
    } else if strict {
        let arguments = call
            .get("arguments")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_tool_arguments",
                    "api_resolver",
                    "Anthropic tool_use item requires string arguments",
                )
            })?;
        let parsed = sonic_rs::from_str::<Value>(arguments).map_err(|reason| {
            StreamError::new(
                "invalid_tool_arguments",
                "api_resolver",
                format!("Anthropic tool_use arguments are not valid JSON: {reason}"),
            )
        })?;
        if !parsed.is_object() {
            return Err(StreamError::new(
                "invalid_tool_arguments",
                "api_resolver",
                "Anthropic tool_use arguments must be a JSON object",
            ));
        }
        parsed
    } else {
        call.get("arguments")
            .and_then(Value::as_str)
            .and_then(|arguments| sonic_rs::from_str::<Value>(arguments).ok())
            .unwrap_or_else(|| json!({}))
    };

    let name = if strict {
        match call.get("namespace").and_then(Value::as_str) {
            Some(namespace) => flattened_namespace_tool_name(namespace, raw_name),
            None => flattened_namespace_tool_name("", raw_name),
        }
    } else {
        call.get("name")
            .and_then(Value::as_str)
            .map(|name| match call.get("namespace").and_then(Value::as_str) {
                Some(namespace) => flattened_namespace_tool_name(namespace, name),
                None => flattened_namespace_tool_name("", name),
            })
            .unwrap_or_default()
    };

    Ok(json!({
        "type": "tool_use",
        "id": call_id,
        "name": name,
        "input": input
    }))
}

fn anthropic_role(role: Option<&str>, strict: bool) -> Result<&'static str, StreamError> {
    match role {
        Some("assistant") => Ok("assistant"),
        Some("user") => Ok("user"),
        None if !strict => Ok("user"),
        Some(_other) if !strict => Ok("user"),
        Some(other) => Err(StreamError::new(
            "invalid_input_item",
            "api_resolver",
            format!("unsupported Anthropic message role `{other}`"),
        )),
        None => Err(StreamError::new(
            "invalid_input_item",
            "api_resolver",
            "Anthropic message item requires a role",
        )),
    }
}

fn anthropic_content(content: Option<&Value>, strict: bool) -> Result<Value, StreamError> {
    match content {
        Some(Value::String(text)) => Ok(json!([{ "type": "text", "text": text }])),
        Some(Value::Array(parts)) => {
            let mut mapped = Vec::with_capacity(parts.len());
            for part in parts {
                let Some(map) = part.as_object() else {
                    if strict {
                        return Err(StreamError::new(
                            "invalid_input_item",
                            "api_resolver",
                            "Anthropic message content part must be a JSON object",
                        ));
                    }
                    mapped.push(json!({ "type": "text", "text": value_to_text(part) }));
                    continue;
                };
                let block = match map.get("type").and_then(Value::as_str) {
                    Some("input_text" | "output_text" | "text") => {
                        let mut text_block = Map::new();
                        text_block.insert("type".to_string(), json!("text"));
                        text_block.insert(
                            "text".to_string(),
                            json!(map.get("text").map(value_to_text).unwrap_or_default()),
                        );
                        for key in ["cache_control", "citations"] {
                            maybe_put_from(&mut text_block, map, key);
                        }
                        Value::Object(text_block)
                    }
                    Some("document") => {
                        let mut doc = Map::new();
                        doc.insert("type".to_string(), json!("document"));
                        for key in ["source", "title", "context", "cache_control", "citations"] {
                            maybe_put_from(&mut doc, map, key);
                        }
                        Value::Object(doc)
                    }
                    Some("tool_use") => {
                        let mut tool = Map::new();
                        for key in ["type", "id", "name", "input"] {
                            maybe_put_from(&mut tool, map, key);
                        }
                        Value::Object(tool)
                    }
                    Some("tool_result") => {
                        let mut result = Map::new();
                        for key in ["type", "tool_use_id", "content", "is_error"] {
                            maybe_put_from(&mut result, map, key);
                        }
                        Value::Object(result)
                    }
                    Some("input_image" | "image_url" | "image") => {
                        anthropic_image_part(map, strict)?
                    }
                    _type => unsupported_anthropic_content_part(map, part, strict)?,
                };
                mapped.push(block);
            }
            Ok(Value::Array(mapped))
        }
        Some(value) if !strict => Ok(json!([{ "type": "text", "text": value_to_text(value) }])),
        Some(_value) => Err(StreamError::new(
            "invalid_input_item",
            "api_resolver",
            "Anthropic message content must be a string or array",
        )),
        None => Ok(json!([])),
    }
}

fn anthropic_image_part(map: &Map<String, Value>, strict: bool) -> Result<Value, StreamError> {
    let Some(url) = anthropic_image_url(map) else {
        return anthropic_unsupported_image(strict, "Anthropic image part is missing a valid URL");
    };

    if let Some((media_type, data)) = parse_image_data_url(&url) {
        return Ok(json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": data
            }
        }));
    }

    if url.starts_with("https://") || url.starts_with("http://") {
        return Ok(json!({
            "type": "image",
            "source": {
                "type": "url",
                "url": url
            }
        }));
    }

    anthropic_unsupported_image(
        strict,
        "Anthropic image part requires an http(s) or base64 image data URL",
    )
}

fn anthropic_unsupported_image(strict: bool, message: &'static str) -> Result<Value, StreamError> {
    if strict {
        Err(StreamError::new(
            "unsupported_content_modality",
            "api_resolver",
            message,
        ))
    } else {
        Ok(anthropic_image_placeholder())
    }
}

fn anthropic_image_url(map: &Map<String, Value>) -> Option<String> {
    for key in ["image_url", "url", "image"] {
        if let Some(url) = map.get(key).and_then(image_url_value) {
            return Some(url);
        }
    }
    None
}

fn image_url_value(value: &Value) -> Option<String> {
    match value {
        Value::String(url) if !url.trim().is_empty() => Some(url.clone()),
        Value::Object(map) => map
            .get("url")
            .and_then(Value::as_str)
            .filter(|url| !url.trim().is_empty())
            .map(ToOwned::to_owned),
        _value => None,
    }
}

fn parse_image_data_url(url: &str) -> Option<(String, String)> {
    let (metadata, data) = url.strip_prefix("data:")?.split_once(',')?;
    let (media_type, encoding) = metadata.rsplit_once(';')?;
    if encoding != "base64" || !media_type.starts_with("image/") || data.trim().is_empty() {
        return None;
    }
    Some((media_type.to_string(), data.to_string()))
}

fn unsupported_anthropic_content_part(
    map: &Map<String, Value>,
    part: &Value,
    strict: bool,
) -> Result<Value, StreamError> {
    if binaryish_content_part(map) {
        return anthropic_unsupported_image(
            strict,
            "unsupported binary or media content part for Anthropic Messages",
        );
    }

    if strict {
        return Err(StreamError::new(
            "invalid_input_item",
            "api_resolver",
            "unsupported Anthropic message content part type",
        ));
    }

    Ok(json!({ "type": "text", "text": value_to_text(part) }))
}

fn binaryish_content_part(map: &Map<String, Value>) -> bool {
    let binaryish_keys = [
        "image",
        "image_url",
        "file",
        "file_data",
        "data",
        "bytes",
        "base64",
        "b64_json",
    ];
    if binaryish_keys.iter().any(|key| map.contains_key(*key)) {
        return true;
    }

    map.get("type")
        .and_then(Value::as_str)
        .map(|part_type| {
            ["image", "file", "audio", "video"]
                .iter()
                .any(|needle| part_type.contains(needle))
        })
        .unwrap_or(false)
}

fn anthropic_image_placeholder() -> Value {
    json!({ "type": "text", "text": "[image content omitted: unsupported image source]" })
}

fn anthropic_tools(tools: Option<&Value>, strict: bool) -> Result<Option<Value>, StreamError> {
    let Some(tools) = tools.and_then(Value::as_array) else {
        return Ok(None);
    };
    let mut mapped = Vec::new();
    for tool in tools {
        let Some(map) = tool.as_object() else {
            if strict {
                return Err(unexpressible_anthropic_field("tools"));
            }
            continue;
        };
        if map.get("type").and_then(Value::as_str) == Some("namespace") {
            let expected_len = map
                .get("tools")
                .and_then(Value::as_array)
                .map_or(0, Vec::len);
            let ns_tools = anthropic_namespace_tools(map);
            if strict && (ns_tools.is_empty() || ns_tools.len() != expected_len) {
                return Err(unexpressible_anthropic_field("tools"));
            }
            mapped.extend(ns_tools);
            continue;
        }
        if map.get("type").and_then(Value::as_str) == Some("custom") {
            if strict
                && !map
                    .get("name")
                    .and_then(Value::as_str)
                    .is_some_and(|n| !n.trim().is_empty())
            {
                return Err(unexpressible_anthropic_field("tools"));
            }
            mapped.push(anthropic_custom_tool(map, ""));
            continue;
        }
        if let Some(function) = map.get("function").and_then(Value::as_object) {
            let raw_name = function.get("name").and_then(Value::as_str);
            if strict && !raw_name.is_some_and(|n| !n.trim().is_empty()) {
                return Err(unexpressible_anthropic_field("tools"));
            }
            let name = raw_name
                .map(|name| flattened_namespace_tool_name("", name))
                .unwrap_or_default();
            mapped.push(json!({
                "name": name,
                "description": function.get("description").map(value_to_text).unwrap_or_default(),
                "input_schema": function.get("parameters").cloned().unwrap_or_else(|| json!({ "type": "object" }))
            }));
            continue;
        }
        if let Some(name) = map.get("name").filter(|value| useful_value(value)) {
            let name = flattened_namespace_tool_name("", &value_to_text(name));
            mapped.push(json!({
                "name": name,
                "description": map.get("description").map(value_to_text).unwrap_or_default(),
                "input_schema": map.get("input_schema").or_else(|| map.get("parameters")).cloned().unwrap_or_else(|| json!({ "type": "object" }))
            }));
            continue;
        }
        if strict {
            return Err(unexpressible_anthropic_field("tools"));
        }
    }

    reject_duplicate_emulated_tool_names(
        mapped
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str)),
    )?;

    Ok((!mapped.is_empty()).then_some(Value::Array(mapped)))
}

fn anthropic_namespace_tools(namespace: &Map<String, Value>) -> Vec<Value> {
    let namespace_name = namespace
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default();

    namespace
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|tool| {
            let tool = tool.as_object()?;
            if tool.get("type").and_then(Value::as_str) == Some("custom") {
                return Some(anthropic_custom_tool(tool, namespace_name));
            }
            let function = tool
                .get("function")
                .and_then(Value::as_object)
                .unwrap_or(tool);
            let name = function.get("name").and_then(Value::as_str)?;

            Some(json!({
                "name": flattened_namespace_tool_name(namespace_name, name),
                "description": function.get("description").map(value_to_text).unwrap_or_default(),
                "input_schema": function.get("parameters").or_else(|| function.get("input_schema")).cloned().unwrap_or_else(|| json!({ "type": "object" }))
            }))
        })
        .collect()
}

fn anthropic_custom_tool(tool: &Map<String, Value>, namespace: &str) -> Value {
    let (description, parameters) = custom_tool_function_fields(tool);
    let name = tool.get("name").and_then(Value::as_str).unwrap_or_default();
    json!({
        "name": flattened_namespace_tool_name(namespace, name),
        "description": description.as_str().unwrap_or_default(),
        "input_schema": parameters
    })
}

fn anthropic_function_call_item(context: &ResponseContext, call: &ToolCall, status: &str) -> Value {
    let mut item = function_call_item(call, status);
    restore_tool_namespace(context, &mut item);
    restore_custom_tool(context, &mut item);
    item
}

// Anthropic rejects `any` and `tool` choices with HTTP 400 when extended or
// adaptive thinking is active, allowing only `auto` or `none`.
fn anthropic_thinking_enabled(thinking: Option<&Value>) -> bool {
    matches!(
        thinking
            .and_then(Value::as_object)
            .and_then(|map| map.get("type"))
            .and_then(Value::as_str),
        Some("enabled" | "adaptive")
    )
}

fn anthropic_tool_choice(
    choice: Option<&Value>,
    thinking_enabled: bool,
    strict: bool,
) -> Result<Option<Value>, StreamError> {
    let forced_with_thinking = || -> Result<Option<Value>, StreamError> {
        if strict {
            Err(unexpressible_anthropic_field("tool_choice"))
        } else {
            Ok(Some(json!({ "type": "auto" })))
        }
    };
    match choice {
        Some(Value::Object(map)) => match map.get("type").and_then(Value::as_str) {
            Some("function" | "custom") => {
                let function = map
                    .get("function")
                    .and_then(Value::as_object)
                    .unwrap_or(map);
                let Some(name) = function.get("name").and_then(Value::as_str) else {
                    return Ok(None);
                };
                if thinking_enabled {
                    return forced_with_thinking();
                }
                let namespace = function
                    .get("namespace")
                    .or_else(|| map.get("namespace"))
                    .and_then(Value::as_str);
                let name = namespace
                    .map(|namespace| flattened_namespace_tool_name(namespace, name))
                    .unwrap_or_else(|| flattened_namespace_tool_name("", name));
                Ok(Some(json!({ "type": "tool", "name": name })))
            }
            Some("tool") => {
                let Some(name) = map.get("name").and_then(Value::as_str) else {
                    return Ok(None);
                };
                if thinking_enabled {
                    return forced_with_thinking();
                }
                let name = map
                    .get("namespace")
                    .and_then(Value::as_str)
                    .map(|namespace| flattened_namespace_tool_name(namespace, name))
                    .unwrap_or_else(|| flattened_namespace_tool_name("", name));
                Ok(Some(json!({ "type": "tool", "name": name })))
            }
            Some("any" | "required") => {
                if thinking_enabled {
                    forced_with_thinking()
                } else {
                    Ok(Some(json!({ "type": "any" })))
                }
            }
            Some("auto") => Ok(Some(json!({ "type": "auto" }))),
            Some("none") => Ok(Some(json!({ "type": "none" }))),
            _type => Ok(None),
        },
        Some(Value::String(value)) if value == "auto" => Ok(Some(json!({ "type": "auto" }))),
        Some(Value::String(value)) if value == "required" || value == "any" => {
            if thinking_enabled {
                forced_with_thinking()
            } else {
                Ok(Some(json!({ "type": "any" })))
            }
        }
        Some(Value::String(value)) if value == "none" => Ok(Some(json!({ "type": "none" }))),
        _choice => Ok(None),
    }
}
