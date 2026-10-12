use super::*;
use std::collections::BTreeSet;

#[derive(Debug, Default)]
pub(super) struct OpenAIResponsesState {
    sequence: u64,
    terminal: bool,
    response: Option<Value>,
    provider_error: Option<Value>,
    emulated_item_ids: BTreeSet<String>,
}

impl OpenAIResponsesState {
    fn ingest(
        &mut self,
        context: &ResponseContext,
        mut event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        let event_type = event
            .get("type")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                StreamError::new(
                    "invalid_provider_event",
                    "api_resolver",
                    "OpenAI Responses stream event must include a string type",
                )
            })?
            .to_string();

        // An emulated stream drops the upstream argument deltas, so the
        // resolver renumbers what it forwards to keep the sequence contiguous.
        if custom_tool_emulation_requested(context) {
            if !self.lift_emulated_event(context, &mut event) {
                return Ok(Vec::new());
            }
            event["sequence_number"] = json!(self.next_sequence());
        } else {
            self.ensure_sequence(&mut event);
        }

        if let Some(response) = event.get("response").filter(|value| value.is_object()) {
            let normalized = complete_response_resource(context, response.clone());
            event["response"] = normalized.clone();
            self.response = Some(normalized);
        }

        match event_type.as_str() {
            "error" if self.provider_error.is_none() => {
                self.provider_error = provider_error_diagnostic(&event);
            }
            "response.completed" | "response.failed" | "response.incomplete" => {
                self.terminal = true;
            }
            _event => {}
        }

        Ok(vec![event])
    }

    /// Restores one upstream event into the official custom-tool space.
    /// Returns `false` when the event must not reach the caller: argument
    /// deltas stream a JSON-escaped string that cannot be unescaped
    /// incrementally, so emulated calls deliver their input only at `done`,
    /// exactly like the chat-completions resolver.
    fn lift_emulated_event(&mut self, context: &ResponseContext, event: &mut Value) -> bool {
        if let Some(item) = event.get_mut("item")
            && let Some(item_id) = lift_custom_tool_item(context, item)
        {
            self.emulated_item_ids.insert(item_id);
        }

        if let Some(response) = event.get_mut("response") {
            lift_custom_tool_response(context, response);
        }

        let item_id = event.get("item_id").and_then(Value::as_str);
        let emulated_item = item_id.is_some_and(|id| self.emulated_item_ids.contains(id));
        if !emulated_item {
            return true;
        }

        match event.get("type").and_then(Value::as_str) {
            Some("response.function_call_arguments.delta") => false,
            Some("response.function_call_arguments.done") => {
                let input = event
                    .get("arguments")
                    .and_then(Value::as_str)
                    .map(custom_tool_input)
                    .unwrap_or_default();
                if let Some(map) = event.as_object_mut() {
                    map.insert(
                        "type".to_string(),
                        json!("response.custom_tool_call_input.done"),
                    );
                    map.insert("input".to_string(), json!(input));
                    map.remove("arguments");
                }
                true
            }
            _type => true,
        }
    }

    fn finish(&mut self) -> Result<Vec<Value>, StreamError> {
        if self.terminal {
            Ok(Vec::new())
        } else if self.provider_error.is_some() {
            Err(StreamError::new(
                "upstream_stream_closed_before_terminal_event",
                "api_resolver",
                "OpenAI Responses stream closed after an error event without response.failed",
            ))
        } else {
            Err(StreamError::new(
                "upstream_stream_closed_before_terminal_event",
                "api_resolver",
                "OpenAI Responses stream closed before response.completed, response.failed, or response.incomplete",
            ))
        }
    }

    fn fail(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
        if self.terminal {
            return Vec::new();
        }

        self.terminal = true;
        let normalized_error = self.failure_error(error);
        let mut response = failed_response_resource(context, error, self.response.clone());
        response["error"] = normalized_error;
        let failed = self.event("response.failed", json!({ "response": response }));
        vec![failed]
    }

    fn failure_error(&self, error: &StreamError) -> Value {
        let mut normalized = openresponses_error(error);
        let Some(diagnostic) = &self.provider_error else {
            return normalized;
        };

        let mut details = normalized["details_json"]
            .as_object()
            .cloned()
            .unwrap_or_default();
        for (source, field) in [
            ("code", "provider_error_code"),
            ("type", "provider_error_type"),
            ("status", "provider_status"),
            ("message", "provider_diagnostic_message"),
        ] {
            if let Some(value) = diagnostic.get(source) {
                details.insert(field.to_string(), value.clone());
            }
        }
        if let Some(message) = diagnostic.get("message") {
            normalized["message"] = message.clone();
        }

        let validation = matches!(diagnostic["status"].as_u64(), Some(400 | 422))
            || matches!(
                diagnostic["type"].as_str(),
                Some("invalid_request" | "invalid_request_error")
            )
            || matches!(
                diagnostic["code"].as_str(),
                Some("bad_request" | "invalid_request" | "invalid_request_error")
            );
        if validation && diagnostic["retryable"] != true {
            normalized["code"] = diagnostic
                .get("code")
                .cloned()
                .unwrap_or_else(|| json!("provider_response_rejected"));
            normalized["retryable"] = json!(false);
        }
        normalized["details_json"] = Value::Object(details);
        normalized
    }

    fn event(&mut self, event_type: &str, fields: Value) -> Value {
        let sequence = self.next_sequence();
        build_event(sequence, event_type, fields)
    }

    fn ensure_sequence(&mut self, value: &mut Value) {
        match value.get("sequence_number").and_then(Value::as_u64) {
            Some(sequence) => self.sequence = self.sequence.max(sequence.saturating_add(1)),
            None => {
                value["sequence_number"] = json!(self.next_sequence());
            }
        }
    }

    fn next_sequence(&mut self) -> u64 {
        let sequence = self.sequence;
        self.sequence = self.sequence.saturating_add(1);
        sequence
    }
}

fn provider_error_diagnostic(event: &Value) -> Option<Value> {
    let error = event
        .get("error")
        .filter(|value| value.is_object())
        .unwrap_or(event);
    let mut diagnostic = Map::new();
    for field in ["code", "type", "message"] {
        if let Some(value) = error.get(field).and_then(Value::as_str)
            && !(field == "type" && value == "error")
        {
            diagnostic.insert(
                field.to_string(),
                json!(
                    value
                        .chars()
                        .take(super::super::error::PROVIDER_BODY_EXCERPT_LIMIT)
                        .collect::<String>()
                ),
            );
        }
    }
    if let Some(status) = error.get("status").and_then(Value::as_u64) {
        diagnostic.insert("status".to_string(), json!(status));
    }
    if let Some(retryable) = error.get("retryable").and_then(Value::as_bool) {
        diagnostic.insert("retryable".to_string(), json!(retryable));
    }
    (!diagnostic.is_empty()).then_some(Value::Object(diagnostic))
}

impl APIProtocol for OpenAIResponsesState {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let mut body = context.resolved_provider_request_object();
        if custom_tool_emulation_requested(context) {
            lower_custom_tools(&mut body)?;
        }
        Ok(body)
    }

    fn websocket_initial_messages(
        &self,
        context: &ResponseContext,
    ) -> Result<Vec<String>, StreamError> {
        let mut event = self.build_body(context)?;
        event.remove("background");
        event.insert("type".to_string(), json!("response.create"));
        Ok(vec![encode_protocol_json(Value::Object(event))?])
    }

    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        self.ingest(context, event)
    }

    fn on_upstream_close(&mut self, _context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        self.finish()
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
        let mut response = complete_response_resource(
            context,
            provider_object_body(status, body, "OpenAI Responses")?,
        );
        if custom_tool_emulation_requested(context) {
            lift_custom_tool_response(context, &mut response);
        }
        Ok(response)
    }

    fn classify_provider_rejection(
        &self,
        context: &ResponseContext,
        status: u16,
        body: &[u8],
    ) -> Option<StreamError> {
        classify_stateful_replay_rejection(context, status, body)
    }

    fn is_terminal(&self) -> bool {
        self.terminal
    }
}

fn classify_stateful_replay_rejection(
    context: &ResponseContext,
    status: u16,
    body: &[u8],
) -> Option<StreamError> {
    if status != 400
        || context
            .request
            .get("__ankole_stateful_provider_replay")
            .and_then(Value::as_bool)
            != Some(true)
    {
        return None;
    }

    let body = sonic_rs::from_slice::<Value>(body).ok()?;
    let error = body.get("error")?.as_object()?;

    if error.get("type").and_then(Value::as_str) == Some("invalid_request_error")
        && error.get("param").and_then(Value::as_str) == Some("input")
    {
        Some(StreamError::new(
            "stateful_replay_input_rejected",
            "socket_open",
            "upstream rejected provider-native stateful replay input",
        ))
    } else {
        None
    }
}
