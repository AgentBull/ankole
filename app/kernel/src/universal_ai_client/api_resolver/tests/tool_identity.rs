use super::super::*;

#[test]
fn openai_chat_emulates_and_restores_namespaced_custom_tool_calls() {
    let patch = "*** Begin Patch\n*** Add File: report.md\n+done\n*** End Patch\n";
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "openrouter-test".to_string(),
            request: json!({
                "tools": [{
                    "type": "namespace",
                    "name": "editing",
                    "description": "Editing tools.",
                    "tools": [{
                        "type": "custom",
                        "name": "apply_patch",
                        "description": "Apply one patch.",
                        "format": {"type": "text"}
                    }]
                }],
                "tool_choice": {
                    "type": "custom",
                    "namespace": "editing",
                    "name": "apply_patch"
                },
                "input": [
                    {
                        "type": "custom_tool_call",
                        "call_id": "call_previous_patch",
                        "namespace": "editing",
                        "name": "apply_patch",
                        "input": patch
                    },
                    {
                        "type": "custom_tool_call_output",
                        "call_id": "call_previous_patch",
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
    assert_eq!(body["tools"][0]["function"]["name"], "editing__apply_patch");
    assert_eq!(
        body["tool_choice"]["function"]["name"],
        "editing__apply_patch"
    );
    assert_eq!(
        body["messages"][0]["tool_calls"][0]["function"]["name"],
        "editing__apply_patch"
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_namespaced_patch",
                "created": 10,
                "model": "openrouter-test",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [{
                            "id": "call_namespaced_patch",
                            "type": "function",
                            "function": {
                                "name": "editing__apply_patch",
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
    assert_eq!(response["output"][0]["namespace"], "editing");
    assert_eq!(response["output"][0]["name"], "apply_patch");
    assert_eq!(response["output"][0]["input"], patch);
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
fn anthropic_emulates_and_restores_response_tool_namespaces() {
    let request = json!({
        "tools": [{
            "type": "namespace",
            "name": "collaboration",
            "description": "Team tools",
            "tools": [{
                "type": "function",
                "name": "spawn_agent",
                "description": "Spawn an agent",
                "parameters": {"type": "object"}
            }]
        }],
        "tool_choice": {
            "type": "function",
            "namespace": "collaboration",
            "name": "spawn_agent"
        },
        "input": [{
            "type": "function_call",
            "call_id": "toolu_namespaced",
            "namespace": "collaboration",
            "name": "spawn_agent",
            "arguments": "{\"task\":\"audit\"}"
        }]
    });
    let context = ResponseContext {
        model: "claude-test".to_string(),
        request,
        provider_options: json!({}),
        stream: Some(false),
        include_model: true,
    };
    let mut resolver = APIResolver::new(APIResolverKind::AnthropicMessages, context.clone());
    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["tools"][0]["name"], "collaboration__spawn_agent");
    assert_eq!(body["tool_choice"]["name"], "collaboration__spawn_agent");
    assert_eq!(
        body["messages"][0]["content"][0]["name"],
        "collaboration__spawn_agent"
    );

    let response = resolver
        .normalize_body(
            200,
            json!({
                "id": "msg_namespaced",
                "model": "claude-test",
                "content": [{
                    "type": "tool_use",
                    "id": "toolu_new",
                    "name": "collaboration__spawn_agent",
                    "input": {"task": "review"}
                }],
                "usage": {}
            }),
        )
        .unwrap();

    assert_eq!(response["output"][0]["namespace"], "collaboration");
    assert_eq!(response["output"][0]["name"], "spawn_agent");

    let mut streaming = APIResolver::new(APIResolverKind::AnthropicMessages, context);
    streaming
        .ingest(json!({
            "type": "message_start",
            "message": {"id": "msg_stream_namespaced", "model": "claude-test"}
        }))
        .unwrap();
    let events = streaming
        .ingest(json!({
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_stream_namespaced",
                "name": "collaboration__spawn_agent"
            }
        }))
        .unwrap();

    assert_eq!(events[0]["item"]["namespace"], "collaboration");
    assert_eq!(events[0]["item"]["name"], "spawn_agent");
}

#[test]
fn single_name_adapters_reject_colliding_tool_namespace_aliases() {
    let request = json!({
        "tools": [
            {
                "type": "function",
                "name": "collaboration__spawn_agent",
                "parameters": {"type": "object"}
            },
            {
                "type": "namespace",
                "name": "collaboration",
                "tools": [{
                    "type": "function",
                    "name": "spawn_agent",
                    "parameters": {"type": "object"}
                }]
            }
        ]
    });

    for kind in [
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
    ] {
        let resolver = APIResolver::new(
            kind,
            ResponseContext {
                model: "provider-test".to_string(),
                request: request.clone(),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let error = resolver.build_body().unwrap_err();
        assert_eq!(error.code, "tool_namespace_alias_collision");
    }
}

#[test]
fn single_name_adapters_treat_functions_as_the_default_namespace() {
    let request = json!({
        "tools": [
            {
                "type": "function",
                "name": "lookup",
                "parameters": {"type": "object"}
            },
            {
                "type": "namespace",
                "name": "functions",
                "tools": [{
                    "type": "function",
                    "name": "lookup",
                    "parameters": {"type": "object"}
                }]
            }
        ]
    });

    for kind in [
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
    ] {
        let resolver = APIResolver::new(
            kind,
            ResponseContext {
                model: "provider-test".to_string(),
                request: request.clone(),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let error = resolver.build_body().unwrap_err();
        assert_eq!(error.code, "tool_namespace_alias_collision");
    }
}

#[test]
fn single_name_adapters_use_provider_wire_name_rules() {
    let long_name = "x".repeat(65);
    let long_alias = flattened_namespace_tool_name("", &long_name);
    let dollar_alias = flattened_namespace_tool_name("", "$value");

    assert!(long_alias.len() <= 64);
    assert!(
        long_alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    );
    assert_ne!(dollar_alias, "$value");
    assert!(
        dollar_alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    );

    let request = json!({
        "tools": [
            {
                "type": "function",
                "name": "7-get-value",
                "parameters": {"type": "object"}
            },
            {
                "type": "namespace",
                "name": "extension-2",
                "tools": [{
                    "type": "function",
                    "name": "send-note",
                    "parameters": {"type": "object"}
                }]
            },
            {
                "type": "function",
                "name": long_name,
                "parameters": {"type": "object"}
            },
            {
                "type": "function",
                "name": "7_get_value",
                "parameters": {"type": "object"}
            }
        ]
    });

    let mut chat = APIResolver::new(
        APIResolverKind::OpenAIChatCompletions,
        ResponseContext {
            model: "provider-test".to_string(),
            request: request.clone(),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );
    let chat_body = Value::Object(chat.build_body().unwrap());
    assert_eq!(chat_body["tools"][0]["function"]["name"], "7-get-value");
    assert_eq!(
        chat_body["tools"][1]["function"]["name"],
        "extension-2__send-note"
    );
    assert_eq!(chat_body["tools"][2]["function"]["name"], long_alias);
    assert_eq!(chat_body["tools"][3]["function"]["name"], "7_get_value");
    let chat_response = chat
        .normalize_body(
            200,
            json!({
                "id": "chatcmpl_root_alias",
                "choices": [{
                    "message": {
                        "role": "assistant",
                        "tool_calls": [{
                            "id": "call_root_alias",
                            "type": "function",
                            "function": {"name": long_alias, "arguments": "{}"}
                        }]
                    },
                    "finish_reason": "tool_calls"
                }]
            }),
        )
        .unwrap();
    assert_eq!(chat_response["output"][0]["name"], long_name);
    assert!(chat_response["output"][0].get("namespace").is_none());

    let mut anthropic = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        ResponseContext {
            model: "provider-test".to_string(),
            request,
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );
    let anthropic_body = Value::Object(anthropic.build_body().unwrap());
    assert_eq!(anthropic_body["tools"][0]["name"], "7-get-value");
    assert_eq!(anthropic_body["tools"][1]["name"], "extension-2__send-note");
    assert_eq!(anthropic_body["tools"][2]["name"], long_alias);
    assert_eq!(anthropic_body["tools"][3]["name"], "7_get_value");
    let anthropic_response = anthropic
        .normalize_body(
            200,
            json!({
                "id": "msg_root_alias",
                "role": "assistant",
                "content": [{
                    "type": "tool_use",
                    "id": "toolu_root_alias",
                    "name": long_alias,
                    "input": {}
                }],
                "stop_reason": "tool_use",
                "usage": {"input_tokens": 1, "output_tokens": 1}
            }),
        )
        .unwrap();
    assert_eq!(anthropic_response["output"][0]["name"], long_name);
    assert!(anthropic_response["output"][0].get("namespace").is_none());
}
