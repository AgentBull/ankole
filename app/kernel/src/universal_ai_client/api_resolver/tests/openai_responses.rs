use super::super::*;

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
fn openai_responses_classifies_only_structured_stateful_replay_rejections() {
    let context = ResponseContext {
        model: "gpt-test".to_string(),
        request: json!({
            "__ankole_stateful_provider_replay": true,
            "input": [{"id": "rs_provider", "type": "reasoning"}]
        }),
        provider_options: json!({}),
        stream: Some(true),
        include_model: true,
    };

    let resolver = APIResolver::new(APIResolverKind::OpenAIResponses, context.clone());
    let body =
        br#"{"error":{"message":"arbitrary","param":"input","type":"invalid_request_error"}}"#;
    let error = resolver.classify_provider_rejection(400, body).unwrap();

    assert_eq!(error.code, "stateful_replay_input_rejected");
    assert_eq!(error.stage, "socket_open");

    for (status, body) in [
        (401, body.as_slice()),
        (429, body.as_slice()),
        (500, body.as_slice()),
        (
            400,
            br#"{"error":{"param":"model","type":"invalid_request_error"}}"#,
        ),
        (400, br#"{"error":{"param":"input","type":"server_error"}}"#),
    ] {
        assert!(resolver.classify_provider_rejection(status, body).is_none());
    }

    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            request: json!({"input": [{"id": "rs_provider", "type": "reasoning"}]}),
            ..context
        },
    );

    assert!(resolver.classify_provider_rejection(400, body).is_none());
}

#[test]
fn openai_responses_preserves_provider_native_compaction_input() {
    let input = json!([
        {"type": "compaction", "encrypted_content": "opaque"},
        {"type": "message", "role": "user", "content": "continue"},
        {"type": "compaction_trigger"}
    ]);
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({"input": input.clone()}),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    assert_eq!(
        Value::Object(resolver.build_body().unwrap())["input"],
        input
    );
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
fn openai_responses_failure_keeps_the_first_bounded_provider_diagnostic() {
    let mut resolver =
        APIResolver::new(APIResolverKind::OpenAIResponses, ResponseContext::default());
    let message = "故障".repeat(3000);
    resolver
        .ingest(json!({"type": "error", "error": {
            "code": "upstream_stream_break", "type": "provider_disconnect", "message": message
        }}))
        .unwrap();
    resolver
        .ingest(json!({"type": "error", "error": {
            "code": "later_error", "message": "must not replace the first diagnostic"
        }}))
        .unwrap();
    let error = StreamError::new("upstream_read_failed", "read", "connection closed");
    let events = resolver.fail(&error);
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.failed");
    let error = &terminal["response"]["error"];
    assert_eq!(error["code"], "upstream_read_failed");
    assert_eq!(
        error["details_json"]["provider_error_code"],
        "upstream_stream_break"
    );
    assert_eq!(
        error["details_json"]["provider_error_type"],
        "provider_disconnect"
    );
    assert_eq!(
        error["message"].as_str().unwrap().chars().count(),
        crate::universal_ai_client::error::PROVIDER_BODY_EXCERPT_LIMIT
    );
    assert_eq!(
        error["details_json"]["provider_diagnostic_message"],
        error["message"]
    );
}

#[test]
fn openai_responses_validation_diagnostic_owns_the_failure_terminal() {
    let mut resolver =
        APIResolver::new(APIResolverKind::OpenAIResponses, ResponseContext::default());
    resolver
        .ingest(json!({"type": "error", "error": {
            "type": "invalid_request_error", "status": 400, "message": "Invalid tool schema"
        }}))
        .unwrap();
    let close = resolver.finish().unwrap_err();
    let events = resolver.fail(&close);
    assert_eq!(events.last().unwrap()["type"], "response.failed");
    let error = &events.last().unwrap()["response"]["error"];
    assert_eq!(error["code"], "provider_response_rejected");
    assert_eq!(error["retryable"], false);
    assert_eq!(error["message"], "Invalid tool schema");
    assert_eq!(
        error["details_json"]["provider_error_type"],
        "invalid_request_error"
    );
    assert_eq!(error["details_json"]["provider_status"], 400);
    assert!(
        resolver.fail(&close).is_empty(),
        "one provider round has one failure terminal"
    );
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

fn emulated_responses_context(mut request: Value) -> ResponseContext {
    request
        .as_object_mut()
        .unwrap()
        .insert("__ankole_emulate_custom_tools".to_string(), json!(true));

    ResponseContext {
        model: "deepseek-test".to_string(),
        request,
        provider_options: json!({}),
        stream: Some(true),
        include_model: true,
    }
}

fn exec_custom_tool() -> Value {
    json!({
        "type": "custom",
        "name": "exec",
        "description": "Run source code.",
        "format": {
            "type": "grammar",
            "syntax": "lark",
            "definition": "start: SOURCE"
        }
    })
}

#[test]
fn openai_responses_emulation_lowers_custom_tools_history_and_tool_choice() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        emulated_responses_context(json!({
            "tools": [
                exec_custom_tool(),
                {
                    "type": "function",
                    "name": "lookup",
                    "description": "Look something up.",
                    "parameters": {"type": "object", "properties": {}}
                },
                {"type": "web_search"}
            ],
            "tool_choice": {"type": "custom", "name": "exec"},
            "input": [
                {
                    "type": "custom_tool_call",
                    "id": "fc_prev",
                    "call_id": "call_prev",
                    "name": "exec",
                    "input": "console.log(1)"
                },
                {
                    "type": "custom_tool_call_output",
                    "call_id": "call_prev",
                    "output": "1"
                }
            ]
        })),
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        body["tools"][0],
        json!({
            "type": "function",
            "name": "exec",
            "description": "Run source code.",
            "parameters": {
                "type": "object",
                "properties": {
                    "input": {
                        "type": "string",
                        "description": "Raw tool input. It must match this grammar:\nstart: SOURCE"
                    }
                },
                "required": ["input"],
                "additionalProperties": false
            },
            "strict": false
        })
    );
    assert_eq!(body["tools"][1]["type"], "function");
    assert_eq!(body["tools"][1]["name"], "lookup");
    assert_eq!(body["tools"][2], json!({"type": "web_search"}));
    assert_eq!(
        body["tool_choice"],
        json!({"type": "function", "name": "exec"})
    );
    assert_eq!(
        body["input"][0],
        json!({
            "type": "function_call",
            "id": "fc_prev",
            "call_id": "call_prev",
            "name": "exec",
            "arguments": sonic_rs::to_string(&json!({"input": "console.log(1)"})).unwrap()
        })
    );
    assert_eq!(body["input"][1]["type"], "function_call_output");
    assert_eq!(body["input"][1]["output"], "1");
    assert!(body.get("__ankole_emulate_custom_tools").is_none());
}

#[test]
fn openai_responses_without_marker_passes_custom_tools_through() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "tools": [exec_custom_tool()],
                "input": [{
                    "type": "custom_tool_call",
                    "call_id": "call_prev",
                    "name": "exec",
                    "input": "console.log(1)"
                }]
            }),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["tools"][0]["type"], "custom");
    assert_eq!(body["input"][0]["type"], "custom_tool_call");
}

#[test]
fn openai_responses_emulation_rejects_duplicate_tool_names() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        emulated_responses_context(json!({
            "tools": [
                exec_custom_tool(),
                {
                    "type": "function",
                    "name": "exec",
                    "description": "Conflicting function.",
                    "parameters": {"type": "object", "properties": {}}
                }
            ]
        })),
    );

    let error = resolver.build_body().unwrap_err();
    assert_eq!(error.code, "tool_namespace_alias_collision");
}

#[test]
fn openai_responses_emulation_restores_streamed_function_calls() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        emulated_responses_context(json!({
            "tools": [
                exec_custom_tool(),
                {
                    "type": "function",
                    "name": "lookup",
                    "description": "Look something up.",
                    "parameters": {"type": "object", "properties": {}}
                }
            ]
        })),
    );

    let events = resolver
        .ingest(json!({
            "type": "response.output_item.added",
            "sequence_number": 7,
            "output_index": 0,
            "item": {
                "type": "function_call",
                "id": "fc_1",
                "call_id": "call_1",
                "name": "exec",
                "arguments": "",
                "status": "in_progress"
            }
        }))
        .unwrap();
    assert_eq!(events[0]["item"]["type"], "custom_tool_call");
    assert_eq!(events[0]["item"]["input"], "");
    assert!(events[0]["item"].get("arguments").is_none());
    assert_eq!(events[0]["sequence_number"], 0);

    let suppressed = resolver
        .ingest(json!({
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_1",
            "output_index": 0,
            "delta": "{\"input\":\"con"
        }))
        .unwrap();
    assert!(suppressed.is_empty());

    let events = resolver
        .ingest(json!({
            "type": "response.function_call_arguments.done",
            "item_id": "fc_1",
            "output_index": 0,
            "arguments": sonic_rs::to_string(&json!({"input": "console.log(1)"})).unwrap()
        }))
        .unwrap();
    assert_eq!(events[0]["type"], "response.custom_tool_call_input.done");
    assert_eq!(events[0]["input"], "console.log(1)");
    assert!(events[0].get("arguments").is_none());
    assert_eq!(events[0]["sequence_number"], 1);

    let events = resolver
        .ingest(json!({
            "type": "response.output_item.added",
            "output_index": 1,
            "item": {
                "type": "function_call",
                "id": "fc_2",
                "call_id": "call_2",
                "name": "lookup",
                "arguments": "",
                "status": "in_progress"
            }
        }))
        .unwrap();
    assert_eq!(events[0]["item"]["type"], "function_call");

    let events = resolver
        .ingest(json!({
            "type": "response.function_call_arguments.delta",
            "item_id": "fc_2",
            "output_index": 1,
            "delta": "{}"
        }))
        .unwrap();
    assert_eq!(events[0]["type"], "response.function_call_arguments.delta");

    let events = resolver
        .ingest(json!({
            "type": "response.completed",
            "response": {
                "id": "resp_1",
                "status": "completed",
                "output": [
                    {
                        "type": "function_call",
                        "id": "fc_1",
                        "call_id": "call_1",
                        "name": "exec",
                        "arguments": sonic_rs::to_string(&json!({"input": "console.log(1)"}))
                            .unwrap(),
                        "status": "completed"
                    },
                    {
                        "type": "function_call",
                        "id": "fc_2",
                        "call_id": "call_2",
                        "name": "lookup",
                        "arguments": "{}",
                        "status": "completed"
                    }
                ]
            }
        }))
        .unwrap();
    let output = events[0]["response"]["output"].as_array().unwrap();
    assert_eq!(output[0]["type"], "custom_tool_call");
    assert_eq!(output[0]["call_id"], "call_1");
    assert_eq!(output[0]["input"], "console.log(1)");
    assert!(output[0].get("arguments").is_none());
    assert_eq!(output[1]["type"], "function_call");
    assert!(resolver.is_terminal());
}

#[test]
fn openai_responses_emulation_restores_non_streaming_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        emulated_responses_context(json!({"tools": [exec_custom_tool()]})),
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "resp_1",
                "status": "completed",
                "output": [{
                    "type": "function_call",
                    "id": "fc_1",
                    "call_id": "call_1",
                    "name": "exec",
                    "arguments": sonic_rs::to_string(&json!({"input": "pwd"})).unwrap(),
                    "status": "completed"
                }]
            }),
        )
        .unwrap();

    assert_eq!(response["output"][0]["type"], "custom_tool_call");
    assert_eq!(response["output"][0]["input"], "pwd");
}
