#[derive(Debug)]
struct GoogleGeminiState {
    inner: ChatState,
}

impl GoogleGeminiState {
    fn new(model: String) -> Self {
        Self {
            inner: ChatState::new(model),
        }
    }

    fn ingest(&mut self, context: &ResponseContext, value: Value) -> Vec<Value> {
        let mut events = self.inner.ensure_response_started(context);

        if let Some(usage) = value.get("usageMetadata") {
            self.inner.usage = normalize_provider_token_usage(usage);
        }

        for candidate in value
            .get("candidates")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            for part in candidate
                .pointer("/content/parts")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(text) = part.get("text").and_then(Value::as_str) {
                    events.extend(self.inner.text_delta(text));
                }

                if let Some(call) = part.get("functionCall").filter(|value| value.is_object()) {
                    let arguments = call
                        .get("args")
                        .map(|args| sonic_rs::to_string(args).unwrap_or_else(|_| "{}".to_string()))
                        .unwrap_or_else(|| "{}".to_string());
                    events.extend(self.inner.tool_call_delta(&json!({
                        "index": self.inner.tool_calls.len(),
                        "function": {
                            "name": call.get("name").and_then(Value::as_str).unwrap_or("unknown"),
                            "arguments": arguments
                        }
                    })));
                }
            }

            if candidate
                .get("finishReason")
                .and_then(Value::as_str)
                .is_some()
            {
                events.extend(self.inner.finish(context, "completed", None));
            }
        }

        events
    }

    fn finish(
        &mut self,
        context: &ResponseContext,
        status: &str,
        incomplete_reason: Option<&str>,
    ) -> Vec<Value> {
        self.inner.finish(context, status, incomplete_reason)
    }

    fn fail(&mut self, context: &ResponseContext, error: &StreamError) -> Vec<Value> {
        self.inner.fail(context, error)
    }
}

impl ApiProtocol for GoogleGeminiState {
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
        Ok(google_gemini_body_to_response(
            context,
            provider_object_body(status, body, "Google Gemini GenerateContent")?,
        ))
    }

    fn is_terminal(&self) -> bool {
        self.inner.terminal
    }
}

fn google_gemini_body_to_response(context: &ResponseContext, body: Value) -> Value {
    let mut state = GoogleGeminiState::new(context.model.clone());
    let mut events = state.ingest(context, body);
    if !state.inner.terminal {
        events.extend(state.finish(context, "completed", None));
    }
    events
        .into_iter()
        .rev()
        .find_map(|event| event.get("response").cloned())
        .unwrap_or_else(|| complete_response_resource(context, json!({ "output": [] })))
}
