use serde_json::{Map, Value};

use super::api_resolver::{APIResolver, anthropic_v2026::resolve_anthropic_api_version};
use super::error::StreamError;
use super::spec::{
    APIResolverKind, ModelRequestSpec, ResponseContext, StreamSpec, UpstreamKind, UpstreamSpec,
};

pub(crate) fn prepare_stream_spec(mut spec: StreamSpec) -> Result<StreamSpec, StreamError> {
    match spec.upstream.kind {
        UpstreamKind::WebSocketText => {
            if spec.upstream.websocket_initial_messages.is_empty() {
                let resolver = APIResolver::new(spec.api_resolver, spec.response_context.clone());
                spec.upstream.websocket_initial_messages = resolver.websocket_initial_messages()?;
            }
            spec.upstream.body = None;
        }
        UpstreamKind::HTTPSSE | UpstreamKind::HTTPEventstream => {
            let context = context_with_header_anthropic_version(
                &spec.api_resolver,
                &spec.response_context,
                &spec.upstream,
            );
            let resolver = APIResolver::new(spec.api_resolver, context.clone());
            let body = resolver.build_body()?;
            put_resolved_anthropic_version(spec.api_resolver, &context, &body, &mut spec.upstream);
            spec.upstream.body = Some(encode_json(&Value::Object(body))?);
            put_default_model_headers(&mut spec.upstream);
        }
    }

    Ok(spec)
}

pub(crate) fn prepare_model_upstream(spec: &ModelRequestSpec) -> Result<UpstreamSpec, StreamError> {
    let mut upstream = spec.stream_upstream();
    let context = context_with_header_anthropic_version(
        &spec.api_resolver,
        &spec.response_context,
        &upstream,
    );
    let resolver = APIResolver::new(spec.api_resolver, context.clone());
    let body = resolver.build_body()?;
    put_resolved_anthropic_version(spec.api_resolver, &context, &body, &mut upstream);
    // A GET reads a resource that the request's URL names, such as the state
    // of a video generation, so it sends no body.
    if !upstream.method.eq_ignore_ascii_case("GET") {
        upstream.body = Some(encode_json(&Value::Object(body))?);
    }
    put_default_json_headers(&mut upstream);
    if let Some(credentials) = &spec.upstream.aws_sigv4 {
        super::aws_sigv4::sign(&mut upstream, credentials, std::time::SystemTime::now())?;
    }
    Ok(upstream)
}

fn context_with_header_anthropic_version(
    api_resolver: &APIResolverKind,
    context: &ResponseContext,
    upstream: &UpstreamSpec,
) -> ResponseContext {
    if *api_resolver != APIResolverKind::AnthropicMessages {
        return context.clone();
    }
    let Some(header_version) = upstream
        .headers
        .iter()
        .find(|(name, _)| name.eq_ignore_ascii_case("anthropic-version"))
        .map(|(_, value)| value.trim())
        .filter(|value| !value.is_empty())
    else {
        return context.clone();
    };
    let mut next = context.clone();
    let mut opts = next
        .provider_options
        .as_object()
        .cloned()
        .unwrap_or_default();
    let has_explicit = ["api_version", "anthropic_version", "anthropic-version"]
        .iter()
        .any(|k| {
            opts.get(*k)
                .and_then(Value::as_str)
                .is_some_and(|s| !s.trim().is_empty())
                || next
                    .request
                    .get(*k)
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.trim().is_empty())
        });
    if !has_explicit {
        opts.insert(
            "anthropic-version".to_string(),
            Value::String(header_version.to_string()),
        );
        next.provider_options = Value::Object(opts);
    }
    next
}

/// Anthropic selects its protocol through the request header, so the version
/// that shaped the body must also be sent when the caller did not set one.
fn put_resolved_anthropic_version(
    api_resolver: APIResolverKind,
    context: &ResponseContext,
    body: &Map<String, Value>,
    upstream: &mut UpstreamSpec,
) {
    if api_resolver != APIResolverKind::AnthropicMessages {
        return;
    }

    let request = context.resolved_provider_request_object();
    let version = resolve_anthropic_api_version(context, &request, body);
    put_new_header(&mut upstream.headers, "anthropic-version", version);
}

fn put_default_model_headers(upstream: &mut UpstreamSpec) {
    put_new_header(&mut upstream.headers, "content-type", "application/json");

    match upstream.kind {
        UpstreamKind::HTTPSSE => {
            put_new_header(&mut upstream.headers, "accept", "text/event-stream")
        }
        UpstreamKind::HTTPEventstream => put_new_header(
            &mut upstream.headers,
            "accept",
            "application/vnd.amazon.eventstream",
        ),
        UpstreamKind::WebSocketText => {}
    }
}

fn put_default_json_headers(upstream: &mut UpstreamSpec) {
    put_new_header(&mut upstream.headers, "content-type", "application/json");
    put_new_header(&mut upstream.headers, "accept", "application/json");
}

fn put_new_header(headers: &mut Vec<(String, String)>, name: &str, value: &str) {
    if headers
        .iter()
        .any(|(header, _value)| header.eq_ignore_ascii_case(name))
    {
        return;
    }

    headers.push((name.to_string(), value.to_string()));
}

fn encode_json(value: &Value) -> Result<String, StreamError> {
    sonic_rs::to_string(value).map_err(|reason| {
        StreamError::new(
            "request_encode_failed",
            "request_builder",
            format!("model request body could not be encoded as JSON: {reason}"),
        )
    })
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::super::spec::{
        APIResolverKind, ResponseContext, StreamLimits, StreamSpec, TimeoutSpec, TransportSpec,
        UpstreamKind, UpstreamSpec,
    };
    use super::*;

    fn protocol_body(kind: APIResolverKind, context: ResponseContext) -> Value {
        let resolver = APIResolver::new(kind, context);
        sonic_rs::from_str(&encode_json(&Value::Object(resolver.build_body().unwrap())).unwrap())
            .unwrap()
    }

    #[test]
    fn openai_responses_websocket_initial_message_preserves_provider_service_tier() {
        let spec = StreamSpec {
            api_resolver: APIResolverKind::OpenAIResponses,
            upstream: UpstreamSpec {
                kind: UpstreamKind::WebSocketText,
                method: "GET".to_string(),
                url: "wss://example.test/v1/responses".to_string(),
                headers: Vec::new(),
                body: None,
                websocket_initial_messages: Vec::new(),
                timeout: TimeoutSpec::default(),
                transport: TransportSpec::default(),
            },
            response_context: ResponseContext {
                model: "gpt-test".to_string(),
                request: json!({
                    "input": "hello",
                    "stream_options": {"include_usage": true},
                    "service_tier": "agent_computer",
                    "generate": false,
                    "client_metadata": {"traceparent": "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"}
                }),
                provider_options: json!({"service_tier": "priority"}),
                stream: Some(true),
                include_model: true,
                ..ResponseContext::default()
            },
            limits: StreamLimits::default(),
            hosted_tools: None,
        };

        let prepared = prepare_stream_spec(spec).unwrap();
        assert!(prepared.upstream.body.is_none());
        assert_eq!(prepared.upstream.websocket_initial_messages.len(), 1);

        let payload: Value =
            sonic_rs::from_str(&prepared.upstream.websocket_initial_messages[0]).unwrap();

        assert_eq!(payload["type"], "response.create");
        assert_eq!(payload["model"], "gpt-test");
        assert_eq!(payload["stream"], true);
        assert_eq!(payload["stream_options"], json!({"include_usage": true}));
        assert_eq!(payload["generate"], false);
        assert_eq!(
            payload["client_metadata"]["traceparent"],
            "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        );
        assert_eq!(payload["service_tier"], "priority");
    }

    #[test]
    fn anthropic_requests_send_the_resolved_protocol_version() {
        let spec = |headers: Vec<(String, String)>| StreamSpec {
            api_resolver: APIResolverKind::AnthropicMessages,
            upstream: UpstreamSpec {
                kind: UpstreamKind::HTTPSSE,
                method: "POST".to_string(),
                url: "https://api.anthropic.com/v1/messages".to_string(),
                headers,
                body: None,
                websocket_initial_messages: Vec::new(),
                timeout: TimeoutSpec::default(),
                transport: TransportSpec::default(),
            },
            response_context: ResponseContext {
                model: "claude-sonnet-5".to_string(),
                request: json!({"input": "hello"}),
                stream: Some(true),
                ..ResponseContext::default()
            },
            limits: StreamLimits::default(),
            hosted_tools: None,
        };

        let prepared = prepare_stream_spec(spec(Vec::new())).unwrap();
        let version = prepared
            .upstream
            .headers
            .iter()
            .find(|(name, _)| name == "anthropic-version")
            .map(|(_, value)| value.as_str());
        assert_eq!(version, Some("2026-10-21"));

        let explicit = vec![("anthropic-version".to_string(), "2023-06-01".to_string())];
        let prepared = prepare_stream_spec(spec(explicit)).unwrap();
        let version = prepared
            .upstream
            .headers
            .iter()
            .find(|(name, _)| name == "anthropic-version")
            .map(|(_, value)| value.as_str());
        assert_eq!(version, Some("2023-06-01"));
    }

    #[test]
    fn google_embeddings_body_builds_embed_content_request() {
        let body = protocol_body(
            APIResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "gemini-embedding-001".to_string(),
                request: json!({"input": "hello", "dimensions": 2}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
                ..ResponseContext::default()
            },
        );

        assert_eq!(body["model"], "models/gemini-embedding-001");
        assert_eq!(body["content"], json!({"parts": [{"text": "hello"}]}));
        assert_eq!(body["embedContentConfig"]["outputDimensionality"], 2);
    }

    #[test]
    fn google_embeddings_body_builds_batch_embed_contents_request() {
        let body = protocol_body(
            APIResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "models/gemini-embedding-001".to_string(),
                request: json!({"input": ["hello", "world"], "taskType": "RETRIEVAL_DOCUMENT"}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
                ..ResponseContext::default()
            },
        );

        assert_eq!(body["requests"][0]["model"], "models/gemini-embedding-001");
        assert_eq!(
            body["requests"][0]["content"],
            json!({"parts": [{"text": "hello"}]})
        );
        assert_eq!(
            body["requests"][1]["content"],
            json!({"parts": [{"text": "world"}]})
        );
        assert_eq!(
            body["requests"][0]["embedContentConfig"]["taskType"],
            "RETRIEVAL_DOCUMENT"
        );
    }

    #[test]
    fn openai_chat_body_keeps_provider_options_as_body_defaults() {
        let body = protocol_body(
            APIResolverKind::OpenAIChatCompletions,
            ResponseContext {
                model: "openrouter/model".to_string(),
                request: json!({
                    "input": "hello",
                    "extra_body": {"provider": {"sort": "throughput"}}
                }),
                provider_options: json!({
                    "reasoning": {"effort": "high"},
                    "reasoningEffort": "medium"
                }),
                stream: Some(false),
                include_model: true,
                ..ResponseContext::default()
            },
        );

        assert_eq!(body["model"], "openrouter/model");
        assert_eq!(body["reasoning"], json!({"effort": "high"}));
        assert_eq!(body["reasoningEffort"], "medium");
        assert_eq!(body["provider"], json!({"sort": "throughput"}));
        assert!(!body.as_object().unwrap().contains_key("provider_options"));
    }

    #[test]
    fn anthropic_messages_body_keeps_provider_options_as_body_defaults() {
        let body = protocol_body(
            APIResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-sonnet".to_string(),
                request: json!({"input": "hello", "max_output_tokens": 128}),
                provider_options: json!({
                    "thinking": {"type": "enabled", "budget_tokens": 1024}
                }),
                stream: Some(false),
                include_model: true,
                ..ResponseContext::default()
            },
        );

        assert_eq!(
            body["thinking"],
            json!({"type": "enabled", "budget_tokens": 1024})
        );
        assert_eq!(body["max_tokens"], 128);
        assert_eq!(body["model"], "claude-sonnet");
        assert!(!body.as_object().unwrap().contains_key("provider_options"));
    }
}
