use super::*;

#[derive(Debug)]
pub struct APIResolver {
    context: ResponseContext,
    provider_context: ResponseContext,
    protocol: Box<dyn APIProtocol>,
    opaque_tool_fields: OpaqueToolFields,
    prepare_error: Option<StreamError>,
}

pub(super) trait APIProtocol: std::fmt::Debug + Send + Sync {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(context.resolved_provider_request_object())
    }

    fn websocket_initial_messages(
        &self,
        _context: &ResponseContext,
    ) -> Result<Vec<String>, StreamError> {
        Err(StreamError::new(
            "unsupported_websocket_model_request",
            "api_resolver",
            "upstream WebSocket model requests currently require openai_responses",
        ))
    }

    fn on_provider_event(
        &mut self,
        _context: &ResponseContext,
        _event: Value,
    ) -> Result<Vec<Value>, StreamError> {
        Err(StreamError::new(
            "unsupported_stream_resolver",
            "api_resolver",
            "api resolver is only valid for non-streaming requests",
        ))
    }

    fn on_upstream_close(&mut self, _context: &ResponseContext) -> Result<Vec<Value>, StreamError> {
        Ok(Vec::new())
    }

    fn on_transport_error(
        &mut self,
        _context: &ResponseContext,
        _error: &StreamError,
    ) -> Vec<Value> {
        Vec::new()
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        Err(invalid_upstream_body_error(
            status,
            body,
            "api resolver does not support non-streaming response normalization",
        ))
    }

    fn is_terminal(&self) -> bool {
        false
    }
}

impl APIResolver {
    pub fn new(kind: APIResolverKind, context: ResponseContext) -> Self {
        let protocol = make_protocol(kind, &context);
        let (opaque_tool_fields, provider_context, opaque_prepare_error) =
            if kind == APIResolverKind::OpenAIResponsesCompact {
                (OpaqueToolFields::inactive(), context.clone(), None)
            } else {
                match OpaqueToolFields::prepare(kind, &context) {
                    Ok((opaque_tool_fields, provider_context)) => {
                        (opaque_tool_fields, provider_context, None)
                    }
                    Err(error) => (OpaqueToolFields::inactive(), context.clone(), Some(error)),
                }
            };
        let prepare_error = validate_compaction_replay_wire(kind, &provider_context)
            .err()
            .or(opaque_prepare_error);
        Self {
            context,
            provider_context,
            protocol,
            opaque_tool_fields,
            prepare_error,
        }
    }

    pub fn build_body(&self) -> Result<Map<String, Value>, StreamError> {
        self.check_prepared()?;
        self.protocol.build_body(&self.provider_context)
    }

    pub fn websocket_initial_messages(&self) -> Result<Vec<String>, StreamError> {
        self.check_prepared()?;
        self.protocol
            .websocket_initial_messages(&self.provider_context)
    }

    pub fn ingest(&mut self, value: Value) -> Result<Vec<Value>, StreamError> {
        self.check_prepared()?;
        let events = self.protocol.on_provider_event(&self.context, value)?;
        self.opaque_tool_fields.lift_events(events)
    }

    pub fn finish(&mut self) -> Result<Vec<Value>, StreamError> {
        self.check_prepared()?;
        let events = self.protocol.on_upstream_close(&self.context)?;
        self.opaque_tool_fields.lift_events(events)
    }

    pub fn is_terminal(&self) -> bool {
        self.opaque_tool_fields.is_terminal() || self.protocol.is_terminal()
    }

    pub fn fail(&mut self, error: &StreamError) -> Vec<Value> {
        let events = self.protocol.on_transport_error(&self.context, error);
        self.opaque_tool_fields
            .fail_events(&self.context, error, events)
    }

    pub fn normalize_body(&mut self, status: u16, body: Value) -> Result<Value, StreamError> {
        self.check_prepared()?;
        let response = self
            .protocol
            .on_provider_body(&self.context, status, body)?;
        self.opaque_tool_fields.lift_response(response)
    }

    fn check_prepared(&self) -> Result<(), StreamError> {
        match &self.prepare_error {
            Some(error) => Err(error.clone()),
            None => Ok(()),
        }
    }
}

fn make_protocol(kind: APIResolverKind, context: &ResponseContext) -> Box<dyn APIProtocol> {
    match kind {
        APIResolverKind::OpenAIResponses => Box::new(OpenAIResponsesState::default()),
        APIResolverKind::OpenAIResponsesCompact => Box::new(OpenAIResponsesCompact),
        APIResolverKind::OpenAIChatCompletions => Box::new(ChatState::new(context.model.clone())),
        APIResolverKind::AnthropicMessages => Box::new(AnthropicState::new(context.model.clone())),
        APIResolverKind::GeminiGenerateContent => {
            Box::new(GoogleGeminiState::new(context.model.clone()))
        }
        APIResolverKind::BedrockConverse => {
            Box::new(AWSBedrockConverseState::new(context.model.clone()))
        }
        APIResolverKind::OpenAIEmbeddings => Box::new(OpenAIEmbeddings),
        APIResolverKind::OpenrouterEmbeddings => Box::new(OpenrouterEmbeddings),
        APIResolverKind::JinaEmbeddings => Box::new(JinaEmbeddings),
        APIResolverKind::GoogleEmbeddings => Box::new(GoogleEmbeddings),
        APIResolverKind::OpenrouterRerank => Box::new(OpenrouterRerank),
        APIResolverKind::JinaRerank => Box::new(JinaRerank),
        APIResolverKind::OpenrouterImages => Box::new(OpenrouterImages),
        APIResolverKind::ParallelWebSearch => Box::new(ParallelWebSearch),
        APIResolverKind::ParallelWebFetch => Box::new(ParallelWebFetch),
        APIResolverKind::BrightDataSerpWebSearch => Box::new(BrightDataSerpWebSearch),
        APIResolverKind::AgentbullWebSearch => Box::new(AgentBullWebSearch),
        APIResolverKind::JinaSearchWebSearch => Box::new(JinaSearchWebSearch),
        APIResolverKind::JinaReaderWebFetch => Box::new(JinaReaderWebFetch),
    }
}

fn validate_compaction_replay_wire(
    kind: APIResolverKind,
    context: &ResponseContext,
) -> Result<(), StreamError> {
    if matches!(
        kind,
        APIResolverKind::OpenAIResponses | APIResolverKind::OpenAIResponsesCompact
    ) {
        return Ok(());
    }

    let has_compaction = context
        .request
        .get("input")
        .and_then(Value::as_array)
        .is_some_and(|items| {
            items
                .iter()
                .any(|item| item.get("type").and_then(Value::as_str) == Some("compaction"))
        });

    if has_compaction {
        Err(StreamError::new(
            "unsupported_compaction_replay_wire",
            "api_resolver",
            "provider-native compaction items require the OpenAI Responses wire protocol",
        ))
    } else {
        Ok(())
    }
}
