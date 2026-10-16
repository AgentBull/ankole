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
                "usage": {"inputTokens": 3, "outputTokens": 5, "totalTokens": 8},
                "metrics": {"latencyMs": 42}
            }),
        )
        .unwrap();

    assert_eq!(response["status"], "completed");
    assert!(!response["completed_at"].is_null());
    assert_eq!(response["output"][0]["type"], "message");
    assert_eq!(response["output"][0]["content"][0]["text"], "hello bedrock");
    assert_eq!(response["usage"]["input_tokens"], 3);
    assert_eq!(response["usage"]["output_tokens"], 5);
    assert_eq!(response["usage"]["total_tokens"], 8);
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
fn bedrock_converse_one_shot_content_filtered_fails() {
    let mut resolver =
        APIResolver::new(APIResolverKind::BedrockConverse, ResponseContext::default());

    let error = resolver
        .normalize_body(
            200,
            json!({
                "output": {"message": {"content": [{"text": "blocked"}]}},
                "stopReason": "content_filtered"
            }),
        )
        .unwrap_err();

    assert_eq!(error.code, "provider_terminal_rejected");
}
