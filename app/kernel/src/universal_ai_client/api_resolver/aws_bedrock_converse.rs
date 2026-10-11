use super::*;
#[derive(Debug)]
pub(super) struct AWSBedrockConverseState {
    inner: ChatState,
    // ConverseStream sends `metadata`, with the token usage, after
    // `messageStop`. The response finishes with this stop reason when the
    // stream closes.
    stop_reason: Option<String>,
}

impl AWSBedrockConverseState {
    pub(super) fn new(model: String) -> Self {
        Self {
            inner: ChatState::new(model),
            stop_reason: None,
        }
    }

    // Reads one `ConverseStreamOutput` event in the `{event_type: payload}`
    // shape of the AWS SDK union. `messageStart` only starts the response, and
    // `ChatState::finish` closes the text block that `contentBlockStop` ends.
    // `contentBlockStart` starts only toolUse, toolResult, and image blocks,
    // which this resolver does not support.
    fn ingest(&mut self, context: &ResponseContext, event: Value) -> Vec<Value> {
        let mut events = self.inner.ensure_response_started(context);

        if let Some(text) = event
            .pointer("/contentBlockDelta/delta/text")
            .and_then(Value::as_str)
        {
            events.extend(self.inner.text_delta(text));
        }

        if let Some(message_stop) = event.get("messageStop") {
            let stop_reason = message_stop
                .get("stopReason")
                .and_then(Value::as_str)
                .unwrap_or("end_turn");
            self.stop_reason = Some(stop_reason.to_string());
        }

        if let Some(usage) = event.pointer("/metadata/usage") {
            self.inner.set_usage(normalize_provider_token_usage(usage));
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

impl APIProtocol for AWSBedrockConverseState {
    fn on_provider_event(
        &mut self,
        context: &ResponseContext,
        event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        Ok(self.ingest(context, event))
    }

    fn on_upstream_close(&mut self, context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        let Some(stop_reason) = self.stop_reason.take() else {
            return Ok(self.finish(context, "incomplete", Some("upstream_stream_closed")));
        };
        Ok(match bedrock_terminal(&stop_reason) {
            ProviderTerminal::Completed => self.finish(context, "completed", None),
            ProviderTerminal::Incomplete(reason) => {
                self.finish(context, "incomplete", Some(reason))
            }
            ProviderTerminal::Failed(error) => self.fail(context, &error),
        })
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
        aws_bedrock_converse_body_to_response(
            context,
            provider_object_body(status, body, "AWS Bedrock Converse")?,
        )
    }

    // ConverseStream sends a modeled exception as an eventstream frame after the
    // HTTP 200 response has started. These are the `httpError` statuses that the
    // Bedrock Runtime model declares for the exception members of
    // `ConverseStreamOutput`.
    fn provider_exception_status(&self, exception_type: &str) -> Option<u16> {
        match exception_type {
            "internalServerException" => Some(500),
            "modelStreamErrorException" => Some(424),
            "serviceUnavailableException" => Some(503),
            "throttlingException" => Some(429),
            "validationException" => Some(400),
            _exception_type => None,
        }
    }

    fn is_terminal(&self) -> bool {
        self.inner.is_terminal()
    }
}

// Parses the official non-streaming Converse body, which shares no shape with
// the stream events that `ingest` reads. `toolUse` blocks stay unsupported on
// both paths.
fn aws_bedrock_converse_body_to_response(
    context: &ResponseContext,
    body: Value,
) -> Result<Value, StreamError> {
    let stop_reason = body
        .get("stopReason")
        .and_then(Value::as_str)
        .unwrap_or("end_turn");
    let (status, incomplete_reason) = match bedrock_terminal(stop_reason) {
        ProviderTerminal::Completed => ("completed", None),
        ProviderTerminal::Incomplete(reason) => ("incomplete", Some(reason)),
        ProviderTerminal::Failed(error) => return Err(error),
    };

    let mut text = String::new();
    for block in body
        .pointer("/output/message/content")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(delta) = block.get("text").and_then(Value::as_str) {
            text.push_str(delta);
        }
    }
    let output = if text.is_empty() {
        json!([])
    } else {
        json!([{
            "id": generated_id("msg"),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": text, "annotations": []}]
        }])
    };

    Ok(complete_response_resource(
        context,
        json!({
            "status": status,
            "incomplete_details": incomplete_reason.map(|reason| json!({"reason": reason})).unwrap_or(Value::Null),
            "output": output,
            "usage": normalize_provider_token_usage(body.get("usage").unwrap_or(&Value::Null))
        }),
    ))
}

fn bedrock_terminal(reason: &str) -> ProviderTerminal {
    match reason {
        "end_turn" | "stop_sequence" | "tool_use" => ProviderTerminal::Completed,
        "max_tokens" | "model_context_window_exceeded" => {
            ProviderTerminal::Incomplete("max_output_tokens")
        }
        other => ProviderTerminal::Failed(provider_terminal_rejected("AWS Bedrock", other)),
    }
}
