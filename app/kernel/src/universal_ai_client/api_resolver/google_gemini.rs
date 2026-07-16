use super::*;
#[derive(Debug)]
pub(super) struct GoogleGeminiState {
    inner: ChatState,
}

impl GoogleGeminiState {
    pub(super) fn new(model: String) -> Self {
        Self {
            inner: ChatState::new(model),
        }
    }

    fn ingest(&mut self, context: &ResponseContext, value: Value) -> Vec<Value> {
        let mut events = self.inner.ensure_response_started(context);

        if let Some(usage) = value.get("usageMetadata") {
            self.inner.set_usage(normalize_provider_token_usage(usage));
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
                    events.extend(self.inner.tool_call_delta(
                        context,
                        &json!({
                            "index": self.inner.next_tool_call_index(),
                            "function": {
                                "name": call.get("name").and_then(Value::as_str).unwrap_or("unknown"),
                                "arguments": arguments
                            }
                        }),
                    ));
                }
            }

            if let Some(finish_reason) = candidate.get("finishReason").and_then(Value::as_str) {
                events.extend(self.finish_reason(context, finish_reason));
            }
        }

        events
    }

    fn finish_reason(&mut self, context: &ResponseContext, reason: &str) -> Vec<Value> {
        match gemini_terminal(reason) {
            ProviderTerminal::Completed => self.inner.finish(context, "completed", None),
            ProviderTerminal::Incomplete(incomplete_reason) => {
                self.inner
                    .finish(context, "incomplete", Some(incomplete_reason))
            }
            ProviderTerminal::Failed(error) => self.inner.fail(context, &error),
        }
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

impl APIProtocol for GoogleGeminiState {
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
        self.inner.is_terminal()
    }
}

fn google_gemini_body_to_response(context: &ResponseContext, body: Value) -> Value {
    let mut state = GoogleGeminiState::new(context.model.clone());
    let mut events = state.ingest(context, body);
    if !state.inner.is_terminal() {
        events.extend(state.finish(context, "completed", None));
    }
    events
        .into_iter()
        .rev()
        .find_map(|event| event.get("response").cloned())
        .unwrap_or_else(|| complete_response_resource(context, json!({ "output": [] })))
}

pub(super) enum ProviderTerminal {
    Completed,
    Incomplete(&'static str),
    Failed(StreamError),
}

fn gemini_terminal(reason: &str) -> ProviderTerminal {
    match reason {
        "STOP" => ProviderTerminal::Completed,
        "MAX_TOKENS" => ProviderTerminal::Incomplete("max_output_tokens"),
        "SAFETY"
        | "RECITATION"
        | "SPII"
        | "PROHIBITED_CONTENT"
        | "BLOCKLIST"
        | "MALFORMED_FUNCTION_CALL"
        | "MODEL_ARMOR"
        | "OTHER"
        | "FINISH_REASON_UNSPECIFIED" => {
            ProviderTerminal::Failed(provider_terminal_rejected("Google Gemini", reason))
        }
        other => ProviderTerminal::Failed(provider_terminal_rejected("Google Gemini", other)),
    }
}

pub(super) fn provider_terminal_rejected(provider: &str, reason: &str) -> StreamError {
    StreamError::new(
        StreamErrorCode::ProviderTerminalRejected,
        "api_resolver",
        format!("{provider} rejected the response with terminal reason {reason}"),
    )
}
