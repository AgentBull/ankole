use super::super::*;

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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
fn openrouter_embeddings_normalizes_openrouter_body() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterEmbeddings,
        ResponseContext {
            model: "openai/text-embedding-3-small".to_string(),
            request: json!({}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
fn google_embeddings_builds_single_and_batch_requests() {
    let single = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "text-embedding-004".to_string(),
            request: json!({
                "input": "embed me",
                "dimensions": 256,
                "task": "RETRIEVAL_DOCUMENT"
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap();

    assert_eq!(single["model"], "models/text-embedding-004");
    assert_eq!(single["content"]["parts"][0]["text"], "embed me");
    assert_eq!(
        single["embedContentConfig"]["outputDimensionality"],
        json!(256)
    );
    assert_eq!(
        single["embedContentConfig"]["taskType"],
        json!("RETRIEVAL_DOCUMENT")
    );

    let batch = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "models/text-embedding-004".to_string(),
            request: json!({
                "input": ["first", "second"],
                "encoding_format": "float"
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap();

    assert_eq!(batch["requests"].as_array().unwrap().len(), 2);
    assert_eq!(batch["requests"][0]["model"], "models/text-embedding-004");
}

#[test]
fn google_embeddings_rejects_base64_and_invalid_batch_or_missing_usage_in_strict() {
    let rejected = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "text-embedding-004".to_string(),
            request: json!({
                "input": "hello",
                "encoding_format": "base64"
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap_err();
    assert_eq!(rejected.code, "unsupported_parameter");
    assert_eq!(rejected.provider_status, Some(400));

    let bad_batch = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "text-embedding-004".to_string(),
            request: json!({ "input": [""] }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap_err();
    assert_eq!(bad_batch.code, "invalid_embeddings_input");

    let mut resolver = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "text-embedding-004".to_string(),
            request: json!({ "input": "hello" }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    let missing_usage = resolver
        .normalize_body(200, json!({"embedding": {"values": [0.1, 0.2]}}))
        .unwrap_err();
    assert_eq!(missing_usage.provider_status, Some(502));
}

#[test]
fn openai_embeddings_validates_strict_contract_and_normalizes_vectors() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIEmbeddings,
        ResponseContext {
            model: "text-embedding-3-large".to_string(),
            request: json!({
                "input": ["alpha", "beta"],
                "dimensions": 512,
                "encoding_format": "float"
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let built = resolver.build_body().unwrap();
    assert_eq!(built["model"], "text-embedding-3-large");
    assert_eq!(built["dimensions"], 512);
    assert_eq!(built["encoding_format"], "float");

    let normalized = resolver
        .normalize_body(
            200,
            json!({
                "object": "list",
                "data": [
                    {"index": 0, "embedding": [0.1, 0.2]},
                    {"index": 1, "embedding": [0.3, 0.4]}
                ],
                "usage": {"prompt_tokens": 4, "total_tokens": 4}
            }),
        )
        .unwrap();

    assert_eq!(normalized["data"].as_array().unwrap().len(), 2);
    assert_eq!(normalized["usage"]["total_tokens"], 4);

    let bad_format = APIResolver::new(
        APIResolverKind::OpenAIEmbeddings,
        ResponseContext {
            model: "text-embedding-3-large".to_string(),
            request: json!({
                "input": "alpha",
                "encoding_format": "int8"
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap_err();
    assert_eq!(bad_format.code, "unsupported_parameter");
    assert_eq!(bad_format.provider_status, Some(400));
}

#[test]
fn embeddings_resolvers_l2_normalize_google_subdimensions_and_encode_openai_base64() {
    let mut g_resolver = APIResolver::new(
        APIResolverKind::GoogleEmbeddings,
        ResponseContext {
            model: "text-embedding-004".to_string(),
            request: json!({"input": "hello", "dimensions": 1}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    let g_norm = g_resolver
        .normalize_body(
            200,
            json!({
                "embedding": {"values": [3.0]},
                "usageMetadata": {"promptTokenCount": 1}
            }),
        )
        .unwrap();
    assert_eq!(g_norm["data"][0]["embedding"], json!([1.0]));

    assert!(
        g_resolver
            .normalize_body(
                200,
                json!({"embedding": {"values": [0.0]}, "usageMetadata": {"promptTokenCount": 1}}),
            )
            .is_err()
    );
    assert!(
        g_resolver
            .normalize_body(
                200,
                json!({"embedding": {"values": [3.0]}, "usageMetadata": {}}),
            )
            .is_err()
    );

    let mut oai_b64 = APIResolver::new(
        APIResolverKind::OpenAIEmbeddings,
        ResponseContext {
            model: "text-embedding-3-small".to_string(),
            request: json!({"input": "hello", "encoding_format": "base64"}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    let b64_resp = oai_b64
        .normalize_body(
            200,
            json!({
                "object": "list",
                "data": [{"index": 0, "embedding": [1.0]}],
                "usage": {"prompt_tokens": 1, "total_tokens": 1}
            }),
        )
        .unwrap();
    assert_eq!(b64_resp["data"][0]["embedding"], json!("AACAPw=="));
}

#[test]
fn embeddings_ignore_the_context_stream_flag() {
    for resolver_kind in [
        APIResolverKind::OpenAIEmbeddings,
        APIResolverKind::OpenrouterEmbeddings,
        APIResolverKind::GoogleEmbeddings,
    ] {
        let resolver = APIResolver::new(
            resolver_kind,
            ResponseContext {
                model: "text-embedding-3-small".to_string(),
                request: json!({"input": "hello"}),
                stream: Some(false),
                policy: ConversionPolicy::Strict,
                ..ResponseContext::default()
            },
        );

        let body = resolver.build_body().unwrap();
        assert!(body.get("stream").is_none());
    }
}
