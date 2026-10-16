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
