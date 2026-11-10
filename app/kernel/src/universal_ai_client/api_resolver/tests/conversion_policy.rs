use std::collections::BTreeMap;

use super::super::*;
use crate::universal_ai_client::downstream::DownstreamEncoder;

fn context_with_policy(request: Value, policy: ConversionPolicy) -> ResponseContext {
    ResponseContext {
        model: "model-test".to_string(),
        request,
        provider_options: json!({}),
        stream: Some(false),
        include_model: true,
        policy,
    }
}

#[test]
fn k1a_anthropic_rejects_invalid_image_and_binary_parts_in_strict_and_emits_placeholder_in_tolerant()
 {
    for part in [
        json!({"type": "input_image", "image_url": "ftp://example.com/unsupported.png"}),
        json!({"type": "input_audio", "data": "UklGRg=="}),
    ] {
        let request = json!({
            "input": [{
                "type": "message",
                "role": "user",
                "content": [part]
            }]
        });

        let strict_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        let err = strict_resolver.build_body().unwrap_err();
        assert_eq!(err.code, "unsupported_content_modality");

        let tolerant_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request, ConversionPolicy::Tolerant),
        );
        let body = tolerant_resolver.build_body().unwrap();
        assert_eq!(
            body["messages"][0]["content"][0],
            json!({"type": "text", "text": "[image content omitted: unsupported image source]"})
        );
    }
}

#[test]
fn k1b_openai_chat_rejects_invalid_image_in_tool_output_and_user_part_in_strict_and_degrades_in_tolerant()
 {
    let tool_output_request = json!({
        "input": [{
            "type": "function_call_output",
            "call_id": "call_1",
            "output": [{"type": "input_image", "image_url": ""}]
        }]
    });

    let strict_tool = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(tool_output_request.clone(), ConversionPolicy::Strict),
    );
    assert_eq!(
        strict_tool.build_body().unwrap_err().code,
        "unsupported_content_modality"
    );

    let tolerant_tool = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(tool_output_request, ConversionPolicy::Tolerant),
    );
    let tolerant_tool_body = tolerant_tool.build_body().unwrap();
    assert_eq!(
        tolerant_tool_body["messages"][0]["content"],
        json!("[image content omitted: unsupported image source]")
    );

    for bad_user_part in [
        json!({"type": "input_audio", "audio": "base64"}),
        json!({"type": "image_url", "image_url": {"detail": "high"}}),
    ] {
        let user_request = json!({
            "input": [{
                "type": "message",
                "role": "user",
                "content": [bad_user_part]
            }]
        });

        let strict_user = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(user_request.clone(), ConversionPolicy::Strict),
        );
        assert_eq!(
            strict_user.build_body().unwrap_err().code,
            "unsupported_content_modality"
        );

        let tolerant_user = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(user_request, ConversionPolicy::Tolerant),
        );
        let tolerant_user_body = tolerant_user.build_body().unwrap();
        assert_eq!(
            tolerant_user_body["messages"][0]["content"][0]["type"],
            json!("text")
        );
    }
}

#[test]
fn k2a_openai_chat_rejects_unknown_item_type_missing_role_or_primitive_item_in_strict_and_coerces_in_tolerant()
 {
    for bad_item in [
        json!({"type": "computer_call", "id": "cc_1"}),
        json!({"type": "message", "role": "user"}),
        json!({"type": "message", "role": "moderator", "content": "hi"}),
        json!(42),
    ] {
        let request = json!({ "input": [bad_item.clone()] });

        let strict_resolver = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        assert_eq!(
            strict_resolver.build_body().unwrap_err().code,
            "invalid_input_item"
        );

        let tolerant_resolver = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(request, ConversionPolicy::Tolerant),
        );
        let body = tolerant_resolver.build_body().unwrap();
        assert_eq!(body["messages"][0]["role"], json!("user"));
    }
}

#[test]
fn k2b_anthropic_rejects_unknown_item_missing_content_and_unknown_role_in_strict_and_degrades_in_tolerant()
 {
    for bad_item in [
        json!("raw-non-object"),
        json!({"type": "message", "role": "user"}),
        json!({"type": "message", "role": "system", "content": "inline system"}),
        json!({"type": "computer_call", "id": "cc_1"}),
        json!({"type": "message", "role": "user", "content": [{"type": "custom_widget", "id": "w1"}]}),
    ] {
        let request = json!({ "input": [bad_item] });

        let strict_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        assert_eq!(
            strict_resolver.build_body().unwrap_err().code,
            "invalid_input_item"
        );

        let tolerant_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request, ConversionPolicy::Tolerant),
        );
        assert!(tolerant_resolver.build_body().is_ok());
    }

    let agent_msg_request = json!({
        "input": [{"type": "agent_message", "content": "agent note"}]
    });
    let strict_agent_msg = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(agent_msg_request, ConversionPolicy::Strict),
    );
    let agent_msg_body = strict_agent_msg.build_body().unwrap();
    assert_eq!(agent_msg_body["messages"][0]["role"], json!("user"));
}

#[test]
fn k3_strict_disables_function_call_replay_repair_and_surfaces_invalid_tool_arguments() {
    let request = json!({
        "input": [
            {
                "type": "function_call",
                "call_id": "call_repairable",
                "name": "read_file",
                "arguments": "{\"path\":\"/tmp/a\","
            },
            {
                "type": "function_call_output",
                "call_id": "call_repairable",
                "output": "ok"
            },
            {
                "type": "function_call",
                "call_id": "call_unrepairable",
                "name": "patch",
                "arguments": "{\"path\":\"/tmp/unterminated"
            },
            {
                "type": "function_call_output",
                "call_id": "call_unrepairable",
                "output": "failed"
            },
            {
                "type": "function_call",
                "call_id": "call_unpaired",
                "name": "patch",
                "arguments": "broken"
            }
        ]
    });

    let tolerant_ctx = context_with_policy(request.clone(), ConversionPolicy::Tolerant);
    let tolerant_projected = tolerant_ctx.resolved_provider_request_object();
    let tolerant_items = tolerant_projected["input"].as_array().unwrap();
    assert_eq!(tolerant_items.len(), 4);
    assert_eq!(
        tolerant_items[0]["arguments"],
        json!("{\"path\":\"/tmp/a\"}")
    );
    assert_eq!(tolerant_items[2]["arguments"], json!("{}"));
    assert!(
        tolerant_items[3]["output"]
            .as_str()
            .unwrap()
            .contains("[History replay note:")
    );

    let strict_ctx = context_with_policy(request.clone(), ConversionPolicy::Strict);
    let strict_projected = strict_ctx.resolved_provider_request_object();
    let strict_items = strict_projected["input"].as_array().unwrap();
    assert_eq!(strict_items.len(), 5);
    assert_eq!(strict_items[0]["arguments"], json!("{\"path\":\"/tmp/a\","));

    for kind in [
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
        APIResolverKind::OpenAIResponses,
    ] {
        let resolver = APIResolver::new(
            kind,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        let err = resolver.build_body().unwrap_err();
        assert_eq!(err.code, "invalid_tool_arguments");
    }
}

#[test]
fn k4a_anthropic_rejects_malformed_or_missing_tool_use_fields_in_strict_and_defaults_in_tolerant() {
    for bad_input in [
        json!([{"type": "function_call", "name": "lookup", "arguments": "{}"}]),
        json!([{"type": "function_call", "call_id": "call_1", "arguments": "{}"}]),
        json!([
            {"type": "function_call", "call_id": "call_1", "name": "lookup", "arguments": "[1,2]"},
            {"type": "function_call_output", "call_id": "call_1", "output": "ok"}
        ]),
    ] {
        let request = json!({ "input": bad_input });

        let strict_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        assert_eq!(
            strict_resolver.build_body().unwrap_err().code,
            "invalid_tool_arguments"
        );

        let tolerant_resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(request, ConversionPolicy::Tolerant),
        );
        let body = tolerant_resolver.build_body().unwrap();
        assert_eq!(body["messages"][0]["content"][0]["type"], json!("tool_use"));
    }

    let namespaced_missing_name = json!({
        "input": [{
            "type": "function_call",
            "call_id": "call_ns",
            "name": "",
            "namespace": "mcp_fs",
            "arguments": "{}"
        }]
    });
    let strict_ns = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(namespaced_missing_name.clone(), ConversionPolicy::Strict),
    );
    assert_eq!(
        strict_ns.build_body().unwrap_err().code,
        "invalid_tool_arguments"
    );
    let tolerant_ns = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(namespaced_missing_name, ConversionPolicy::Tolerant),
    );
    let tolerant_ns_body = tolerant_ns.build_body().unwrap();
    assert_eq!(
        tolerant_ns_body["messages"][0]["content"][0]["name"],
        json!("mcp_fs__")
    );
}

#[test]
fn k4b_openai_chat_rejects_malformed_or_missing_function_call_fields_in_strict_and_defaults_in_tolerant()
 {
    for bad_input in [
        json!([{"type": "function_call", "name": "lookup", "arguments": "{}"}]),
        json!([{"type": "function_call", "call_id": "call_1", "arguments": "{}"}]),
        json!([
            {"type": "function_call", "call_id": "call_1", "name": "lookup", "arguments": "123"},
            {"type": "function_call_output", "call_id": "call_1", "output": "ok"}
        ]),
    ] {
        let request = json!({ "input": bad_input });

        let strict_resolver = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(request.clone(), ConversionPolicy::Strict),
        );
        assert_eq!(
            strict_resolver.build_body().unwrap_err().code,
            "invalid_tool_arguments"
        );

        let tolerant_resolver = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            context_with_policy(request, ConversionPolicy::Tolerant),
        );
        let body = tolerant_resolver.build_body().unwrap();
        assert_eq!(
            body["messages"][0]["tool_calls"][0]["type"],
            json!("function")
        );
    }
}

#[test]
fn k5a_openai_chat_validates_upstream_tool_call_arguments_in_stream_and_body_under_strict() {
    let chunk = json!({
        "id": "chatcmpl_1",
        "created": 10,
        "model": "gpt-test",
        "choices": [{
            "delta": {
                "tool_calls": [{
                    "index": 0,
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "lookup", "arguments": "{\"city\":\"Par"}
                }]
            },
            "finish_reason": "tool_calls"
        }]
    });

    let mut strict_stream = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    strict_stream.ingest(chunk.clone()).unwrap();
    strict_stream.on_done_sentinel().unwrap();
    assert_eq!(
        strict_stream.finish().unwrap_err().code,
        "invalid_tool_arguments"
    );

    let mut tolerant_stream = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    tolerant_stream.ingest(chunk).unwrap();
    tolerant_stream.on_done_sentinel().unwrap();
    let events = tolerant_stream.finish().unwrap();
    assert_eq!(
        events.last().unwrap()["response"]["output"][0]["arguments"],
        json!("{\"city\":\"Par")
    );

    // Zero argument deltas in Strict mode normalize empty string "" to "{}"
    let mut zero_delta_strict = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    zero_delta_strict
        .ingest(json!({
            "id": "chatcmpl_2",
            "created": 10,
            "model": "gpt-test",
            "choices": [{
                "delta": {
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_empty",
                        "type": "function",
                        "function": {"name": "ping", "arguments": ""}
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        }))
        .unwrap();
    zero_delta_strict.on_done_sentinel().unwrap();
    let zero_events = zero_delta_strict.finish().unwrap();
    assert_eq!(
        zero_events.last().unwrap()["response"]["output"][0]["arguments"],
        json!("{}")
    );

    // Non-streaming body with malformed tool arguments
    let bad_body = json!({
        "id": "chatcmpl_3",
        "created": 10,
        "model": "gpt-test",
        "choices": [{
            "message": {
                "role": "assistant",
                "tool_calls": [{
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "lookup", "arguments": "not-json"}
                }]
            },
            "finish_reason": "tool_calls"
        }]
    });
    let mut strict_body = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    assert_eq!(
        strict_body
            .normalize_body(200, bad_body.clone())
            .unwrap_err()
            .code,
        "invalid_tool_arguments"
    );

    let mut tolerant_body = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    let normalized = tolerant_body.normalize_body(200, bad_body).unwrap();
    assert_eq!(normalized["output"][0]["arguments"], json!("not-json"));
}

#[test]
fn k5b_anthropic_validates_upstream_tool_use_arguments_in_stream_and_body_under_strict() {
    let run_stream = |policy: ConversionPolicy, partial_json: Option<&str>| {
        let mut resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(json!({"input": "hi"}), policy),
        );
        resolver
            .ingest(json!({
                "type": "message_start",
                "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 3}}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "tool_use", "id": "toolu_1", "name": "lookup", "input": {}}
            }))
            .unwrap();
        if let Some(partial) = partial_json {
            resolver
                .ingest(json!({
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "input_json_delta", "partial_json": partial}
                }))
                .unwrap();
        }
        resolver.ingest(json!({"type": "content_block_stop", "index": 0}))
    };

    assert_eq!(
        run_stream(ConversionPolicy::Strict, Some("{\"city\":\"Par"))
            .unwrap_err()
            .code,
        "invalid_tool_arguments"
    );

    let tolerant_events = run_stream(ConversionPolicy::Tolerant, Some("{\"city\":\"Par")).unwrap();
    assert_eq!(tolerant_events[0]["arguments"], json!("{\"city\":\"Par"));

    // 0 deltas in Strict mode normalizes "" to "{}" for function tools, while preserving "" for custom tools
    let zero_delta_events = run_stream(ConversionPolicy::Strict, None).unwrap();
    assert_eq!(zero_delta_events[0]["arguments"], json!("{}"));

    let mut custom_zero_delta = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(
            json!({"input": "hi", "tools": [{"type": "custom", "name": "raw_tool"}]}),
            ConversionPolicy::Strict,
        ),
    );
    custom_zero_delta
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 3}}
        }))
        .unwrap();
    custom_zero_delta
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "tool_use", "id": "toolu_1", "name": "raw_tool", "input": {}}
        }))
        .unwrap();
    let custom_done = custom_zero_delta
        .ingest(json!({"type": "content_block_stop", "index": 0}))
        .unwrap();
    assert_eq!(custom_done[0]["input"], json!(""));

    // message_stop without content_block_stop on invalid tool arguments leaves stream non-terminal so fail() emits response.failed
    let mut unclosed_tool_stream = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    unclosed_tool_stream
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 3}}
        }))
        .unwrap();
    unclosed_tool_stream
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {"type": "tool_use", "id": "toolu_1", "name": "lookup", "input": {}}
        }))
        .unwrap();
    unclosed_tool_stream
        .ingest(json!({
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "input_json_delta", "partial_json": "{\"city\":\"Par"}
        }))
        .unwrap();
    let err = unclosed_tool_stream
        .ingest(json!({"type": "message_stop"}))
        .unwrap_err();
    assert_eq!(err.code, "invalid_tool_arguments");
    assert!(!unclosed_tool_stream.is_terminal());
    let fail_events = unclosed_tool_stream.fail(&err);
    assert_eq!(fail_events.last().unwrap()["type"], "response.failed");

    // Non-streaming body with non-object input
    let bad_body = json!({
        "id": "msg_1",
        "model": "claude-test",
        "stop_reason": "tool_use",
        "content": [
            {"type": "tool_use", "id": "toolu_1", "name": "lookup", "input": "not-an-object"}
        ]
    });
    let mut strict_body = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    assert_eq!(
        strict_body
            .normalize_body(200, bad_body.clone())
            .unwrap_err()
            .code,
        "invalid_tool_arguments"
    );

    let mut tolerant_body = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    let normalized = tolerant_body.normalize_body(200, bad_body).unwrap();
    assert_eq!(
        normalized["output"][0]["arguments"],
        json!("\"not-an-object\"")
    );
}

#[test]
fn k6a_openai_chat_rejects_missing_done_sentinel_and_empty_stream_in_strict() {
    let text_chunk = json!({
        "id": "chatcmpl_1",
        "created": 10,
        "model": "gpt-test",
        "choices": [{"delta": {"content": "hello"}, "finish_reason": "stop"}]
    });

    // Missing [DONE] sentinel before finish()
    let mut strict_no_done = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    strict_no_done.ingest(text_chunk.clone()).unwrap();
    assert_eq!(
        strict_no_done.finish().unwrap_err().code,
        "upstream_stream_truncated"
    );

    let mut tolerant_no_done = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    tolerant_no_done.ingest(text_chunk).unwrap();
    let tolerant_events = tolerant_no_done.finish().unwrap();
    assert_eq!(
        tolerant_events.last().unwrap()["type"],
        "response.completed"
    );

    // Empty stream with finish_reason + [DONE]
    let empty_chunk = json!({
        "id": "chatcmpl_empty",
        "created": 10,
        "model": "gpt-test",
        "choices": [{"delta": {}, "finish_reason": "stop"}]
    });
    let mut strict_empty = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    strict_empty.ingest(empty_chunk.clone()).unwrap();
    strict_empty.on_done_sentinel().unwrap();
    assert_eq!(
        strict_empty.finish().unwrap_err().code,
        "empty_upstream_stream"
    );

    let mut tolerant_empty = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    tolerant_empty.ingest(empty_chunk).unwrap();
    tolerant_empty.on_done_sentinel().unwrap();
    let tolerant_empty_events = tolerant_empty.finish().unwrap();
    assert_eq!(
        tolerant_empty_events.last().unwrap()["type"],
        "response.completed"
    );
}

#[test]
fn k6b_anthropic_rejects_missing_message_stop_and_empty_stream_in_strict() {
    // Stream closes after text_delta without message_stop
    for policy in [ConversionPolicy::Strict, ConversionPolicy::Tolerant] {
        let mut resolver = APIResolver::new(
            APIResolverKind::AnthropicMessages,
            context_with_policy(json!({"input": "hi"}), policy),
        );
        resolver
            .ingest(json!({
                "type": "message_start",
                "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 1}}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "partial"}
            }))
            .unwrap();
        let result = resolver.finish();
        if policy == ConversionPolicy::Strict {
            assert_eq!(result.unwrap_err().code, "upstream_stream_truncated");
        } else {
            let events = result.unwrap();
            assert_eq!(events.last().unwrap()["type"], "response.incomplete");
        }
    }

    // Empty stream with message_start + message_stop but no blocks
    let mut strict_empty = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    strict_empty
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_empty", "model": "claude-test", "usage": {"input_tokens": 1}}
        }))
        .unwrap();
    assert_eq!(
        strict_empty
            .ingest(json!({"type": "message_stop"}))
            .unwrap_err()
            .code,
        "empty_upstream_stream"
    );

    let mut tolerant_empty = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    tolerant_empty
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_empty", "model": "claude-test", "usage": {"input_tokens": 1}}
        }))
        .unwrap();
    let events = tolerant_empty
        .ingest(json!({"type": "message_stop"}))
        .unwrap();
    assert_eq!(events.last().unwrap()["type"], "response.completed");
}

#[test]
fn k7_rejects_empty_non_streaming_response_and_downstream_encode_failure_in_strict() {
    let empty_chat_body = json!({
        "id": "chatcmpl_empty",
        "created": 10,
        "model": "gpt-test",
        "choices": [{"message": {"role": "assistant", "content": null}, "finish_reason": "stop"}]
    });

    let mut strict_chat = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Strict),
    );
    assert_eq!(
        strict_chat
            .normalize_body(200, empty_chat_body.clone())
            .unwrap_err()
            .code,
        "empty_upstream_response"
    );

    let mut tolerant_chat = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        context_with_policy(json!({"input": "hi"}), ConversionPolicy::Tolerant),
    );
    let chat_resp = tolerant_chat.normalize_body(200, empty_chat_body).unwrap();
    assert_eq!(chat_resp["output"][0]["content"][0]["text"], json!(""));

    // DownstreamEncoder with non-string map keys that fail JSON serialization
    let mut bad_map = BTreeMap::new();
    bad_map.insert((1, 2), "non-string-key");
    let strict_encode =
        DownstreamEncoder.encode_serializable_with_policy(&bad_map, ConversionPolicy::Strict);
    assert_eq!(strict_encode.unwrap_err().code, "downstream_encode_failed");

    let tolerant_encode = DownstreamEncoder
        .encode_serializable_with_policy(&bad_map, ConversionPolicy::Tolerant)
        .unwrap();
    assert_eq!(tolerant_encode.bytes, b"{}");
}
