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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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
            ..ResponseContext::default()
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

    assert_eq!(
        body,
        json!({"items": [{
            "title": "Ankole docs",
            "url": "https://example.com/ankole",
            "description": "AIGateway\nWeb Search",
            "published_at": "2026-07-04"
        }]})
    );
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
            ..ResponseContext::default()
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

    assert_eq!(body["items"][0]["title"], "Ankole docs");
    assert_eq!(
        body["items"][0]["description"],
        "RuntimeFabric and AIGateway"
    );
    assert_eq!(body["items"][0]["published_at"], "2026-07-04");
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
            ..ResponseContext::default()
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

#[test]
fn cloudflare_web_search_builds_gateway_body_and_caps_the_limit() {
    let resolver = APIResolver::new(
        APIResolverKind::CloudflareWebSearch,
        ResponseContext {
            model: "default".to_string(),
            // The provider row names the gateway; the caller's field is ignored.
            request: json!({"query": "ankole web search", "limit": 25, "gateway_id": "other"}),
            provider_options: json!({"provider": "exa", "gateway_id": "default"}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    );

    let body = Value::Object(resolver.build_body().unwrap());

    assert_eq!(
        body,
        json!({
            "query": "ankole web search",
            "limit": 10,
            "provider": "exa",
            "options": {"gateway": {"id": "default"}}
        })
    );
}

#[test]
fn cloudflare_web_search_reads_bare_and_enveloped_results() {
    let item = json!({
        "url": "https://example.com/ankole",
        "title": "Ankole docs",
        "description": "RuntimeFabric and AIGateway"
    });
    let bodies = [
        json!({"items": [item], "metadata": {"query": "Ankole", "requestId": "r1", "latencyMs": 612}}),
        json!({"success": true, "errors": [], "result": {"items": [item]}}),
    ];

    for upstream in bodies {
        let mut resolver = APIResolver::new(
            APIResolverKind::CloudflareWebSearch,
            ResponseContext {
                model: "default".to_string(),
                request: json!({"query": "Ankole"}),
                provider_options: json!({}),
                stream: None,
                include_model: false,
                ..ResponseContext::default()
            },
        );

        assert_eq!(
            resolver.normalize_body(200, upstream).unwrap(),
            json!({"items": [item]})
        );
    }
}
