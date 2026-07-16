use super::*;
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
            events.push(self.event(
                "response.function_call_arguments.delta",
                json!({
                    "item_id": call.id,
                    "output_index": output_index,
                    "delta": arguments
                }),
            ));
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

        if self.content_started {
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

        for call in self.tool_calls.values().cloned().collect::<Vec<_>>() {
            events.push(self.event(
                "response.function_call_arguments.done",
                json!({
                    "item_id": call.id,
                    "output_index": call.output_index,
                    "arguments": call.arguments
                }),
            ));
            events.push(self.event(
                "response.output_item.done",
                json!({
                    "output_index": call.output_index,
                    "item": chat_function_call_item(context, &call, "completed")
                }),
            ));
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
        let mut output = Vec::new();
        if self.content_started {
            output.push(self.message_item("completed"));
        }
        let mut calls = self.tool_calls.values().cloned().collect::<Vec<_>>();
        calls.sort_by_key(|call| call.output_index);
        output.extend(
            calls
                .iter()
                .map(|call| chat_function_call_item(context, call, "completed")),
        );

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

impl APIProtocol for ChatState {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(build_openai_chat_body(context))
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
        Ok(chat_completion_body_to_response(
            context,
            provider_object_body(status, body, "OpenAI Chat Completions")?,
        ))
    }

    fn is_terminal(&self) -> bool {
        self.terminal
    }
}

fn chat_completion_body_to_response(context: &ResponseContext, body: Value) -> Value {
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

    complete_response_resource(
        context,
        json!({
            "id": id,
            "object": "response",
            "created_at": created_at,
            "completed_at": created_at,
            "status": "completed",
            "model": model,
            "output": chat_output_items(context, &message),
            "usage": normalize_response_usage(body.get("usage").unwrap_or(&Value::Null)),
            "metadata": {}
        }),
    )
}

fn chat_output_items(context: &ResponseContext, message: &Value) -> Value {
    let content = message.get("content").unwrap_or(&Value::Null);
    let mut items = Vec::new();
    let content_parts = chat_assistant_content_parts(content);

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
            let mut item = json!({
                "id": generated_id("fc"),
                "type": "function_call",
                "call_id": tool_call.get("id").and_then(Value::as_str).unwrap_or("call"),
                "name": function.get("name").and_then(Value::as_str).unwrap_or("unknown"),
                "arguments": function.get("arguments").map(value_to_string).unwrap_or_else(|| "{}".to_string()),
                "status": "completed"
            });
            restore_tool_namespace(context, &mut item);
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

    Value::Array(items)
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

fn build_openai_chat_body(context: &ResponseContext) -> Map<String, Value> {
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
    body.insert("messages".to_string(), chat_messages(&request));
    body
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

fn chat_messages(request: &Map<String, Value>) -> Value {
    let mut messages = Vec::new();
    let input = request.get("input");

    if let Some(instructions) = request
        .get("instructions")
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
    {
        messages.push(json!({ "role": "system", "content": instructions }));
    }

    match input {
        Some(Value::String(text)) => messages.push(json!({ "role": "user", "content": text })),
        Some(Value::Array(items)) => {
            let mut pending_tool_calls = Vec::new();
            for item in items {
                match item {
                    Value::Object(map) => {
                        match map.get("type").and_then(Value::as_str) {
                            Some("function_call") => {
                                pending_tool_calls.push(chat_function_call(map));
                                continue;
                            }
                            Some("function_call_output") => {
                                flush_chat_tool_calls(&mut messages, &mut pending_tool_calls);
                                messages.push(chat_function_call_output(map));
                                continue;
                            }
                            _type => {}
                        }

                        flush_chat_tool_calls(&mut messages, &mut pending_tool_calls);
                        let role = map
                            .get("role")
                            .and_then(Value::as_str)
                            .map(normalize_chat_role);
                        let content = map.get("content");
                        match (role, content) {
                            (Some(role), Some(content)) => {
                                messages.push(chat_role_content_message(role, content, map))
                            }
                            _ => messages.push(json!({
                                "role": "user",
                                "content": value_to_text(item)
                            })),
                        }
                    }
                    value => {
                        flush_chat_tool_calls(&mut messages, &mut pending_tool_calls);
                        messages.push(json!({ "role": "user", "content": value_to_text(value) }))
                    }
                }
            }
            flush_chat_tool_calls(&mut messages, &mut pending_tool_calls);
        }
        _input => {}
    }

    Value::Array(messages)
}

fn flush_chat_tool_calls(messages: &mut Vec<Value>, pending_tool_calls: &mut Vec<Value>) {
    if pending_tool_calls.is_empty() {
        return;
    }

    messages.push(json!({
        "role": "assistant",
        "content": Value::Null,
        "tool_calls": std::mem::take(pending_tool_calls)
    }));
}

fn chat_function_call(map: &Map<String, Value>) -> Value {
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

    json!({
        "id": call_id,
        "type": "function",
        "function": {
            "name": name,
            "arguments": arguments
        }
    })
}

fn chat_function_call_output(map: &Map<String, Value>) -> Value {
    json!({
        "role": "tool",
        "tool_call_id": map.get("call_id").map(value_to_text).unwrap_or_default(),
        "content": map.get("output").map(value_to_text).unwrap_or_default()
    })
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
                _other => vec![tool.clone()],
            }
        })
        .collect();

    (!mapped.is_empty()).then_some(Value::Array(mapped))
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
    item
}

fn restore_tool_namespace(context: &ResponseContext, item: &mut Value) {
    let Some(flattened_name) = item.get("name").and_then(Value::as_str) else {
        return;
    };
    let Some((namespace, name)) = namespaced_tool_for_flattened_name(context, flattened_name)
    else {
        return;
    };

    item["namespace"] = json!(namespace);
    item["name"] = json!(name);
}

fn namespaced_tool_for_flattened_name(
    context: &ResponseContext,
    flattened_name: &str,
) -> Option<(String, String)> {
    let tools = context
        .request
        .get("tools")
        .or_else(|| context.provider_options.get("tools"))?
        .as_array()?;

    for namespace in tools {
        let Some(namespace) = namespace.as_object() else {
            continue;
        };
        if namespace.get("type").and_then(Value::as_str) != Some("namespace") {
            continue;
        }
        let Some(namespace_name) = namespace.get("name").and_then(Value::as_str) else {
            continue;
        };
        let Some(namespace_tools) = namespace.get("tools").and_then(Value::as_array) else {
            continue;
        };

        for tool in namespace_tools {
            let Some(tool) = tool.as_object() else {
                continue;
            };
            if tool.get("type").and_then(Value::as_str) != Some("function") {
                continue;
            }
            let function = tool
                .get("function")
                .and_then(Value::as_object)
                .unwrap_or(tool);
            let Some(child_name) = function.get("name").and_then(Value::as_str) else {
                continue;
            };
            if flattened_namespace_tool_name(namespace_name, child_name) == flattened_name {
                return Some((namespace_name.to_string(), child_name.to_string()));
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
