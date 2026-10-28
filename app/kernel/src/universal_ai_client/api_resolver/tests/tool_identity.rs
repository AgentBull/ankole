use super::super::*;

struct IdentityCase {
    namespace: Option<&'static str>,
    name: String,
    custom: bool,
    wrapped: bool,
}

impl IdentityCase {
    fn declaration(&self) -> Value {
        let mut tool = if self.custom {
            json!({"type": "custom", "name": self.name, "format": {"type": "text"}})
        } else {
            json!({"type": "function", "name": self.name, "parameters": {"type": "object"}})
        };
        if self.wrapped {
            tool = json!({"type": "function", "function": tool});
        }
        match self.namespace {
            Some(namespace) => json!({"type": "namespace", "name": namespace, "tools": [tool]}),
            None => tool,
        }
    }
}

fn identity_resolver(kind: APIResolverKind, declarations: Vec<Value>) -> APIResolver {
    APIResolver::new(
        kind,
        ResponseContext {
            model: "provider-test".to_string(),
            request: json!({"tools": declarations}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    )
}

fn wire_names(body: &Map<String, Value>) -> Vec<&str> {
    body.get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|tool| {
            tool.get("function")
                .unwrap_or(tool)
                .get("name")
                .and_then(Value::as_str)
                .expect("every emitted tool must have a wire name")
        })
        .collect()
}

#[test]
fn bounded_tool_sets_reject_alias_collisions_or_roundtrip_every_identity() {
    // These representatives cover root/default/named namespaces, underscore
    // joins, custom/function collisions, nested declarations and byte limits.
    // Enumerate every ordered list of zero to three entries, with repetition.
    let cases: Vec<_> = [
        (None, "lookup".to_owned(), false, false),
        (Some("functions"), "lookup".to_owned(), false, false),
        (Some("alpha"), "lookup".to_owned(), false, false),
        (None, "alpha__lookup".to_owned(), false, false),
        (Some("alpha_"), "lookup".to_owned(), false, false),
        (Some("alpha"), "_lookup".to_owned(), false, false),
        (Some("alpha"), "lookup".to_owned(), true, false),
        (Some("beta"), "lookup".to_owned(), true, false),
        (None, "$lookup".to_owned(), true, false),
        (None, "查找😀".to_owned(), false, false),
        (None, "x".repeat(64), false, false),
        (None, "x".repeat(65), false, false),
        (Some("alpha"), "x".repeat(64), false, false),
        (None, "plain".to_owned(), false, true),
        (Some("beta"), "lookup".to_owned(), false, false),
        (None, "alpha_lookup".to_owned(), false, false),
    ]
    .into_iter()
    .map(|(namespace, name, custom, wrapped)| IdentityCase {
        namespace,
        name,
        custom,
        wrapped,
    })
    .collect();
    let mut checked = 0;
    let mut accepted = 0;
    let mut rejected = 0;
    for kind in [
        APIResolverKind::OpenAIChatCompletions,
        APIResolverKind::AnthropicMessages,
    ] {
        // Derive each alias through the real adapter in isolation. The oracle
        // checks composition and reversal without copying the alias algorithm.
        let aliases: Vec<String> = cases
            .iter()
            .map(|case| {
                let body = identity_resolver(kind, vec![case.declaration()])
                    .build_body()
                    .unwrap();
                let names = wire_names(&body);
                assert_eq!(names.len(), 1);
                names[0].to_owned()
            })
            .collect();
        for length in 0..=3 {
            for mut encoding in 0..cases.len().pow(length) {
                let indices: Vec<_> = (0..length)
                    .map(|_| {
                        let index = encoding % cases.len();
                        encoding /= cases.len();
                        index
                    })
                    .collect();
                let expected_names: Vec<_> = indices.iter().map(|&i| aliases[i].as_str()).collect();
                let unique: BTreeSet<_> = expected_names.iter().copied().collect();
                let mut resolver = identity_resolver(
                    kind,
                    indices.iter().map(|&i| cases[i].declaration()).collect(),
                );
                let body = resolver.build_body();
                checked += 1;
                if unique.len() != expected_names.len() {
                    assert_eq!(body.unwrap_err().code, "tool_namespace_alias_collision");
                    rejected += 1;
                    continue;
                }
                let body = body.unwrap();
                assert_eq!(wire_names(&body), expected_names);
                for name in &expected_names {
                    assert!(!name.is_empty() && name.len() <= 64);
                    assert!(
                        name.bytes()
                            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
                    );
                }
                accepted += 1;
                if indices.is_empty() {
                    continue;
                }
                let calls: Vec<_> = indices
                    .iter()
                    .enumerate()
                    .map(|(position, &i)| {
                        let input = if cases[i].custom { json!({"input": "payload"}) } else { json!({"x": 1}) };
                        let id = format!("call_{position}");
                        if kind == APIResolverKind::OpenAIChatCompletions {
                            json!({"id": id, "type": "function", "function": {
                                "name": aliases[i], "arguments": sonic_rs::to_string(&input).unwrap()
                            }})
                        } else {
                            json!({"id": id, "type": "tool_use", "name": aliases[i], "input": input})
                        }
                    })
                    .collect();
                let response = if kind == APIResolverKind::OpenAIChatCompletions {
                    json!({"id": "response", "choices": [{"message": {"role": "assistant", "tool_calls": calls}, "finish_reason": "tool_calls"}]})
                } else {
                    json!({"id": "response", "content": calls, "stop_reason": "tool_use", "usage": {}})
                };
                let response = resolver.normalize_body(200, response).unwrap();
                let output = response["output"].as_array().unwrap();
                assert_eq!(output.len(), indices.len());
                for (position, (&i, output)) in indices.iter().zip(output).enumerate() {
                    let original = &cases[i];
                    assert_eq!(output["name"], original.name);
                    assert_eq!(
                        output.get("namespace").and_then(Value::as_str),
                        original.namespace
                    );
                    assert_eq!(output["call_id"], format!("call_{position}"));
                    assert_eq!(
                        output["type"],
                        if original.custom {
                            "custom_tool_call"
                        } else {
                            "function_call"
                        },
                        "{kind:?} identity {i} in {indices:?}"
                    );
                    if original.custom {
                        assert_eq!(output["input"], "payload");
                    } else {
                        let arguments: Value =
                            sonic_rs::from_str(output["arguments"].as_str().unwrap()).unwrap();
                        assert_eq!(arguments, json!({"x": 1}));
                    }
                }
            }
        }
    }
    assert_eq!(checked, 8738);
    assert!(accepted > 0 && rejected > 0);
}

#[test]
fn anthropic_custom_tools_preserve_schema_choice_replay_and_fragmented_input() {
    let input = "line one\nquote \" and slash \\ 😀";
    let encoded = sonic_rs::to_string(&json!({"input": input})).unwrap();
    for namespace in [None, Some("editing")] {
        let case = IdentityCase {
            namespace,
            name: "apply_patch".to_owned(),
            custom: true,
            wrapped: false,
        };
        let mut choice = json!({"type": "custom", "name": case.name});
        let mut previous = json!({
            "type": "custom_tool_call", "call_id": "previous", "name": case.name, "input": input
        });
        if let Some(namespace) = namespace {
            choice["namespace"] = json!(namespace);
            previous["namespace"] = json!(namespace);
        }
        let context = ResponseContext {
            model: "provider-test".to_string(),
            request: json!({
                "tools": [case.declaration()],
                "tool_choice": choice,
                "input": [previous, {"type": "custom_tool_call_output", "call_id": "previous", "output": "done"}]
            }),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        };
        let resolver = APIResolver::new(APIResolverKind::AnthropicMessages, context.clone());
        let body = Value::Object(resolver.build_body().unwrap());
        let alias = body["tools"][0]["name"].as_str().unwrap();
        assert_eq!(
            body["tools"][0]["input_schema"]["properties"]["input"]["type"],
            "string"
        );
        assert_eq!(
            body["tools"][0]["input_schema"]["required"],
            json!(["input"])
        );
        assert_eq!(
            body["tools"][0]["input_schema"]["additionalProperties"],
            false
        );
        assert_eq!(body["tool_choice"], json!({"type": "tool", "name": alias}));
        assert_eq!(
            body["messages"][0]["content"][0],
            json!({
                "type": "tool_use", "id": "previous", "name": alias, "input": {"input": input}
            })
        );
        assert_eq!(
            body["messages"][1]["content"][0],
            json!({
                "type": "tool_result", "tool_use_id": "previous", "content": "done"
            })
        );

        // Exercise every UTF-8-safe split of the JSON wrapper, including inside
        // JSON escape sequences. Only the completed text belongs in public events.
        for split in (0..=encoded.len()).filter(|&split| encoded.is_char_boundary(split)) {
            let mut resolver =
                APIResolver::new(APIResolverKind::AnthropicMessages, context.clone());
            let mut events = Vec::new();
            for event in [
                json!({"type": "message_start", "message": {"id": "response", "model": "provider-test"}}),
                json!({"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "current", "name": alias, "input": {}}}),
                json!({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": &encoded[..split]}}),
                json!({"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": &encoded[split..]}}),
                json!({"type": "content_block_stop", "index": 0}),
                json!({"type": "message_delta", "delta": {"stop_reason": "tool_use"}, "usage": {}}),
                json!({"type": "message_stop"}),
            ] {
                events.extend(resolver.ingest(event).unwrap());
            }
            assert!(!events.iter().any(|event| {
                event["type"]
                    .as_str()
                    .unwrap()
                    .starts_with("response.function_call_arguments.")
            }));
            let input_events: Vec<_> = events
                .iter()
                .filter(|event| event["type"] == "response.custom_tool_call_input.done")
                .collect();
            assert_eq!(input_events.len(), 1);
            assert_eq!(input_events[0]["input"], input);
            for event_type in ["response.output_item.added", "response.output_item.done"] {
                let item = &events
                    .iter()
                    .find(|event| event["type"] == event_type)
                    .unwrap()["item"];
                assert_eq!(item["type"], "custom_tool_call");
                assert_eq!(item["name"], "apply_patch");
                assert_eq!(item.get("namespace").and_then(Value::as_str), namespace);
                assert_eq!(item["call_id"], "current");
                assert!(item.get("arguments").is_none());
                assert_eq!(
                    item["input"],
                    if event_type.ends_with("done") {
                        input
                    } else {
                        ""
                    }
                );
            }
            let terminal = events
                .iter()
                .find(|event| event["type"] == "response.completed")
                .unwrap();
            let item = &terminal["response"]["output"][0];
            assert_eq!(item["type"], "custom_tool_call");
            assert_eq!(item["input"], input);
            assert_eq!(item.get("namespace").and_then(Value::as_str), namespace);
        }
    }
}

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
