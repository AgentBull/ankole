#[derive(Debug)]
struct AwsBedrockConverseState {
    inner: ChatState,
}

impl AwsBedrockConverseState {
    fn new(model: String) -> Self {
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
            self.inner.usage = normalize_provider_token_usage(usage);
        }

        if let Some(text) = value
            .pointer("/contentBlockDelta/delta/text")
            .and_then(Value::as_str)
            .or_else(|| value.pointer("/delta/text").and_then(Value::as_str))
        {
            events.extend(self.inner.text_delta(text));
        }

        if value.get("messageStop").is_some() {
            events.extend(self.inner.finish(context, "completed", None));
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

impl ApiProtocol for AwsBedrockConverseState {
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
        self.inner.terminal
    }
}

fn aws_bedrock_converse_body_to_response(context: &ResponseContext, body: Value) -> Value {
    let mut state = AwsBedrockConverseState::new(context.model.clone());
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
