use super::super::*;

fn v2026_context(
    model: &str,
    request: Value,
    provider_options: Value,
    policy: ConversionPolicy,
) -> ResponseContext {
    ResponseContext {
        model: model.to_string(),
        request,
        provider_options,
        stream: Some(false),
        include_model: true,
        policy,
    }
}

#[test]
fn claude_45_plus_and_v2026_models_are_classified_correctly() {
    for model in [
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-5-20251101",
        "claude-haiku-4-5-20251001",
        "claude-4.5-sonnet",
        "claude-opus-4-8-20260601",
        "claude-sonnet-5-20261001",
        "claude-fable-5-preview",
        "claude-mythos-5-20261021",
        "anthropic/claude-sonnet-5",
    ] {
        assert!(is_claude_45_plus_model(model), "expected {model} to match");
    }

    for legacy in [
        "claude-3-5-sonnet-20241022",
        "claude-3-7-sonnet-20250219",
        "claude-opus-4-1-20250805",
        "claude-test",
    ] {
        assert!(
            !is_claude_45_plus_model(legacy),
            "expected {legacy} not to match"
        );
    }
}

#[test]
fn anthropic_v2026_rejects_deprecated_sampling_params_in_strict_and_strips_in_tolerant() {
    for (param, value) in [
        ("temperature", json!(0.7)),
        ("top_p", json!(0.9)),
        ("top_k", json!(40)),
    ] {
        for (model, opts) in [
            ("claude-sonnet-4-5-20250929", json!({})),
            ("claude-opus-4-8", json!({})),
            ("claude-sonnet-5", json!({})),
            ("claude-fable-5", json!({})),
            ("claude-mythos-5", json!({})),
            ("claude-3-5-sonnet", json!({"api_version": "2026-10-21"})),
        ] {
            let mut req_obj = Map::new();
            req_obj.insert("input".to_string(), json!("hello"));
            req_obj.insert(param.to_string(), value.clone());
            let request = Value::Object(req_obj);

            let strict_resolver = APIResolver::new(
                APIResolverKind::AnthropicMessages,
                v2026_context(
                    model,
                    request.clone(),
                    opts.clone(),
                    ConversionPolicy::Strict,
                ),
            );
            let err = strict_resolver.build_body().unwrap_err();
            assert_eq!(err.code, "unexpressible_field", "{model} {param}");
            assert_eq!(err.provider_status, Some(400), "{model} {param}");

            let tolerant_resolver = APIResolver::new(
                APIResolverKind::AnthropicMessages,
                v2026_context(model, request, opts, ConversionPolicy::Tolerant),
            );
            let body = tolerant_resolver.build_body().unwrap();
            assert!(
                !body.contains_key(param),
                "{model} {param} should be stripped"
            );
            assert!(!body.contains_key("api_version"));
        }
    }
}

#[test]
fn anthropic_v2026_rejects_assistant_document_and_user_citations_in_strict_and_strips_in_tolerant()
{
    let assistant_doc_req = json!({
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": "summarize"}]
            },
            {
                "type": "message",
                "role": "assistant",
                "content": [
                    {
                        "type": "document",
                        "source": {"type": "text", "media_type": "text/plain", "data": "doc body"}
                    },
                    {"type": "output_text", "text": "Here is the summary."}
                ]
            }
        ]
    });

    let strict_doc = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        v2026_context(
            "claude-sonnet-5",
            assistant_doc_req.clone(),
            json!({}),
            ConversionPolicy::Strict,
        ),
    );
    let doc_err = strict_doc.build_body().unwrap_err();
    assert_eq!(doc_err.code, "unexpressible_field");
    assert_eq!(doc_err.provider_status, Some(400));

    let tolerant_doc = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        v2026_context(
            "claude-sonnet-5",
            assistant_doc_req,
            json!({}),
            ConversionPolicy::Tolerant,
        ),
    );
    let doc_body = Value::Object(tolerant_doc.build_body().unwrap());
    assert_eq!(
        doc_body["messages"][1]["content"],
        json!([{"type": "text", "text": "Here is the summary."}])
    );

    let user_citations_req = json!({
        "input": [
            {
                "type": "message",
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": "cited text",
                        "citations": [{"type": "char_location", "cited_text": "foo"}]
                    }
                ]
            }
        ]
    });

    let strict_cit = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        v2026_context(
            "claude-4.5-sonnet",
            user_citations_req.clone(),
            json!({}),
            ConversionPolicy::Strict,
        ),
    );
    let cit_err = strict_cit.build_body().unwrap_err();
    assert_eq!(cit_err.code, "unexpressible_field");
    assert_eq!(cit_err.provider_status, Some(400));

    let tolerant_cit = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        v2026_context(
            "claude-4.5-sonnet",
            user_citations_req,
            json!({}),
            ConversionPolicy::Tolerant,
        ),
    );
    let cit_body = Value::Object(tolerant_cit.build_body().unwrap());
    assert_eq!(
        cit_body["messages"][0]["content"],
        json!([{"type": "text", "text": "cited text"}])
    );
}

#[test]
fn anthropic_legacy_2023_06_01_preserves_sampling_params() {
    let req = json!({
        "input": "hello",
        "temperature": 0.5,
        "top_p": 0.8,
        "top_k": 20
    });
    let resolver = APIResolver::new(
        APIResolverKind::AnthropicMessages,
        v2026_context(
            "claude-3-5-sonnet-20241022",
            req,
            json!({}),
            ConversionPolicy::Strict,
        ),
    );
    let body = resolver.build_body().unwrap();
    assert_eq!(body.get("temperature"), Some(&json!(0.5)));
    assert_eq!(body.get("top_p"), Some(&json!(0.8)));
    assert_eq!(body.get("top_k"), Some(&json!(20)));
}

#[test]
fn anthropic_v2026_drops_assistant_messages_left_without_content() {
    let context = v2026_context(
        "claude-sonnet-5",
        json!({
            "input": [
                {
                    "role": "assistant",
                    "content": [{"type": "document", "source": {"type": "text", "data": "doc"}}]
                },
                {"role": "user", "content": "hello"}
            ]
        }),
        json!({}),
        ConversionPolicy::Tolerant,
    );

    let resolver = APIResolver::new(APIResolverKind::AnthropicMessages, context);
    let body = resolver.build_body().unwrap();
    let messages = body["messages"].as_array().unwrap();

    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0]["role"], "user");
}
