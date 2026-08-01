use super::*;
use crate::common::{base64_url_safe_decode, base64_url_safe_encode};

const CHAT_REASONING_PREFIX: &str = "ankole-aigateway-chat-reasoning-v1:";

#[derive(Debug, Clone, Default)]
struct ChatReasoning {
    details: Vec<Value>,
    text: String,
}

impl ChatReasoning {
    fn is_empty(&self) -> bool {
        self.details.is_empty() && self.text.is_empty()
    }

    fn append_delta(&mut self, delta: &Value) -> Result<bool, StreamError> {
        let mut appended = false;

        match delta.get("reasoning_details") {
            Some(Value::Array(details)) => {
                self.details.extend(details.iter().cloned());
                appended = !details.is_empty();
            }
            Some(Value::Null) | None => {}
            Some(_invalid) => {
                return Err(invalid_chat_reasoning(
                    "provider reasoning_details must be an array",
                ));
            }
        }

        match delta.get("reasoning") {
            Some(Value::String(text)) => {
                self.text.push_str(text);
                appended |= !text.is_empty();
            }
            Some(Value::Null) | None => {}
            Some(_invalid) => {
                return Err(invalid_chat_reasoning(
                    "provider reasoning must be a string",
                ));
            }
        }

        Ok(appended)
    }

    fn from_message(message: &Value) -> Result<Self, StreamError> {
        let mut reasoning = Self::default();
        reasoning.append_delta(message)?;
        Ok(reasoning)
    }

    fn encoded_content(&self) -> String {
        let payload = json!({
            "reasoning_details": self.details,
            "reasoning": self.text
        });
        let encoded = payload.to_string();

        format!(
            "{CHAT_REASONING_PREFIX}{}",
            base64_url_safe_encode(encoded.as_bytes())
        )
    }

    fn decode_item(item: &Map<String, Value>) -> Result<Self, StreamError> {
        let encoded = item
            .get("encrypted_content")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                invalid_chat_reasoning("reasoning replay requires AIGateway encrypted_content")
            })?;
        let payload = encoded.strip_prefix(CHAT_REASONING_PREFIX).ok_or_else(|| {
            invalid_chat_reasoning(
                "AIGateway cannot replay reasoning from another provider implementation",
            )
        })?;
        let decoded = base64_url_safe_decode(payload)
            .map_err(|_| invalid_chat_reasoning("reasoning encrypted_content is not Base64URL"))?;
        let value: Value = serde_json::from_slice(&decoded)
            .map_err(|_| invalid_chat_reasoning("reasoning encrypted_content is not valid JSON"))?;
        let object = value.as_object().ok_or_else(|| {
            invalid_chat_reasoning("reasoning encrypted_content must contain an object")
        })?;

        let details = match object.get("reasoning_details") {
            Some(Value::Array(details)) => details.clone(),
            Some(Value::Null) | None => Vec::new(),
            Some(_invalid) => {
                return Err(invalid_chat_reasoning(
                    "reasoning encrypted_content has invalid reasoning_details",
                ));
            }
        };
        let text = match object.get("reasoning") {
            Some(Value::String(text)) => text.clone(),
            Some(Value::Null) | None => String::new(),
            Some(_invalid) => {
                return Err(invalid_chat_reasoning(
                    "reasoning encrypted_content has invalid reasoning text",
                ));
            }
        };

        let reasoning = Self { details, text };
        if reasoning.is_empty() {
            return Err(invalid_chat_reasoning(
                "reasoning encrypted_content contains no replayable reasoning",
            ));
        }
        Ok(reasoning)
    }

    fn extend(&mut self, mut other: Self) {
        self.details.append(&mut other.details);
        self.text.push_str(&other.text);
    }

    fn apply_to_message(&self, message: &mut Map<String, Value>) {
        if !self.details.is_empty() {
            message.insert(
                "reasoning_details".to_string(),
                Value::Array(self.details.clone()),
            );
        }
        if !self.text.is_empty() {
            message.insert("reasoning".to_string(), json!(self.text));
        }
    }
}

#[derive(Debug, Clone)]
pub(super) struct ToolCall {
    pub(super) id: String,
    pub(super) call_id: String,
    pub(super) name: String,
    pub(super) arguments: String,
    pub(super) output_index: usize,
}

#[derive(Debug)]
pub(super) struct ChatState {
    sequence: u64,
    response_started: bool,
    response_id: Option<String>,
    upstream_id: Option<String>,
    created_at: Option<i64>,
    model: Option<String>,
    message_item_id: Option<String>,
    message_output_index: Option<usize>,
    content_started: bool,
    output_text: String,
    reasoning: ChatReasoning,
    reasoning_item_id: Option<String>,
    reasoning_output_index: Option<usize>,
    tool_calls: BTreeMap<usize, ToolCall>,
    usage: Value,
    terminal: bool,
    pending_status: Option<String>,
    pending_incomplete_reason: Option<String>,
    next_output_index: usize,
}

impl ChatState {
    pub(super) fn new(model: String) -> Self {
        Self {
            sequence: 0,
            response_started: false,
            response_id: None,
            upstream_id: None,
            created_at: None,
            model: (!model.is_empty()).then_some(model),
            message_item_id: None,
            message_output_index: None,
            content_started: false,
            output_text: String::new(),
            reasoning: ChatReasoning::default(),
            reasoning_item_id: None,
            reasoning_output_index: None,
            tool_calls: BTreeMap::new(),
            usage: json!({}),
            terminal: false,
            pending_status: None,
            pending_incomplete_reason: None,
            next_output_index: 0,
        }
    }

    pub(super) fn set_usage(&mut self, usage: Value) {
        self.usage = usage;
    }

    pub(super) fn next_tool_call_index(&self) -> usize {
        self.tool_calls.len()
    }

    pub(super) fn is_terminal(&self) -> bool {
        self.terminal
    }

    fn ingest_openai_chat(
        &mut self,
        context: &ResponseContext,
        chunk: Value,
    ) -> Result<Vec<Value>, StreamError> {
        if chunk.get("error").is_some_and(|error| !error.is_null()) {
            return Err(provider_body_error(200, chunk));
        }

        self.put_chat_metadata(&chunk);
        if let Some(usage) = chunk.get("usage").filter(|value| value.is_object()) {
            self.usage = usage.clone();
        }

        let mut events = self.ensure_response_started(context);
        let choice = chunk
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|choices| choices.first())
            .cloned()
            .unwrap_or_else(|| json!({}));
        let delta = choice.get("delta").cloned().unwrap_or_else(|| json!({}));

        let terminal_pending = self.pending_status.is_some();

        if !terminal_pending {
            events.extend(self.reasoning_delta(&delta)?);

            if let Some(content) = delta.get("content").and_then(Value::as_str)
                && !content.is_empty()
            {
                events.extend(self.text_delta(content));
            }

            if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
                for tool_call in tool_calls {
                    events.extend(self.tool_call_delta(context, tool_call));
                }
            }
        }

        if let Some(finish_reason) = choice.get("finish_reason").and_then(Value::as_str) {
            let (status, reason) = match finish_reason {
                "length" => ("incomplete", Some("max_output_tokens")),
                _reason => ("completed", None),
            };
            self.pending_status = Some(status.to_string());
            self.pending_incomplete_reason = reason.map(ToOwned::to_owned);
        }

        Ok(events)
    }

    fn reasoning_delta(&mut self, delta: &Value) -> Result<Vec<Value>, StreamError> {
        if !self.reasoning.append_delta(delta)? {
            return Ok(Vec::new());
        }

        if self.reasoning_item_id.is_some() {
            return Ok(Vec::new());
        }

        let item_id = generated_id("rs");
        let output_index = self.next_output_index;
        self.next_output_index += 1;
        self.reasoning_item_id = Some(item_id.clone());
        self.reasoning_output_index = Some(output_index);

        Ok(vec![self.event(
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
        )])
    }

    fn put_chat_metadata(&mut self, chunk: &Value) {
        if self.upstream_id.is_none() {
            self.upstream_id = chunk
                .get("id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
        }
        if self.response_id.is_none() {
            self.response_id = self
                .upstream_id
                .clone()
                .or_else(|| Some(generated_id("resp")));
        }
        if self.created_at.is_none() {
            self.created_at = chunk
                .get("created")
                .and_then(Value::as_i64)
                .or_else(|| Some(now_seconds()));
        }
        if let Some(model) = chunk.get("model").and_then(Value::as_str) {
            self.model = Some(model.to_string());
        }
    }

    pub(super) fn ensure_response_started(&mut self, context: &ResponseContext) -> Vec<Value> {
        if self.response_started {
            return Vec::new();
        }

        self.response_started = true;
        vec![self.event(
            "response.created",
            json!({ "response": self.response_body(context, "in_progress", None, None) }),
        )]
    }

    pub(super) fn text_delta(&mut self, text: &str) -> Vec<Value> {
        let mut events = Vec::new();
        let (item_id, output_index) = self.ensure_message_item(&mut events);

        if !self.content_started {
            self.content_started = true;
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

        self.output_text.push_str(text);
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

    pub(super) fn tool_call_delta(
        &mut self,
        context: &ResponseContext,
        delta: &Value,
    ) -> Vec<Value> {
        let mut events = Vec::new();
        let index = delta
            .get("index")
            .and_then(Value::as_u64)
            .map(|value| value as usize)
            .unwrap_or_else(|| self.tool_calls.len());
        let function = delta.get("function").unwrap_or(&Value::Null);
        let is_new = !self.tool_calls.contains_key(&index);

        let output_index = if let Some(call) = self.tool_calls.get(&index) {
            call.output_index
        } else {
            let value = self.next_output_index;
            self.next_output_index += 1;
            value
        };

        let mut call = self
            .tool_calls
            .get(&index)
            .cloned()
            .unwrap_or_else(|| ToolCall {
                id: generated_id("fc"),
                call_id: delta
                    .get("id")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned)
                    .unwrap_or_else(|| generated_id("call")),
                name: "unknown".to_string(),
                arguments: String::new(),
                output_index,
            });

        if let Some(call_id) = delta.get("id").and_then(Value::as_str) {
            call.call_id = call_id.to_string();
        }
        if let Some(name) = function.get("name").and_then(Value::as_str) {
            call.name = name.to_string();
        }

        if is_new {
            events.push(self.event(
                "response.output_item.added",
                json!({
                    "output_index": output_index,
                    "item": chat_function_call_item(context, &call, "in_progress")
                }),
            ));
        }

        if let Some(arguments) = function.get("arguments").and_then(Value::as_str)
            && !arguments.is_empty()
        {
            call.arguments.push_str(arguments);
            if !chat_custom_tool(context, &call.name) {
                events.push(self.event(
                    "response.function_call_arguments.delta",
                    json!({
                        "item_id": call.id,
                        "output_index": output_index,
                        "delta": arguments
                    }),
                ));
            }
        }

        self.tool_calls.insert(index, call);
        events
    }

    pub(super) fn finish(
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
        let completed = status == "completed";

        if completed && !self.reasoning.is_empty() {
            let output_index = self.reasoning_output_index.unwrap_or(0);
            events.push(self.event(
                "response.output_item.done",
                json!({
                    "output_index": output_index,
                    "item": self.reasoning_item("completed")
                }),
            ));
        }

        if completed && self.content_started {
            let item_id = self
                .message_item_id
                .clone()
                .unwrap_or_else(|| generated_id("msg"));
            let output_index = self.message_output_index.unwrap_or(0);
            events.push(self.event(
                "response.output_text.done",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": 0,
                    "text": self.output_text
                }),
            ));
            events.push(self.event(
                "response.content_part.done",
                json!({
                    "item_id": item_id,
                    "output_index": output_index,
                    "content_index": 0,
                    "part": {"type": "output_text", "text": self.output_text, "annotations": []}
                }),
            ));
            events.push(self.event(
                "response.output_item.done",
                json!({
                    "output_index": output_index,
                    "item": self.message_item("completed")
                }),
            ));
        }

        if completed {
            for call in self.tool_calls.values().cloned().collect::<Vec<_>>() {
                if chat_custom_tool(context, &call.name) {
                    events.push(self.event(
                        "response.custom_tool_call_input.done",
                        json!({
                            "item_id": call.id,
                            "output_index": call.output_index,
                            "input": custom_tool_input(&call.arguments)
                        }),
                    ));
                } else {
                    events.push(self.event(
                        "response.function_call_arguments.done",
                        json!({
                            "item_id": call.id,
                            "output_index": call.output_index,
                            "arguments": call.arguments
                        }),
                    ));
                }
                events.push(self.event(
                    "response.output_item.done",
                    json!({
                        "output_index": call.output_index,
                        "item": chat_function_call_item(context, &call, "completed")
                    }),
                ));
            }
        }

        let event_type = terminal_event(status);
        events.push(self.event(
            event_type,
            json!({
                "response": self.response_body(context, status, incomplete_reason, None)
            }),
        ));
        events
    }

    pub(super) fn fail(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
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
        if !self.reasoning.is_empty() {
            indexed_output.push((
                self.reasoning_output_index.unwrap_or(0),
                self.reasoning_item(item_status),
            ));
        }
        if self.content_started {
            indexed_output.push((
                self.message_output_index.unwrap_or(0),
                self.message_item(item_status),
            ));
        }
        let mut calls = self.tool_calls.values().cloned().collect::<Vec<_>>();
        calls.sort_by_key(|call| call.output_index);
        indexed_output.extend(calls.iter().map(|call| {
            (
                call.output_index,
                chat_function_call_item(context, call, item_status),
            )
        }));
        indexed_output.sort_by_key(|(output_index, _item)| *output_index);
        let output = indexed_output
            .into_iter()
            .map(|(_output_index, item)| item)
            .collect::<Vec<_>>();

        let created_at = self.created_at.unwrap_or_else(now_seconds);
        complete_response_resource(
            context,
            json!({
                "id": self.response_id.clone().unwrap_or_else(|| generated_id("resp")),
                "object": "response",
                "created_at": created_at,
                "completed_at": if status == "completed" { json!(now_seconds()) } else { Value::Null },
                "status": status,
                "incomplete_details": incomplete_reason.map(|reason| json!({"reason": reason})).unwrap_or(Value::Null),
                "model": self.model.clone().unwrap_or_else(|| context.model.clone()),
                "output": output,
                "usage": normalize_response_usage(&self.usage),
                "error": error.map(openresponses_error).unwrap_or(Value::Null),
                "metadata": {}
            }),
        )
    }

    fn message_item(&self, status: &str) -> Value {
        json!({
            "id": self.message_item_id.clone().unwrap_or_else(|| generated_id("msg")),
            "type": "message",
            "status": status,
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": self.output_text,
                "annotations": []
            }]
        })
    }

    fn reasoning_item(&self, status: &str) -> Value {
        json!({
            "id": self
                .reasoning_item_id
                .clone()
                .unwrap_or_else(|| generated_id("rs")),
            "type": "reasoning",
            "status": status,
            "encrypted_content": self.reasoning.encoded_content(),
            "summary": []
        })
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

pub(super) fn response_item_status(response_status: &str) -> &str {
    match response_status {
        "completed" => "completed",
        "in_progress" => "in_progress",
        _status => "incomplete",
    }
}

impl APIProtocol for ChatState {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        build_openai_chat_body(context)
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        self.ingest_openai_chat(context, event)
    }

    fn on_upstream_close(&mut self, context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        if let Some(status) = self.pending_status.clone() {
            let reason = self.pending_incomplete_reason.clone();
            return Ok(self.finish(context, &status, reason.as_deref()));
        }

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
        chat_completion_body_to_response(
            context,
            provider_object_body(status, body, "OpenAI Chat Completions")?,
        )
    }

    fn is_terminal(&self) -> bool {
        self.terminal
    }
}

fn chat_completion_body_to_response(
    context: &ResponseContext,
    body: Value,
) -> Result<Value, StreamError> {
    let message = body
        .pointer("/choices/0/message")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let id = body
        .get("id")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| generated_id("resp"));
    let created_at =
        integer_value(body.get("created").unwrap_or(&Value::Null)).unwrap_or_else(now_seconds);
    let model = body
        .get("model")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| context.model.clone());

    let output = chat_output_items(context, &message)?;
    Ok(complete_response_resource(
        context,
        json!({
            "id": id,
            "object": "response",
            "created_at": created_at,
            "completed_at": created_at,
            "status": "completed",
            "model": model,
            "output": output,
            "usage": normalize_response_usage(body.get("usage").unwrap_or(&Value::Null)),
            "metadata": {}
        }),
    ))
}

fn chat_output_items(context: &ResponseContext, message: &Value) -> Result<Value, StreamError> {
    let content = message.get("content").unwrap_or(&Value::Null);
    let mut items = Vec::new();
    let content_parts = chat_assistant_content_parts(content);
    let reasoning = ChatReasoning::from_message(message)?;

    if !reasoning.is_empty() {
        items.push(chat_reasoning_item(&reasoning, "completed"));
    }

    if !content_parts.is_empty() {
        items.push(json!({
            "id": generated_id("msg"),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": content_parts
        }));
    }

    if let Some(tool_calls) = message.get("tool_calls").and_then(Value::as_array) {
        for tool_call in tool_calls {
            let function = tool_call.get("function").unwrap_or(&Value::Null);
            let name = function
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("unknown");
            let arguments = function
                .get("arguments")
                .map(value_to_string)
                .unwrap_or_else(|| "{}".to_string());
            let mut item = json!({
                "id": generated_id("fc"),
                "type": "function_call",
                "call_id": tool_call.get("id").and_then(Value::as_str).unwrap_or("call"),
                "name": name,
                "arguments": arguments,
                "status": "completed"
            });
            restore_tool_namespace(context, &mut item);
            restore_custom_tool(context, &mut item);
            items.push(item);
        }
    }

    if items.is_empty() {
        items.push(json!({
            "id": generated_id("msg"),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "", "annotations": []}]
        }));
    }

    Ok(Value::Array(items))
}

fn chat_reasoning_item(reasoning: &ChatReasoning, status: &str) -> Value {
    json!({
        "id": generated_id("rs"),
        "type": "reasoning",
        "status": status,
        "encrypted_content": reasoning.encoded_content(),
        "summary": []
    })
}

fn invalid_chat_reasoning(message: impl Into<String>) -> StreamError {
    StreamError::new("invalid_reasoning_replay", "api_resolver", message)
}

fn chat_assistant_content_parts(content: &Value) -> Vec<Value> {
    match content {
        Value::String(text) => output_text_part(text).into_iter().collect(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(chat_assistant_content_part)
            .collect(),
        Value::Null => Vec::new(),
        value => output_text_part(&value_to_string(value))
            .into_iter()
            .collect(),
    }
}

fn chat_assistant_content_part(part: &Value) -> Option<Value> {
    match part {
        Value::String(text) => output_text_part(text),
        Value::Object(map) => match map.get("type").and_then(Value::as_str) {
            Some("output_text" | "text" | "input_text") => map
                .get("text")
                .map(value_to_text)
                .and_then(|text| output_text_part(&text)),
            Some("refusal") => map
                .get("refusal")
                .or_else(|| map.get("text"))
                .map(value_to_text)
                .and_then(|text| output_text_part(&text)),
            _type => map
                .get("text")
                .map(value_to_text)
                .and_then(|text| output_text_part(&text)),
        },
        _part => None,
    }
}

fn output_text_part(text: &str) -> Option<Value> {
    if text.trim().is_empty() {
        None
    } else {
        Some(json!({
            "type": "output_text",
            "text": text,
            "annotations": []
        }))
    }
}

fn build_openai_chat_body(context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
    let request = context.resolved_provider_request_object();
    let stream = request
        .get("stream")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let mut body = provider_options_object(context);

    if let Some(extra_body) = request.get("extra_body").and_then(Value::as_object) {
        merge_object(&mut body, extra_body);
    }

    for key in [
        "temperature",
        "top_p",
        "presence_penalty",
        "frequency_penalty",
        "parallel_tool_calls",
        "service_tier",
        "user",
        "top_logprobs",
        "metadata",
    ] {
        maybe_put_from(&mut body, &request, key);
    }

    if let Some(response_format) = chat_response_format(&request) {
        body.insert("response_format".to_string(), response_format);
    }

    if let Some(value) = request
        .get("max_output_tokens")
        .or_else(|| request.get("max_tokens"))
        .cloned()
        .filter(useful_value)
    {
        body.insert("max_tokens".to_string(), value);
    }

    if let Some(tools) = chat_tools(request.get("tools")) {
        body.insert("tools".to_string(), tools);
    }

    if let Some(tool_choice) = chat_tool_choice(request.get("tool_choice")) {
        body.insert("tool_choice".to_string(), tool_choice);
    }

    if let Some(stream_options) = chat_stream_options(request.get("stream_options"), stream) {
        body.insert("stream_options".to_string(), stream_options);
    }

    if context.include_model {
        put_default_if_useful(&mut body, "model", json!(context.model));
    }
    body.insert("stream".to_string(), json!(stream));
    body.insert("messages".to_string(), chat_messages(context, &request)?);
    Ok(body)
}

fn chat_response_format(request: &Map<String, Value>) -> Option<Value> {
    if let Some(value) = request
        .get("response_format")
        .filter(|value| value.is_object())
    {
        return Some(value.clone());
    }

    let format = request.get("text")?.get("format")?;
    match format.get("type").and_then(Value::as_str) {
        Some("json_schema") => {
            let mut json_schema = Map::new();
            json_schema.insert(
                "name".to_string(),
                format
                    .get("name")
                    .cloned()
                    .unwrap_or_else(|| json!("response")),
            );
            maybe_put_from(&mut json_schema, format.as_object()?, "description");
            maybe_put_from(&mut json_schema, format.as_object()?, "schema");
            maybe_put_from(&mut json_schema, format.as_object()?, "strict");
            Some(json!({ "type": "json_schema", "json_schema": json_schema }))
        }
        Some("json_object") => Some(json!({ "type": "json_object" })),
        _value => None,
    }
}

fn chat_stream_options(value: Option<&Value>, stream: bool) -> Option<Value> {
    if !stream {
        return None;
    }

    let mut options = value
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    options
        .entry("include_usage".to_string())
        .or_insert_with(|| json!(true));
    Some(Value::Object(options))
}

fn chat_messages(
    context: &ResponseContext,
    request: &Map<String, Value>,
) -> Result<Value, StreamError> {
    let mut messages = Vec::new();
    let input = request.get("input");

    if let Some(system_content) = chat_system_content(request, input) {
        messages.push(json!({ "role": "system", "content": system_content }));
    }

    match input {
        Some(Value::String(text)) => messages.push(json!({ "role": "user", "content": text })),
        Some(Value::Array(items)) => {
            let mut pending_tool_calls = Vec::new();
            let mut pending_tool_output_images = Vec::new();
            let mut pending_reasoning = ChatReasoning::default();
            for item in items {
                match item {
                    Value::Object(map) => {
                        if is_chat_system_message(map) {
                            continue;
                        }

                        let item_type = map.get("type").and_then(Value::as_str);
                        if !matches!(
                            item_type,
                            Some("function_call_output" | "custom_tool_call_output")
                        ) {
                            flush_chat_tool_output_images(
                                &mut messages,
                                &mut pending_tool_output_images,
                            );
                        }

                        match item_type {
                            Some("reasoning") => {
                                flush_chat_tool_calls(
                                    &mut messages,
                                    &mut pending_tool_calls,
                                    &mut pending_reasoning,
                                );
                                pending_reasoning.extend(ChatReasoning::decode_item(map)?);
                                continue;
                            }
                            Some("function_call") => {
                                pending_tool_calls.push(chat_function_call(context, map)?);
                                continue;
                            }
                            Some("custom_tool_call") => {
                                pending_tool_calls.push(chat_custom_tool_call(map)?);
                                continue;
                            }
                            Some("function_call_output") => {
                                flush_chat_tool_calls(
                                    &mut messages,
                                    &mut pending_tool_calls,
                                    &mut pending_reasoning,
                                );
                                let (tool_message, image_parts) = chat_function_call_output(map);
                                messages.push(tool_message);
                                pending_tool_output_images.extend(image_parts);
                                continue;
                            }
                            Some("custom_tool_call_output") => {
                                flush_chat_tool_calls(
                                    &mut messages,
                                    &mut pending_tool_calls,
                                    &mut pending_reasoning,
                                );
                                let (tool_message, image_parts) = chat_function_call_output(map);
                                messages.push(tool_message);
                                pending_tool_output_images.extend(image_parts);
                                continue;
                            }
                            Some("agent_message") => {
                                flush_chat_tool_calls(
                                    &mut messages,
                                    &mut pending_tool_calls,
                                    &mut pending_reasoning,
                                );
                                push_chat_message(
                                    &mut messages,
                                    chat_agent_message(map)?,
                                    &mut pending_reasoning,
                                );
                                continue;
                            }
                            _type => {}
                        }

                        flush_chat_tool_calls(
                            &mut messages,
                            &mut pending_tool_calls,
                            &mut pending_reasoning,
                        );
                        let role = map
                            .get("role")
                            .and_then(Value::as_str)
                            .map(normalize_chat_role);
                        let content = map.get("content");
                        match (role, content) {
                            (Some(role), Some(content)) => push_chat_message(
                                &mut messages,
                                chat_role_content_message(role, content, map),
                                &mut pending_reasoning,
                            ),
                            _ => {
                                discard_unattached_chat_reasoning(&mut pending_reasoning);
                                messages.push(json!({
                                    "role": "user",
                                    "content": value_to_text(item)
                                }));
                            }
                        }
                    }
                    value => {
                        flush_chat_tool_output_images(
                            &mut messages,
                            &mut pending_tool_output_images,
                        );
                        flush_chat_tool_calls(
                            &mut messages,
                            &mut pending_tool_calls,
                            &mut pending_reasoning,
                        );
                        discard_unattached_chat_reasoning(&mut pending_reasoning);
                        messages.push(json!({ "role": "user", "content": value_to_text(value) }))
                    }
                }
            }
            flush_chat_tool_calls(
                &mut messages,
                &mut pending_tool_calls,
                &mut pending_reasoning,
            );
            discard_unattached_chat_reasoning(&mut pending_reasoning);
            flush_chat_tool_output_images(&mut messages, &mut pending_tool_output_images);
        }
        _input => {}
    }

    Ok(Value::Array(messages))
}

// Several OpenAI-compatible chat backends accept only one system message at
// index zero, so preserve all higher-priority text in one leading message.
fn chat_system_content(request: &Map<String, Value>, input: Option<&Value>) -> Option<String> {
    let mut contents = Vec::new();

    if let Some(instructions) = request.get("instructions") {
        let text = chat_text_content(instructions);
        if !text.is_empty() {
            contents.push(text);
        }
    }

    if let Some(Value::Array(items)) = input {
        contents.extend(items.iter().filter_map(|item| {
            let map = item.as_object()?;
            if !is_chat_system_message(map) {
                return None;
            }

            let text = chat_text_content(map.get("content").unwrap_or(&Value::Null));
            (!text.is_empty()).then_some(text)
        }));
    }

    (!contents.is_empty()).then(|| contents.join("\n\n"))
}

fn is_chat_system_message(map: &Map<String, Value>) -> bool {
    matches!(
        map.get("role").and_then(Value::as_str),
        Some("developer" | "system")
    )
}

fn flush_chat_tool_calls(
    messages: &mut Vec<Value>,
    pending_tool_calls: &mut Vec<Value>,
    pending_reasoning: &mut ChatReasoning,
) {
    if pending_tool_calls.is_empty() {
        return;
    }

    let mut message = Map::from_iter([
        ("role".to_string(), json!("assistant")),
        ("content".to_string(), Value::Null),
        (
            "tool_calls".to_string(),
            Value::Array(std::mem::take(pending_tool_calls)),
        ),
    ]);
    pending_reasoning.apply_to_message(&mut message);
    *pending_reasoning = ChatReasoning::default();
    messages.push(Value::Object(message));
}

fn push_chat_message(
    messages: &mut Vec<Value>,
    mut message: Value,
    pending_reasoning: &mut ChatReasoning,
) {
    if message.get("role").and_then(Value::as_str) == Some("assistant") {
        if let Some(message) = message.as_object_mut() {
            pending_reasoning.apply_to_message(message);
            *pending_reasoning = ChatReasoning::default();
        }
    } else {
        discard_unattached_chat_reasoning(pending_reasoning);
    }
    messages.push(message);
}

fn discard_unattached_chat_reasoning(pending_reasoning: &mut ChatReasoning) {
    *pending_reasoning = ChatReasoning::default();
}

fn flush_chat_tool_output_images(messages: &mut Vec<Value>, image_parts: &mut Vec<Value>) {
    if image_parts.is_empty() {
        return;
    }

    messages.push(json!({
        "role": "user",
        "content": std::mem::take(image_parts)
    }));
}

fn chat_function_call(
    _context: &ResponseContext,
    map: &Map<String, Value>,
) -> Result<Value, StreamError> {
    let call_id = map
        .get("call_id")
        .map(value_to_text)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| generated_id("call"));
    let name = map
        .get("name")
        .map(value_to_text)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let name = match map
        .get("namespace")
        .and_then(Value::as_str)
        .filter(|namespace| !namespace.is_empty())
    {
        Some(namespace) => flattened_namespace_tool_name(namespace, &name),
        None => name,
    };
    let arguments = map
        .get("arguments")
        .map(value_to_string)
        .unwrap_or_else(|| "{}".to_string());

    Ok(json!({
        "id": call_id,
        "type": "function",
        "function": {
            "name": name,
            "arguments": arguments
        }
    }))
}

fn chat_custom_tool_call(map: &Map<String, Value>) -> Result<Value, StreamError> {
    let call_id = map
        .get("call_id")
        .map(value_to_text)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| generated_id("call"));
    let name = map
        .get("name")
        .map(value_to_text)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".to_string());
    let input = map.get("input").map(value_to_text).unwrap_or_default();
    let arguments = serde_json::to_string(&json!({ "input": input })).map_err(|error| {
        StreamError::new("custom_tool_encode_failed", "request", error.to_string())
    })?;

    Ok(json!({
        "id": call_id,
        "type": "function",
        "function": {
            "name": name,
            "arguments": arguments
        }
    }))
}

fn chat_function_call_output(map: &Map<String, Value>) -> (Value, Vec<Value>) {
    let tool_call_id = map.get("call_id").map(value_to_text).unwrap_or_default();
    let (mut text, images) =
        chat_function_call_output_content(map.get("output").unwrap_or(&Value::Null));

    if text.is_empty() && !images.is_empty() {
        text = "[Image output is attached in the next user message.]".to_string();
    }

    let image_parts = if images.is_empty() {
        Vec::new()
    } else {
        let mut parts = vec![json!({
            "type": "text",
            "text": format!("Image output from tool call {tool_call_id}.")
        })];
        parts.extend(images);
        parts
    };

    (
        json!({
            "role": "tool",
            "tool_call_id": tool_call_id,
            "content": text
        }),
        image_parts,
    )
}

fn chat_function_call_output_content(output: &Value) -> (String, Vec<Value>) {
    let Value::Array(parts) = output else {
        return (value_to_text(output), Vec::new());
    };

    let mut text = String::new();
    let mut images = Vec::new();

    for part in parts {
        let Some(map) = part.as_object() else {
            text.push_str(&value_to_text(part));
            continue;
        };

        if matches!(
            map.get("type").and_then(Value::as_str),
            Some("input_image" | "image_url")
        ) {
            match chat_function_call_output_image(map) {
                Some(image) => images.push(image),
                None => text.push_str("[image content omitted: unsupported image source]"),
            }
            continue;
        }

        match chat_text_content_part(part) {
            Some(part_text) => text.push_str(&part_text),
            None => text.push_str(&value_to_text(part)),
        }
    }

    (text, images)
}

fn chat_function_call_output_image(map: &Map<String, Value>) -> Option<Value> {
    let image_url = map.get("image_url")?;
    let valid = match image_url {
        Value::String(url) => !url.trim().is_empty(),
        Value::Object(map) => map
            .get("url")
            .and_then(Value::as_str)
            .is_some_and(|url| !url.trim().is_empty()),
        _value => false,
    };

    valid.then(|| chat_image_url_part(Some(image_url)))
}

fn chat_agent_message(map: &Map<String, Value>) -> Result<Value, StreamError> {
    let content = map.get("content").unwrap_or(&Value::Null);
    let mut text = String::new();

    match content {
        Value::Array(parts) => {
            for part in parts {
                let Some(part) = part.as_object() else {
                    text.push_str(&value_to_text(part));
                    continue;
                };
                if let Some(value) = part.get("text") {
                    text.push_str(&value_to_text(value));
                }
            }
        }
        value => text.push_str(&value_to_text(value)),
    }

    Ok(json!({"role": "user", "content": text}))
}

fn chat_role_content_message(role: &str, content: &Value, map: &Map<String, Value>) -> Value {
    let mut message = Map::new();
    message.insert("role".to_string(), json!(role));
    message.insert("content".to_string(), chat_message_content(role, content));

    if role == "tool"
        && let Some(tool_call_id) = map
            .get("tool_call_id")
            .or_else(|| map.get("call_id"))
            .map(value_to_text)
            .filter(|value| !value.is_empty())
    {
        message.insert("tool_call_id".to_string(), json!(tool_call_id));
    }

    Value::Object(message)
}

fn normalize_chat_role(role: &str) -> &str {
    match role {
        "developer" | "system" => "system",
        "assistant" => "assistant",
        "tool" => "tool",
        _role => "user",
    }
}

fn chat_message_content(role: &str, content: &Value) -> Value {
    if role == "user"
        && let Some(parts) = content.as_array()
    {
        return Value::Array(parts.iter().map(chat_user_content_part).collect());
    }

    json!(chat_text_content(content))
}

fn chat_text_content(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(chat_text_content_part)
            .collect::<Vec<_>>()
            .join(""),
        Value::Null => String::new(),
        value => value_to_text(value),
    }
}

fn chat_text_content_part(part: &Value) -> Option<String> {
    match part {
        Value::String(text) => Some(text.clone()),
        Value::Object(map) => match map.get("type").and_then(Value::as_str) {
            Some("input_text" | "output_text" | "text") => map.get("text").map(value_to_text),
            Some("refusal") => map
                .get("refusal")
                .or_else(|| map.get("text"))
                .map(value_to_text),
            _type => map.get("text").map(value_to_text),
        },
        Value::Null => None,
        value => Some(value_to_text(value)),
    }
}

fn chat_user_content_part(part: &Value) -> Value {
    let Some(map) = part.as_object() else {
        return json!({ "type": "text", "text": value_to_text(part) });
    };

    match map.get("type").and_then(Value::as_str) {
        Some("input_text" | "output_text" | "text") => json!({
            "type": "text",
            "text": map.get("text").map(value_to_text).unwrap_or_default()
        }),
        Some("input_image" | "image_url") => chat_image_url_part(map.get("image_url")),
        _type => {
            if let Some(text) = map.get("text") {
                json!({ "type": "text", "text": value_to_text(text) })
            } else {
                json!({ "type": "text", "text": value_to_text(part) })
            }
        }
    }
}

fn chat_image_url_part(image_url: Option<&Value>) -> Value {
    match image_url {
        Some(Value::String(url)) => json!({ "type": "image_url", "image_url": { "url": url } }),
        Some(Value::Object(map)) if map.get("url").and_then(Value::as_str).is_some() => {
            json!({ "type": "image_url", "image_url": map })
        }
        Some(value) => json!({ "type": "text", "text": value_to_text(value) }),
        None => json!({ "type": "text", "text": "" }),
    }
}

fn chat_tools(tools: Option<&Value>) -> Option<Value> {
    let tools = tools?.as_array()?;
    let mapped: Vec<Value> = tools
        .iter()
        .flat_map(|tool| {
            let Some(map) = tool.as_object() else {
                return Vec::new();
            };
            match map.get("type").and_then(Value::as_str) {
                Some("namespace") => chat_namespace_tools(map),
                Some("function") => {
                    let function = map
                        .get("function")
                        .and_then(Value::as_object)
                        .unwrap_or(map);
                    vec![json!({
                        "type": "function",
                        "function": chat_function_tool(function, map)
                    })]
                }
                Some("custom") => vec![json!({
                    "type": "function",
                    "function": chat_custom_function_tool(map)
                })],
                _other => vec![tool.clone()],
            }
        })
        .collect();

    (!mapped.is_empty()).then_some(Value::Array(mapped))
}

fn chat_custom_function_tool(tool: &Map<String, Value>) -> Value {
    let format = tool.get("format").and_then(Value::as_object);
    let input_description = format
        .and_then(|format| format.get("definition"))
        .and_then(Value::as_str)
        .map(|definition| format!("Raw tool input. It must match this grammar:\n{definition}"))
        .unwrap_or_else(|| "Raw tool input.".to_string());

    json!({
        "name": tool.get("name").cloned().unwrap_or_else(|| json!("unknown")),
        "description": tool.get("description").cloned().unwrap_or(Value::Null),
        "parameters": {
            "type": "object",
            "properties": {
                "input": {
                    "type": "string",
                    "description": input_description
                }
            },
            "required": ["input"],
            "additionalProperties": false
        },
        "strict": false
    })
}

fn chat_namespace_tools(namespace: &Map<String, Value>) -> Vec<Value> {
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
            if tool.get("type").and_then(Value::as_str) != Some("function") {
                return None;
            }

            let function = tool
                .get("function")
                .and_then(Value::as_object)
                .unwrap_or(tool);
            let child_name = function.get("name").and_then(Value::as_str)?;
            let mut function = chat_function_tool(function, tool);
            function["name"] = json!(flattened_namespace_tool_name(namespace_name, child_name));

            Some(json!({
                "type": "function",
                "function": function
            }))
        })
        .collect()
}

fn chat_function_call_item(context: &ResponseContext, call: &ToolCall, status: &str) -> Value {
    let mut item = function_call_item(call, status);
    restore_tool_namespace(context, &mut item);
    restore_custom_tool(context, &mut item);
    item
}

fn restore_custom_tool(context: &ResponseContext, item: &mut Value) {
    let Some(name) = item.get("name").and_then(Value::as_str) else {
        return;
    };
    if !chat_custom_tool(context, name) {
        return;
    }

    let input = item
        .get("arguments")
        .and_then(Value::as_str)
        .map(custom_tool_input)
        .unwrap_or_default();
    let Some(item) = item.as_object_mut() else {
        return;
    };
    item.insert("type".to_string(), json!("custom_tool_call"));
    item.insert("input".to_string(), json!(input));
    item.remove("arguments");
}

fn custom_tool_input(arguments: &str) -> String {
    serde_json::from_str::<Value>(arguments)
        .ok()
        .and_then(|value| {
            value
                .get("input")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| arguments.to_string())
}

fn chat_custom_tool(context: &ResponseContext, name: &str) -> bool {
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

fn restore_tool_namespace(context: &ResponseContext, item: &mut Value) {
    let Some(flattened_name) = item.get("name").and_then(Value::as_str) else {
        return;
    };
    let Some((Some(namespace), function)) = chat_tool_for_flattened_name(context, flattened_name)
    else {
        return;
    };
    let Some(name) = function.get("name").and_then(Value::as_str) else {
        return;
    };

    item["namespace"] = json!(namespace);
    item["name"] = json!(name);
}

fn chat_tool_for_flattened_name<'a>(
    context: &'a ResponseContext,
    flattened_name: &str,
) -> Option<(Option<&'a str>, &'a Map<String, Value>)> {
    let tools = context
        .request
        .get("tools")
        .or_else(|| context.provider_options.get("tools"))?
        .as_array()?;

    for tool in tools {
        let Some(tool) = tool.as_object() else {
            continue;
        };
        match tool.get("type").and_then(Value::as_str) {
            Some("namespace") => {
                let namespace = tool.get("name").and_then(Value::as_str).unwrap_or_default();
                let Some(children) = tool.get("tools").and_then(Value::as_array) else {
                    continue;
                };
                for child in children {
                    let Some(child) = child.as_object() else {
                        continue;
                    };
                    if child.get("type").and_then(Value::as_str) != Some("function") {
                        continue;
                    }
                    let function = child
                        .get("function")
                        .and_then(Value::as_object)
                        .unwrap_or(child);
                    let Some(name) = function.get("name").and_then(Value::as_str) else {
                        continue;
                    };
                    if flattened_namespace_tool_name(namespace, name) == flattened_name {
                        return Some((Some(namespace), function));
                    }
                }
            }
            Some("function") => {
                let function = tool
                    .get("function")
                    .and_then(Value::as_object)
                    .unwrap_or(tool);
                if function.get("name").and_then(Value::as_str) == Some(flattened_name) {
                    return Some((None, function));
                }
            }
            _type => {
                continue;
            }
        }
    }

    None
}

fn flattened_namespace_tool_name(namespace: &str, name: &str) -> String {
    if namespace.is_empty() {
        name.to_string()
    } else if namespace.ends_with("__") {
        format!("{namespace}{name}")
    } else {
        format!("{namespace}__{name}")
    }
}

fn chat_function_tool(function: &Map<String, Value>, tool: &Map<String, Value>) -> Value {
    let mut mapped = Map::new();
    maybe_put_from(&mut mapped, function, "name");
    maybe_put_from(&mut mapped, function, "description");
    if let Some(parameters) = function
        .get("parameters")
        .or_else(|| function.get("input_schema"))
        .cloned()
        .filter(useful_value)
    {
        mapped.insert("parameters".to_string(), parameters);
    } else {
        mapped.insert("parameters".to_string(), json!({ "type": "object" }));
    }
    if let Some(strict) = function
        .get("strict")
        .or_else(|| tool.get("strict"))
        .cloned()
        .filter(useful_value)
    {
        mapped.insert("strict".to_string(), strict);
    }
    Value::Object(mapped)
}

fn chat_tool_choice(choice: Option<&Value>) -> Option<Value> {
    let value = choice?;
    let Some(map) = value.as_object() else {
        return Some(value.clone());
    };

    if map
        .get("function")
        .and_then(Value::as_object)
        .and_then(|function| function.get("name"))
        .and_then(Value::as_str)
        .is_some()
    {
        return Some(value.clone());
    }

    if map.get("type").and_then(Value::as_str) == Some("function")
        && let Some(name) = map.get("name").and_then(Value::as_str)
    {
        return Some(json!({ "type": "function", "function": { "name": name } }));
    }

    Some(value.clone())
}
