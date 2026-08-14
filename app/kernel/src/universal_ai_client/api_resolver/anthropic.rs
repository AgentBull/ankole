use super::*;

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
            usage: json!({}),
            stop_reason: None,
            terminal: false,
            next_output_index: 0,
        }
    }

    fn ingest(&mut self, context: &ResponseContext, value: Value) -> Vec<Value> {
        match value.get("type").and_then(Value::as_str) {
            Some("message_start") => self.message_start(context, &value),
            Some("content_block_start") => self.content_block_start(&value),
            Some("content_block_delta") => self.content_block_delta(&value),
            Some("content_block_stop") => self.content_block_stop(&value),
            Some("message_delta") => {
                self.message_delta(&value);
                Vec::new()
            }
            Some("message_stop") => {
                let status = match self.stop_reason.as_deref() {
                    Some("max_tokens") => "incomplete",
                    _reason => "completed",
                };
                let reason = (status == "incomplete").then_some("max_output_tokens");
                self.finish(context, status, reason)
            }
            Some("ping") | None => Vec::new(),
            Some(_event) => Vec::new(),
        }
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

    fn content_block_start(&mut self, value: &Value) -> Vec<Value> {
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
                        "item": function_call_item(&call, "in_progress")
                    }),
                );
                self.tool_calls.insert(index, call);
                vec![event]
            }
            _block => Vec::new(),
        }
    }

    fn content_block_delta(&mut self, value: &Value) -> Vec<Value> {
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
                self.tool_arguments_delta(index, partial)
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

    fn tool_arguments_delta(&mut self, index: usize, partial: &str) -> Vec<Value> {
        let Some(mut call) = self.tool_calls.get(&index).cloned() else {
            return Vec::new();
        };

        call.arguments.push_str(partial);
        let event = self.event(
            "response.function_call_arguments.delta",
            json!({
                "item_id": call.id,
                "output_index": call.output_index,
                "delta": partial
            }),
        );
        self.tool_calls.insert(index, call);
        vec![event]
    }

    fn content_block_stop(&mut self, value: &Value) -> Vec<Value> {
        let index = value.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        match self.active_blocks.get(&index).map(String::as_str) {
            Some("text") => self.finish_text_part(),
            Some("tool_use") => self.finish_tool_call(index),
            Some("reasoning") => Vec::new(),
            _block => Vec::new(),
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

        let current = block
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        block.insert(key.to_string(), json!(format!("{current}{delta}")));
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

    fn finish_tool_call(&mut self, index: usize) -> Vec<Value> {
        if self.tool_done_indices.contains(&index) {
            return Vec::new();
        }

        let Some(call) = self.tool_calls.get(&index).cloned() else {
            return Vec::new();
        };
        self.tool_done_indices.insert(index);
        vec![
            self.event(
                "response.function_call_arguments.done",
                json!({
                    "item_id": call.id,
                    "output_index": call.output_index,
                    "arguments": call.arguments
                }),
            ),
            self.event(
                "response.output_item.done",
                json!({
                    "output_index": call.output_index,
                    "item": function_call_item(&call, "completed")
                }),
            ),
        ]
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
    ) -> Vec<Value> {
        if self.terminal {
            return Vec::new();
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
            for index in self.tool_calls.keys().copied().collect::<Vec<_>>() {
                events.extend(self.finish_tool_call(index));
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
        events
    }

    fn fail(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
        if self.terminal {
            return Vec::new();
        }

        let error_event = self.event("error", json!({ "error": openresponses_error(error) }));
        let response = self.response_body(context, "failed", None, Some(error));
        self.terminal = true;
        let failed = self.event("response.failed", json!({ "response": response }));
        vec![error_event, failed]
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
        indexed_output.extend(
            self.tool_calls
                .values()
                .map(|call| (call.output_index, function_call_item(call, item_status))),
        );
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
        Ok(build_anthropic_body(context))
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        Ok(self.ingest(context, event))
    }

    fn on_upstream_close(&mut self, context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        Ok(self.finish(context, "incomplete", Some("upstream_stream_closed")))
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
        if !(200..300).contains(&status) {
            return Err(provider_body_error(status, body));
        }
        reject_provider_body_error(status, &body)?;
        Ok(anthropic_body_to_response(
            context,
            provider_object_body(status, body, "Anthropic Messages")?,
        ))
    }

    fn is_terminal(&self) -> bool {
        self.terminal
    }
}

fn anthropic_body_to_response(context: &ResponseContext, body: Value) -> Value {
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
                output.push(json!({
                    "id": generated_id("fc"),
                    "type": "function_call",
                    "call_id": block.get("id").and_then(Value::as_str).unwrap_or("call"),
                    "name": block.get("name").and_then(Value::as_str).unwrap_or("unknown"),
                    "arguments": block.get("input").map(|input| sonic_rs::to_string(input).unwrap_or_else(|_| "{}".to_string())).unwrap_or_else(|| "{}".to_string()),
                    "status": "completed"
                }));
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

    complete_response_resource(
        context,
        json!({
            "id": body.get("id").and_then(Value::as_str).map(ToOwned::to_owned).unwrap_or_else(|| generated_id("resp")),
            "object": "response",
            "created_at": now_seconds(),
            "completed_at": now_seconds(),
            "status": "completed",
            "model": body.get("model").and_then(Value::as_str).map(ToOwned::to_owned).unwrap_or_else(|| context.model.clone()),
            "output": output,
            "usage": normalize_anthropic_usage(body.get("usage").unwrap_or(&Value::Null)),
            "metadata": {}
        }),
    )
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

fn build_anthropic_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let mut body = context
        .provider_options
        .as_object()
        .cloned()
        .unwrap_or_default();

    maybe_put_from(&mut body, &request, "instructions");
    if let Some(system) = body.remove("instructions") {
        body.insert("system".to_string(), system);
    }

    body.insert(
        "max_tokens".to_string(),
        request
            .get("max_output_tokens")
            .or_else(|| request.get("max_tokens"))
            .cloned()
            .filter(useful_value)
            .unwrap_or_else(|| json!(4096)),
    );

    for key in ["temperature", "top_p", "metadata"] {
        maybe_put_from(&mut body, &request, key);
    }

    if let Some(tools) = anthropic_tools(request.get("tools")) {
        body.insert("tools".to_string(), tools);
    }

    if let Some(tool_choice) = anthropic_tool_choice(request.get("tool_choice")) {
        body.insert("tool_choice".to_string(), tool_choice);
    }

    if context.include_model {
        body.insert("model".to_string(), json!(context.model));
    }
    body.insert(
        "stream".to_string(),
        request.get("stream").cloned().unwrap_or(Value::Bool(false)),
    );
    body.insert(
        "messages".to_string(),
        anthropic_messages(context, request.get("input")),
    );
    body
}

// One Anthropic assistant turn arrives back as several Responses items: a
// `reasoning` item, an assistant `message`, and one `function_call` for each tool
// use. Replay merges each run of assistant items into one message and puts the
// decoded `thinking` blocks in front, which is the order Claude requires. Merging
// by adjacency needs no count of derived items, so a history that lost or
// reordered items degrades into a turn without private reasoning instead of a
// failed request.
fn anthropic_messages(context: &ResponseContext, input: Option<&Value>) -> Value {
    match input {
        Some(Value::String(text)) => json!([
            {"role": "user", "content": [{"type": "text", "text": text}]}
        ]),
        Some(Value::Array(items)) => {
            let mut replay = AnthropicReplay::default();

            for item in items {
                let Some(map) = item.as_object() else {
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
                    Some("function_call") => replay.push_assistant(vec![anthropic_tool_use(map)]),
                    Some("function_call_output") => replay.push_user(json!([{
                        "type": "tool_result",
                        "tool_use_id": map.get("call_id").map(value_to_text).unwrap_or_default(),
                        "content": map.get("output").map(value_to_text).unwrap_or_default()
                    }])),
                    _type => replay.push_item(map),
                }
            }

            Value::Array(replay.finish())
        }
        _input => json!([]),
    }
}

#[derive(Debug, Default)]
struct AnthropicReplay {
    messages: Vec<Value>,
    assistant_blocks: Vec<Value>,
    pending_thinking: Vec<Value>,
}

impl AnthropicReplay {
    fn push_assistant(&mut self, mut blocks: Vec<Value>) {
        if self.assistant_blocks.is_empty() {
            self.assistant_blocks.append(&mut self.pending_thinking);
        }
        self.assistant_blocks.append(&mut blocks);
    }

    fn push_user(&mut self, content: Value) {
        self.flush_assistant();
        self.pending_thinking.clear();
        self.messages
            .push(json!({"role": "user", "content": content}));
    }

    // An item with no content is not a message. Anthropic rejects an empty
    // content array, so an item this adapter does not model is dropped instead of
    // being sent as an empty one.
    fn push_item(&mut self, map: &Map<String, Value>) {
        let Some(content) = map.get("content") else {
            return;
        };
        match anthropic_role(map.get("role").and_then(Value::as_str)) {
            "assistant" => match anthropic_content(Some(content)) {
                Value::Array(blocks) => self.push_assistant(blocks),
                _content => {}
            },
            _role => self.push_user(anthropic_content(Some(content))),
        }
    }

    fn flush_assistant(&mut self) {
        if self.assistant_blocks.is_empty() {
            return;
        }
        let content = std::mem::take(&mut self.assistant_blocks);
        self.messages
            .push(json!({"role": "assistant", "content": content}));
    }

    fn finish(mut self) -> Vec<Value> {
        self.flush_assistant();
        self.messages
    }
}

fn anthropic_tool_use(call: &Map<String, Value>) -> Value {
    let input = call
        .get("arguments")
        .and_then(Value::as_str)
        .and_then(|arguments| serde_json::from_str::<Value>(arguments).ok())
        .unwrap_or_else(|| json!({}));

    json!({
        "type": "tool_use",
        "id": call.get("call_id").map(value_to_text).unwrap_or_default(),
        "name": call.get("name").map(value_to_text).unwrap_or_default(),
        "input": input
    })
}

fn anthropic_role(role: Option<&str>) -> &'static str {
    match role {
        Some("assistant") => "assistant",
        _role => "user",
    }
}

fn anthropic_content(content: Option<&Value>) -> Value {
    match content {
        Some(Value::String(text)) => json!([{ "type": "text", "text": text }]),
        Some(Value::Array(parts)) => Value::Array(
            parts
                .iter()
                .map(|part| {
                    let Some(map) = part.as_object() else {
                        return json!({ "type": "text", "text": value_to_text(part) });
                    };
                    match map.get("type").and_then(Value::as_str) {
                        Some("input_text" | "output_text" | "text") => json!({
                            "type": "text",
                            "text": map.get("text").map(value_to_text).unwrap_or_default()
                        }),
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
                        Some("input_image" | "image_url" | "image") => anthropic_image_part(map),
                        _type => unsupported_anthropic_content_part(map, part),
                    }
                })
                .collect(),
        ),
        Some(value) => json!([{ "type": "text", "text": value_to_text(value) }]),
        None => json!([]),
    }
}

fn anthropic_image_part(map: &Map<String, Value>) -> Value {
    let Some(url) = anthropic_image_url(map) else {
        return anthropic_image_placeholder();
    };

    if let Some((media_type, data)) = parse_image_data_url(&url) {
        return json!({
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": media_type,
                "data": data
            }
        });
    }

    if url.starts_with("https://") || url.starts_with("http://") {
        return json!({
            "type": "image",
            "source": {
                "type": "url",
                "url": url
            }
        });
    }

    anthropic_image_placeholder()
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

fn unsupported_anthropic_content_part(map: &Map<String, Value>, part: &Value) -> Value {
    if binaryish_content_part(map) {
        return anthropic_image_placeholder();
    }

    json!({ "type": "text", "text": value_to_text(part) })
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

fn anthropic_tools(tools: Option<&Value>) -> Option<Value> {
    let tools = tools?.as_array()?;
    let mapped: Vec<Value> = tools
        .iter()
        .filter_map(|tool| {
            let map = tool.as_object()?;
            if let Some(function) = map.get("function").and_then(Value::as_object) {
                return Some(json!({
                    "name": function.get("name").map(value_to_text).unwrap_or_default(),
                    "description": function.get("description").map(value_to_text).unwrap_or_default(),
                    "input_schema": function.get("parameters").cloned().unwrap_or_else(|| json!({ "type": "object" }))
                }));
            }
            if let Some(name) = map.get("name").filter(|value| useful_value(value)) {
                return Some(json!({
                    "name": value_to_text(name),
                    "description": map.get("description").map(value_to_text).unwrap_or_default(),
                    "input_schema": map.get("input_schema").or_else(|| map.get("parameters")).cloned().unwrap_or_else(|| json!({ "type": "object" }))
                }));
            }
            None
        })
        .collect();

    (!mapped.is_empty()).then_some(Value::Array(mapped))
}

fn anthropic_tool_choice(choice: Option<&Value>) -> Option<Value> {
    match choice {
        Some(Value::Object(map)) => match map.get("type").and_then(Value::as_str) {
            Some("function") => map
                .get("function")
                .and_then(Value::as_object)
                .and_then(|function| function.get("name"))
                .and_then(Value::as_str)
                .map(|name| json!({ "type": "tool", "name": name })),
            Some("tool") if map.get("name").and_then(Value::as_str).is_some() => {
                Some(Value::Object(map.clone()))
            }
            _type => None,
        },
        Some(Value::String(value)) if value == "auto" => Some(json!({ "type": "auto" })),
        Some(Value::String(value)) if value == "none" => Some(json!({ "type": "none" })),
        _choice => None,
    }
}
