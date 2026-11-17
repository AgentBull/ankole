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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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

#[test]
fn anthropic_build_body_maps_required_tool_choice_to_any_when_thinking_is_off() {
    for provider_options in [
        json!({}),
        json!({"thinking": {"type": "disabled"}}),
        json!({"thinking": {"type": "between_tools"}}),
    ] {
        let resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: json!({
                    "input": "call a tool",
                    "tools": [{"type": "function", "name": "lookup", "parameters": {"type": "object"}}],
                    "tool_choice": "required"
                }),
                provider_options,
                stream: None,
                include_model: true,
                ..ResponseContext::default()
            },
        );

        let body = Value::Object(resolver.build_body().unwrap());
        assert_eq!(body["tool_choice"], json!({"type": "any"}));
    }
}

#[test]
fn anthropic_build_body_downgrades_forced_tool_choice_to_auto_when_thinking_is_enabled() {
    for thinking in [
        json!({"type": "enabled", "budget_tokens": 2048}),
        json!({"type": "adaptive"}),
    ] {
        for tool_choice in [
            json!("required"),
            json!("any"),
            json!({"type": "required"}),
            json!({"type": "function", "name": "lookup"}),
            json!({"type": "tool", "name": "lookup"}),
        ] {
            let resolver = APIResolver::new(
                APIResolverKind::AnthropicMessages,
                ResponseContext {
                    model: "claude-test".to_string(),
                    request: json!({
                        "input": "call a tool",
                        "tools": [{"type": "function", "name": "lookup", "parameters": {"type": "object"}}],
                        "tool_choice": tool_choice
                    }),
                    provider_options: json!({"thinking": thinking}),
                    stream: None,
                    include_model: true,
                    ..ResponseContext::default()
                },
            );

            let body = Value::Object(resolver.build_body().unwrap());
            assert_eq!(body["tool_choice"], json!({"type": "auto"}));
        }

        let none_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: json!({
                    "input": "do not call a tool",
                    "tools": [{"type": "function", "name": "lookup", "parameters": {"type": "object"}}],
                    "tool_choice": "none"
                }),
                provider_options: json!({"thinking": thinking}),
                stream: None,
                include_model: true,
                ..ResponseContext::default()
            },
        );

        let none_body = Value::Object(none_resolver.build_body().unwrap());
        assert_eq!(none_body["tool_choice"], json!({"type": "none"}));
    }
}

#[test]
fn anthropic_build_body_merges_consecutive_tool_outputs_into_one_user_message() {
    let resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({
                "input": [
                    {"type": "message", "role": "user", "content": "check weather and time"},
                    {"type": "function_call", "call_id": "call_1", "name": "weather", "arguments": "{\"city\":\"Paris\"}"},
                    {"type": "function_call", "call_id": "call_2", "name": "clock", "arguments": "{\"tz\":\"UTC\"}"},
                    {"type": "function_call_output", "call_id": "call_1", "output": "sunny"},
                    {"type": "function_call_output", "call_id": "call_2", "output": "12:00"}
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
            ..ResponseContext::default()
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(messages.len(), 3);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(messages[1]["role"], "assistant");
    assert_eq!(messages[1]["content"].as_array().unwrap().len(), 2);
    assert_eq!(messages[2]["role"], "user");
    assert_eq!(
        messages[2]["content"],
        json!([
            {"type": "tool_result", "tool_use_id": "call_1", "content": "sunny"},
            {"type": "tool_result", "tool_use_id": "call_2", "content": "12:00"}
        ])
    );
}

#[test]
fn anthropic_strict_rejects_unconsumed_fields() {
    for unexpressible in [
        json!({"model": "claude-test", "input": "hi", "response_format": "json_object"}),
        json!({"model": "claude-test", "input": "hi", "text": {"format": {"type": "json_object"}}}),
        json!({"model": "claude-test", "input": "hi", "text": {"format": {"type": "text", "extra": 1}}}),
        json!({"model": "claude-test", "input": "hi", "stop": ""}),
        json!({"model": "claude-test", "input": "hi", "tool_choice": "invalid_choice"}),
    ] {
        let resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: unexpressible,
                provider_options: json!({}),
                stream: None,
                include_model: true,
                policy: ConversionPolicy::Strict,
            },
        );
        let err = resolver.build_body().unwrap_err();
        assert_eq!(err.code, "unexpressible_field");
        assert_eq!(err.provider_status, Some(400));
    }
}

#[test]
fn anthropic_skips_null_output_limits_and_uses_max_tokens() {
    let resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({"input": "hello", "max_output_tokens": null, "max_tokens": 128}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let body = resolver.build_body().unwrap();
    assert_eq!(body["max_tokens"], 128);
}

#[test]
fn anthropic_strict_rejects_forced_tool_choice_when_thinking_is_enabled() {
    for tool_choice in [
        json!("required"),
        json!("any"),
        json!({"type": "required"}),
        json!({"type": "function", "name": "lookup"}),
        json!({"type": "tool", "name": "lookup"}),
    ] {
        let resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: json!({
                    "input": "call lookup",
                    "tools": [{"type": "function", "name": "lookup", "parameters": {"type": "object"}}],
                    "tool_choice": tool_choice
                }),
                provider_options: json!({"thinking": {"type": "enabled", "budget_tokens": 1024}}),
                stream: None,
                include_model: true,
                policy: ConversionPolicy::Strict,
            },
        );
        let err = resolver.build_body().unwrap_err();
        assert_eq!(err.code, "unexpressible_field");
        assert_eq!(err.provider_status, Some(400));
    }
}

#[test]
fn anthropic_refusal_stop_reason_maps_to_incomplete_content_filter_on_one_shot_and_stream() {
    let mut one_shot = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    let response = one_shot
        .normalize_body(
            200,
            json!({
                "id": "msg_refusal",
                "model": "claude-test",
                "content": [],
                "stop_reason": "refusal",
                "usage": {"input_tokens": 8, "output_tokens": 0}
            }),
        )
        .unwrap();
    assert_eq!(response["status"], "incomplete");
    assert_eq!(response["incomplete_details"]["reason"], "content_filter");
    assert!(response["completed_at"].is_null());
    assert_eq!(response["output"], json!([]));

    let mut stream = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    stream
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_stream_refusal", "model": "claude-test", "usage": {"input_tokens": 6}}
        }))
        .unwrap();
    stream
        .ingest(json!({
            "type": "message_delta",
            "delta": {"stop_reason": "refusal"},
            "usage": {"output_tokens": 0}
        }))
        .unwrap();
    let events = stream.ingest(json!({"type": "message_stop"})).unwrap();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(terminal["response"]["status"], "incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "content_filter"
    );
    assert!(terminal["response"]["completed_at"].is_null());
}

#[test]
fn anthropic_message_threads_create_and_continue_slice_coalesced_messages_and_omit_create_only_fields()
 {
    let source = json!({
        "provider_type": "claude",
        "model_id": "claude-sonnet-4-6",
        "account_id": "prov:cred"
    });
    let tools = json!([{
        "type": "function",
        "name": "calc",
        "description": "Calculator",
        "parameters": {"type": "object", "properties": {"expr": {"type": "string"}}}
    }]);

    // Turn 1: create thread with system, tools, thinking, and tool_use output.
    let turn1_ctx = ResponseContext {
        model: "claude-sonnet-4-6".to_string(),
        request: json!({
            "__ankole_reasoning_source": source,
            "__ankole_anthropic_thread": {"mode": "create"},
            "instructions": "Be concise.",
            "tools": tools,
            "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "2+2?"}]}]
        }),
        provider_options: json!({"thinking": {"type": "adaptive"}}),
        stream: Some(true),
        include_model: true,
        policy: ConversionPolicy::Strict,
    };
    let mut resolver1 = APIResolver::new(APIResolverKind::AnthropicMessages, turn1_ctx);
    let body1 = resolver1.build_body().unwrap();
    assert_eq!(body1["thread"], json!({"type": "create"}));
    assert_eq!(body1["system"], "Be concise.");
    assert!(body1.contains_key("tools"));
    assert_eq!(body1["messages"].as_array().unwrap().len(), 1);

    resolver1
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_turn_1", "model": "claude-sonnet-4-6", "usage": {"input_tokens": 20}}
        }))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "thinking", "thinking": "", "signature": ""}
        }))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "add"}
        }))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "sig_1"}
        }))
        .unwrap();
    resolver1
        .ingest(json!({"type": "content_block_stop", "index": 0}))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "content_block_start",
            "index": 1,
            "content_block": {"type": "tool_use", "id": "toolu_1", "name": "calc"}
        }))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "content_block_delta",
            "index": 1,
            "delta": {"type": "input_json_delta", "partial_json": "{\"expr\":\"2+2\"}"}
        }))
        .unwrap();
    resolver1
        .ingest(json!({"type": "content_block_stop", "index": 1}))
        .unwrap();
    resolver1
        .ingest(json!({
            "type": "message_delta",
            "delta": {"stop_reason": "tool_use"},
            "usage": {"output_tokens": 12}
        }))
        .unwrap();
    let events1 = resolver1.ingest(json!({"type": "message_stop"})).unwrap();
    let turn1_output = events1.last().unwrap()["response"]["output"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(turn1_output.len(), 2);

    let meta1 = resolver1.completion_metadata().unwrap();
    let thread_meta1 = &meta1["anthropic_thread"];
    assert_eq!(thread_meta1["effective_mode"], "create");
    assert_eq!(thread_meta1["prefix_mismatch_fallback"], false);
    assert_eq!(thread_meta1["upstream_message_id"], "msg_turn_1");
    assert_eq!(thread_meta1["fallback_message_used"], false);
    let prefix_count = thread_meta1["next_prefix_count"].as_u64().unwrap();
    let prefix_digest = thread_meta1["next_prefix_digest"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(prefix_count, 2);

    // Turn 2: continue thread with full canonical history; only tool_result suffix goes upstream.
    let mut turn2_input = vec![json!({
        "type": "message",
        "role": "user",
        "content": [{"type": "input_text", "text": "2+2?"}]
    })];
    turn2_input.extend(turn1_output);
    turn2_input.push(json!({
        "type": "function_call_output",
        "call_id": "toolu_1",
        "output": "4"
    }));

    let turn2_ctx = ResponseContext {
        model: "claude-sonnet-4-6".to_string(),
        request: json!({
            "__ankole_reasoning_source": source,
            "__ankole_anthropic_thread": {
                "mode": "continue",
                "previous_message_id": "msg_turn_1",
                "expected_prefix_count": prefix_count,
                "expected_prefix_digest": prefix_digest,
            },
            "instructions": "Be concise.",
            "tools": tools,
            "input": turn2_input,
        }),
        provider_options: json!({"thinking": {"type": "adaptive"}}),
        stream: Some(true),
        include_model: true,
        policy: ConversionPolicy::Strict,
    };
    let resolver2 = APIResolver::new(APIResolverKind::AnthropicMessages, turn2_ctx.clone());
    let body2 = resolver2.build_body().unwrap();
    assert_eq!(
        body2["thread"],
        json!({"type": "continue", "previous_message_id": "msg_turn_1"})
    );
    assert!(!body2.contains_key("system"));
    assert!(!body2.contains_key("tools"));
    let msgs2 = body2["messages"].as_array().unwrap();
    assert_eq!(msgs2.len(), 1);
    assert_eq!(msgs2[0]["role"], "user");
    assert_eq!(msgs2[0]["content"][0]["type"], "tool_result");
    assert_eq!(msgs2[0]["content"][0]["tool_use_id"], "toolu_1");

    // Mutated history digest falls back in-place to full create with system and tools restored.
    let mismatch_ctx = ResponseContext {
        request: json!({
            "__ankole_reasoning_source": source,
            "__ankole_anthropic_thread": {
                "mode": "continue",
                "previous_message_id": "msg_turn_1",
                "expected_prefix_count": prefix_count,
                "expected_prefix_digest": "wrong_digest",
            },
            "instructions": "Be concise.",
            "tools": tools,
            "input": turn2_ctx.request["input"],
        }),
        ..turn2_ctx
    };
    let resolver_mismatch = APIResolver::new(APIResolverKind::AnthropicMessages, mismatch_ctx);
    let body_mismatch = resolver_mismatch.build_body().unwrap();
    assert_eq!(body_mismatch["thread"], json!({"type": "create"}));
    assert_eq!(body_mismatch["system"], "Be concise.");
    assert!(body_mismatch.contains_key("tools"));
    assert_eq!(body_mismatch["messages"].as_array().unwrap().len(), 3);
}

#[test]
fn anthropic_message_threads_skips_anchor_on_fallback_message_or_incomplete() {
    let ctx = ResponseContext {
        model: "claude-sonnet-4-6".to_string(),
        request: json!({
            "__ankole_anthropic_thread": {"mode": "create"},
            "input": "hello"
        }),
        stream: Some(false),
        include_model: true,
        policy: ConversionPolicy::Strict,
        ..ResponseContext::default()
    };
    let mut resolver = APIResolver::new(APIResolverKind::AnthropicMessages, ctx);
    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "msg_fallback",
                "model": "claude-haiku-4-5",
                "content": [{"type": "text", "text": "hi from fallback"}],
                "stop_reason": "end_turn",
                "usage": {
                    "input_tokens": 10,
                    "output_tokens": 4,
                    "iterations": [
                        {"type": "fallback_message", "input_tokens": 10, "output_tokens": 4}
                    ]
                }
            }),
        )
        .unwrap();
    assert!(response["usage"].get("iterations").is_none());

    let meta = resolver.completion_metadata().unwrap();
    assert_eq!(meta["anthropic_thread"]["fallback_message_used"], true);
    assert!(meta["anthropic_thread"]["next_prefix_digest"].is_null());
    assert!(meta["anthropic_thread"]["next_prefix_count"].is_null());
}
