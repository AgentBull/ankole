use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Number, Value};
use uuid::Uuid;

use super::error::StreamError;
use super::spec::{ApiResolverKind, ResponseContext};

#[derive(Debug)]
pub struct ApiResolver {
    context: ResponseContext,
    protocol: Box<dyn ApiProtocol>,
}

trait ApiProtocol: std::fmt::Debug + Send + Sync {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(context.resolved_request_object())
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

impl ApiResolver {
    pub fn new(kind: ApiResolverKind, context: ResponseContext) -> Self {
        let protocol = make_protocol(kind, &context);
        Self { context, protocol }
    }

    pub fn build_body(&self) -> Result<Map<String, Value>, StreamError> {
        self.protocol.build_body(&self.context)
    }

    pub fn websocket_initial_messages(&self) -> Result<Vec<String>, StreamError> {
        self.protocol.websocket_initial_messages(&self.context)
    }

    pub fn ingest(&mut self, value: Value) -> Result<Vec<Value>, StreamError> {
        self.protocol.on_provider_event(&self.context, value)
    }

    pub fn finish(&mut self) -> Result<Vec<Value>, StreamError> {
        self.protocol.on_upstream_close(&self.context)
    }

    pub fn is_terminal(&self) -> bool {
        self.protocol.is_terminal()
    }

    pub fn fail(&mut self, error: &StreamError) -> Vec<Value> {
        self.protocol.on_transport_error(&self.context, error)
    }

    pub fn normalize_body(&mut self, status: u16, body: Value) -> Result<Value, StreamError> {
        self.protocol.on_provider_body(&self.context, status, body)
    }
}

fn make_protocol(kind: ApiResolverKind, context: &ResponseContext) -> Box<dyn ApiProtocol> {
    match kind.canonical() {
        ApiResolverKind::OpenaiResponses => Box::new(OpenaiResponsesState::default()),
        ApiResolverKind::OpenaiChatCompletions => Box::new(ChatState::new(context.model.clone())),
        ApiResolverKind::AnthropicMessages => Box::new(AnthropicState::new(context.model.clone())),
        ApiResolverKind::GeminiGenerateContent => {
            Box::new(GoogleGeminiState::new(context.model.clone()))
        }
        ApiResolverKind::BedrockConverse => {
            Box::new(AwsBedrockConverseState::new(context.model.clone()))
        }
        ApiResolverKind::OpenaiEmbeddings => Box::new(OpenaiEmbeddings),
        ApiResolverKind::OpenrouterEmbeddings => Box::new(OpenrouterEmbeddings),
        ApiResolverKind::JinaEmbeddings => Box::new(JinaEmbeddings),
        ApiResolverKind::GoogleEmbeddings => Box::new(GoogleEmbeddings),
        ApiResolverKind::OpenrouterRerank => Box::new(OpenrouterRerank),
        ApiResolverKind::JinaRerank => Box::new(JinaRerank),
    }
}
