use super::super::*;

#[test]
fn openrouter_images_preserves_all_n_images_and_first_result_fields() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterImages,
        ResponseContext {
            model: "openai/gpt-image-1".to_string(),
            request: json!({"prompt": "two cats", "n": 2, "output_format": "webp"}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "created": 1700000000,
                "data": [
                    {"b64_json": "aW1nMQ==", "revised_prompt": "cat one"},
                    {"b64_json": "aW1nMg==", "revised_prompt": "cat two"}
                ],
                "usage": {"total_tokens": 200, "cost": 0.08}
            }),
        )
        .unwrap();

    let data = body["data"].as_array().unwrap();
    assert_eq!(data.len(), 2);
    assert_eq!(data[0]["b64_json"], "aW1nMQ==");
    assert_eq!(data[1]["b64_json"], "aW1nMg==");
    assert_eq!(body["result"], "aW1nMQ==");
    assert_eq!(body["mime_type"], "image/webp");
    assert_eq!(body["usage"]["total_tokens"], 200);
}

#[test]
fn openrouter_images_maps_inbound_images_and_validates_strict_stream_usage() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterImages,
        ResponseContext {
            model: "openai/gpt-image-1".to_string(),
            request: json!({
                "prompt": "edit cat",
                "images": ["data:image/png;base64,aW1nMQ=="],
                "mask": "data:image/png;base64,bWFzaw=="
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let built = resolver.build_body().unwrap();
    assert_eq!(
        built["input_references"],
        json!(["data:image/png;base64,aW1nMQ=="])
    );
    assert_eq!(
        built["input_image_mask"],
        json!("data:image/png;base64,bWFzaw==")
    );
    assert!(built.get("images").is_none());
    assert!(built.get("mask").is_none());

    let missing_usage = resolver
        .ingest(json!({
            "type": "image_generation.completed",
            "b64_json": "ZmluYWw="
        }))
        .unwrap_err();
    assert_eq!(missing_usage.provider_status, Some(502));
}

#[test]
fn openai_images_maps_references_and_normalizes_streaming_events() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenAIImages,
        ResponseContext {
            model: "gpt-image-1".to_string(),
            request: json!({
                "prompt": "edit cat",
                "n": 2,
                "input_references": [{"image_url": {"url": "data:image/png;base64,aW1nMQ=="}}],
                "input_image_mask": {"image_url": {"url": "data:image/png;base64,bWFzaw=="}}
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let built = resolver.build_body().unwrap();
    assert_eq!(
        built["images"],
        json!([{ "image_url": "data:image/png;base64,aW1nMQ==" }])
    );
    assert_eq!(
        built["mask"],
        json!({ "image_url": "data:image/png;base64,bWFzaw==" })
    );

    let partial = resolver
        .ingest(json!({
            "type": "image_generation.partial_image",
            "partial_image_index": 0,
            "b64_json": "cGFydGlhbA=="
        }))
        .unwrap();
    assert_eq!(partial[0]["type"], "image_generation.partial_image");
    assert_eq!(partial[0]["b64_json"], "cGFydGlhbA==");

    let completed = resolver
        .ingest(json!({
            "type": "image_generation.completed",
            "b64_json": "ZmluYWw=",
            "usage": {"total_tokens": 120}
        }))
        .unwrap();
    assert_eq!(completed[0]["type"], "image_generation.completed");
    assert_eq!(completed[0]["b64_json"], "ZmluYWw=");
}

#[test]
fn google_images_builds_generate_content_and_rejects_transparent_or_mask_in_strict() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "gemini-2.5-flash-image-preview".to_string(),
            request: json!({
                "prompt": "a lighthouse",
                "n": 2,
                "size": "1024x1024",
                "input_references": ["data:image/png;base64,aW1nMQ=="]
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let built = resolver.build_body().unwrap();
    assert_eq!(
        built["generationConfig"]["responseModalities"],
        json!(["IMAGE"])
    );
    assert_eq!(built["generationConfig"]["candidateCount"], 2);
    assert_eq!(
        built["contents"][0]["parts"][0]["inlineData"]["data"],
        "aW1nMQ=="
    );

    let normalized = resolver
        .normalize_body(
            200,
            json!({
                "candidates": [
                    {"content": {"parts": [{"inlineData": {"mimeType": "image/png", "data": "aW1nMQ=="}}]}},
                    {"content": {"parts": [{"inlineData": {"mimeType": "image/png", "data": "aW1nMg=="}}]}}
                ],
                "usageMetadata": {"promptTokenCount": 12, "candidatesTokenCount": 258, "totalTokenCount": 270}
            }),
        )
        .unwrap();
    assert_eq!(normalized["data"].as_array().unwrap().len(), 2);
    assert_eq!(normalized["usage"]["total_tokens"], 270);

    let bad_bg = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "gemini-2.5-flash-image-preview".to_string(),
            request: json!({"prompt": "a cat", "background": "transparent"}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap_err();
    assert_eq!(bad_bg.code, "unsupported_parameter");
    assert_eq!(bad_bg.provider_status, Some(400));
}

#[test]
fn images_resolvers_reject_conflicting_references_remote_google_urls_and_invalid_usage() {
    let conflict = APIResolver::new(
        APIResolverKind::OpenAIImages,
        ResponseContext {
            model: "gpt-image-1".to_string(),
            request: json!({
                "prompt": "edit",
                "input_references": ["data:image/png;base64,aW1nMQ=="],
                "images": ["data:image/png;base64,aW1nMg=="]
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body();
    assert!(conflict.is_err());

    let scalar_images = APIResolver::new(
        APIResolverKind::OpenrouterImages,
        ResponseContext {
            model: "openai/gpt-image-1".to_string(),
            request: json!({"prompt": "edit", "images": "http://127.0.0.1/private.png"}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body();
    assert!(scalar_images.is_err());

    let google_remote = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "gemini-2.5-flash-image-preview".to_string(),
            request: json!({"prompt": "edit", "input_references": ["https://example.com/a.png"]}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body();
    assert!(google_remote.is_err());

    let mut or_resolver = APIResolver::new(
        APIResolverKind::OpenrouterImages,
        ResponseContext {
            model: "openai/gpt-image-1".to_string(),
            request: json!({"prompt": "cat", "n": 1}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    assert!(
        or_resolver
            .normalize_body(
                200,
                json!({"data": [{"b64_json": "aW1nMQ=="}], "usage": {"total_tokens": "bogus"}})
            )
            .is_err()
    );

    let mut g_resolver = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "gemini-2.5-flash-image-preview".to_string(),
            request: json!({"prompt": "cat", "n": 1}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    assert!(g_resolver
        .normalize_body(
            200,
            json!({
                "candidates": [{"content": {"parts": [{"inlineData": {"mimeType": "image/png", "data": "aW1nMQ=="}}]}}],
                "usageMetadata": {"promptTokenCount": u64::MAX, "candidatesTokenCount": 1}
            }),
        )
        .is_err());
}

#[test]
fn imagen_response_without_usage_uses_the_image_count_receipt() {
    let mut resolver = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "imagen-4.0-generate-001".to_string(),
            request: json!({"prompt": "a cat", "n": 1}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let normalized = resolver
        .normalize_body(
            200,
            json!({
                "predictions": [{"bytesBase64Encoded": "aW1n", "mimeType": "image/png"}]
            }),
        )
        .unwrap();

    assert_eq!(normalized["usage"], json!({"images": 1}));
}

#[test]
fn google_and_openrouter_images_handle_parameterized_data_urls_and_corrupt_base64() {
    let google_built = APIResolver::new(
        APIResolverKind::GoogleImages,
        ResponseContext {
            model: "gemini-2.5-flash-image-preview".to_string(),
            request: json!({
                "prompt": "edit cat",
                "images": ["data:image/webp;charset=utf-8;BASE64,aW1nMQ=="]
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    )
    .build_body()
    .unwrap();
    assert_eq!(
        google_built["contents"][0]["parts"][0]["inlineData"],
        json!({"mimeType": "image/webp", "data": "aW1nMQ=="})
    );

    let mut bad_resolver = APIResolver::new(
        APIResolverKind::OpenrouterImages,
        ResponseContext {
            model: "openai/gpt-image-1".to_string(),
            request: json!({"prompt": "cat", "n": 1}),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );
    let err = bad_resolver
        .normalize_body(
            200,
            json!({
                "data": [{"b64_json": "not-valid-base64!!!"}],
                "usage": {"total_tokens": 10}
            }),
        )
        .unwrap_err();
    assert_eq!(err.provider_status, Some(502));
}
