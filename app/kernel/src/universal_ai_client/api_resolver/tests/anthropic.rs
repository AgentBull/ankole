use super::super::*;
use super::support::reasoning_source_context;

#[test]
fn anthropic_non_streaming_round_trips_thinking_blocks() {
    let native_content = json!([
        {
            "type": "thinking",
            "thinking": "Use the lookup tool.",
            "signature": "signed-thinking"
        },
        {
            "type": "redacted_thinking",
            "data": "opaque-redacted-state"
        },
        {
            "type": "text",
            "text": "I will look it up."
        },
        {
            "type": "tool_use",
            "id": "toolu_lookup",
            "name": "lookup",
            "input": {"query": "weather"}
        }
    ]);
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context("claude", "claude-test", json!({"input": "start"})),
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "msg_thinking",
                "model": "claude-test",
                "content": native_content,
                "stop_reason": "tool_use",
                "usage": {}
            }),
        )
        .unwrap();
    let output = response["output"].as_array().unwrap();
    assert_eq!(output[0]["type"], "reasoning");
    assert!(
        output[0]["encrypted_content"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-anthropic-reasoning:")
    );

    let mut replay_input = output.clone();
    replay_input.push(json!({
        "type": "function_call_output",
        "call_id": "toolu_lookup",
        "output": "sunny"
    }));
    let replay = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context(
            "claude",
            "claude-test",
            json!({"input": Value::Array(replay_input.clone())}),
        ),
    );
    let body = Value::Object(replay.build_body().unwrap());

    assert_eq!(body["messages"].as_array().unwrap().len(), 2);
    assert_eq!(body["messages"][0]["role"], "assistant");
    assert_eq!(body["messages"][0]["content"], native_content);
    assert_eq!(body["messages"][1]["content"][0]["type"], "tool_result");
}

#[test]
fn anthropic_stream_round_trips_thinking_and_signature_deltas() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context("claude", "claude-test", json!({"input": "start"})),
    );
    let mut events = Vec::new();
    for event in [
        json!({
            "type": "message_start",
            "message": {"id": "msg_stream_thinking", "model": "claude-test"}
        }),
        json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": "", "signature": ""}
        }),
        json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "Check the "}
        }),
        json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "evidence."}
        }),
        json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "signed-"}
        }),
        json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "stream"}
        }),
        json!({"type": "content_block_stop", "index": 0}),
        json!({
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "text", "text": ""}
        }),
        json!({
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "text_delta", "text": "Done."}
        }),
        json!({"type": "content_block_stop", "index": 1}),
        json!({
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 4}
        }),
        json!({"type": "message_stop"}),
    ] {
        events.extend(resolver.ingest(event).unwrap());
    }

    let terminal = events.last().unwrap();
    let output = terminal["response"]["output"].as_array().unwrap();
    assert_eq!(output[0]["type"], "reasoning");
    assert!(events.iter().any(|event| {
        event["type"] == "response.output_item.done"
            && event["item"]["type"] == "reasoning"
            && event["item"]["encrypted_content"].is_string()
    }));

    let mut replay_input = output.clone();
    replay_input.push(json!({
        "type": "message",
        "role": "user",
        "content": "continue"
    }));
    let replay = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context(
            "claude",
            "claude-test",
            json!({"input": Value::Array(replay_input.clone())}),
        ),
    );
    let body = Value::Object(replay.build_body().unwrap());

    assert_eq!(body["messages"].as_array().unwrap().len(), 2);
    assert_eq!(
        body["messages"][0]["content"],
        json!([
            {
                "type": "thinking",
                "thinking": "Check the evidence.",
                "signature": "signed-stream"
            },
            {"type": "text", "text": "Done."}
        ])
    );

    // Claude verifies a thinking signature against the model that minted it, so
    // another model's turn keeps the visible message and drops the private state.
    let foreign = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context(
            "claude",
            "claude-other",
            json!({"input": Value::Array(replay_input)}),
        ),
    );
    let foreign_body = Value::Object(foreign.build_body().unwrap());

    assert_eq!(
        foreign_body["messages"][0]["content"],
        json!([{"type": "text", "text": "Done."}])
    );
}

#[test]
fn anthropic_replays_tool_calls_without_a_reasoning_envelope() {
    let replay_input = json!([
        {
            "id": "msg_plain",
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{"type": "output_text", "text": "Looking it up."}]
        },
        {
            "id": "fc_plain",
            "type": "function_call",
            "call_id": "toolu_plain",
            "name": "lookup",
            "arguments": "{\"query\":\"weather\"}",
            "status": "completed"
        },
        {
            "type": "function_call_output",
            "call_id": "toolu_plain",
            "output": "sunny"
        }
    ]);
    let replay = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        reasoning_source_context("claude", "claude-test", json!({"input": replay_input})),
    );
    let body = Value::Object(replay.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    // Thinking is off, so the turn rebuilds from the public items alone.
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[0]["role"], "assistant");
    assert_eq!(
        messages[0]["content"],
        json!([
            {"type": "text", "text": "Looking it up."},
            {
                "type": "tool_use",
                "id": "toolu_plain",
                "name": "lookup",
                "input": {"query": "weather"}
            }
        ])
    );
    assert_eq!(messages[1]["role"], "user");
    assert_eq!(messages[1]["content"][0]["type"], "tool_result");
    assert_eq!(messages[1]["content"][0]["tool_use_id"], "toolu_plain");
}

#[test]
fn anthropic_text_stream_accumulates_response_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    resolver
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 1}}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "hello"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 2}
        }))
        .unwrap();
    let events = resolver.ingest(json!({"type": "message_stop"})).unwrap();
    let terminal = events.last().unwrap();

    assert_eq!(terminal["type"], "response.completed");
    assert_eq!(
        terminal["response"]["output"][0]["content"][0]["text"],
        "hello"
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 3);
}

#[test]
fn anthropic_usage_counts_cache_reads_and_writes_as_input() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    resolver
        .ingest(json!({
            "type": "message_start",
            "message": {
                "id": "msg_cache",
                "model": "claude-test",
                "usage": {
                    "input_tokens": 3,
                    "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 20,
                    "output_tokens": 1
                }
            }
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "cached"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "message_delta",
            "delta": {"stop_reason": "end_turn"},
            "usage": {"output_tokens": 5}
        }))
        .unwrap();
    let events = resolver.ingest(json!({"type": "message_stop"})).unwrap();
    let usage = &events.last().unwrap()["response"]["usage"];

    assert_eq!(usage["input_tokens"], 33);
    assert_eq!(usage["output_tokens"], 5);
    assert_eq!(usage["total_tokens"], 38);
    assert_eq!(usage["input_tokens_details"]["cached_tokens"], 20);
    assert_eq!(usage["input_tokens_details"]["cache_creation_tokens"], 10);
}

#[test]
fn anthropic_message_stop_closes_open_text_block() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    resolver
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_1", "model": "claude-test"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "text"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "text_delta", "text": "hello"}
        }))
        .unwrap();

    let events = resolver
        .ingest(json!({
            "type": "message_stop"
        }))
        .unwrap();

    assert!(
        events
            .iter()
            .any(|event| event["type"] == "response.output_text.done")
    );
    assert!(
        events
            .iter()
            .any(|event| event["type"] == "response.content_part.done")
    );
    assert_eq!(events.last().unwrap()["type"], "response.completed");
}

#[test]
fn anthropic_eof_keeps_partial_tool_call_incomplete_without_done_events() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    resolver
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_partial", "model": "claude-test"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "tool_use", "id": "call_partial", "name": "patch"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "input_json_delta", "partial_json": "{\"path\":\"/tmp/repor"}
        }))
        .unwrap();

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call")
        .unwrap();

    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(call["status"], "incomplete");
    assert_eq!(call["arguments"], "{\"path\":\"/tmp/repor");
    assert!(!events.iter().any(|event| {
        matches!(
            event["type"].as_str(),
            Some("response.function_call_arguments.done" | "response.output_item.done")
        )
    }));
}

#[test]
fn anthropic_build_body_maps_openresponses_images_to_image_blocks() {
    let resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({
                "input": [{
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "describe"},
                        {"type": "input_image", "image_url": "data:image/png;base64,aW1hZ2U="},
                        {"type": "input_image", "image_url": {"url": "https://example.test/image.webp"}},
                        {"type": "custom_image_payload", "data": "SHOULD_NOT_APPEAR_IN_TEXT"}
                    ]
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let content = body["messages"][0]["content"].as_array().unwrap();

    assert_eq!(content[0], json!({"type": "text", "text": "describe"}));
    assert_eq!(content[1]["type"], "image");
    assert_eq!(content[1]["source"]["type"], "base64");
    assert_eq!(content[1]["source"]["media_type"], "image/png");
    assert_eq!(content[1]["source"]["data"], "aW1hZ2U=");
    assert_eq!(content[2]["type"], "image");
    assert_eq!(content[2]["source"]["type"], "url");
    assert_eq!(
        content[2]["source"]["url"],
        "https://example.test/image.webp"
    );
    assert_eq!(
        content[3],
        json!({"type": "text", "text": "[image content omitted: unsupported image source]"})
    );
    assert!(
        !sonic_rs::to_string(&body)
            .unwrap()
            .contains("SHOULD_NOT_APPEAR_IN_TEXT")
    );
}

#[test]
fn anthropic_stream_max_tokens_stop_reason_maps_to_incomplete() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext::default(),
    );

    resolver
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_stream", "model": "claude-test"}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "type": "message_delta",
            "delta": {"stop_reason": "max_tokens"},
            "usage": {"output_tokens": 5}
        }))
        .unwrap();
    let events = resolver.ingest(json!({"type": "message_stop"})).unwrap();
    let terminal = events.last().unwrap();

    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(terminal["response"]["status"], "incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "max_output_tokens"
    );
    assert!(terminal["response"]["completed_at"].is_null());
}

#[test]
fn anthropic_stream_error_event_is_a_provider_failure_with_the_documented_status() {
    for (error_type, status) in [
        ("overloaded_error", Some(529)),
        ("rate_limit_error", Some(429)),
        ("api_error", Some(500)),
        ("invalid_request_error", Some(400)),
        ("undocumented_error", None),
    ] {
        let mut resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            ResponseContext::default(),
        );
        for event in [
            json!({
                "type": "message_start",
                "message": {"id": "msg_error", "model": "claude-test"}
            }),
            json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""}
            }),
            json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "partial"}
            }),
        ] {
            resolver.ingest(event).unwrap();
        }
        let event = json!({
            "type": "error",
            "error": {"type": error_type, "message": "provider message"}
        });

        let error = resolver.ingest(event.clone()).unwrap_err();

        assert_eq!(error.code, "provider_status_rejected");
        assert_eq!(error.message, "provider message");
        assert_eq!(error.provider_status, status, "{error_type}");
        let excerpt = error.provider_body_excerpt.as_deref().unwrap();
        assert_eq!(sonic_rs::from_str::<Value>(excerpt).unwrap(), event);

        let events = resolver.fail(&error);
        assert_eq!(events.len(), 1);
        let failed = &events[0]["response"];
        assert_eq!(events[0]["type"], "response.failed");
        assert_eq!(
            failed["error"]["details_json"]["provider_status"],
            json!(status)
        );
        assert_eq!(failed["output"][0]["status"], "incomplete");
        assert_eq!(failed["output"][0]["content"][0]["text"], "partial");
    }
}

#[test]
fn anthropic_one_shot_max_tokens_stop_reason_maps_to_incomplete() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext::default(),
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "msg_one_shot",
                "model": "claude-test",
                "content": [{"type": "text", "text": "truncated"}],
                "stop_reason": "max_tokens",
                "usage": {"input_tokens": 3, "output_tokens": 5}
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
    assert_eq!(response["usage"]["input_tokens"], 3);
    assert_eq!(response["usage"]["output_tokens"], 5);
}
