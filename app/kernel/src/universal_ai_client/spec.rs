use std::time::Duration;

use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::common::{KernelError, KernelResult};

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum APIResolverKind {
    #[serde(rename = "openai_responses")]
    OpenAIResponses,
    #[serde(rename = "openai_chat_completions")]
    OpenAIChatCompletions,
    AnthropicMessages,
    GeminiGenerateContent,
    BedrockConverse,
    #[serde(rename = "openai_embeddings")]
    OpenAIEmbeddings,
    OpenrouterEmbeddings,
    JinaEmbeddings,
    GoogleEmbeddings,
    OpenrouterRerank,
    JinaRerank,
    ParallelWebSearch,
    ParallelWebFetch,
    BrightDataSerpWebSearch,
    AgentbullWebSearch,
    JinaSearchWebSearch,
    JinaReaderWebFetch,
}

impl APIResolverKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OpenAIResponses => "openai_responses",
            Self::OpenAIChatCompletions => "openai_chat_completions",
            Self::AnthropicMessages => "anthropic_messages",
            Self::GeminiGenerateContent => "gemini_generate_content",
            Self::BedrockConverse => "bedrock_converse",
            Self::OpenAIEmbeddings => "openai_embeddings",
            Self::OpenrouterEmbeddings => "openrouter_embeddings",
            Self::JinaEmbeddings => "jina_embeddings",
            Self::GoogleEmbeddings => "google_embeddings",
            Self::OpenrouterRerank => "openrouter_rerank",
            Self::JinaRerank => "jina_rerank",
            Self::ParallelWebSearch => "parallel_web_search",
            Self::ParallelWebFetch => "parallel_web_fetch",
            Self::BrightDataSerpWebSearch => "bright_data_serp_web_search",
            Self::AgentbullWebSearch => "agentbull_web_search",
            Self::JinaSearchWebSearch => "jina_search_web_search",
            Self::JinaReaderWebFetch => "jina_reader_web_fetch",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum UpstreamKind {
    #[serde(rename = "http_sse")]
    HTTPSSE,
    #[serde(rename = "http_eventstream")]
    HTTPEventstream,
    #[serde(rename = "websocket_text")]
    WebSocketText,
}

impl UpstreamKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HTTPSSE => "http_sse",
            Self::HTTPEventstream => "http_eventstream",
            Self::WebSocketText => "websocket_text",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum DownstreamKind {
    #[serde(rename = "sse")]
    SSE,
    #[serde(rename = "websocket_text")]
    WebSocketText,
}

impl DownstreamKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SSE => "sse",
            Self::WebSocketText => "websocket_text",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum HTTPVersionPreference {
    H3,
    H2,
    H1,
}

impl HTTPVersionPreference {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::H3 => "h3",
            Self::H2 => "h2",
            Self::H1 => "h1",
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum CompressionPreference {
    Zstd,
    Br,
    Gzip,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StreamSpec {
    pub api_resolver: APIResolverKind,
    pub upstream: UpstreamSpec,
    pub downstream: DownstreamKind,
    #[serde(default)]
    pub response_context: ResponseContext,
    #[serde(default)]
    pub limits: StreamLimits,
}

impl StreamSpec {
    pub fn from_json(json: &str) -> KernelResult<Self> {
        let spec: Self = sonic_rs::from_str(json).map_err(|reason| {
            KernelError::new(format!("spec must contain valid JSON: {reason}"))
        })?;
        spec.validate()?;
        Ok(spec)
    }

    fn validate(&self) -> KernelResult<()> {
        match self.upstream.kind {
            UpstreamKind::HTTPSSE | UpstreamKind::HTTPEventstream => {
                if self.upstream.url.starts_with("ws://") || self.upstream.url.starts_with("wss://")
                {
                    return Err(KernelError::new(
                        "HTTP upstream kind requires an http:// or https:// URL",
                    ));
                }
            }
            UpstreamKind::WebSocketText => {
                if !self.upstream.url.starts_with("ws://")
                    && !self.upstream.url.starts_with("wss://")
                {
                    return Err(KernelError::new(
                        "websocket_text upstream kind requires a ws:// or wss:// URL",
                    ));
                }
            }
        }

        if self.upstream.method.trim().is_empty() {
            return Err(KernelError::new("upstream.method must not be empty"));
        }

        if self.upstream.url.trim().is_empty() {
            return Err(KernelError::new("upstream.url must not be empty"));
        }

        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct UpstreamSpec {
    pub kind: UpstreamKind,
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub websocket_initial_messages: Vec<String>,
    #[serde(default)]
    pub timeout: TimeoutSpec,
    #[serde(default)]
    pub transport: TransportSpec,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PreparedHTTPRequestSpec {
    pub method: String,
    pub url: String,
    #[serde(default)]
    pub headers: Vec<(String, String)>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub timeout: TimeoutSpec,
    #[serde(default)]
    pub transport: TransportSpec,
}

#[derive(Debug, Clone, Deserialize)]
pub struct TimeoutSpec {
    #[serde(default = "default_connect_ms")]
    pub connect_ms: u64,
    #[serde(default = "default_first_byte_ms")]
    pub first_byte_ms: u64,
    #[serde(default = "default_idle_ms")]
    pub idle_ms: u64,
    #[serde(default)]
    pub total_ms: Option<u64>,
}

impl Default for TimeoutSpec {
    fn default() -> Self {
        Self {
            connect_ms: default_connect_ms(),
            first_byte_ms: default_first_byte_ms(),
            idle_ms: default_idle_ms(),
            total_ms: None,
        }
    }
}

impl TimeoutSpec {
    pub fn connect_duration(&self) -> Duration {
        Duration::from_millis(self.connect_ms.max(1))
    }

    pub fn first_byte_duration(&self) -> Duration {
        Duration::from_millis(self.first_byte_ms.max(1))
    }

    pub fn idle_duration(&self) -> Duration {
        Duration::from_millis(self.idle_ms.max(1))
    }

    pub fn total_duration(&self) -> Option<Duration> {
        self.total_ms
            .map(|value| Duration::from_millis(value.max(1)))
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct TransportSpec {
    #[serde(default = "default_http_versions")]
    pub http_versions: Vec<HTTPVersionPreference>,
    #[serde(default = "default_compression")]
    pub compression: Vec<CompressionPreference>,
    #[serde(default)]
    pub proxy: Option<String>,
}

impl Default for TransportSpec {
    fn default() -> Self {
        Self {
            http_versions: default_http_versions(),
            compression: default_compression(),
            proxy: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct StreamLimits {
    #[serde(default = "default_max_sse_event_bytes")]
    pub max_sse_event_bytes: usize,
    #[serde(default = "default_max_eventstream_frame_bytes")]
    pub max_eventstream_frame_bytes: usize,
    #[serde(default = "default_max_websocket_text_bytes")]
    pub max_websocket_text_bytes: usize,
    #[serde(default = "default_max_pending_chunks")]
    pub max_pending_chunks: usize,
    #[serde(default = "default_max_pending_bytes")]
    pub max_pending_bytes: usize,
}

impl Default for StreamLimits {
    fn default() -> Self {
        Self {
            max_sse_event_bytes: default_max_sse_event_bytes(),
            max_eventstream_frame_bytes: default_max_eventstream_frame_bytes(),
            max_websocket_text_bytes: default_max_websocket_text_bytes(),
            max_pending_chunks: default_max_pending_chunks(),
            max_pending_bytes: default_max_pending_bytes(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct RequestLimits {
    #[serde(default = "default_max_response_bytes")]
    pub max_response_bytes: usize,
}

impl Default for RequestLimits {
    fn default() -> Self {
        Self {
            max_response_bytes: default_max_response_bytes(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ResponseContext {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub request: Value,
    #[serde(default)]
    pub provider_options: Value,
    #[serde(default)]
    pub stream: Option<bool>,
    #[serde(default = "default_include_model")]
    pub include_model: bool,
}

impl Default for ResponseContext {
    fn default() -> Self {
        Self {
            model: String::new(),
            request: Value::Null,
            provider_options: Value::Null,
            stream: None,
            include_model: true,
        }
    }
}

impl ResponseContext {
    pub fn resolved_request(&self) -> Value {
        Value::Object(self.resolved_request_object())
    }

    pub fn resolved_request_object(&self) -> Map<String, Value> {
        let mut request = self
            .provider_options
            .as_object()
            .cloned()
            .unwrap_or_default();

        if let Some(input) = self.request.as_object() {
            for (key, value) in input {
                request.insert(key.clone(), value.clone());
            }
        }

        request.remove("previous_response_id");
        request.remove("provider_options");

        if let Some(stream) = self.stream {
            request.insert("stream".to_string(), json!(stream));
        }

        if self.include_model {
            request.insert("model".to_string(), json!(self.model));
        } else {
            request.remove("model");
        }

        request
    }

    pub fn resolved_provider_request(&self) -> Value {
        Value::Object(self.resolved_provider_request_object())
    }

    pub fn resolved_provider_request_object(&self) -> Map<String, Value> {
        let mut request = self.resolved_request_object();
        request.remove("service_tier");
        normalize_compaction_input(&mut request);
        request
    }
}

fn normalize_compaction_input(request: &mut Map<String, Value>) {
    let Some(Value::Array(items)) = request.get_mut("input") else {
        return;
    };

    for item in items {
        if let Some(normalized) = normalize_compaction_item(item) {
            *item = normalized;
        }
    }
}

fn normalize_compaction_item(item: &Value) -> Option<Value> {
    let map = item.as_object()?;
    if map.get("type").and_then(Value::as_str) != Some("compaction") {
        return None;
    }

    let summary = map
        .get("summary")
        .or_else(|| map.get("encrypted_content"))
        .map(value_to_prompt_text)
        .filter(|text| !text.trim().is_empty())
        .unwrap_or_else(|| value_to_prompt_text(item));

    let projected_summary = format!(
        "Context checkpoint: an earlier context window of this same agent already worked on this task and was compacted into the summary below. Tool side effects (files created or edited, commands run, processes started) remain in effect. Messages after this summary are verbatim and take precedence over it; continue the summary's in-progress work unless later messages supersede it.\n\n{summary}"
    );

    Some(json!({
        "type": "message",
        "role": "user",
        "content": [{
            "type": "input_text",
            "text": projected_summary
        }]
    }))
}

fn value_to_prompt_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => String::new(),
        value => serde_json::to_string(value).unwrap_or_default(),
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ModelRequestSpec {
    pub api_resolver: APIResolverKind,
    pub upstream: PreparedHTTPRequestSpec,
    #[serde(default)]
    pub response_context: ResponseContext,
    #[serde(default)]
    pub limits: RequestLimits,
}

impl ModelRequestSpec {
    pub fn from_json(json: &str) -> KernelResult<Self> {
        let spec: Self = sonic_rs::from_str(json).map_err(|reason| {
            KernelError::new(format!(
                "model request spec must contain valid JSON: {reason}"
            ))
        })?;
        spec.validate()?;
        Ok(spec)
    }

    fn validate(&self) -> KernelResult<()> {
        validate_prepared_http_request(&self.upstream, "model_request")
    }

    pub fn stream_upstream(&self) -> UpstreamSpec {
        UpstreamSpec {
            kind: UpstreamKind::HTTPSSE,
            method: self.upstream.method.clone(),
            url: self.upstream.url.clone(),
            headers: self.upstream.headers.clone(),
            body: self.upstream.body.clone(),
            websocket_initial_messages: Vec::new(),
            timeout: self.upstream.timeout.clone(),
            transport: self.upstream.transport.clone(),
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct RawRequestSpec {
    pub upstream: PreparedHTTPRequestSpec,
    #[serde(default)]
    pub limits: RequestLimits,
}

impl RawRequestSpec {
    pub fn from_json(json: &str) -> KernelResult<Self> {
        let spec: Self = sonic_rs::from_str(json).map_err(|reason| {
            KernelError::new(format!(
                "raw request spec must contain valid JSON: {reason}"
            ))
        })?;
        spec.validate()?;
        Ok(spec)
    }

    fn validate(&self) -> KernelResult<()> {
        validate_prepared_http_request(&self.upstream, "raw_request")
    }

    pub fn stream_upstream(&self) -> UpstreamSpec {
        UpstreamSpec {
            kind: UpstreamKind::HTTPSSE,
            method: self.upstream.method.clone(),
            url: self.upstream.url.clone(),
            headers: self.upstream.headers.clone(),
            body: self.upstream.body.clone(),
            websocket_initial_messages: Vec::new(),
            timeout: self.upstream.timeout.clone(),
            transport: self.upstream.transport.clone(),
        }
    }
}

fn default_connect_ms() -> u64 {
    30_000
}

fn default_first_byte_ms() -> u64 {
    default_model_request_timeout_ms()
}

fn default_idle_ms() -> u64 {
    default_model_request_timeout_ms()
}

fn default_model_request_timeout_ms() -> u64 {
    1_800_000
}

fn default_http_versions() -> Vec<HTTPVersionPreference> {
    vec![
        HTTPVersionPreference::H3,
        HTTPVersionPreference::H2,
        HTTPVersionPreference::H1,
    ]
}

fn default_compression() -> Vec<CompressionPreference> {
    vec![
        CompressionPreference::Zstd,
        CompressionPreference::Br,
        CompressionPreference::Gzip,
    ]
}

fn default_max_sse_event_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_max_eventstream_frame_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_max_websocket_text_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_max_pending_chunks() -> usize {
    256
}

fn default_max_pending_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_max_response_bytes() -> usize {
    16 * 1024 * 1024
}

fn default_include_model() -> bool {
    true
}

fn validate_prepared_http_request(
    upstream: &PreparedHTTPRequestSpec,
    label: &str,
) -> KernelResult<()> {
    if upstream.url.starts_with("ws://") || upstream.url.starts_with("wss://") {
        return Err(KernelError::new(format!(
            "{label} requires an http:// or https:// URL"
        )));
    }

    if upstream.method.trim().is_empty() {
        return Err(KernelError::new("upstream.method must not be empty"));
    }

    if upstream.url.trim().is_empty() {
        return Err(KernelError::new("upstream.url must not be empty"));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_spec_default_timeout_uses_model_request_budget() {
        let spec = StreamSpec::from_json(
            r#"{
              "api_resolver": "openai_chat_completions",
              "upstream": {
                "kind": "http_sse",
                "method": "POST",
                "url": "https://example.test/v1/chat/completions"
              },
              "downstream": "sse"
            }"#,
        )
        .unwrap();

        assert_eq!(spec.upstream.timeout.connect_ms, 30_000);
        assert_eq!(spec.upstream.timeout.first_byte_ms, 1_800_000);
        assert_eq!(spec.upstream.timeout.idle_ms, 1_800_000);
        assert_eq!(spec.upstream.timeout.total_ms, None);
    }

    #[test]
    fn response_context_merges_provider_options_without_leaking_control_field() {
        let context = ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": "hello",
                "provider_options": {"reasoningEffort": "high"},
                "previous_response_id": "resp_old",
                "prompt_cache_key": "cache-a",
                "service_tier": "agent_computer",
                "stream_options": {"include_usage": true}
            }),
            provider_options: json!({"reasoningEffort": "minimal", "textVerbosity": "low"}),
            stream: Some(false),
            include_model: true,
        };

        let request = context.resolved_request_object();

        assert_eq!(request.get("input"), Some(&json!("hello")));
        assert_eq!(request.get("reasoningEffort"), Some(&json!("minimal")));
        assert_eq!(request.get("textVerbosity"), Some(&json!("low")));
        assert_eq!(request.get("stream"), Some(&json!(false)));
        assert_eq!(request.get("model"), Some(&json!("gpt-test")));
        assert_eq!(request.get("prompt_cache_key"), Some(&json!("cache-a")));
        assert_eq!(request.get("service_tier"), Some(&json!("agent_computer")));
        assert_eq!(
            request.get("stream_options"),
            Some(&json!({"include_usage": true}))
        );
        assert!(!request.contains_key("provider_options"));
        assert!(!request.contains_key("previous_response_id"));

        let provider_request = context.resolved_provider_request_object();

        assert_eq!(provider_request.get("input"), Some(&json!("hello")));
        assert_eq!(
            provider_request.get("reasoningEffort"),
            Some(&json!("minimal"))
        );
        assert_eq!(
            provider_request.get("prompt_cache_key"),
            Some(&json!("cache-a"))
        );
        assert_eq!(
            provider_request.get("stream_options"),
            Some(&json!({"include_usage": true}))
        );
        assert!(!provider_request.contains_key("service_tier"));
    }

    #[test]
    fn response_context_preserves_codex_encrypted_reasoning_request_fields() {
        let context = ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "include": ["reasoning.encrypted_content"],
                "input": [
                    {
                        "type": "reasoning",
                        "id": "rs_previous",
                        "encrypted_content": "encrypted-reasoning-payload"
                    },
                    {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "continue"}]
                    }
                ],
                "store": false
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        };

        let provider_request = context.resolved_provider_request_object();

        assert_eq!(
            provider_request.get("include"),
            Some(&json!(["reasoning.encrypted_content"]))
        );
        assert_eq!(
            provider_request
                .get("input")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(|item| item.get("encrypted_content")),
            Some(&json!("encrypted-reasoning-payload"))
        );
        assert_eq!(provider_request.get("store"), Some(&json!(false)));
    }

    #[test]
    fn provider_request_projects_internal_compaction_items_as_user_text() {
        let context = ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [
                    {"type": "compaction", "summary": "Prior work was summarized."},
                    {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "continue"}]}
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        };

        let provider_request = context.resolved_provider_request_object();
        let input = provider_request
            .get("input")
            .and_then(Value::as_array)
            .unwrap();

        assert_eq!(input[0]["type"], json!("message"));
        assert_eq!(input[0]["role"], json!("user"));
        assert_eq!(
            input[0]["content"][0]["text"],
            json!(
                "Context checkpoint: an earlier context window of this same agent already worked on this task and was compacted into the summary below. Tool side effects (files created or edited, commands run, processes started) remain in effect. Messages after this summary are verbatim and take precedence over it; continue the summary's in-progress work unless later messages supersede it.\n\nPrior work was summarized."
            )
        );
        assert_eq!(input[1]["type"], json!("message"));
    }

    #[test]
    fn provider_request_projects_openresponses_compaction_items_as_user_text() {
        let context = ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [
                    {"type": "compaction", "encrypted_content": "OpenResponses compacted state."},
                    {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "continue"}]}
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        };

        let provider_request = context.resolved_provider_request_object();
        let input = provider_request
            .get("input")
            .and_then(Value::as_array)
            .unwrap();

        assert_eq!(input[0]["type"], json!("message"));
        assert_eq!(
            input[0]["content"][0]["text"],
            json!(
                "Context checkpoint: an earlier context window of this same agent already worked on this task and was compacted into the summary below. Tool side effects (files created or edited, commands run, processes started) remain in effect. Messages after this summary are verbatim and take precedence over it; continue the summary's in-progress work unless later messages supersede it.\n\nOpenResponses compacted state."
            )
        );
        assert_eq!(input[1]["type"], json!("message"));
    }
}
