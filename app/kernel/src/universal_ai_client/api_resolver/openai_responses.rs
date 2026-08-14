use super::*;
#[derive(Debug, Default)]
pub(super) struct OpenAIResponsesState {
    sequence: u64,
    terminal: bool,
    response: Option<Value>,
    saw_error: bool,
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

        self.ensure_sequence(&mut event);

        if let Some(response) = event.get("response").filter(|value| value.is_object()) {
            let normalized = complete_response_resource(context, response.clone());
            event["response"] = normalized.clone();
            self.response = Some(normalized);
        }

        match event_type.as_str() {
            "error" => self.saw_error = true,
            "response.completed" | "response.failed" | "response.incomplete" => {
                self.terminal = true;
            }
            _event => {}
        }

        Ok(vec![event])
    }

    fn finish(&mut self) -> Result<Vec<Value>, StreamError> {
        if self.terminal {
            Ok(Vec::new())
        } else if self.saw_error {
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
        let error_event = self.event("error", json!({ "error": openresponses_error(error) }));
        let response = failed_response_resource(context, error, self.response.clone());
        let failed = self.event("response.failed", json!({ "response": response }));
        vec![error_event, failed]
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

impl APIProtocol for OpenAIResponsesState {
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
        Ok(complete_response_resource(
            context,
            provider_object_body(status, body, "OpenAI Responses")?,
        ))
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

#[derive(Debug, Default)]
pub(super) struct OpenAIResponsesCompact;

impl APIProtocol for OpenAIResponsesCompact {
    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        if !(200..300).contains(&status) {
            return Err(provider_body_error(status, body));
        }
        reject_provider_body_error(status, &body)?;
        provider_object_body(status, body, "OpenAI Responses compact")
    }
}
