use serde_json::json;

use super::*;

fn encrypted_send_message_tool() -> Value {
    json!({
        "type": "function",
        "name": "send_message",
        "description": "Send a private message",
        "parameters": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "encrypted": true},
                "task_name": {"type": "string"}
            },
            "required": ["message"]
        }
    })
}

#[test]
fn openai_responses_passthrough_adds_zero_based_sequence() {
    let mut resolver =
        APIResolver::new(APIResolverKind::OpenAIResponses, ResponseContext::default());

    let events = resolver
        .ingest(json!({"type": "response.created"}))
        .unwrap();

    assert_eq!(events[0]["type"], "response.created");
    assert_eq!(events[0]["sequence_number"], 0);
}

#[test]
fn openai_responses_requires_terminal_event_on_finish() {
    let mut resolver =
        APIResolver::new(APIResolverKind::OpenAIResponses, ResponseContext::default());

    let error = resolver.finish().unwrap_err();

    assert_eq!(error.code, "upstream_stream_closed_before_terminal_event");
}

#[test]
fn openai_responses_error_event_is_not_terminal_by_itself() {
    let mut resolver =
        APIResolver::new(APIResolverKind::OpenAIResponses, ResponseContext::default());

    resolver
        .ingest(json!({"type": "error", "error": {"code": "boom"}}))
        .unwrap();

    let error = resolver.finish().unwrap_err();
    assert_eq!(error.code, "upstream_stream_closed_before_terminal_event");
}

#[test]
fn openai_responses_preserves_encrypted_reasoning_output_item() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({"input": "continue"}),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "resp_reasoning",
                "status": "completed",
                "output": [
                    {
                        "type": "reasoning",
                        "id": "rs_1",
                        "encrypted_content": "encrypted-reasoning-payload",
                        "summary": []
                    }
                ],
                "usage": {}
            }),
        )
        .unwrap();

    assert_eq!(
        response["output"][0]["encrypted_content"],
        json!("encrypted-reasoning-payload")
    );
}

#[test]
fn aigateway_removes_encrypted_tool_markers_before_every_provider_adapter() {
    for kind in [
        APIResolverKind::OpenAIResponses,
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
        APIResolverKind::GeminiGenerateContent,
        APIResolverKind::BedrockConverse,
    ] {
        let resolver = APIResolver::new(
            kind,
            ResponseContext {
                model: "provider-test".to_string(),
                request: json!({
                    "tools": [encrypted_send_message_tool()],
                    "input": "start"
                }),
                provider_options: json!({}),
                stream: Some(false),
                include_model: true,
            },
        );

        let provider_body = Value::Object(resolver.build_body().unwrap());
        let encoded = provider_body.to_string();
        assert!(encoded.contains("Send a private message"), "{kind:?}");
        assert!(!encoded.contains("\"encrypted\""), "{kind:?}: {encoded}");
    }
}

#[test]
fn aigateway_encodes_marked_outputs_after_responses_and_anthropic_adapters() {
    let context = || ResponseContext {
        model: "provider-test".to_string(),
        request: json!({"tools": [encrypted_send_message_tool()]}),
        provider_options: json!({}),
        stream: Some(false),
        include_model: true,
    };

    let mut responses = APIResolver::new(APIResolverKind::OpenAIResponses, context());
    let responses_body = responses
        .normalize_body(
            200,
            json!({
                "id": "resp_opaque",
                "status": "completed",
                "output": [{
                    "id": "fc_responses",
                    "type": "function_call",
                    "call_id": "call_responses",
                    "name": "send_message",
                    "arguments": "{\"message\":\"responses secret\",\"task_name\":\"r\"}",
                    "status": "completed"
                }]
            }),
        )
        .unwrap();

    let mut anthropic = APIResolver::new(APIResolverKind::AnthropicMessages, context());
    let anthropic_body = anthropic
        .normalize_body(
            200,
            json!({
                "id": "msg_opaque",
                "model": "claude-test",
                "content": [{
                    "type": "tool_use",
                    "id": "call_anthropic",
                    "name": "send_message",
                    "input": {"message": "anthropic secret", "task_name": "a"}
                }],
                "usage": {}
            }),
        )
        .unwrap();

    for (body, plain_text) in [
        (responses_body, "responses secret"),
        (anthropic_body, "anthropic secret"),
    ] {
        let arguments: Value =
            serde_json::from_str(body["output"][0]["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(arguments["task_name"].as_str().unwrap().len(), 1);
        assert_ne!(arguments["message"], plain_text);
        assert!(
            arguments["message"]
                .as_str()
                .unwrap()
                .starts_with("ankole-aigateway-opaque-v1:")
        );
        assert!(!body.to_string().contains(plain_text));
    }
}

#[test]
fn aigateway_buffers_and_encodes_native_responses_tool_streams() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({"tools": [encrypted_send_message_tool()]}),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );
    let mut public_events = Vec::new();
    let arguments = "{\"message\":\"native stream secret\",\"task_name\":\"stream\"}";

    for event in [
        json!({
            "type": "response.created",
            "response": {"id": "resp_native_opaque", "status": "in_progress", "output": []}
        }),
        json!({
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {
                "id": "fc_native_opaque",
                "type": "function_call",
                "call_id": "call_native_opaque",
                "name": "send_message",
                "arguments": "",
                "status": "in_progress"
            }
        }),
        json!({
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_native_opaque",
            "output_index": 0,
            "delta": "{\"message\":\"native stream secret\","
        }),
        json!({
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_native_opaque",
            "output_index": 0,
            "delta": "\"task_name\":\"stream\"}"
        }),
        json!({
            "type": "response.function_call_arguments.done",
            "item_id": "fc_native_opaque",
            "output_index": 0,
            "arguments": arguments
        }),
        json!({
            "type": "response.output_item.done",
            "output_index": 0,
            "item": {
                "id": "fc_native_opaque",
                "type": "function_call",
                "call_id": "call_native_opaque",
                "name": "send_message",
                "arguments": arguments,
                "status": "completed"
            }
        }),
        json!({
            "type": "response.completed",
            "response": {
                "id": "resp_native_opaque",
                "status": "completed",
                "output": [{
                    "id": "fc_native_opaque",
                    "type": "function_call",
                    "call_id": "call_native_opaque",
                    "name": "send_message",
                    "arguments": arguments,
                    "status": "completed"
                }]
            }
        }),
    ] {
        public_events.extend(resolver.ingest(event).unwrap());
    }

    assert!(
        public_events
            .iter()
            .all(|event| !event.to_string().contains("native stream secret"))
    );
    let terminal = public_events.last().unwrap();
    let encoded: Value = serde_json::from_str(
        terminal["response"]["output"][0]["arguments"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(encoded["task_name"], "stream");
    assert!(
        encoded["message"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-opaque-v1:")
    );
    for (expected, event) in public_events.iter().enumerate() {
        assert_eq!(event["sequence_number"], expected as u64);
    }
}

#[test]
fn aigateway_buffers_and_encodes_gemini_encrypted_tool_streams() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GeminiGenerateContent,
        ResponseContext {
            model: "gemini-test".to_string(),
            request: json!({"tools": [encrypted_send_message_tool()]}),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "candidates": [{
                "content": {
                    "parts": [{
                        "functionCall": {
                            "name": "send_message",
                            "args": {
                                "message": "gemini stream secret",
                                "task_name": "gemini"
                            }
                        }
                    }]
                },
                "finishReason": "STOP"
            }]
        }))
        .unwrap();

    assert!(
        events
            .iter()
            .all(|event| !event.to_string().contains("gemini stream secret"))
    );
    let terminal = events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call")
        .unwrap();
    let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["task_name"], "gemini");
    assert!(
        arguments["message"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-opaque-v1:")
    );
    for (expected, event) in events.iter().enumerate() {
        assert_eq!(event["sequence_number"], expected as u64);
    }
}

#[test]
fn aigateway_decodes_opaque_history_before_native_responses_provider() {
    let opaque_message = "ankole-aigateway-opaque-v1:aGlzdG9yeSBzZWNyZXQ";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "tools": [encrypted_send_message_tool()],
                "input": [
                    {
                        "type": "function_call",
                        "call_id": "call_history",
                        "name": "send_message",
                        "arguments": format!("{{\"message\":\"{opaque_message}\",\"task_name\":\"h\"}}")
                    },
                    {
                        "type": "agent_message",
                        "content": [{
                            "type": "encrypted_content",
                            "encrypted_content": opaque_message
                        }]
                    },
                    {
                        "type": "agent_message",
                        "content": [{
                            "type": "encrypted_content",
                            "encrypted_content": "ankole-chat-encoded-v1:bGVnYWN5"
                        }]
                    }
                ]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());
    let arguments: Value =
        serde_json::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

    assert_eq!(arguments["message"], "history secret");
    assert_eq!(
        provider_body["input"][1]["content"][0]["type"],
        "input_text"
    );
    assert_eq!(
        provider_body["input"][1]["content"][0]["text"],
        "history secret"
    );
    assert_eq!(provider_body["input"][2]["content"][0]["text"], "legacy");
    assert!(!provider_body.to_string().contains(opaque_message));
}

#[test]
fn aigateway_decodes_opaque_history_without_tool_definitions() {
    // A Codex local compaction request replays the full history with no tools.
    let opaque_message = "ankole-aigateway-opaque-v1:aGlzdG9yeSBzZWNyZXQ";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{
                    "type": "function_call",
                    "call_id": "call_history",
                    "name": "send_message",
                    "arguments": format!("{{\"message\":\"{opaque_message}\",\"task_name\":\"h\"}}")
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());
    let arguments: Value =
        serde_json::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

    assert_eq!(arguments["message"], "history secret");
    assert!(!provider_body.to_string().contains(opaque_message));
}

#[test]
fn aigateway_keeps_prefix_substrings_inside_plain_argument_values_verbatim() {
    let quoted = "rg 'ankole-aigateway-opaque-v1:aGlzdG9yeSBzZWNyZXQ' logs/";
    let arguments = json!({"cmd": quoted}).to_string();
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{
                    "type": "function_call",
                    "call_id": "call_grep",
                    "name": "exec_command",
                    "arguments": arguments
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());
    let replayed: Value =
        serde_json::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

    assert_eq!(replayed["cmd"], quoted);
}

#[test]
fn aigateway_passes_plaintext_values_of_encrypted_fields_through() {
    // History can hold a plaintext value for a marked field when the emitting
    // request carried no markers. That value was never encoded, so it must
    // pass through instead of failing the request.
    let arguments = json!({"message": "already plain", "task_name": "h"}).to_string();
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "tools": [encrypted_send_message_tool()],
                "input": [{
                    "type": "function_call",
                    "call_id": "call_plain",
                    "name": "send_message",
                    "arguments": arguments.clone()
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        provider_body["input"][0]["arguments"].as_str().unwrap(),
        arguments
    );
}

#[test]
fn aigateway_rejects_corrupt_opaque_history_values() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{
                    "type": "function_call",
                    "call_id": "call_corrupt",
                    "name": "send_message",
                    "arguments": "{\"message\":\"ankole-aigateway-opaque-v1:!!not-base64!!\"}"
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();
    assert_eq!(error.code, "invalid_encrypted_content");
}

#[test]
fn aigateway_rejects_nested_encrypted_tool_fields_before_provider_dispatch() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "function",
                    "name": "nested_secret",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "payload": {
                                "type": "object",
                                "properties": {
                                    "message": {"type": "string", "encrypted": true}
                                }
                            }
                        }
                    }
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();
    assert_eq!(error.code, "invalid_encrypted_tool_schema");
    assert!(error.message.contains("direct object properties"));
}

#[test]
fn openai_chat_accumulates_text_usage_and_terminal_response() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({"input": "hi"}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "id": "chatcmpl_1",
            "created": 10,
            "model": "gpt-test",
            "choices": [{"delta": {"content": "hello"}, "finish_reason": null}]
        }))
        .unwrap();
    assert!(
        events
            .iter()
            .any(|event| event["type"] == "response.output_text.delta")
    );

    let events = resolver
        .ingest(json!({
            "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5},
            "choices": [{"delta": {}, "finish_reason": "stop"}]
        }))
        .unwrap();
    assert!(
        !events
            .iter()
            .any(|event| event["type"] == "response.completed")
    );

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();

    assert_eq!(terminal["type"], "response.completed");
    assert_eq!(
        terminal["response"]["output"][0]["content"][0]["text"],
        "hello"
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 5);
}

#[test]
fn openai_chat_top_level_error_chunk_becomes_provider_failure() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({"input": "hi"}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let error = resolver
        .ingest(json!({
            "error": {
                "message": "error decoding response body",
                "code": 502
            }
        }))
        .unwrap_err();

    assert_eq!(error.code, "provider_status_rejected");
    assert_eq!(error.provider_status, Some(502));
    assert!(
        error
            .provider_body_excerpt
            .as_deref()
            .unwrap_or_default()
            .contains("error decoding response body")
    );

    let events = resolver.fail(&error);
    assert_eq!(events[0]["type"], "error");
    assert_eq!(events[0]["error"]["status"], 502);
    assert_eq!(events[1]["type"], "response.failed");
    assert_eq!(events[1]["response"]["error"]["status"], 502);
}

#[test]
fn openai_chat_waits_for_late_openrouter_usage_before_terminal_response() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({"input": "hi"}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    resolver
        .ingest(json!({
            "id": "chatcmpl_1",
            "created": 10,
            "model": "openrouter-test",
            "choices": [{"delta": {"content": "hello"}, "finish_reason": null}]
        }))
        .unwrap();

    let events = resolver
        .ingest(json!({
            "choices": [{"delta": {"content": ""}, "finish_reason": "stop"}]
        }))
        .unwrap();
    assert!(
        !events
            .iter()
            .any(|event| event["type"] == "response.completed")
    );

    let events = resolver
        .ingest(json!({
            "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5},
            "choices": [{"delta": {"content": "hello"}, "finish_reason": "stop"}]
        }))
        .unwrap();
    assert!(
        !events
            .iter()
            .any(|event| event["type"] == "response.completed")
    );

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();

    assert_eq!(terminal["type"], "response.completed");
    assert_eq!(
        terminal["response"]["output"][0]["content"][0]["text"],
        "hello"
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 5);
}

#[test]
fn openai_chat_non_streaming_flattens_assistant_content_parts() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({"input": "hi"}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_parts",
                "created": 10,
                "model": "openrouter-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": [
                            {"type": "output_text", "text": "hello"},
                            {"type": "text", "text": " world"}
                        ]
                    },
                    "finish_reason": "stop"
                }],
                "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}
            }),
        )
        .unwrap();

    assert_eq!(
        response["output"][0]["content"],
        json!([
            {"type": "output_text", "text": "hello", "annotations": []},
            {"type": "output_text", "text": " world", "annotations": []}
        ])
    );
}

#[test]
fn openai_chat_accumulates_tool_calls() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "call_1",
                    "function": {"name": "get_weather", "arguments": "{\"city\""}
                }]},
                "finish_reason": null
            }]
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "function": {"arguments": ":\"Shanghai\"}"}
                }]},
                "finish_reason": "tool_calls"
            }]
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

    assert_eq!(call["name"], "get_weather");
    assert_eq!(call["arguments"], "{\"city\":\"Shanghai\"}");
}

#[test]
fn openai_chat_eof_keeps_partial_tool_call_incomplete_without_done_events() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "call_partial",
                    "function": {"name": "patch", "arguments": "{\"path\":\"/tmp/repor"}
                }]},
                "finish_reason": null
            }]
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
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "upstream_stream_closed"
    );
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
fn openai_chat_build_body_keeps_png_data_url_as_chat_image_url() {
    let image_data_url = "data:image/png;base64,iVBORw0KGgo=";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-vision-test".to_string(),
            request: json!({
                "input": [{
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "look"},
                        {"type": "input_image", "image_url": image_data_url}
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

    assert_eq!(content[0], json!({"type": "text", "text": "look"}));
    assert_eq!(
        content[1],
        json!({"type": "image_url", "image_url": {"url": image_data_url}})
    );
}

#[test]
fn openai_chat_build_body_flattens_assistant_content_parts() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "input": [{
                    "role": "assistant",
                    "content": [
                        {"type": "output_text", "text": "first"},
                        {"type": "text", "text": " second"}
                    ]
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["messages"][0]["role"], "assistant");
    assert_eq!(body["messages"][0]["content"], "first second");
}

#[test]
fn openai_chat_build_body_maps_function_call_history_to_tool_messages() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "input": [
                    {"role": "user", "content": "Use the todo tool."},
                    {
                        "type": "function_call",
                        "call_id": "call_todo",
                        "name": "todo",
                        "arguments": "{\"todos\":[]}"
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_todo",
                        "output": "{\"ok\":true}"
                    },
                    {
                        "role": "assistant",
                        "content": [{"type": "output_text", "text": "done"}]
                    }
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(
        messages[0],
        json!({"role": "user", "content": "Use the todo tool."})
    );
    assert_eq!(
        messages[1],
        json!({
            "role": "assistant",
            "content": null,
            "tool_calls": [{
                "id": "call_todo",
                "type": "function",
                "function": {
                    "name": "todo",
                    "arguments": "{\"todos\":[]}"
                }
            }]
        })
    );
    assert_eq!(
        messages[2],
        json!({
            "role": "tool",
            "tool_call_id": "call_todo",
            "content": "{\"ok\":true}"
        })
    );
    assert_eq!(messages[3], json!({"role": "assistant", "content": "done"}));

    assert!(
        !serde_json::to_string(&messages)
            .unwrap()
            .contains("function_call_output")
    );
}

#[test]
fn openai_chat_build_body_keeps_tool_output_images_out_of_tool_text() {
    let image_data_url = "data:image/png;base64,iVBORw0KGgo=";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-vision-test".to_string(),
            request: json!({
                "input": [
                    {
                        "type": "function_call",
                        "call_id": "call_image",
                        "name": "view_image",
                        "arguments": "{\"path\":\"/tmp/contact-sheet.png\"}"
                    },
                    {
                        "type": "function_call",
                        "call_id": "call_text",
                        "name": "read_file",
                        "arguments": "{\"path\":\"/tmp/report.txt\"}"
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_image",
                        "output": [{
                            "type": "input_image",
                            "image_url": image_data_url
                        }]
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_text",
                        "output": "report"
                    }
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(messages[0]["role"], "assistant");
    assert_eq!(messages[0]["tool_calls"].as_array().unwrap().len(), 2);
    assert_eq!(
        messages[1],
        json!({
            "role": "tool",
            "tool_call_id": "call_image",
            "content": "[Image output is attached in the next user message.]"
        })
    );
    assert_eq!(
        messages[2],
        json!({
            "role": "tool",
            "tool_call_id": "call_text",
            "content": "report"
        })
    );
    assert_eq!(messages[3]["role"], "user");
    assert_eq!(
        messages[3]["content"][0],
        json!({
            "type": "text",
            "text": "Image output from tool call call_image."
        })
    );
    assert_eq!(
        messages[3]["content"][1],
        json!({
            "type": "image_url",
            "image_url": {"url": image_data_url}
        })
    );
    assert!(
        !messages[1]["content"]
            .as_str()
            .unwrap()
            .contains(image_data_url)
    );
    assert_eq!(
        serde_json::to_string(&body)
            .unwrap()
            .matches(image_data_url)
            .count(),
        1
    );
}

#[test]
fn openai_chat_build_body_coalesces_interleaved_system_messages_at_the_front() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "instructions": "base instructions",
                "input": [
                    {"role": "developer", "content": "permissions"},
                    {"role": "user", "content": "start the job"},
                    {
                        "type": "function_call",
                        "call_id": "call_read",
                        "name": "read_file",
                        "arguments": "{\"path\":\"README.md\"}"
                    },
                    {
                        "role": "developer",
                        "content": [{"type": "input_text", "text": "job guidance"}]
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_read",
                        "output": "# Ankole"
                    },
                    {"role": "assistant", "content": "working"},
                    {"role": "system", "content": "late runtime policy"},
                    {"role": "user", "content": "continue"}
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(
        messages[0],
        json!({
            "role": "system",
            "content": "base instructions\n\npermissions\n\njob guidance\n\nlate runtime policy"
        })
    );
    assert_eq!(
        messages
            .iter()
            .filter(|message| message["role"] == "system")
            .count(),
        1
    );
    assert_eq!(
        messages[1],
        json!({"role": "user", "content": "start the job"})
    );
    assert_eq!(messages[2]["role"], "assistant");
    assert_eq!(messages[2]["tool_calls"][0]["id"], "call_read");
    assert_eq!(messages[3]["role"], "tool");
    assert_eq!(messages[3]["tool_call_id"], "call_read");
    assert_eq!(
        messages[4],
        json!({"role": "assistant", "content": "working"})
    );
    assert_eq!(messages[5], json!({"role": "user", "content": "continue"}));
}

#[test]
fn openai_chat_build_body_repairs_trailing_function_call_history() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "input": [
                    {
                        "type": "function_call",
                        "call_id": "call_truncated",
                        "name": "patch",
                        "arguments": "{\"path\":\"/tmp/report.py\","
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_truncated",
                        "output": "Invalid arguments: unterminated JSON"
                    }
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(
        messages[0]["tool_calls"][0]["function"]["arguments"],
        json!("{\"path\":\"/tmp/report.py\"}")
    );
    assert_eq!(messages[0]["tool_calls"][0]["id"], "call_truncated");
    assert_eq!(messages[1]["tool_call_id"], "call_truncated");
    assert_eq!(
        messages[1]["content"],
        "Invalid arguments: unterminated JSON"
    );
}

#[test]
fn openai_chat_emulates_response_tool_namespaces() {
    let context = ResponseContext {
        model: "openrouter-test".to_string(),
        request: json!({
            "tools": [{
                "type": "namespace",
                "name": "multi_agent_v1",
                "description": "Codex collaboration tools",
                "tools": [{
                    "type": "function",
                    "name": "spawn_agent",
                    "description": "Spawn a subagent",
                    "strict": false,
                    "parameters": {
                        "type": "object",
                        "properties": {"message": {"type": "string"}},
                        "required": ["message"]
                    }
                }]
            }],
            "input": [
                {
                    "type": "function_call",
                    "call_id": "call_previous",
                    "namespace": "multi_agent_v1",
                    "name": "spawn_agent",
                    "arguments": "{\"message\":\"review\"}"
                },
                {
                    "type": "function_call_output",
                    "call_id": "call_previous",
                    "output": "done"
                }
            ]
        }),
        provider_options: json!({}),
        stream: None,
        include_model: true,
    };
    let mut resolver = APIResolver::new(APIResolverKind::OpenAIChatCompletions, context);

    let body = Value::Object(resolver.build_body().unwrap());
    assert_eq!(
        body["tools"][0]["function"]["name"],
        "multi_agent_v1__spawn_agent"
    );
    assert_eq!(
        body["messages"][0]["tool_calls"][0]["function"]["name"],
        "multi_agent_v1__spawn_agent"
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_namespace",
                "created": 10,
                "model": "openrouter-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_next",
                            "type": "function",
                            "function": {
                                "name": "multi_agent_v1__spawn_agent",
                                "arguments": "{\"message\":\"fact check\"}"
                            }
                        }]
                    },
                    "finish_reason": "tool_calls"
                }]
            }),
        )
        .unwrap();
    let call = &response["output"][0];

    assert_eq!(call["namespace"], "multi_agent_v1");
    assert_eq!(call["name"], "spawn_agent");
}

#[test]
fn openai_chat_round_trips_response_encrypted_tool_parameters() {
    let tools = json!([{
        "type": "namespace",
        "name": "collaboration",
        "description": "Codex collaboration tools",
        "tools": [{
            "type": "function",
            "name": "spawn_agent",
            "description": "Spawn a subagent",
            "strict": false,
            "parameters": {
                "type": "object",
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "Initial task",
                        "encrypted": true
                    },
                    "task_name": {"type": "string"}
                },
                "required": ["message", "task_name"]
            }
        }]
    }]);
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({"tools": tools.clone(), "input": "start"}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());
    let provider_message_schema =
        &provider_body["tools"][0]["function"]["parameters"]["properties"]["message"];
    assert_eq!(provider_message_schema["encrypted"], Value::Null);
    assert_eq!(provider_message_schema["description"], "Initial task");

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_encrypted_tool",
                "created": 10,
                "model": "openrouter-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_spawn",
                            "type": "function",
                            "function": {
                                "name": "collaboration__spawn_agent",
                                "arguments": "{\"message\":\"fact check\",\"task_name\":\"review\"}"
                            }
                        }]
                    },
                    "finish_reason": "tool_calls"
                }]
            }),
        )
        .unwrap();
    let call = &response["output"][0];
    let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
    let encoded_message = arguments["message"].as_str().unwrap();

    assert_eq!(call["namespace"], "collaboration");
    assert_eq!(call["name"], "spawn_agent");
    assert_eq!(arguments["task_name"], "review");
    assert_ne!(encoded_message, "fact check");
    assert!(encoded_message.starts_with("ankole-aigateway-opaque-v1:"));

    let replay = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": tools,
                "input": [
                    {
                        "type": "function_call",
                        "call_id": "call_spawn",
                        "namespace": "collaboration",
                        "name": "spawn_agent",
                        "arguments": call["arguments"].clone()
                    },
                    {
                        "type": "function_call_output",
                        "call_id": "call_spawn",
                        "output": "spawned"
                    },
                    {
                        "type": "agent_message",
                        "author": "/root",
                        "recipient": "/root/review",
                        "content": [
                            {"type": "input_text", "text": "Payload:\n"},
                            {"type": "encrypted_content", "encrypted_content": encoded_message}
                        ]
                    }
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );
    let replay_body = Value::Object(replay.build_body().unwrap());
    let replay_messages = replay_body["messages"].as_array().unwrap();
    let replay_arguments: Value = serde_json::from_str(
        replay_messages[0]["tool_calls"][0]["function"]["arguments"]
            .as_str()
            .unwrap(),
    )
    .unwrap();

    assert_eq!(replay_arguments["message"], "fact check");
    assert_eq!(replay_arguments["task_name"], "review");
    assert_eq!(replay_messages[2]["content"], "Payload:\nfact check");
}

#[test]
fn openai_chat_assembles_interleaved_encrypted_tool_call_streams() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "namespace",
                    "name": "collaboration",
                    "tools": [{
                        "type": "function",
                        "name": "spawn_agent",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "message": {"type": "string", "encrypted": true},
                                "task_name": {"type": "string"}
                            },
                            "required": ["message", "task_name"]
                        }
                    }]
                }]
            }),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );

    let mut provider_events = resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [
                    {
                        "index": 0,
                        "id": "call_alpha",
                        "function": {
                            "name": "collaboration__spawn_agent",
                            "arguments": "{\"message\":\"alpha\","
                        }
                    },
                    {
                        "index": 1,
                        "id": "call_beta",
                        "function": {
                            "name": "collaboration__spawn_agent",
                            "arguments": "{\"message\":\"beta\","
                        }
                    }
                ]},
                "finish_reason": null
            }]
        }))
        .unwrap();
    provider_events.extend(
        resolver
            .ingest(json!({
                "choices": [{
                    "delta": {"tool_calls": [
                        {
                            "index": 1,
                            "function": {"arguments": "\"task_name\":\"second\"}"}
                        },
                        {
                            "index": 0,
                            "function": {"arguments": "\"task_name\":\"first\"}"}
                        }
                    ]},
                    "finish_reason": "tool_calls"
                }]
            }))
            .unwrap(),
    );

    assert!(!provider_events.iter().any(|event| {
        event["type"] == "response.function_call_arguments.delta"
            && event["delta"]
                .as_str()
                .is_some_and(|delta| delta.contains("alpha") || delta.contains("beta"))
    }));

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();
    let calls = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["type"] == "function_call")
        .collect::<Vec<_>>();

    assert_eq!(calls.len(), 2);
    for (call, task_name) in calls.into_iter().zip(["first", "second"]) {
        let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
        assert_eq!(arguments["task_name"], task_name);
        assert!(
            arguments["message"]
                .as_str()
                .unwrap()
                .starts_with("ankole-aigateway-opaque-v1:")
        );
    }
    assert!(events.iter().all(|event| {
        !event
            .get("delta")
            .and_then(Value::as_str)
            .is_some_and(|delta| delta.contains("alpha") || delta.contains("beta"))
    }));
}

#[test]
fn openai_chat_rejects_foreign_encrypted_agent_messages() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "input": [{
                    "type": "agent_message",
                    "author": "/root",
                    "recipient": "/root/review",
                    "content": [
                        {"type": "input_text", "text": "Payload:\n"},
                        {"type": "encrypted_content", "encrypted_content": "foreign-provider-ciphertext"}
                    ]
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();

    assert_eq!(error.code, "invalid_encrypted_content");
    assert!(error.message.contains("another gateway"));

    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "input": [{
                    "type": "agent_message",
                    "content": [{
                        "type": "encrypted_content",
                        "encrypted_content": "ankole-aigateway-opaque-v1:not_base64!"
                    }]
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();

    assert_eq!(error.code, "invalid_encrypted_content");
    assert!(error.message.contains("Base64URL"));
}

#[test]
fn openai_chat_redacts_incomplete_encrypted_tool_arguments() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "namespace",
                    "name": "collaboration",
                    "tools": [{
                        "type": "function",
                        "name": "spawn_agent",
                        "parameters": {
                            "type": "object",
                            "properties": {
                                "message": {"type": "string", "encrypted": true}
                            },
                            "required": ["message"]
                        }
                    }]
                }]
            }),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "call_partial_secret",
                    "function": {
                        "name": "collaboration__spawn_agent",
                        "arguments": "{\"message\":\"partial plaintext"
                    }
                }]},
                "finish_reason": null
            }]
        }))
        .unwrap();
    assert!(!events.iter().any(|event| {
        event
            .get("delta")
            .and_then(Value::as_str)
            .is_some_and(|delta| delta.contains("partial plaintext"))
    }));

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call")
        .unwrap();

    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(call["arguments"], "");
}

#[test]
fn openai_chat_fails_closed_for_malformed_complete_encrypted_tool_arguments() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "function",
                    "name": "send_message",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "message": {"type": "string", "encrypted": true}
                        },
                        "required": ["message"]
                    }
                }]
            }),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "call_malformed_secret",
                    "function": {
                        "name": "send_message",
                        "arguments": "{\"message\":\"malformed plaintext"
                    }
                }]},
                "finish_reason": "tool_calls"
            }]
        }))
        .unwrap();
    assert!(!events.iter().any(|event| {
        event
            .get("delta")
            .and_then(Value::as_str)
            .is_some_and(|delta| delta.contains("malformed plaintext"))
    }));

    let error = resolver.finish().unwrap_err();
    assert_eq!(error.code, "invalid_encrypted_tool_arguments");
    let events = resolver.fail(&error);
    let terminal = events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call")
        .unwrap();

    assert_eq!(terminal["type"], "response.failed");
    assert_eq!(
        terminal["response"]["error"]["code"],
        "invalid_encrypted_tool_arguments"
    );
    assert_eq!(call["arguments"], "");
    assert!(
        events
            .iter()
            .all(|event| { !event.to_string().contains("malformed plaintext") })
    );
}

#[test]
fn jina_embeddings_preserves_multivector_items() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaEmbeddings,
        ResponseContext {
            model: "jina-embeddings-v4".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-embeddings-v4",
                "data": [{
                    "embeddings": [[0.1, 0.2], [0.3, 0.4]],
                    "tokenized_input": ["hello", "world"]
                }],
                "usage": {"total_tokens": 2}
            }),
        )
        .unwrap();

    assert_eq!(body["data"][0]["index"], 0);
    assert_eq!(body["data"][0]["object"], "embedding");
    assert_eq!(
        body["data"][0]["embeddings"],
        json!([[0.1, 0.2], [0.3, 0.4]])
    );
    assert!(body["data"][0].get("embedding").is_none());
}

#[test]
fn jina_embeddings_preserves_string_embedding_and_multimodal_usage() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaEmbeddings,
        ResponseContext {
            model: "jina-embeddings-v4".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-embeddings-v4",
                "object": "list",
                "usage": {
                    "total_tokens": 5,
                    "prompt_tokens": 2,
                    "image_tokens": 1,
                    "audio_tokens": 1,
                    "video_tokens": 1
                },
                "data": [{
                    "object": "embedding",
                    "embedding": "base64-embedding"
                }]
            }),
        )
        .unwrap();

    assert_eq!(body["object"], "list");
    assert_eq!(body["data"][0]["index"], 0);
    assert_eq!(body["data"][0]["embedding"], "base64-embedding");
    assert_eq!(body["usage"]["image_tokens"], 1);
    assert_eq!(body["usage"]["audio_tokens"], 1);
    assert_eq!(body["usage"]["video_tokens"], 1);
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
fn aigateway_buffers_and_encodes_anthropic_encrypted_tool_streams() {
    let mut resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "claude-test".to_string(),
            request: json!({"tools": [encrypted_send_message_tool()]}),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );
    let mut public_events = Vec::new();

    public_events.extend(
        resolver
            .ingest(json!({
                "type": "message_start",
                "message": {"id": "msg_opaque_stream", "model": "claude-test"}
            }))
            .unwrap(),
    );
    public_events.extend(
        resolver
            .ingest(json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": {
                    "type": "tool_use",
                    "id": "call_opaque_stream",
                    "name": "send_message"
                }
            }))
            .unwrap(),
    );
    public_events.extend(
        resolver
            .ingest(json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {
                    "type": "input_json_delta",
                    "partial_json": "{\"message\":\"anthropic stream secret\","
                }
            }))
            .unwrap(),
    );
    public_events.extend(
        resolver
            .ingest(json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {
                    "type": "input_json_delta",
                    "partial_json": "\"task_name\":\"stream\"}"
                }
            }))
            .unwrap(),
    );

    assert!(!public_events.iter().any(|event| {
        event
            .get("delta")
            .and_then(Value::as_str)
            .is_some_and(|delta| delta.contains("anthropic stream secret"))
    }));

    public_events.extend(
        resolver
            .ingest(json!({"type": "content_block_stop", "index": 0}))
            .unwrap(),
    );
    public_events.extend(resolver.ingest(json!({"type": "message_stop"})).unwrap());

    assert!(
        public_events
            .iter()
            .all(|event| { !event.to_string().contains("anthropic stream secret") })
    );
    let done = public_events
        .iter()
        .find(|event| event["type"] == "response.function_call_arguments.done")
        .unwrap();
    let arguments: Value = serde_json::from_str(done["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["task_name"], "stream");
    assert!(
        arguments["message"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-opaque-v1:")
    );
    for (expected, event) in public_events.iter().enumerate() {
        assert_eq!(event["sequence_number"], expected as u64);
    }
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
        !serde_json::to_string(&body)
            .unwrap()
            .contains("SHOULD_NOT_APPEAR_IN_TEXT")
    );
}

#[test]
fn gemini_generate_content_accumulates_text_tool_and_usage() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GeminiGenerateContent,
        ResponseContext {
            model: "gemini-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "candidates": [{
                "content": {
                    "parts": [
                        {"text": "hello gemini"},
                        {"functionCall": {"name": "lookup", "args": {"query": "weather"}}}
                    ]
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 4,
                "candidatesTokenCount": 6,
                "totalTokenCount": 10
            }
        }))
        .unwrap();
    let terminal = events.last().unwrap();
    let output = terminal["response"]["output"].as_array().unwrap();

    assert_eq!(terminal["type"], "response.completed");
    assert_eq!(output[0]["content"][0]["text"], "hello gemini");
    assert!(
        output
            .iter()
            .any(|item| item["type"] == "function_call" && item["name"] == "lookup")
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 10);
}

#[test]
fn gemini_terminal_reasons_map_to_incomplete_or_failed() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GeminiGenerateContent,
        ResponseContext {
            model: "gemini-test".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({"candidates": [{"finishReason": "MAX_TOKENS"}]}))
        .unwrap();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "max_output_tokens"
    );

    let mut resolver = APIResolver::new(
        APIResolverKind::GeminiGenerateContent,
        ResponseContext::default(),
    );
    let events = resolver
        .ingest(json!({"candidates": [{"finishReason": "SAFETY"}]}))
        .unwrap();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.failed");
    assert_eq!(
        terminal["response"]["error"]["code"],
        "provider_terminal_rejected"
    );
}

#[test]
fn bedrock_converse_accumulates_eventstream_text_and_usage() {
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

    resolver
        .ingest(json!({
            "contentBlockDelta": {"delta": {"text": "hello bedrock"}}
        }))
        .unwrap();
    resolver
        .ingest(json!({
            "metadata": {
                "usage": {"inputTokens": 3, "outputTokens": 5, "totalTokens": 8}
            }
        }))
        .unwrap();
    let events = resolver.ingest(json!({"messageStop": {}})).unwrap();
    let terminal = events.last().unwrap();

    assert_eq!(terminal["type"], "response.completed");
    assert_eq!(
        terminal["response"]["output"][0]["content"][0]["text"],
        "hello bedrock"
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 8);
}

#[test]
fn bedrock_stop_reasons_map_to_incomplete_or_failed() {
    let mut resolver =
        APIResolver::new(APIResolverKind::BedrockConverse, ResponseContext::default());
    let events = resolver
        .ingest(json!({"messageStop": {"stopReason": "max_tokens"}}))
        .unwrap();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "max_output_tokens"
    );

    let mut resolver =
        APIResolver::new(APIResolverKind::BedrockConverse, ResponseContext::default());
    let events = resolver
        .ingest(json!({"messageStop": {"stopReason": "content_filtered"}}))
        .unwrap();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.failed");
    assert_eq!(
        terminal["response"]["error"]["code"],
        "provider_terminal_rejected"
    );
}

#[test]
fn openrouter_embeddings_normalizes_openrouter_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterEmbeddings,
        ResponseContext {
            model: "openai/text-embedding-3-small".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "data": [{
                    "embedding": [0.1, 0.2],
                    "object": "embedding"
                }],
                "object": "list",
                "usage": {"prompt_tokens": 2, "total_tokens": 2}
            }),
        )
        .unwrap();

    assert_eq!(body["model"], "openai/text-embedding-3-small");
    assert_eq!(body["data"][0]["index"], 0);
    assert_eq!(body["data"][0]["embedding"], json!([0.1, 0.2]));
    assert_eq!(body["usage"]["total_tokens"], 2);
}

#[test]
fn google_embeddings_normalizes_native_embed_content_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "gemini-embedding-001".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(200, json!({"embedding": {"values": [0.1, 0.2]}}))
        .unwrap();

    assert_eq!(body["object"], "list");
    assert_eq!(body["model"], "gemini-embedding-001");
    assert_eq!(body["data"][0]["object"], "embedding");
    assert_eq!(body["data"][0]["embedding"], json!([0.1, 0.2]));
    assert_eq!(body["data"][0]["index"], 0);
}

#[test]
fn google_embeddings_normalizes_native_batch_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "gemini-embedding-001".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({"embeddings": [{"values": [0.1]}, {"values": [0.2]}]}),
        )
        .unwrap();

    assert_eq!(body["data"][0]["embedding"], json!([0.1]));
    assert_eq!(body["data"][0]["index"], 0);
    assert_eq!(body["data"][1]["embedding"], json!([0.2]));
    assert_eq!(body["data"][1]["index"], 1);
}

#[test]
fn openrouter_rerank_preserves_provider_and_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterRerank,
        ResponseContext {
            model: "cohere/rerank-v3.5".to_string(),
            request: json!({"documents": ["Paris", "Berlin"]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "id": "gen-rerank-123",
                "model": "cohere/rerank-v3.5",
                "provider": "Cohere",
                "results": [{
                    "document": {"text": "Paris"},
                    "index": 0,
                    "relevance_score": 0.98
                }],
                "usage": {"total_tokens": 12}
            }),
        )
        .unwrap();

    assert_eq!(body["id"], "gen-rerank-123");
    assert_eq!(body["provider"], "Cohere");
    assert_eq!(body["results"][0]["document"], json!({"text": "Paris"}));
    assert_eq!(body["results"][0]["relevance_score"], 0.98);
}

#[test]
fn jina_rerank_reconstructs_document_when_omitted() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaRerank,
        ResponseContext {
            model: "jina-reranker-v3".to_string(),
            request: json!({"documents": ["Paris", {"text": "Berlin"}]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-reranker-v3",
                "results": [{"index": 1, "relevance_score": 0.31}],
                "usage": {"total_tokens": 12}
            }),
        )
        .unwrap();

    assert_eq!(body["results"][0]["document"], json!({"text": "Berlin"}));
    assert_eq!(body["results"][0]["index"], 1);
    assert_eq!(body["usage"]["total_tokens"], 12);
}

#[test]
fn jina_rerank_normalizes_string_document_and_preserves_embedding() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaRerank,
        ResponseContext {
            model: "jina-reranker-v3".to_string(),
            request: json!({"documents": ["Paris"]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-reranker-v3",
                "object": "list",
                "results": [{
                    "index": 0,
                    "relevance_score": 0.99,
                    "document": "Paris is the capital of France.",
                    "embedding": [1]
                }],
                "usage": {"total_tokens": 1}
            }),
        )
        .unwrap();

    assert_eq!(body["object"], "list");
    assert_eq!(
        body["results"][0]["document"],
        json!({"text": "Paris is the capital of France."})
    );
    assert_eq!(body["results"][0]["embedding"], json!([1]));
    assert_eq!(body["usage"]["total_tokens"], 1);
}

#[test]
fn parallel_web_search_builds_search_body() {
    let resolver = APIResolver::new(
        APIResolverKind::ParallelWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "ankole web search", "limit": 3}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["objective"], "ankole web search");
    assert_eq!(body["search_queries"], json!(["ankole web search"]));
    assert_eq!(body["advanced_settings"]["max_results"], 3);
    assert!(body.get("model").is_none());
}

#[test]
fn bright_data_serp_web_search_builds_direct_request_body() {
    let resolver = APIResolver::new(
        APIResolverKind::BrightDataSerpWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "agent operating system", "limit": 7}),
            provider_options: json!({
                "zone": "serp_api1",
                "country": "us",
                "language": "en"
            }),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["zone"], "serp_api1");
    assert_eq!(body["format"], "json");
    assert_eq!(
        body["url"],
        "https://www.google.com/search?q=agent+operating+system&num=7&gl=us&hl=en"
    );
}

#[test]
fn jina_search_builds_search_body() {
    let resolver = APIResolver::new(
        APIResolverKind::JinaSearchWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "ankole web search", "limit": 4}),
            provider_options: json!({"gl": "us", "hl": "en"}),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["q"], "ankole web search");
    assert_eq!(body["num"], 4);
    assert_eq!(body["gl"], "us");
    assert_eq!(body["hl"], "en");
    assert!(body.get("model").is_none());
}

#[test]
fn web_search_normalizes_parallel_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::ParallelWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "Ankole"}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "results": [{
                    "title": "Ankole docs",
                    "url": "https://example.com/ankole",
                    "publish_date": "2026-07-04",
                    "excerpts": ["AIGateway", "Web Search"]
                }]
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["query"], "Ankole");
    assert_eq!(body["results"][0]["title"], "Ankole docs");
    assert_eq!(body["results"][0]["snippet"], "AIGateway\nWeb Search");
    assert_eq!(body["results"][0]["published_at"], "2026-07-04");
}

#[test]
fn web_search_normalizes_jina_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaSearchWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "Ankole"}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "results": [{
                    "title": "Ankole docs",
                    "url": "https://example.com/ankole",
                    "snippet": "RuntimeFabric and AIGateway",
                    "date": "2026-07-04"
                }]
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["query"], "Ankole");
    assert_eq!(body["results"][0]["title"], "Ankole docs");
    assert_eq!(body["results"][0]["snippet"], "RuntimeFabric and AIGateway");
    assert_eq!(body["results"][0]["published_at"], "2026-07-04");
}

#[test]
fn jina_reader_web_fetch_normalizes_data_content() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaReaderWebFetch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"urls": ["https://example.com/page"]}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let request_body = Value::Object(resolver.build_body().unwrap());
    assert_eq!(request_body["url"], "https://example.com/page");

    let body = resolver
        .normalize_body(
            200,
            json!({
                "data": {
                    "title": "Example",
                    "url": "https://example.com/page",
                    "content": "# Example\nBody"
                }
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["results"][0]["url"], "https://example.com/page");
    assert_eq!(body["results"][0]["title"], "Example");
    assert_eq!(body["results"][0]["text"], "# Example\nBody");
}

#[test]
fn native_error_events_use_openresponses_error_then_failed() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    let events = resolver.fail(
        &StreamError::new("invalid_provider_event", "api_resolver", "bad event")
            .provider_status(503)
            .provider_body_excerpt(br#"{"error":"upstream unavailable"}"#),
    );

    assert_eq!(events[0]["type"], "error");
    assert_eq!(events[0]["error"]["status"], 503);
    assert_eq!(events[0]["error"]["details_json"]["stage"], "api_resolver");
    assert_eq!(
        events[0]["error"]["details_json"]["provider_body_excerpt"],
        r#"{"error":"upstream unavailable"}"#
    );
    assert_eq!(events[1]["type"], "response.failed");
    assert_eq!(events[1]["response"]["status"], "failed");
    assert_eq!(events[1]["response"]["error"]["status"], 503);
    assert_eq!(
        events[1]["response"]["error"]["details_json"]["provider_body_excerpt"],
        r#"{"error":"upstream unavailable"}"#
    );
}
