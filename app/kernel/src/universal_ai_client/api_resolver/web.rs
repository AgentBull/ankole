#[derive(Debug)]
struct ParallelWebSearch;

#[derive(Debug)]
struct ParallelWebFetch;

#[derive(Debug)]
struct BrightDataSerpWebSearch;

#[derive(Debug)]
struct AgentBullWebSearch;

#[derive(Debug)]
struct JinaReaderWebFetch;

impl ApiProtocol for ParallelWebSearch {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(parallel_search_body(context))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_parallel_search_body(context, status, body)
    }
}

impl ApiProtocol for ParallelWebFetch {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(parallel_extract_body(context))
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_parallel_extract_body(status, body)
    }
}

impl ApiProtocol for BrightDataSerpWebSearch {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(bright_data_serp_body(context))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_bright_data_search_body(context, status, body)
    }
}

impl ApiProtocol for AgentBullWebSearch {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(agentbull_search_body(context))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_agentbull_search_body(context, status, body)
    }
}

impl ApiProtocol for JinaReaderWebFetch {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(jina_reader_extract_body(context))
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        normalize_jina_reader_extract_body(context, status, body)
    }
}

fn parallel_search_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let query = request_string(&request, "query");
    let limit = request_limit(&request);
    let mut body = Map::new();

    body.insert(
        "objective".to_string(),
        json!(request_optional_string(&request, "objective").unwrap_or_else(|| query.clone())),
    );
    body.insert(
        "search_queries".to_string(),
        request_string_list(&request, "search_queries").unwrap_or_else(|| json!([query])),
    );
    maybe_put_from(&mut body, &request, "mode");
    maybe_put_from(&mut body, &request, "max_chars_total");
    maybe_put_from(&mut body, &request, "session_id");
    maybe_put_from(&mut body, &request, "client_model");

    let mut advanced_settings = request
        .get("advanced_settings")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    put_default(&mut advanced_settings, "max_results", json!(limit));
    body.insert(
        "advanced_settings".to_string(),
        Value::Object(advanced_settings),
    );
    body
}

fn parallel_extract_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let mut body = Map::new();

    body.insert(
        "urls".to_string(),
        request_string_list(&request, "urls").unwrap_or_else(|| json!([])),
    );
    maybe_put_from(&mut body, &request, "objective");
    maybe_put_from(&mut body, &request, "search_queries");
    maybe_put_from(&mut body, &request, "max_chars_total");
    maybe_put_from(&mut body, &request, "session_id");
    maybe_put_from(&mut body, &request, "client_model");
    maybe_put_from(&mut body, &request, "advanced_settings");
    body
}

fn bright_data_serp_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let query = request_string(&request, "query");
    let limit = request_limit(&request);
    let zone = request_string(&request, "zone");
    let country = request_optional_string(&request, "country");
    let language = request_optional_string(&request, "language");
    let google_domain = request_optional_string(&request, "google_domain")
        .unwrap_or_else(|| "www.google.com".to_string());
    let mut search_params = vec![
        ("q".to_string(), query),
        ("num".to_string(), limit.to_string()),
    ];

    if let Some(country) = country.filter(|value| !value.is_empty()) {
        search_params.push(("gl".to_string(), country));
    }
    if let Some(language) = language.filter(|value| !value.is_empty()) {
        search_params.push(("hl".to_string(), language));
    }

    let mut body = Map::new();
    body.insert("zone".to_string(), json!(zone));
    body.insert(
        "url".to_string(),
        json!(format!(
            "https://{}/search?{}",
            google_domain,
            encode_query(search_params)
        )),
    );
    body.insert("format".to_string(), json!("json"));
    body
}

fn agentbull_search_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let mut body = Map::new();

    body.insert("q".to_string(), json!(request_string(&request, "query")));
    body.insert("top".to_string(), json!(request_limit(&request)));
    maybe_put_from(&mut body, &request, "sources");
    maybe_put_from(&mut body, &request, "timeRange");
    maybe_put_from(&mut body, &request, "skip_cache");
    body
}

fn jina_reader_extract_body(context: &ResponseContext) -> Map<String, Value> {
    let request = context.resolved_provider_request_object();
    let url = request
        .get("urls")
        .and_then(Value::as_array)
        .and_then(|urls| urls.first())
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let mut body = Map::new();

    body.insert("url".to_string(), json!(url));
    for key in [
        "respondWith",
        "retainLinks",
        "noCache",
        "timeout",
        "targetSelector",
        "waitForSelector",
        "removeSelector",
        "engine",
        "maxTokens",
    ] {
        maybe_put_from(&mut body, &request, key);
    }
    body
}

fn normalize_parallel_search_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = checked_provider_object(status, body, "Parallel search")?;
    let results = object
        .get("results")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .enumerate()
                .map(|(index, item)| normalize_parallel_search_result(index, item))
                .collect()
        })
        .unwrap_or_default();

    Ok(search_response(context, results))
}

fn normalize_bright_data_search_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = checked_provider_object(status, body, "Bright Data SERP")?;
    let source = object
        .get("organic_results")
        .or_else(|| object.get("organic"))
        .or_else(|| object.get("results"));
    let results = source
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .enumerate()
                .map(|(index, item)| normalize_bright_data_result(index, item))
                .collect()
        })
        .unwrap_or_default();

    Ok(search_response(context, results))
}

fn normalize_agentbull_search_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = checked_provider_object(status, body, "AgentBull search")?;
    let results = object
        .get("items")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .enumerate()
                .map(|(index, item)| normalize_agentbull_result(index, item))
                .collect()
        })
        .unwrap_or_default();

    Ok(search_response(context, results))
}

fn normalize_parallel_extract_body(status: u16, body: Value) -> Result<Value, StreamError> {
    let object = checked_provider_object(status, body, "Parallel extract")?;
    let mut results = extract_results(object.get("results").unwrap_or(&Value::Null));
    results.extend(extract_errors(object.get("errors").unwrap_or(&Value::Null)));
    Ok(extract_response(results))
}

fn normalize_jina_reader_extract_body(
    context: &ResponseContext,
    status: u16,
    body: Value,
) -> Result<Value, StreamError> {
    let object = checked_provider_object(status, body, "Jina Reader")?;
    let data = object
        .get("data")
        .and_then(Value::as_object)
        .unwrap_or(&object);
    let request = context.resolved_provider_request_object();
    let url = data
        .get("url")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| {
            request
                .get("urls")
                .and_then(Value::as_array)
                .and_then(|urls| urls.first())
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_default();
    let title = data
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let text = data
        .get("content")
        .or_else(|| data.get("text"))
        .or_else(|| data.get("markdown"))
        .map(value_to_text)
        .unwrap_or_default();
    let mut result = Map::new();

    result.insert("url".to_string(), json!(url));
    result.insert("title".to_string(), json!(title));
    result.insert("text".to_string(), json!(text));
    result.insert("truncated".to_string(), json!(false));
    Ok(extract_response(vec![Value::Object(result)]))
}

fn checked_provider_object(
    status: u16,
    body: Value,
    label: &'static str,
) -> Result<Map<String, Value>, StreamError> {
    if !(200..300).contains(&status) {
        return Err(provider_body_error(status, body));
    }
    reject_provider_body_error(status, &body)?;
    Ok(provider_object_body(status, body, label)?
        .as_object()
        .cloned()
        .unwrap_or_default())
}

fn search_response(context: &ResponseContext, results: Vec<Value>) -> Value {
    let request = context.resolved_provider_request_object();
    json!({
        "success": true,
        "query": request_string(&request, "query"),
        "results": results
    })
}

fn extract_response(results: Vec<Value>) -> Value {
    json!({
        "success": results.iter().all(|result| result.get("error").map_or(true, Value::is_null)),
        "results": results
    })
}

fn normalize_parallel_search_result(index: usize, item: &Value) -> Value {
    let Some(map) = item.as_object() else {
        return search_result(index, "", "", value_to_text(item), None);
    };
    let snippet = excerpts_text(map.get("excerpts").unwrap_or(&Value::Null))
        .or_else(|| map.get("snippet").map(value_to_text))
        .unwrap_or_default();

    search_result(
        index,
        map.get("title").and_then(Value::as_str).unwrap_or_default(),
        map.get("url").and_then(Value::as_str).unwrap_or_default(),
        snippet,
        map.get("publish_date")
            .or_else(|| map.get("published_at"))
            .and_then(Value::as_str),
    )
}

fn normalize_bright_data_result(index: usize, item: &Value) -> Value {
    let Some(map) = item.as_object() else {
        return search_result(index, "", "", value_to_text(item), None);
    };
    let position = integer_value(map.get("position").unwrap_or(&Value::Null))
        .or_else(|| integer_value(map.get("rank").unwrap_or(&Value::Null)))
        .unwrap_or((index + 1) as i64);
    let mut result = search_result(
        index,
        map.get("title").and_then(Value::as_str).unwrap_or_default(),
        map.get("link")
            .or_else(|| map.get("url"))
            .and_then(Value::as_str)
            .unwrap_or_default(),
        map.get("snippet")
            .or_else(|| map.get("description"))
            .map(value_to_text)
            .unwrap_or_default(),
        map.get("date").and_then(Value::as_str),
    );
    if let Value::Object(result) = &mut result {
        result.insert("position".to_string(), json!(position));
    }
    result
}

fn normalize_agentbull_result(index: usize, item: &Value) -> Value {
    let Some(map) = item.as_object() else {
        return search_result(index, "", "", value_to_text(item), None);
    };
    let mut result = search_result(
        index,
        map.get("title").and_then(Value::as_str).unwrap_or_default(),
        map.get("url").and_then(Value::as_str).unwrap_or_default(),
        map.get("snippet").map(value_to_text).unwrap_or_default(),
        map.get("publishedAt").and_then(Value::as_str),
    );
    if let (Value::Object(result), Some(score)) = (&mut result, map.get("rerankScore")) {
        result.insert("score".to_string(), score.clone());
    }
    result
}

fn search_result(
    index: usize,
    title: &str,
    url: &str,
    snippet: impl Into<String>,
    published_at: Option<&str>,
) -> Value {
    let mut result = Map::new();
    result.insert("title".to_string(), json!(title));
    result.insert("url".to_string(), json!(url));
    result.insert("snippet".to_string(), json!(snippet.into()));
    result.insert("position".to_string(), json!(index + 1));
    if let Some(published_at) = published_at.filter(|value| !value.is_empty()) {
        result.insert("published_at".to_string(), json!(published_at));
    }
    Value::Object(result)
}

fn extract_results(value: &Value) -> Vec<Value> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .map(|item| {
            let Some(map) = item.as_object() else {
                return json!({
                    "url": "",
                    "title": "",
                    "text": value_to_text(item),
                    "truncated": false
                });
            };

            json!({
                "url": map.get("url").and_then(Value::as_str).unwrap_or_default(),
                "title": map.get("title").and_then(Value::as_str).unwrap_or_default(),
                "text": map.get("full_content")
                    .or_else(|| map.get("content"))
                    .map(value_to_text)
                    .or_else(|| excerpts_text(map.get("excerpts").unwrap_or(&Value::Null)))
                    .unwrap_or_default(),
                "truncated": false
            })
        })
        .collect()
}

fn extract_errors(value: &Value) -> Vec<Value> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .map(|item| {
            let Some(map) = item.as_object() else {
                return json!({"url": "", "error": value_to_text(item)});
            };

            json!({
                "url": map.get("url").and_then(Value::as_str).unwrap_or_default(),
                "error": map.get("error_type")
                    .or_else(|| map.get("error"))
                    .map(value_to_text)
                    .unwrap_or_else(|| "extract_failed".to_string())
            })
        })
        .collect()
}

fn excerpts_text(value: &Value) -> Option<String> {
    let excerpts = value.as_array()?;
    let text = excerpts
        .iter()
        .map(value_to_text)
        .filter(|value| !value.trim().is_empty())
        .collect::<Vec<_>>()
        .join("\n");

    (!text.is_empty()).then_some(text)
}

fn request_string(request: &Map<String, Value>, key: &str) -> String {
    request_optional_string(request, key).unwrap_or_default()
}

fn request_optional_string(request: &Map<String, Value>, key: &str) -> Option<String> {
    request
        .get(key)
        .and_then(Value::as_str)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn request_string_list(request: &Map<String, Value>, key: &str) -> Option<Value> {
    let values = request.get(key)?.as_array()?;
    Some(Value::Array(
        values
            .iter()
            .filter_map(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|value| json!(value))
            .collect(),
    ))
}

fn request_limit(request: &Map<String, Value>) -> i64 {
    integer_value(request.get("limit").unwrap_or(&Value::Null))
        .unwrap_or(5)
        .clamp(1, 100)
}

fn encode_query(params: Vec<(String, String)>) -> String {
    params
        .into_iter()
        .map(|(key, value)| format!("{}={}", percent_encode(&key), percent_encode(&value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(*byte as char)
            }
            b' ' => encoded.push('+'),
            byte => encoded.push_str(&format!("%{:02X}", *byte)),
        }
    }
    encoded
}
