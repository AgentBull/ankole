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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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

#[test]
fn cohere_rerank_serializes_structured_documents_and_lifts_meta_usage() {
    let mut resolver = APIResolver::new(
        APIResolverKind::CohereRerank,
        ResponseContext {
            model: "rerank-v3.5".to_string(),
            request: json!({
                "query": "capital of France",
                "documents": [
                    "Berlin is in Germany",
                    {"text": "Paris is in France"},
                    {"text": "Eiffel Tower", "image": "data:image/png;base64,iVBORw0KGgo="}
                ],
                "top_n": 2,
                "return_documents": true
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let built = resolver.build_body().unwrap();
    let docs = built["documents"].as_array().unwrap();
    assert_eq!(docs.len(), 3);
    assert_eq!(docs[0], json!("Berlin is in Germany"));
    assert_eq!(docs[1], json!("Paris is in France"));
    assert!(docs[2].as_str().unwrap().contains("Eiffel Tower"));

    let normalized = resolver
        .normalize_body(
            200,
            json!({
                "id": "cohere-rerank-1",
                "results": [
                    {"index": 1, "relevance_score": 0.97},
                    {"index": 2, "relevance_score": 0.84}
                ],
                "meta": {
                    "billed_units": {"search_units": 1},
                    "tokens": {"input_tokens": 28, "output_tokens": 0}
                }
            }),
        )
        .unwrap();

    assert_eq!(normalized["usage"]["search_units"], 1);
    assert_eq!(normalized["usage"]["prompt_tokens"], 28);
    assert_eq!(normalized["usage"]["total_tokens"], 28);
    assert_eq!(
        normalized["results"][0]["document"],
        json!({"text": "Paris is in France"})
    );
}

#[test]
fn rerank_omits_documents_when_disabled_and_sorts_by_score_descending() {
    let mut resolver = APIResolver::new(
        APIResolverKind::OpenrouterRerank,
        ResponseContext {
            model: "cohere/rerank-v3.5".to_string(),
            request: json!({
                "query": "capital",
                "documents": ["Berlin", "Paris"],
                "return_documents": false
            }),
            policy: ConversionPolicy::Strict,
            ..ResponseContext::default()
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "results": [
                    {"index": 0, "relevance_score": 0.42, "document": {"text": "Berlin"}},
                    {"index": 1, "relevance_score": 0.95, "document": {"text": "Paris"}}
                ],
                "usage": {"total_tokens": 10}
            }),
        )
        .unwrap();

    let results = body["results"].as_array().unwrap();
    assert_eq!(results[0]["index"], 1);
    assert_eq!(results[0]["relevance_score"], 0.95);
    assert!(results[0].get("document").is_none());
    assert_eq!(results[1]["index"], 0);
    assert!(results[1].get("document").is_none());

    let no_usage = resolver
        .normalize_body(
            200,
            json!({
                "results": [{"index": 0, "relevance_score": 0.9}],
                "usage": {}
            }),
        )
        .unwrap_err();
    assert_eq!(no_usage.provider_status, Some(502));

    let unrelated_usage = resolver
        .normalize_body(
            200,
            json!({
                "results": [{"index": 0, "relevance_score": 0.9}],
                "usage": {"unrelated": true}
            }),
        )
        .unwrap_err();
    assert_eq!(unrelated_usage.provider_status, Some(502));
}
