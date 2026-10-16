use super::super::*;
use super::support::reasoning_source_context;
use crate::common::base64_url_safe_decode;

#[test]
fn non_responses_wire_rejects_provider_native_compaction_input() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{"type": "compaction", "encrypted_content": "opaque"}]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();
    assert_eq!(error.code, "unsupported_compaction_replay_wire");
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
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "response.failed");
    assert_eq!(events[0]["response"]["error"]["status"], 502);
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
    let mut public_events = Vec::new();

    public_events.extend(
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
            .unwrap(),
    );
    public_events.extend(
        resolver
            .ingest(json!({
                "choices": [{
                    "delta": {"tool_calls": [{
                        "index": 0,
                        "id": "",
                        "function": {"name": "", "arguments": ":\"Shanghai\"}"}
                    }]},
                    "finish_reason": "tool_calls"
                }]
            }))
            .unwrap(),
    );
    public_events.extend(resolver.finish().unwrap());
    let terminal = public_events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "function_call")
        .unwrap();

    assert_eq!(call["call_id"], "call_1");
    assert_eq!(call["name"], "get_weather");
    assert_eq!(call["arguments"], "{\"city\":\"Shanghai\"}");
    assert_eq!(
        public_events
            .iter()
            .filter_map(|event| event["type"].as_str())
            .collect::<Vec<_>>(),
        vec![
            "response.created",
            "response.output_item.added",
            "response.function_call_arguments.delta",
            "response.function_call_arguments.delta",
            "response.function_call_arguments.done",
            "response.output_item.done",
            "response.completed"
        ]
    );
    for (expected, event) in public_events.iter().enumerate() {
        assert_eq!(event["sequence_number"], expected as u64);
    }
}

#[test]
fn openai_chat_stream_round_trips_reasoning_details_with_tool_calls() {
    let reasoning_details = json!([
        {
            "type": "reasoning.encrypted",
            "data": "provider-state",
            "format": "google-gemini-v1",
            "id": "reasoning_1",
            "index": 0
        },
        {
            "type": "reasoning.text",
            "text": "Select the weather tool.",
            "format": "google-gemini-v1",
            "id": "reasoning_1",
            "index": 1
        }
    ]);
    let mut resolver = APIResolver::new(APIResolverKind::OpenAIChatCompletions, {
        let mut context = reasoning_source_context(
            "openrouter",
            "gemini-test",
            json!({
                "tools": [{
                    "type": "function",
                    "name": "get_weather",
                    "parameters": {"type": "object"}
                }],
                "input": "Get the weather."
            }),
        );
        context.stream = Some(true);
        context
    });

    let events = resolver
        .ingest(json!({
            "choices": [{
                "delta": {
                    "reasoning_details": [reasoning_details[0].clone()],
                    "reasoning": "Select "
                },
                "finish_reason": null
            }]
        }))
        .unwrap();
    assert!(events.iter().any(|event| {
        event["type"] == "response.output_item.added" && event["item"]["type"] == "reasoning"
    }));

    resolver
        .ingest(json!({
            "choices": [{
                "delta": {
                    "reasoning_details": [reasoning_details[1].clone()],
                    "reasoning": "the weather tool.",
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_weather",
                        "function": {
                            "name": "get_weather",
                            "arguments": "{\"city\":\"Shanghai\"}"
                        }
                    }]
                },
                "finish_reason": "tool_calls"
            }]
        }))
        .unwrap();

    let events = resolver.finish().unwrap();
    let terminal = events.last().unwrap();
    let output = terminal["response"]["output"].as_array().unwrap();
    assert_eq!(output[0]["type"], "reasoning");
    assert_eq!(output[1]["type"], "function_call");
    assert!(
        output[0]["encrypted_content"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-chat-reasoning:")
    );
    let encoded = output[0]["encrypted_content"].as_str().unwrap();
    let payload = encoded
        .strip_prefix("ankole-aigateway-chat-reasoning:")
        .unwrap();
    let decoded: Value = sonic_rs::from_slice(&base64_url_safe_decode(payload).unwrap()).unwrap();
    assert_eq!(decoded["provider_type"], "openrouter");
    assert_eq!(decoded["model_id"], "gemini-test");
    assert!(decoded.get("version").is_none());
    assert!(decoded.get("provider_id").is_none());

    let mut replay_input = output.clone();
    replay_input.push(json!({
        "type": "function_call_output",
        "call_id": "call_weather",
        "output": "sunny"
    }));
    let replay = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        reasoning_source_context(
            "openrouter",
            "gemini-test",
            json!({
                "tools": [{
                    "type": "function",
                    "name": "get_weather",
                    "parameters": {"type": "object"}
                }],
                "input": replay_input
            }),
        ),
    );
    let replay_body = Value::Object(replay.build_body().unwrap());
    let replay_messages = replay_body["messages"].as_array().unwrap();

    assert_eq!(replay_messages[0]["reasoning_details"], reasoning_details);
    assert_eq!(replay_messages[0]["reasoning"], "Select the weather tool.");
    assert_eq!(replay_messages[0]["tool_calls"][0]["id"], "call_weather");
    assert_eq!(replay_messages[1]["role"], "tool");
    assert_eq!(replay_messages[1]["tool_call_id"], "call_weather");
}

#[test]
fn openai_chat_non_streaming_round_trips_reasoning_details() {
    let reasoning_details = json!([{
        "type": "reasoning.encrypted",
        "data": "provider-state",
        "format": "google-gemini-v1",
        "id": "reasoning_1",
        "index": 0
    }]);
    let tools = json!([{
        "type": "function",
        "name": "lookup",
        "parameters": {"type": "object"}
    }]);
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        reasoning_source_context(
            "openrouter",
            "gemini-test",
            json!({"tools": tools.clone(), "input": "Look it up."}),
        ),
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_reasoning",
                "created": 10,
                "model": "gemini-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "reasoning_details": reasoning_details.clone(),
                        "tool_calls": [{
                            "id": "call_lookup",
                            "type": "function",
                            "function": {"name": "lookup", "arguments": "{}"}
                        }]
                    },
                    "finish_reason": "tool_calls"
                }],
                "usage": {}
            }),
        )
        .unwrap();
    assert_eq!(response["output"][0]["type"], "reasoning");
    assert_eq!(response["output"][1]["type"], "function_call");

    let replay = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        reasoning_source_context(
            "openrouter",
            "gemini-test",
            json!({
                "tools": tools,
                "input": [
                    response["output"][0].clone(),
                    response["output"][1].clone(),
                    {
                        "type": "function_call_output",
                        "call_id": "call_lookup",
                        "output": "found"
                    }
                ]
            }),
        ),
    );
    let replay_body = Value::Object(replay.build_body().unwrap());

    assert_eq!(
        replay_body["messages"][0]["reasoning_details"],
        reasoning_details
    );
    assert_eq!(
        replay_body["messages"][0]["tool_calls"][0]["id"],
        "call_lookup"
    );
}

// Gemini streams its text before the calls, streams each parallel call whole
// and without `index`, and signs only the first call of a step.
#[test]
fn openai_chat_stream_round_trips_tool_call_extra_content() {
    let signature = json!({"google": {"thought_signature": "signature-state"}});
    let request = json!({
        "tools": [{
            "type": "function",
            "name": "get_weather",
            "parameters": {"type": "object"}
        }],
        "input": "Get the weather in Paris and Tokyo."
    });
    let mut resolver = APIResolver::new(APIResolverKind::OpenAIChatCompletions, {
        let mut context =
            reasoning_source_context("google_ai_studio_openai", "gemini-test", request.clone());
        context.stream = Some(true);
        context
    });

    resolver
        .ingest(json!({
            "choices": [{"delta": {"role": "assistant", "content": "I will check both cities."}, "index": 0}]
        }))
        .unwrap();
    for tool_call in [
        json!({
            "extra_content": signature.clone(),
            "id": "call_paris",
            "type": "function",
            "function": {"name": "get_weather", "arguments": "{\"city\":\"Paris\"}"}
        }),
        json!({
            "id": "call_tokyo",
            "type": "function",
            "function": {"name": "get_weather", "arguments": "{\"city\":\"Tokyo\"}"}
        }),
    ] {
        resolver
            .ingest(json!({
                "choices": [{"delta": {"role": "assistant", "tool_calls": [tool_call]}, "index": 0}]
            }))
            .unwrap();
    }
    resolver
        .ingest(json!({
            "choices": [{"delta": {"role": "assistant"}, "finish_reason": "stop", "index": 0}]
        }))
        .unwrap();

    let events = resolver.finish().unwrap();
    let item_types = |items: &[Value]| {
        items
            .iter()
            .map(|item| item["type"].as_str().unwrap().to_string())
            .collect::<Vec<_>>()
    };
    let terminal_output = events.last().unwrap()["response"]["output"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(
        item_types(&terminal_output),
        ["message", "reasoning", "function_call", "function_call"]
    );
    let done_output = events
        .iter()
        .filter(|event| event["type"] == "response.output_item.done")
        .map(|event| event["item"].clone())
        .collect::<Vec<_>>();
    assert_eq!(
        item_types(&done_output),
        ["reasoning", "message", "function_call", "function_call"]
    );

    let replay_tool_calls = |model: &str, output: &[Value]| {
        let mut replay_input = output.to_vec();
        for call_id in ["call_paris", "call_tokyo"] {
            replay_input.push(json!({
                "type": "function_call_output",
                "call_id": call_id,
                "output": "sunny"
            }));
        }
        let mut replay_request = request.clone();
        replay_request["input"] = Value::Array(replay_input);
        let replay = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            reasoning_source_context("google_ai_studio_openai", model, replay_request),
        );
        let body = Value::Object(replay.build_body().unwrap());
        body["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find_map(|message| message.get("tool_calls").cloned())
            .unwrap()
    };

    for output in [&terminal_output, &done_output] {
        let tool_calls = replay_tool_calls("gemini-test", output);
        assert_eq!(tool_calls[0]["id"], "call_paris");
        assert_eq!(tool_calls[0]["extra_content"], signature);
        assert_eq!(tool_calls[1]["id"], "call_tokyo");
        assert!(tool_calls[1].get("extra_content").is_none());

        let foreign_tool_calls = replay_tool_calls("other-model", output);
        assert!(foreign_tool_calls[0].get("extra_content").is_none());
    }
}

#[test]
fn openai_chat_drops_reasoning_that_has_no_message_or_tool_call() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "qwen-test".to_string(),
            request: json!({"input": "Answer the user."}),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_reasoning_only",
                "created": 10,
                "model": "qwen-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "reasoning_details": [{
                            "type": "reasoning.text",
                            "text": "No visible answer.",
                            "format": "unknown",
                            "index": 0
                        }]
                    },
                    "finish_reason": "stop"
                }],
                "usage": {}
            }),
        )
        .unwrap();

    let replay = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "qwen-test".to_string(),
            request: json!({
                "input": [
                    response["output"][0].clone(),
                    {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "Try again."}]
                    }
                ]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );
    let replay_body = Value::Object(replay.build_body().unwrap());
    let messages = replay_body["messages"].as_array().unwrap();

    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["role"], "user");
    assert_eq!(
        messages[0]["content"],
        json!([{"type": "text", "text": "Try again."}])
    );
}

#[test]
fn openai_chat_drops_foreign_reasoning_replay() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        reasoning_source_context(
            "openrouter",
            "openrouter-test",
            json!({
                "input": [{
                    "type": "reasoning",
                    "encrypted_content": "foreign-provider-state",
                    "summary": []
                }]
            }),
        ),
    );

    let body = Value::Object(resolver.build_body().unwrap());
    assert_eq!(body["messages"], json!([]));
}

#[test]
fn openai_chat_drops_reasoning_when_provider_type_or_model_changes() {
    let mut source = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        reasoning_source_context(
            "openrouter",
            "deepseek/model-a",
            json!({"input": "Answer."}),
        ),
    );
    let response = source
        .normalize_body(
            200,
            json!({
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": "Visible answer.",
                        "reasoning": "Hidden reasoning."
                    },
                    "finish_reason": "stop"
                }],
                "usage": {}
            }),
        )
        .unwrap();

    for (provider_type, model_id) in [
        ("openrouter", "deepseek/model-b"),
        ("openai", "deepseek/model-a"),
    ] {
        let replay = APIResolver::new(
            APIResolverKind::OpenAIChatCompletions,
            reasoning_source_context(
                provider_type,
                model_id,
                json!({"input": response["output"].clone()}),
            ),
        );
        let body = Value::Object(replay.build_body().unwrap());
        let message = &body["messages"][0];
        assert_eq!(message["role"], "assistant");
        assert_eq!(message["content"], "Visible answer.");
        assert!(message.get("reasoning").is_none());
        assert!(message.get("reasoning_details").is_none());
    }
}

#[test]
fn openai_chat_stream_restores_custom_tool_calls() {
    let patch = "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n";
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "custom",
                    "name": "apply_patch",
                    "description": "Apply one patch.",
                    "format": {
                        "type": "grammar",
                        "syntax": "lark",
                        "definition": "start: begin_patch hunk+ end_patch"
                    }
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let events = resolver
        .ingest(json!({
            "choices": [{
                "delta": {"tool_calls": [{
                    "index": 0,
                    "id": "call_patch",
                    "function": {
                        "name": "apply_patch",
                        "arguments": sonic_rs::to_string(&json!({"input": patch})).unwrap()
                    }
                }]},
                "finish_reason": "tool_calls"
            }]
        }))
        .unwrap();
    assert!(events.iter().any(|event| {
        event["type"] == "response.output_item.added" && event["item"]["type"] == "custom_tool_call"
    }));
    assert!(
        !events
            .iter()
            .any(|event| { event["type"] == "response.function_call_arguments.delta" })
    );

    let events = resolver.finish().unwrap();
    assert!(events.iter().any(|event| {
        event["type"] == "response.custom_tool_call_input.done" && event["input"] == patch
    }));
    let terminal = events.last().unwrap();
    let call = terminal["response"]["output"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["type"] == "custom_tool_call")
        .unwrap();
    assert_eq!(call["call_id"], "call_patch");
    assert_eq!(call["name"], "apply_patch");
    assert_eq!(call["input"], patch);
    assert!(call.get("arguments").is_none());
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
        !sonic_rs::to_string(&messages)
            .unwrap()
            .contains("function_call_output")
    );
}

#[test]
fn openai_chat_build_body_maps_custom_tool_and_history_to_chat_functions() {
    let patch = "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "custom",
                    "name": "apply_patch",
                    "description": "Apply one patch.",
                    "format": {
                        "type": "grammar",
                        "syntax": "lark",
                        "definition": "start: begin_patch hunk+ end_patch"
                    }
                }],
                "input": [
                    {
                        "type": "custom_tool_call",
                        "call_id": "call_patch",
                        "name": "apply_patch",
                        "input": patch
                    },
                    {
                        "type": "custom_tool_call_output",
                        "call_id": "call_patch",
                        "output": "Done!"
                    }
                ]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());
    assert_eq!(body["tools"][0]["type"], "function");
    assert_eq!(body["tools"][0]["function"]["name"], "apply_patch");
    assert_eq!(
        body["tools"][0]["function"]["parameters"],
        json!({
            "type": "object",
            "properties": {
                "input": {
                    "type": "string",
                    "description": "Raw tool input. It must match this grammar:\nstart: begin_patch hunk+ end_patch"
                }
            },
            "required": ["input"],
            "additionalProperties": false
        })
    );
    assert_eq!(
        body["messages"][0]["tool_calls"][0]["function"]["arguments"],
        sonic_rs::to_string(&json!({"input": patch})).unwrap()
    );
    assert_eq!(body["messages"][1]["role"], "tool");
    assert_eq!(body["messages"][1]["tool_call_id"], "call_patch");
    assert_eq!(body["messages"][1]["content"], "Done!");
}

#[test]
fn openai_chat_non_streaming_restores_custom_tool_calls() {
    let patch = "*** Begin Patch\n*** Delete File: stale.md\n*** End Patch\n";
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "custom",
                    "name": "apply_patch",
                    "description": "Apply one patch.",
                    "format": {"type": "text"}
                }]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_patch",
                "created": 10,
                "model": "openrouter-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_patch",
                            "type": "function",
                            "function": {
                                "name": "apply_patch",
                                "arguments": sonic_rs::to_string(&json!({"input": patch})).unwrap()
                            }
                        }]
                    },
                    "finish_reason": "tool_calls"
                }]
            }),
        )
        .unwrap();

    assert_eq!(response["output"][0]["type"], "custom_tool_call");
    assert_eq!(response["output"][0]["call_id"], "call_patch");
    assert_eq!(response["output"][0]["name"], "apply_patch");
    assert_eq!(response["output"][0]["input"], patch);
    assert!(response["output"][0].get("arguments").is_none());
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
        sonic_rs::to_string(&body)
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
fn openai_chat_stream_length_finish_reason_maps_to_incomplete() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    resolver
        .ingest(json!({
            "choices": [{
                "delta": {"content": "truncated"},
                "finish_reason": "length"
            }]
        }))
        .unwrap();
    let events = resolver.finish().unwrap();
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
fn openai_chat_one_shot_length_finish_reason_maps_to_incomplete() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_length",
                "created": 10,
                "model": "chat-test",
                "choices": [{
                    "message": {"role": "assistant", "content": "truncated"},
                    "finish_reason": "length"
                }],
                "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5}
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
    assert_eq!(response["usage"]["total_tokens"], 5);
}

#[test]
fn native_failure_has_one_openresponses_terminal_with_all_error_facts() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext::default(),
    );

    let events = resolver.fail(
        &StreamError::new("invalid_provider_event", "api_resolver", "bad event")
            .provider_status(503)
            .provider_body_excerpt(br#"{"error":"upstream unavailable"}"#),
    );

    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["type"], "response.failed");
    assert_eq!(events[0]["response"]["status"], "failed");
    assert_eq!(events[0]["response"]["error"]["status"], 503);
    assert_eq!(
        events[0]["response"]["error"]["details_json"]["stage"],
        "api_resolver"
    );
    assert_eq!(
        events[0]["response"]["error"]["details_json"]["provider_body_excerpt"],
        r#"{"error":"upstream unavailable"}"#
    );
}
