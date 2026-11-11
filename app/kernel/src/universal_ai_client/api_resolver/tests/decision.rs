use super::super::*;

fn resolver(model: &str) -> APIResolver {
    APIResolver::new(
        APIResolverKind::CloudflareDecision,
        ResponseContext {
            model: model.to_string(),
            request: json!({
                "model": "decision.default",
                "state": null,
                "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
            }),
            provider_options: json!({}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn workers_ai_decision_models_take_top_level_fields_and_a_short_model_id() {
    let body = Value::Object(resolver("@cf/cloudflare/clef-flash").build_body().unwrap());

    assert_eq!(
        body,
        json!({
            "model": "clef-flash",
            "state": null,
            "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
        })
    );
}

#[test]
fn partner_decision_models_take_fields_inside_input() {
    let body = Value::Object(resolver("typesafe/jev").build_body().unwrap());

    assert_eq!(
        body,
        json!({
            "model": "typesafe/jev",
            "input": {
                "state": null,
                "questions": {"urgent": {"type": "noul", "instructions": "Is it urgent?"}}
            }
        })
    );
}

#[test]
fn decision_response_is_read_from_the_result_envelope() {
    let answers = json!({"urgent": {"type": "noul", "noul": 0.93}});
    let usage = json!({"input_tokens": 41, "output_tokens": 0});

    let body = resolver("typesafe/jev")
        .normalize_body(
            200,
            json!({
                "state": "Completed",
                "result": {"model": "jev-1.13.0", "answers": answers, "usage": usage}
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({"model": "jev-1.13.0", "answers": answers, "usage": usage})
    );
}

#[test]
fn decision_response_without_answers_is_an_invalid_upstream_response() {
    let error = resolver("@cf/cloudflare/clef")
        .normalize_body(200, json!({"result": {"model": "clef"}}))
        .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}

fn decision_resolver(
    kind: APIResolverKind,
    model: &str,
    request: Value,
    provider_options: Value,
) -> APIResolver {
    APIResolver::new(
        kind,
        ResponseContext {
            model: model.to_string(),
            request,
            provider_options,
            stream: Some(false),
            include_model: true,
            ..ResponseContext::default()
        },
    )
}

fn systemone(model: &str, request: Value) -> APIResolver {
    decision_resolver(
        APIResolverKind::SystemoneDecision,
        model,
        request,
        json!({}),
    )
}

fn openai_decision(request: Value) -> APIResolver {
    decision_resolver(
        APIResolverKind::OpenAIDecision,
        "gpt-6-luna",
        request,
        json!({}),
    )
}

fn one_noul() -> Value {
    json!({"urgent": {"type": "noul", "instructions": "Is it urgent?"}})
}

#[test]
fn systemone_preserves_structured_and_string_states_and_stringifies_primitives() {
    for (state, expected) in [
        (json!({"Ticket-ID": 42}), json!({"Ticket-ID": 42})),
        (json!([{"ticket": 42}]), json!([{"ticket": 42}])),
        (json!("ticket"), json!("ticket")),
        (Value::Null, json!("null")),
        (json!(true), json!("true")),
        (json!(42.5), json!("42.5")),
    ] {
        let body = Value::Object(
            systemone(
                "jev-latest",
                json!({"state": state, "questions": one_noul()}),
            )
            .build_body()
            .unwrap(),
        );
        assert_eq!(body["state"], expected);
        assert_eq!(body["model"], "jev-latest");
        assert_eq!(body["questions"], one_noul());
        assert!(body.get("assets").is_none());
    }
}

#[test]
fn systemone_images_become_assets_with_one_collision_free_reference_each() {
    let state = json!({
        "ticket": "Inspect the attached photo",
        "mention": "ankole-image-1",
        "__ankole_images": "caller data"
    });
    let body = Value::Object(
        systemone(
            "jev-latest",
            json!({
                "state": state,
                "questions": one_noul(),
                "images": [
                    "data:image/png;base64,cG5n",
                    "data:image/jpeg;base64,anBlZw=="
                ]
            }),
        )
        .build_body()
        .unwrap(),
    );

    assert_eq!(body["state"]["mention"], "ankole-image-1");
    assert_eq!(body["state"]["__ankole_images"], "caller data");
    assert_eq!(
        body["state"]["__ankole_images-2"],
        json!(["ankole-image-1-2", "ankole-image-2"])
    );
    assert_eq!(
        body["assets"],
        json!({
            "ankole-image-1-2": {"type": "image", "format": "png", "data_base64": "cG5n"},
            "ankole-image-2": {"type": "image", "format": "jpeg", "data_base64": "anBlZw=="}
        })
    );
}

#[test]
fn systemone_non_object_state_can_still_reference_images() {
    let body = Value::Object(
        systemone(
            "jev-latest",
            json!({
                "state": null,
                "questions": one_noul(),
                "images": ["data:image/png;base64,cG5n"]
            }),
        )
        .build_body()
        .unwrap(),
    );

    assert_eq!(body["state"], json!(["null", ["ankole-image-1"]]));
}

#[test]
fn systemone_rejects_webp_and_normalizes_top_level_usage() {
    let error = systemone(
        "jev-latest",
        json!({
            "state": null,
            "questions": one_noul(),
            "images": ["data:image/webp;base64,d2VicA=="]
        }),
    )
    .build_body()
    .unwrap_err();
    assert_eq!(error.code, "invalid_decision_request");

    let answers = json!({"urgent": {"type": "noul", "noul": 0.8}});
    let usage = json!({"input_tokens": 12, "output_tokens": 2, "cost": 0.0003});
    let body = systemone("typesafe/jev-latest", json!({}))
        .normalize_body(
            200,
            json!({"model": "jev-1.14.0", "answers": answers, "usage": usage}),
        )
        .unwrap();
    assert_eq!(
        body,
        json!({"model": "jev-1.14.0", "answers": answers, "usage": usage})
    );
}

#[test]
fn openai_decision_converts_sorted_questions_and_provider_options() {
    let request = json!({
        "state": {"ticket": {"message": "Charged twice"}},
        "questions": {
            "urgent": {
                "type": "noul",
                "instructions": "Does this need a reply today?",
                "criteria": {"true": "Reply today", "false": "Can wait"}
            },
            "severity": {
                "type": "score",
                "instructions": "How severe is it?",
                "criteria": ["Cosmetic", "Outage"]
            },
            "team": {
                "type": "choice",
                "instructions": "Who owns it?",
                "criteria": {"support": "Product questions", "billing": "Payments"}
            }
        }
    });
    let body = Value::Object(openai_decision(request).build_body().unwrap());

    assert_eq!(body["model"], "gpt-6-luna");
    assert_eq!(
        body["input"],
        json!([{
            "type": "message",
            "role": "user",
            "content": [{
                "type": "input_json",
                "data": {"ticket": {"message": "Charged twice"}}
            }]
        }])
    );
    let questions = body["questions"].as_array().unwrap();
    assert_eq!(questions.len(), 3);
    assert_eq!(questions[0]["name"], "severity");
    assert_eq!(
        questions[0]["levels"],
        json!([{"label": "Cosmetic"}, {"label": "Outage"}])
    );
    assert_eq!(questions[1]["name"], "team");
    assert_eq!(
        questions[1]["choices"],
        json!([
            {"value": "billing", "description": "Payments"},
            {"value": "support", "description": "Product questions"}
        ])
    );
    assert_eq!(questions[2]["type"], "predicate");
    assert_eq!(questions[2]["name"], "urgent");
    let instructions: Value =
        sonic_rs::from_str(questions[2]["instructions"].as_str().unwrap()).unwrap();
    assert_eq!(
        instructions,
        json!({
            "instructions": "Does this need a reply today?",
            "criteria": {"true": "Reply today", "false": "Can wait"}
        })
    );
}

#[test]
fn openai_decision_serializes_array_and_object_instructions_as_text() {
    let request = json!({
        "state": {"ticket": 42},
        "questions": {
            "urgent": {
                "type": "noul",
                "instructions": ["判断是否紧急", "结合 SLA"]
            },
            "team": {
                "type": "choice",
                "instructions": ["Route by product area", "Prefer billing for charges"],
                "criteria": {"billing": "Payments", "support": "Product"}
            },
            "severity": {
                "type": "score",
                "instructions": {"goal": "Rate customer impact", "rubric": ["SLA", "scope"]},
                "criteria": ["Low", "High"]
            }
        }
    });
    let body = Value::Object(openai_decision(request).build_body().unwrap());
    let questions = body["questions"].as_array().unwrap();

    let severity_instructions: Value =
        sonic_rs::from_str(questions[0]["instructions"].as_str().unwrap()).unwrap();
    assert_eq!(
        severity_instructions,
        json!({"goal": "Rate customer impact", "rubric": ["SLA", "scope"]})
    );
    assert_eq!(
        questions[1]["instructions"],
        json!("[\"Route by product area\",\"Prefer billing for charges\"]")
    );
    assert_eq!(
        questions[2]["instructions"],
        json!("[\"判断是否紧急\",\"结合 SLA\"]")
    );
}

#[test]
fn openai_decision_uses_text_for_scalars_and_non_object_arrays() {
    for (state, expected) in [
        (Value::Null, "null".to_string()),
        (json!(true), "true".to_string()),
        (json!(42), "42".to_string()),
        (
            json!([1, {"ticket": 42}]),
            "[1,{\"ticket\":42}]".to_string(),
        ),
    ] {
        let body = Value::Object(
            openai_decision(json!({"state": state, "questions": one_noul()}))
                .build_body()
                .unwrap(),
        );
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(body["input"][0]["content"][0]["text"], expected);
    }

    let body = Value::Object(
        openai_decision(json!({"state": "A plain ticket", "questions": one_noul()}))
            .build_body()
            .unwrap(),
    );
    assert_eq!(body["input"], "A plain ticket");
}

#[test]
fn openai_decision_falls_back_to_text_beyond_input_json_limits() {
    let mut deep = json!("leaf");
    for _ in 0..33 {
        deep = json!({"next": deep});
    }
    let large = json!({"text": "x".repeat(256 * 1024)});
    let many = Value::Array((0..10_000).map(|i| json!({"i": i})).collect());

    for state in [deep, large, many] {
        let body = Value::Object(
            openai_decision(json!({"state": state, "questions": one_noul()}))
                .build_body()
                .unwrap(),
        );
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
    }
}

#[test]
fn openai_decision_appends_images_to_one_user_message() {
    let body = Value::Object(
        openai_decision(json!({
            "state": {"ticket": "Photo attached"},
            "questions": one_noul(),
            "images": ["data:image/webp;base64,d2VicA=="]
        }))
        .build_body()
        .unwrap(),
    );
    assert_eq!(
        body["input"][0]["content"],
        json!([
            {"type": "input_json", "data": {"ticket": "Photo attached"}},
            {"type": "input_image", "image_url": "data:image/webp;base64,d2VicA=="}
        ])
    );
}

#[test]
fn openai_decision_restores_ankole_answer_shapes_and_usage() {
    let usage = json!({
        "input_tokens": 42,
        "input_tokens_details": {"cached_tokens": 4, "cache_write_tokens": 8},
        "output_tokens": 3,
        "output_tokens_details": {"reasoning_tokens": 1},
        "total_tokens": 45
    });
    let body = openai_decision(json!({}))
        .normalize_body(
            200,
            json!({
                "model": "gpt-6-luna",
                "answers": [
                    {"type": "predicate", "name": "urgent", "probability": 0.93},
                    {
                        "type": "choice",
                        "name": "team",
                        "choice": "billing",
                        "probabilities": [
                            {"value": "billing", "probability": 0.9},
                            {"value": "support", "probability": 0.1}
                        ],
                        "confidence": 0.9
                    },
                    {
                        "type": "score",
                        "name": "severity",
                        "score": 1.2,
                        "probabilities": [
                            {"value": 0, "label": "Cosmetic", "probability": 0.1},
                            {"value": 1, "label": "Degraded", "probability": 0.5},
                            {"value": 2, "label": "Outage", "probability": 0.4}
                        ],
                        "confidence": 0.7
                    }
                ],
                "usage": usage
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({
            "model": "gpt-6-luna",
            "answers": {
                "urgent": {"type": "noul", "noul": 0.93},
                "team": {
                    "type": "choice",
                    "choice": "billing",
                    "probabilities": {"billing": 0.9, "support": 0.1},
                    "confidence": 0.9
                },
                "severity": {
                    "type": "score",
                    "score": 1.2,
                    "legend": {"0": "Cosmetic", "1": "Degraded", "2": "Outage"},
                    "probabilities": {"0": 0.1, "1": 0.5, "2": 0.4},
                    "confidence": 0.7
                }
            },
            "usage": usage
        })
    );
}

#[test]
fn openai_decision_refusal_never_returns_partial_answers() {
    let error = openai_decision(json!({}))
        .normalize_body(
            200,
            json!({
                "model": "gpt-6-luna",
                "answers": [
                    {"type": "predicate", "name": "safe", "probability": 0.9},
                    {"type": "refusal", "name": "unsafe"}
                ],
                "usage": {"input_tokens": 10, "output_tokens": 2}
            }),
        )
        .unwrap_err();

    assert_eq!(error.code, "upstream_decision_refusal");
    assert_eq!(error.provider_status, Some(200));
    assert_eq!(error.provider_error_type.as_deref(), Some("refusal"));
}

#[test]
fn openai_decision_wraps_oversized_instructions_in_input_text_part() {
    let huge = "x".repeat(1024 * 1024 + 1);
    let body = Value::Object(
        openai_decision(json!({
            "state": "ticket",
            "questions": {"urgent": {"type": "noul", "instructions": huge}}
        }))
        .build_body()
        .unwrap(),
    );

    assert_eq!(
        body["questions"][0]["instructions"],
        json!([{"type": "input_text", "text": huge}])
    );
}

#[test]
fn openai_decision_preserves_structured_score_criteria_and_validates_answer_shapes() {
    let request = json!({
        "state": {"ticket": 42},
        "questions": {
            "severity": {
                "type": "score",
                "instructions": "Rate severity",
                "criteria": [{"tier": "low"}, {"tier": "high"}]
            },
            "team": {
                "type": "choice",
                "instructions": "Pick team",
                "criteria": {"billing": "Payments", "support": "Product"}
            }
        }
    });

    let body = openai_decision(request.clone())
        .normalize_body(
            200,
            json!({
                "model": "gpt-6-luna",
                "answers": [
                    {
                        "type": "score",
                        "name": "severity",
                        "score": 0.8,
                        "probabilities": [
                            {"value": 0, "label": "{\"tier\":\"low\"}", "probability": 0.2},
                            {"value": 1, "label": "{\"tier\":\"high\"}", "probability": 0.8}
                        ],
                        "confidence": 0.8
                    },
                    {
                        "type": "choice",
                        "name": "team",
                        "choice": "billing",
                        "probabilities": [
                            {"value": "billing", "probability": 0.9},
                            {"value": "support", "probability": 0.1}
                        ],
                        "confidence": 0.9
                    }
                ]
            }),
        )
        .unwrap();

    assert_eq!(
        body["answers"]["severity"]["legend"],
        json!({"0": {"tier": "low"}, "1": {"tier": "high"}})
    );

    for invalid_answers in [
        // Wrong answer type for requested question
        json!([
            {"type": "predicate", "name": "severity", "probability": 0.5},
            {
                "type": "choice",
                "name": "team",
                "choice": "billing",
                "probabilities": [{"value": "billing", "probability": 1.0}],
                "confidence": 1.0
            }
        ]),
        // Choice value not declared in criteria
        json!([
            {
                "type": "score",
                "name": "severity",
                "score": 0.0,
                "probabilities": [{"value": 0, "label": "low", "probability": 1.0}],
                "confidence": 1.0
            },
            {
                "type": "choice",
                "name": "team",
                "choice": "sales",
                "probabilities": [{"value": "sales", "probability": 1.0}],
                "confidence": 1.0
            }
        ]),
        // Negative score level index
        json!([
            {
                "type": "score",
                "name": "severity",
                "score": 0.0,
                "probabilities": [{"value": -1, "label": "bad", "probability": 1.0}],
                "confidence": 1.0
            },
            {
                "type": "choice",
                "name": "team",
                "choice": "billing",
                "probabilities": [{"value": "billing", "probability": 1.0}],
                "confidence": 1.0
            }
        ]),
    ] {
        let error = openai_decision(request.clone())
            .normalize_body(
                200,
                json!({"model": "gpt-6-luna", "answers": invalid_answers}),
            )
            .unwrap_err();
        assert_eq!(error.code, "invalid_upstream_response");
    }
}

#[test]
fn openai_decision_rejects_a_response_with_missing_answers() {
    let error = openai_decision(json!({
        "questions": {
            "first": {"type": "noul", "instructions": "First?"},
            "second": {"type": "noul", "instructions": "Second?"}
        }
    }))
    .normalize_body(
        200,
        json!({
            "model": "gpt-6-luna",
            "answers": [{"type": "predicate", "name": "first", "probability": 0.9}]
        }),
    )
    .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}

#[test]
fn decision_resolver_wire_names_deserialize_exactly() {
    for (wire_name, expected) in [
        ("systemone_decision", APIResolverKind::SystemoneDecision),
        ("openai_decision", APIResolverKind::OpenAIDecision),
    ] {
        let encoded = format!("\"{wire_name}\"");
        let kind = sonic_rs::from_str::<APIResolverKind>(&encoded).unwrap();
        assert_eq!(kind, expected);
        assert_eq!(kind.as_str(), wire_name);
    }
}

#[test]
fn decision_resolvers_pass_provider_options_and_reject_unknown_strict_request_fields() {
    let with_opts = APIResolver::new(
        APIResolverKind::OpenAIDecision,
        ResponseContext {
            model: "gpt-6-luna".to_string(),
            request: json!({"state": "hello", "questions": one_noul()}),
            provider_options: json!({"service_tier": "priority", "store": false}),
            stream: Some(false),
            include_model: true,
            policy: ConversionPolicy::Strict,
        },
    );
    let body = Value::Object(with_opts.build_body().unwrap());
    assert_eq!(body["service_tier"], json!("priority"));
    assert_eq!(body["store"], json!(false));

    let unknown_field = APIResolver::new(
        APIResolverKind::OpenAIDecision,
        ResponseContext {
            model: "gpt-6-luna".to_string(),
            request: json!({"state": "hello", "questions": one_noul(), "unexpected_flag": 1}),
            provider_options: json!({}),
            stream: Some(false),
            include_model: true,
            policy: ConversionPolicy::Strict,
        },
    );
    assert_eq!(
        unknown_field.build_body().unwrap_err().code,
        "unsupported_parameter"
    );
}
