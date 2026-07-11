use super::*;
#[derive(Debug)]
pub(super) struct AWSBedrockConverseState {
    inner: ChatState,
}

impl AWSBedrockConverseState {
    pub(super) fn new(model: String) -> Self {
        Self {
            inner: ChatState::new(model),
        }
    }

    fn ingest(&mut self, context: &ResponseContext, value: Value) -> Vec<Value> {
        let mut events = self.inner.ensure_response_started(context);

        if let Some(usage) = value
            .get("metadata")
            .and_then(|metadata| metadata.get("usage"))
        {
            self.inner.set_usage(normalize_provider_token_usage(usage));
        }

        if let Some(text) = value
            .pointer("/contentBlockDelta/delta/text")
            .and_then(Value::as_str)
            .or_else(|| value.pointer("/delta/text").and_then(Value::as_str))
        {
            events.extend(self.inner.text_delta(text));
        }

        if let Some(message_stop) = value.get("messageStop") {
            let stop_reason = message_stop
                .get("stopReason")
                .and_then(Value::as_str)
                .unwrap_or("end_turn");
            events.extend(self.stop_reason(context, stop_reason));
        }

        events
    }

    fn stop_reason(&mut self, context: &ResponseContext, reason: &str) -> Vec<Value> {
        match bedrock_terminal(reason) {
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

impl APIProtocol for AWSBedrockConverseState {
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
        Ok(aws_bedrock_converse_body_to_response(
            context,
            provider_object_body(status, body, "AWS Bedrock Converse")?,
        ))
    }

    fn is_terminal(&self) -> bool {
        self.inner.is_terminal()
    }
}

fn aws_bedrock_converse_body_to_response(context: &ResponseContext, body: Value) -> Value {
    let mut state = AWSBedrockConverseState::new(context.model.clone());
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

fn bedrock_terminal(reason: &str) -> ProviderTerminal {
    match reason {
        "end_turn" | "stop_sequence" | "tool_use" => ProviderTerminal::Completed,
        "max_tokens" | "model_context_window_exceeded" => {
            ProviderTerminal::Incomplete("max_output_tokens")
        }
        "guardrail_intervened"
        | "content_filtered"
        | "malformed_model_output"
        | "malformed_tool_use" => {
            ProviderTerminal::Failed(provider_terminal_rejected("AWS Bedrock", reason))
        }
        other => ProviderTerminal::Failed(provider_terminal_rejected("AWS Bedrock", other)),
    }
}
