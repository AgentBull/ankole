use super::super::*;

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
fn openai_responses_preserves_native_encrypted_tool_schema() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "provider-test".to_string(),
            request: json!({
                "__ankole_native_encrypted_tool_fields": true,
                "tools": [encrypted_send_message_tool()],
                "input": "start"
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        provider_body["tools"][0]["parameters"]["properties"]["message"]["encrypted"],
        true
    );
}

#[test]
fn openai_responses_adapter_emulates_encrypted_tool_fields() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "compatible-test".to_string(),
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

    assert!(
        provider_body["tools"][0]["parameters"]["properties"]["message"]
            .get("encrypted")
            .is_none()
    );
}

#[test]
fn adapter_routes_remove_aigateway_encrypted_tool_markers() {
    for kind in [
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
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
fn openai_responses_preserves_provider_encrypted_function_arguments() {
    let context = || ResponseContext {
        model: "provider-test".to_string(),
        request: json!({
            "__ankole_native_encrypted_tool_fields": true,
            "tools": [encrypted_send_message_tool()]
        }),
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
                    "arguments": "{\"message\":\"provider ciphertext\",\"task_name\":\"r\"}",
                    "encrypted_function_args": ["message"],
                    "status": "completed"
                }]
            }),
        )
        .unwrap();

    assert_eq!(
        responses_body["output"][0]["arguments"],
        "{\"message\":\"provider ciphertext\",\"task_name\":\"r\"}"
    );
    assert_eq!(
        responses_body["output"][0]["encrypted_function_args"],
        json!(["message"])
    );
}

#[test]
fn aigateway_encodes_marked_outputs_after_anthropic_adapter() {
    let mut anthropic = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "provider-test".to_string(),
            request: json!({"tools": [encrypted_send_message_tool()]}),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );
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

    let arguments: Value =
        sonic_rs::from_str(anthropic_body["output"][0]["arguments"].as_str().unwrap()).unwrap();
    assert_eq!(arguments["task_name"], "a");
    assert!(
        arguments["message"]
            .as_str()
            .unwrap()
            .starts_with("ankole-aigateway-opaque-v1:")
    );
    assert!(!anthropic_body.to_string().contains("anthropic secret"));
}

#[test]
fn openai_responses_stream_preserves_provider_encrypted_function_arguments() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "__ankole_native_encrypted_tool_fields": true,
                "tools": [encrypted_send_message_tool()]
            }),
            provider_options: json!({}),
            stream: Some(true),
            include_model: true,
        },
    );
    let mut public_events = Vec::new();
    let arguments = "{\"message\":\"provider ciphertext\",\"task_name\":\"stream\"}";

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
            "delta": "{\"message\":\"provider ciphertext\","
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
                "encrypted_function_args": ["message"],
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
                    "encrypted_function_args": ["message"],
                    "status": "completed"
                }]
            }
        }),
    ] {
        public_events.extend(resolver.ingest(event).unwrap());
    }

    let terminal = public_events.last().unwrap();
    assert_eq!(terminal["response"]["output"][0]["arguments"], arguments);
    assert_eq!(
        terminal["response"]["output"][0]["encrypted_function_args"],
        json!(["message"])
    );
    for (expected, event) in public_events.iter().enumerate() {
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
                "__ankole_native_encrypted_tool_fields": true,
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
        sonic_rs::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

    assert_eq!(arguments["message"], "history secret");
    assert_eq!(
        provider_body["input"][1]["content"][0]["type"],
        "input_text"
    );
    assert_eq!(
        provider_body["input"][1]["content"][0]["text"],
        "history secret"
    );
    assert!(!provider_body.to_string().contains(opaque_message));
}

#[test]
fn openai_responses_preserves_provider_encrypted_agent_messages() {
    let provider_ciphertext = "gAAAAABprovider-owned-state";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{
                    "type": "agent_message",
                    "author": "/root",
                    "recipient": "/root/review",
                    "content": [
                        {"type": "input_text", "text": "Payload:\n"},
                        {"type": "encrypted_content", "encrypted_content": provider_ciphertext}
                    ]
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        provider_body["input"][0]["content"][1]["type"],
        "encrypted_content"
    );
    assert_eq!(
        provider_body["input"][0]["content"][1]["encrypted_content"],
        provider_ciphertext
    );
}

#[test]
fn openai_responses_preserves_provider_encrypted_function_call_output_parts() {
    let provider_ciphertext = "gAAAAABprovider-owned-output";
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
            request: json!({
                "input": [{
                    "type": "function_call_output",
                    "call_id": "call_1",
                    "output": [{
                        "type": "encrypted_content",
                        "encrypted_content": provider_ciphertext
                    }]
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let provider_body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        provider_body["input"][0]["output"][0]["type"],
        "encrypted_content"
    );
    assert_eq!(
        provider_body["input"][0]["output"][0]["encrypted_content"],
        provider_ciphertext
    );
}

#[test]
fn adapter_route_rejects_provider_encrypted_agent_message_content() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "chat-test".to_string(),
            request: json!({
                "input": [{
                    "type": "agent_message",
                    "author": "/root",
                    "recipient": "/root/review",
                    "content": [{
                        "type": "encrypted_content",
                        "encrypted_content": "gAAAAABprovider-owned-state"
                    }]
                }]
            }),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();

    assert_eq!(error.code, "invalid_encrypted_content");
    assert!(error.message.contains("another gateway"));
}

#[test]
fn openai_responses_rejects_corrupt_aigateway_agent_message_content() {
    let resolver = APIResolver::new(
        APIResolverKind::OpenAIResponses,
        ResponseContext {
            model: "gpt-test".to_string(),
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
            stream: Some(false),
            include_model: true,
        },
    );

    let error = resolver.build_body().unwrap_err();

    assert_eq!(error.code, "invalid_encrypted_content");
    assert!(error.message.contains("Base64URL"));
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
        sonic_rs::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

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
        sonic_rs::from_str(provider_body["input"][0]["arguments"].as_str().unwrap()).unwrap();

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
        APIResolverKind::OpenAIChatCompletions,
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
    let arguments: Value = sonic_rs::from_str(call["arguments"].as_str().unwrap()).unwrap();
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
    let replay_arguments: Value = sonic_rs::from_str(
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
        let arguments: Value = sonic_rs::from_str(call["arguments"].as_str().unwrap()).unwrap();
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
    let arguments: Value = sonic_rs::from_str(done["arguments"].as_str().unwrap()).unwrap();
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
