use super::super::*;

#[test]
fn parallel_web_search_builds_search_body() {
    let resolver = APIResolver::new(
        APIResolverKind::ParallelWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "ankole web search", "limit": 3}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["objective"], "ankole web search");
    assert_eq!(body["search_queries"], json!(["ankole web search"]));
    assert_eq!(body["advanced_settings"]["max_results"], 3);
    assert!(body.get("model").is_none());
}

#[test]
fn bright_data_serp_web_search_builds_direct_request_body() {
    let resolver = APIResolver::new(
        APIResolverKind::BrightDataSerpWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "agent operating system", "limit": 7}),
            provider_options: json!({
                "zone": "serp_api1",
                "country": "us",
                "language": "en"
            }),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["zone"], "serp_api1");
    assert_eq!(body["format"], "json");
    assert_eq!(
        body["url"],
        "https://www.google.com/search?q=agent+operating+system&num=7&gl=us&hl=en"
    );
}

#[test]
fn jina_search_builds_search_body() {
    let resolver = APIResolver::new(
        APIResolverKind::JinaSearchWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "ankole web search", "limit": 4}),
            provider_options: json!({"gl": "us", "hl": "en"}),
            stream: None,
            include_model: false,
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(body["q"], "ankole web search");
    assert_eq!(body["num"], 4);
    assert_eq!(body["gl"], "us");
    assert_eq!(body["hl"], "en");
    assert!(body.get("model").is_none());
}

#[test]
fn web_search_normalizes_parallel_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::ParallelWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "Ankole"}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "results": [{
                    "title": "Ankole docs",
                    "url": "https://example.com/ankole",
                    "publish_date": "2026-07-04",
                    "excerpts": ["AIGateway", "Web Search"]
                }]
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["query"], "Ankole");
    assert_eq!(body["results"][0]["title"], "Ankole docs");
    assert_eq!(body["results"][0]["snippet"], "AIGateway\nWeb Search");
    assert_eq!(body["results"][0]["published_at"], "2026-07-04");
}

#[test]
fn web_search_normalizes_jina_results() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaSearchWebSearch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"query": "Ankole"}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "results": [{
                    "title": "Ankole docs",
                    "url": "https://example.com/ankole",
                    "snippet": "RuntimeFabric and AIGateway",
                    "date": "2026-07-04"
                }]
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["query"], "Ankole");
    assert_eq!(body["results"][0]["title"], "Ankole docs");
    assert_eq!(body["results"][0]["snippet"], "RuntimeFabric and AIGateway");
    assert_eq!(body["results"][0]["published_at"], "2026-07-04");
}

#[test]
fn jina_reader_web_fetch_normalizes_data_content() {
    let mut resolver = APIResolver::new(
        APIResolverKind::JinaReaderWebFetch,
        ResponseContext {
            model: "default".to_string(),
            request: json!({"urls": ["https://example.com/page"]}),
            provider_options: json!({}),
            stream: None,
            include_model: false,
        },
    );

    let request_body = Value::Object(resolver.build_body().unwrap());
    assert_eq!(request_body["url"], "https://example.com/page");

    let body = resolver
        .normalize_body(
            200,
            json!({
                "data": {
                    "title": "Example",
                    "url": "https://example.com/page",
                    "content": "# Example\nBody"
                }
            }),
        )
        .unwrap();

    assert_eq!(body["success"], true);
    assert_eq!(body["results"][0]["url"], "https://example.com/page");
    assert_eq!(body["results"][0]["title"], "Example");
    assert_eq!(body["results"][0]["text"], "# Example\nBody");
}
