use super::super::*;

#[test]
fn bedrock_converse_one_shot_body_maps_text_usage_and_stop_reason() {
    let mut resolver = APIResolver::new(
        APIResolverKind::BedrockConverse,
        ResponseContext {
            model: "bedrock-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
            ..ResponseContext::default()
        },
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "output": {"message": {"role": "assistant", "content": [
                    {"text": "hello "},
                    {"text": "bedrock"}
                ]}},
                "stopReason": "end_turn",
                "usage": {
                    "inputTokens": 3,
                    "outputTokens": 5,
                    "cacheReadInputTokens": 20,
                    "cacheWriteInputTokens": 10,
                    "totalTokens": 38
                },
                "metrics": {"latencyMs": 42}
            }),
        )
        .unwrap();

    assert_eq!(response["status"], "completed");
    assert!(!response["completed_at"].is_null());
    assert_eq!(response["output"][0]["type"], "message");
    assert_eq!(response["output"][0]["content"][0]["text"], "hello bedrock");
    // Bedrock reports cache reads and writes apart from `inputTokens`, so the
    // OpenResponses input count adds them back.
    assert_eq!(response["usage"]["input_tokens"], 33);
    assert_eq!(response["usage"]["output_tokens"], 5);
    assert_eq!(response["usage"]["total_tokens"], 38);
    assert_eq!(
        response["usage"]["input_tokens_details"]["cached_tokens"],
        20
    );
    assert_eq!(
        response["usage"]["input_tokens_details"]["cache_creation_tokens"],
        10
    );
}

#[test]
fn bedrock_converse_one_shot_max_tokens_maps_to_incomplete() {
    let mut resolver =
        APIResolver::new(APIResolverKind::BedrockConverse, ResponseContext::default());

    let response = resolver
        .normalize_body(
            200,
            json!({
                "output": {"message": {"content": [{"text": "truncated"}]}},
                "stopReason": "max_tokens",
                "usage": {"inputTokens": 3, "outputTokens": 5}
            }),
        )
        .unwrap();

    assert_eq!(response["status"], "incomplete");
    assert_eq!(
        response["incomplete_details"]["reason"],
        "max_output_tokens"
    );
    assert!(response["completed_at"].is_null());
    assert_eq!(response["output"][0]["content"][0]["text"], "truncated");
}

#[test]
fn bedrock_converse_safety_and_guardrail_stop_reasons_map_to_incomplete_content_filter() {
    for stop_reason in ["content_filtered", "guardrail_intervened"] {
        let mut one_shot = APIResolver::new(
            APIResolverKind::BedrockConverse,
            ResponseContext {
                policy: ConversionPolicy::Strict,
                ..ResponseContext::default()
            },
        );
        let response = one_shot
            .normalize_body(
                200,
                json!({
                    "output": {"message": {"content": [{"text": "blocked by policy"}]}},
                    "stopReason": stop_reason,
                    "usage": {"inputTokens": 4, "outputTokens": 3}
                }),
            )
            .unwrap();

        assert_eq!(response["status"], "incomplete");
        assert_eq!(response["incomplete_details"]["reason"], "content_filter");
        assert!(response["completed_at"].is_null());
        assert_eq!(response["output"][0]["status"], "incomplete");
        assert_eq!(
            response["output"][0]["content"][0]["text"],
            "blocked by policy"
        );

        let mut stream = APIResolver::new(
            APIResolverKind::BedrockConverse,
            ResponseContext {
                policy: ConversionPolicy::Strict,
                ..ResponseContext::default()
            },
        );
        stream
            .ingest(json!({"messageStop": {"stopReason": stop_reason}}))
            .unwrap();
        let events = stream.finish().unwrap();
        let terminal = events.last().unwrap();
        assert_eq!(terminal["type"], "response.incomplete");
        assert_eq!(terminal["response"]["status"], "incomplete");
        assert_eq!(
            terminal["response"]["incomplete_details"]["reason"],
            "content_filter"
        );
    }

    let mut unknown =
        APIResolver::new(APIResolverKind::BedrockConverse, ResponseContext::default());
    let error = unknown
        .normalize_body(
            200,
            json!({
                "output": {"message": {"content": []}},
                "stopReason": "unknown_stop_reason"
            }),
        )
        .unwrap_err();
    assert_eq!(error.code, "provider_terminal_rejected");
}
