use serde_json::Value;

use super::api_resolver::ApiResolver;
use super::error::StreamError;
use super::spec::{ModelRequestSpec, StreamSpec, UpstreamKind, UpstreamSpec};

pub fn prepare_stream_spec(mut spec: StreamSpec) -> Result<StreamSpec, StreamError> {
    match spec.upstream.kind {
        UpstreamKind::WebsocketText => {
            if spec.upstream.websocket_initial_messages.is_empty() {
                let resolver = ApiResolver::new(spec.api_resolver, spec.response_context.clone());
                spec.upstream.websocket_initial_messages = resolver.websocket_initial_messages()?;
            }
            spec.upstream.body = None;
        }
        UpstreamKind::HttpSse | UpstreamKind::HttpEventstream => {
            let resolver = ApiResolver::new(spec.api_resolver, spec.response_context.clone());
            spec.upstream.body = Some(encode_json(Value::Object(resolver.build_body()?))?);
            put_default_model_headers(&mut spec.upstream);
        }
    }

    Ok(spec)
}

pub fn prepare_model_upstream(spec: &ModelRequestSpec) -> Result<UpstreamSpec, StreamError> {
    let mut upstream = spec.stream_upstream();
    let resolver = ApiResolver::new(spec.api_resolver, spec.response_context.clone());
    upstream.body = Some(encode_json(Value::Object(resolver.build_body()?))?);
    put_default_json_headers(&mut upstream);
    Ok(upstream)
}

fn put_default_model_headers(upstream: &mut UpstreamSpec) {
    put_new_header(&mut upstream.headers, "content-type", "application/json");

    match upstream.kind {
        UpstreamKind::HttpSse => {
            put_new_header(&mut upstream.headers, "accept", "text/event-stream")
        }
        UpstreamKind::HttpEventstream => put_new_header(
            &mut upstream.headers,
            "accept",
            "application/vnd.amazon.eventstream",
        ),
        UpstreamKind::WebsocketText => {}
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

fn encode_json(value: Value) -> Result<String, StreamError> {
    sonic_rs::to_string(&value).map_err(|reason| {
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

    use super::super::spec::{ApiResolverKind, ResponseContext};
    use super::*;

    fn protocol_body(kind: ApiResolverKind, context: ResponseContext) -> Value {
        let resolver = ApiResolver::new(kind, context);
        sonic_rs::from_str(&encode_json(Value::Object(resolver.build_body().unwrap())).unwrap())
            .unwrap()
    }

    #[test]
    fn google_embeddings_body_builds_embed_content_request() {
        let body = protocol_body(
            ApiResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "gemini-embedding-001".to_string(),
                request: json!({"input": "hello", "dimensions": 2}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        assert_eq!(body["model"], "models/gemini-embedding-001");
        assert_eq!(body["content"], json!({"parts": [{"text": "hello"}]}));
        assert_eq!(body["embedContentConfig"]["outputDimensionality"], 2);
    }

    #[test]
    fn google_embeddings_body_builds_batch_embed_contents_request() {
        let body = protocol_body(
            ApiResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "models/gemini-embedding-001".to_string(),
                request: json!({"input": ["hello", "world"], "taskType": "RETRIEVAL_DOCUMENT"}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
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
            ApiResolverKind::OpenaiChatCompletions,
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
            ApiResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-sonnet".to_string(),
                request: json!({"input": "hello", "max_output_tokens": 128}),
                provider_options: json!({
                    "thinking": {"type": "enabled", "budget_tokens": 1024}
                }),
                stream: Some(false),
                include_model: true,
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
