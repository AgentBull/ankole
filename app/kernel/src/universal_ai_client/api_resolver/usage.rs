use serde_json::{Map, Value, json};

use super::{integer_value, put_default};

// A count the Provider did not report stays `null`, so callers can tell it
// apart from a reported zero. A usage that is not an object is `null` as a
// whole.
pub(crate) fn normalize_response_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }
    let input_tokens = usage_count(usage, &["input_tokens", "prompt_tokens"]);
    let output_tokens = usage_count(usage, &["output_tokens", "completion_tokens"]);
    let total_tokens = usage_count(usage, &["total_tokens"])
        .or_else(|| Some(input_tokens?.saturating_add(output_tokens?)));
    let mut input_details = usage_details(usage, "input_tokens_details", "prompt_tokens_details");
    let mut output_details =
        usage_details(usage, "output_tokens_details", "completion_tokens_details");
    // Some OpenAI-compatible Providers report the cache read outside the
    // details object: DeepSeek as `prompt_cache_hit_tokens` and Kimi as a flat
    // `cached_tokens`. Both already count it in `prompt_tokens`.
    if !input_details
        .get("cached_tokens")
        .is_some_and(Value::is_number)
    {
        let cached_tokens = usage_count(usage, &["prompt_cache_hit_tokens", "cached_tokens"]);
        input_details.insert("cached_tokens".to_string(), json!(cached_tokens));
    }
    // OpenRouter and Kimi name the cache write `cache_write_tokens`, and
    // DashScope names it `cache_creation_input_tokens`.
    for alias in ["cache_write_tokens", "cache_creation_input_tokens"] {
        if let Some(cache_write_tokens) =
            input_details.remove(alias).and_then(|v| integer_value(&v))
        {
            input_details
                .entry("cache_creation_tokens")
                .or_insert_with(|| Value::from(cache_write_tokens));
        }
    }
    if !input_details
        .get("cache_creation_tokens")
        .is_some_and(Value::is_number)
        && let Some(flat_creation) = usage_count(
            usage,
            &[
                "cache_creation_tokens",
                "cache_write_tokens",
                "cache_creation_input_tokens",
            ],
        )
    {
        input_details.insert(
            "cache_creation_tokens".to_string(),
            Value::from(flat_creation),
        );
    }
    if let Some(cc) = usage.get("cache_creation").filter(|v| v.is_object()) {
        input_details
            .entry("cache_creation".to_string())
            .or_insert_with(|| cc.clone());
    }
    put_default(&mut output_details, "reasoning_tokens", Value::Null);

    let mut out = json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
        "input_tokens_details": input_details,
        "output_tokens_details": output_details
    });
    if let (Some(cc), Some(obj)) = (
        usage.get("cache_creation").filter(|v| v.is_object()),
        out.as_object_mut(),
    ) {
        obj.insert("cache_creation".to_string(), cc.clone());
    }
    out
}

pub(super) fn normalize_anthropic_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }

    // Anthropic counts uncached input, cache reads, and cache writes as
    // disjoint fields; the OpenResponses shape counts them all as input and
    // keeps the cache portions in `input_tokens_details`.
    let cache_read_tokens = usage_count(usage, &["cache_read_input_tokens"]);
    let ephemeral_creation = usage
        .get("cache_creation")
        .and_then(Value::as_object)
        .and_then(|cc| {
            let m5 = cc.get("ephemeral_5m_input_tokens").and_then(integer_value);
            let h1 = cc.get("ephemeral_1h_input_tokens").and_then(integer_value);
            if m5.is_some() || h1.is_some() {
                Some(m5.unwrap_or(0).saturating_add(h1.unwrap_or(0)))
            } else {
                None
            }
        });
    let cache_creation_tokens = match (
        usage_count(usage, &["cache_creation_input_tokens"]),
        ephemeral_creation,
    ) {
        (Some(top), Some(eph)) => Some(top.max(eph)),
        (Some(top), None) => Some(top),
        (None, Some(eph)) => Some(eph),
        (None, None) => None,
    };
    let input_tokens = usage_count(usage, &["input_tokens"]).map(|input| {
        input
            .saturating_add(cache_read_tokens.unwrap_or(0))
            .saturating_add(cache_creation_tokens.unwrap_or(0))
    });
    let output_tokens = usage_count(usage, &["output_tokens"]);
    let mut input_details = usage_details(usage, "input_tokens_details", "prompt_tokens_details");
    input_details.insert(
        "cached_tokens".to_string(),
        cache_read_tokens.map_or(Value::Null, Value::from),
    );
    input_details.insert(
        "cache_creation_tokens".to_string(),
        cache_creation_tokens.map_or(Value::Null, Value::from),
    );
    if let Some(cc) = usage.get("cache_creation").filter(|v| v.is_object()) {
        input_details.insert("cache_creation".to_string(), cc.clone());
    }
    let mut output_details =
        usage_details(usage, "output_tokens_details", "completion_tokens_details");
    if let Some(thinking) =
        usage_count(usage, &["thinking_tokens", "reasoning_tokens"]).or_else(|| {
            output_details
                .get("thinking_tokens")
                .and_then(integer_value)
                .or_else(|| {
                    output_details
                        .get("reasoning_tokens")
                        .and_then(integer_value)
                })
        })
    {
        output_details
            .entry("thinking_tokens".to_string())
            .or_insert_with(|| Value::from(thinking));
        output_details
            .entry("reasoning_tokens".to_string())
            .or_insert_with(|| Value::from(thinking));
    }
    let mut out = json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens.zip(output_tokens).map(|(input, output)| input.saturating_add(output)),
        "input_tokens_details": input_details,
        "output_tokens_details": output_details
    });
    if let (Some(cc), Some(obj)) = (
        usage.get("cache_creation").filter(|v| v.is_object()),
        out.as_object_mut(),
    ) {
        obj.insert("cache_creation".to_string(), cc.clone());
    }
    out
}

// Bedrock Converse counts uncached input, cache reads, and cache writes as
// disjoint fields, as Anthropic does, so its usage takes the same conversion.
pub(super) fn normalize_bedrock_usage(usage: &Value) -> Value {
    if !usage.is_object() {
        return Value::Null;
    }
    normalize_anthropic_usage(&json!({
        "input_tokens": usage.get("inputTokens"),
        "output_tokens": usage.get("outputTokens"),
        "cache_read_input_tokens": usage.get("cacheReadInputTokens"),
        "cache_creation_input_tokens": usage.get("cacheWriteInputTokens")
    }))
}

// `keys` lists the canonical name first; the first key carrying a numeric count wins.
fn usage_count(usage: &Value, keys: &[&str]) -> Option<i64> {
    keys.iter()
        .find_map(|key| usage.get(*key).and_then(integer_value))
}

fn usage_details(usage: &Value, key: &str, legacy_key: &str) -> Map<String, Value> {
    usage
        .get(key)
        .and_then(Value::as_object)
        .or_else(|| usage.get(legacy_key).and_then(Value::as_object))
        .cloned()
        .unwrap_or_default()
}

// Accumulates raw Anthropic usage counters across stream events. The result
// stays in Anthropic shape; `normalize_anthropic_usage` converts it when a
// response body is built.
pub(super) fn merge_anthropic_usage(left: Value, right: &Value) -> Value {
    let mut merged = left.as_object().cloned().unwrap_or_default();
    if let Some(right) = right.as_object() {
        for key in [
            "input_tokens",
            "output_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
            "thinking_tokens",
            "reasoning_tokens",
        ] {
            if let Some(value) = right.get(key).filter(|v| !v.is_null()) {
                merged.insert(key.to_string(), value.clone());
            }
        }
        for nested_key in [
            "cache_creation",
            "input_tokens_details",
            "output_tokens_details",
        ] {
            if let Some(sub_right) = right.get(nested_key).and_then(Value::as_object) {
                let mut sub_merged = merged
                    .get(nested_key)
                    .and_then(Value::as_object)
                    .cloned()
                    .unwrap_or_default();
                for (k, v) in sub_right {
                    if !v.is_null() {
                        sub_merged.insert(k.clone(), v.clone());
                    }
                }
                if !sub_merged.is_empty() {
                    merged.insert(nested_key.to_string(), Value::Object(sub_merged));
                }
            }
        }
    }
    Value::Object(merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_numbers_saturate_instead_of_wrapping() {
        assert_eq!(integer_value(&json!(u64::MAX)), Some(i64::MAX));

        let response = normalize_response_usage(&json!({
            "input_tokens": i64::MAX,
            "output_tokens": 1
        }));
        assert_eq!(response["total_tokens"], json!(i64::MAX));

        let anthropic = normalize_anthropic_usage(&json!({
            "input_tokens": i64::MAX,
            "cache_read_input_tokens": 1,
            "cache_creation_input_tokens": 1,
            "output_tokens": 1
        }));
        assert_eq!(anthropic["input_tokens"], json!(i64::MAX));
        assert_eq!(anthropic["total_tokens"], json!(i64::MAX));

        let bedrock = normalize_bedrock_usage(&json!({
            "inputTokens": i64::MAX,
            "cacheReadInputTokens": 1,
            "outputTokens": 1
        }));
        assert_eq!(bedrock["input_tokens"], json!(i64::MAX));
        assert_eq!(bedrock["total_tokens"], json!(i64::MAX));
    }

    #[test]
    fn provider_specific_cache_counts_use_the_canonical_details() {
        let deepseek = normalize_response_usage(&json!({
            "prompt_tokens": 100,
            "completion_tokens": 5,
            "prompt_cache_hit_tokens": 60,
            "prompt_cache_miss_tokens": 40
        }));
        assert_eq!(deepseek["input_tokens"], json!(100));
        assert_eq!(deepseek["input_tokens_details"]["cached_tokens"], json!(60));

        let kimi = normalize_response_usage(&json!({
            "prompt_tokens": 19,
            "completion_tokens": 13,
            "cached_tokens": 12,
            "cache_write_tokens": 4
        }));
        assert_eq!(kimi["input_tokens_details"]["cached_tokens"], json!(12));
        assert_eq!(
            kimi["input_tokens_details"]["cache_creation_tokens"],
            json!(4)
        );

        // Null primary keys fall back to populated legacy aliases instead of dropping counts.
        let null_primary = normalize_response_usage(&json!({
            "input_tokens": null,
            "prompt_tokens": 25,
            "input_tokens_details": null,
            "prompt_tokens_details": {"cached_tokens": 10},
            "cache_creation": {"ephemeral_1h_input_tokens": 15}
        }));
        assert_eq!(null_primary["input_tokens"], json!(25));
        assert_eq!(
            null_primary["input_tokens_details"]["cached_tokens"],
            json!(10)
        );
        assert_eq!(
            null_primary["cache_creation"]["ephemeral_1h_input_tokens"],
            json!(15)
        );

        // The canonical detail wins over a flat count, including a reported zero.
        let canonical = normalize_response_usage(&json!({
            "prompt_tokens": 19,
            "cached_tokens": 12,
            "prompt_tokens_details": {"cached_tokens": 0}
        }));
        assert_eq!(canonical["input_tokens_details"]["cached_tokens"], json!(0));

        let openrouter = normalize_response_usage(&json!({
            "prompt_tokens": 100,
            "prompt_tokens_details": {"cached_tokens": 60, "cache_write_tokens": 30}
        }));
        let details = &openrouter["input_tokens_details"];
        assert_eq!(details["cached_tokens"], json!(60));
        assert_eq!(details["cache_creation_tokens"], json!(30));
        assert_eq!(details.get("cache_write_tokens"), None);
        assert_eq!(normalize_response_usage(&openrouter), openrouter);

        let dashscope = normalize_response_usage(&json!({
            "prompt_tokens": 3019,
            "prompt_tokens_details": {"cached_tokens": 0, "cache_creation_input_tokens": 3013}
        }));
        let details = &dashscope["input_tokens_details"];
        assert_eq!(details["cache_creation_tokens"], json!(3013));
        assert_eq!(details.get("cache_creation_input_tokens"), None);

        // A Bedrock usage that reports no cache counts keeps them unreported.
        let bedrock = normalize_bedrock_usage(&json!({"inputTokens": 3, "outputTokens": 5}));
        assert_eq!(bedrock["input_tokens"], json!(3));
        assert_eq!(bedrock["total_tokens"], json!(8));
        assert_eq!(
            bedrock["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
        assert_eq!(normalize_bedrock_usage(&Value::Null), Value::Null);
    }

    #[test]
    fn unreported_usage_counts_stay_null() {
        assert_eq!(normalize_response_usage(&Value::Null), Value::Null);
        assert_eq!(normalize_anthropic_usage(&Value::Null), Value::Null);

        let partial = normalize_response_usage(&json!({"prompt_tokens": 0}));
        assert_eq!(partial["input_tokens"], json!(0));
        assert_eq!(partial["output_tokens"], Value::Null);
        assert_eq!(partial["total_tokens"], Value::Null);
        assert_eq!(
            partial["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
        assert_eq!(
            partial["output_tokens_details"]["reasoning_tokens"],
            Value::Null
        );
        assert_eq!(normalize_response_usage(&partial), partial);

        let anthropic = normalize_anthropic_usage(&json!({"output_tokens": 4}));
        assert_eq!(anthropic["input_tokens"], Value::Null);
        assert_eq!(anthropic["output_tokens"], json!(4));
        assert_eq!(
            anthropic["input_tokens_details"]["cached_tokens"],
            Value::Null
        );
    }
}
