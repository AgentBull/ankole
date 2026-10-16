use super::super::*;

#[test]
fn openrouter_rerank_preserves_provider_and_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterRerank,
        ResponseContext {
            model: "cohere/rerank-v3.5".to_string(),
            request: json!({"documents": ["Paris", "Berlin"]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "id": "gen-rerank-123",
                "model": "cohere/rerank-v3.5",
                "provider": "Cohere",
                "results": [{
                    "document": {"text": "Paris"},
                    "index": 0,
                    "relevance_score": 0.98
                }],
                "usage": {"total_tokens": 12}
            }),
        )
        .unwrap();

    assert_eq!(body["id"], "gen-rerank-123");
    assert_eq!(body["provider"], "Cohere");
    assert_eq!(body["results"][0]["document"], json!({"text": "Paris"}));
    assert_eq!(body["results"][0]["relevance_score"], 0.98);
}

#[test]
fn jina_rerank_reconstructs_document_when_omitted() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaRerank,
        ResponseContext {
            model: "jina-reranker-v3".to_string(),
            request: json!({"documents": ["Paris", {"text": "Berlin"}]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-reranker-v3",
                "results": [{"index": 1, "relevance_score": 0.31}],
                "usage": {"total_tokens": 12}
            }),
        )
        .unwrap();

    assert_eq!(body["results"][0]["document"], json!({"text": "Berlin"}));
    assert_eq!(body["results"][0]["index"], 1);
    assert_eq!(body["usage"]["total_tokens"], 12);
}

#[test]
fn jina_rerank_normalizes_string_document_and_preserves_embedding() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaRerank,
        ResponseContext {
            model: "jina-reranker-v3".to_string(),
            request: json!({"documents": ["Paris"]}),
            provider_options: json!({}),
            stream: None,
            include_model: true,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "model": "jina-reranker-v3",
                "object": "list",
                "results": [{
                    "index": 0,
                    "relevance_score": 0.99,
                    "document": "Paris is the capital of France.",
                    "embedding": [1]
                }],
                "usage": {"total_tokens": 1}
            }),
        )
        .unwrap();

    assert_eq!(body["object"], "list");
    assert_eq!(
        body["results"][0]["document"],
        json!({"text": "Paris is the capital of France."})
    );
    assert_eq!(body["results"][0]["embedding"], json!([1]));
    assert_eq!(body["usage"]["total_tokens"], 1);
}
