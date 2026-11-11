use std::collections::BTreeSet;

use serde_json::{Map, Value};

use super::anthropic::unexpressible_anthropic_field;
use super::{ConversionPolicy, ResponseContext, StreamError};

pub(crate) const ANTHROPIC_VERSION_2023_06_01: &str = "2023-06-01";
pub(crate) const ANTHROPIC_VERSION_2026_10_21: &str = "2026-10-21";

const VERSION_KEYS: [&str; 3] = ["api_version", "anthropic_version", "anthropic-version"];
const DEPRECATED_V2026_SAMPLING_KEYS: [&str; 3] = ["temperature", "top_p", "top_k"];

pub(crate) fn is_claude_45_plus_model(model: &str) -> bool {
    let lower = model.trim().to_ascii_lowercase();
    let Some((_, after_claude)) = lower.split_once("claude-") else {
        return false;
    };

    let tokens: Vec<&str> = after_claude.split(['-', '.', ':']).collect();
    let Some((idx, major)) = tokens
        .iter()
        .enumerate()
        .find_map(|(i, tok)| tok.parse::<u32>().ok().filter(|&v| v < 100).map(|v| (i, v)))
    else {
        return false;
    };
    let minor = tokens
        .get(idx + 1)
        .and_then(|tok| tok.parse::<u32>().ok())
        .filter(|&v| v < 100)
        .unwrap_or(0);

    major > 4 || (major == 4 && minor >= 5)
}

pub(crate) fn resolve_anthropic_api_version(
    context: &ResponseContext,
    request: &Map<String, Value>,
    body: &Map<String, Value>,
) -> &'static str {
    if let Some(explicit) = explicit_api_version(context, request, body) {
        return if explicit == ANTHROPIC_VERSION_2026_10_21 {
            ANTHROPIC_VERSION_2026_10_21
        } else {
            ANTHROPIC_VERSION_2023_06_01
        };
    }
    if target_model_is_claude_45_plus(context, request, body) {
        return ANTHROPIC_VERSION_2026_10_21;
    }
    ANTHROPIC_VERSION_2023_06_01
}

fn explicit_api_version<'a>(
    context: &'a ResponseContext,
    request: &'a Map<String, Value>,
    body: &'a Map<String, Value>,
) -> Option<&'a str> {
    let provider_opts = context.provider_options.as_object();
    for key in VERSION_KEYS {
        if let Some(ver) = provider_opts
            .and_then(|opts| opts.get(key))
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
        {
            return Some(ver.trim());
        }
        if let Some(ver) = request
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
        {
            return Some(ver.trim());
        }
        if let Some(ver) = body
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.trim().is_empty())
        {
            return Some(ver.trim());
        }
    }
    None
}

fn target_model_is_claude_45_plus(
    context: &ResponseContext,
    request: &Map<String, Value>,
    body: &Map<String, Value>,
) -> bool {
    is_claude_45_plus_model(&context.model)
        || request
            .get("model")
            .and_then(Value::as_str)
            .is_some_and(is_claude_45_plus_model)
        || body
            .get("model")
            .and_then(Value::as_str)
            .is_some_and(is_claude_45_plus_model)
}

pub(crate) fn has_non_empty_citations(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::Bool(true)) => true,
        Some(Value::String(s)) => !s.trim().is_empty(),
        Some(Value::Array(arr)) => !arr.is_empty(),
        Some(Value::Object(obj)) => {
            if obj.len() == 1 && obj.get("enabled").is_some_and(Value::is_boolean) {
                false
            } else {
                !obj.is_empty()
            }
        }
        Some(Value::Number(_)) => true,
    }
}

pub(crate) fn enforce_anthropic_v2026_boundary(
    context: &ResponseContext,
    request: &Map<String, Value>,
    body: &mut Map<String, Value>,
    consumed: &mut BTreeSet<&'static str>,
) -> Result<(), StreamError> {
    for key in VERSION_KEYS {
        if request.contains_key(key) {
            consumed.insert(key);
        }
        body.remove(key);
    }

    if resolve_anthropic_api_version(context, request, body) != ANTHROPIC_VERSION_2026_10_21 {
        return Ok(());
    }

    let strict = context.policy() == ConversionPolicy::Strict;
    enforce_v2026_sampling_params(request, body, consumed, strict)?;
    enforce_v2026_input_items(request.get("input"), strict)?;
    enforce_v2026_messages(body.get_mut("messages"), strict)
}

fn enforce_v2026_sampling_params(
    request: &Map<String, Value>,
    body: &mut Map<String, Value>,
    consumed: &mut BTreeSet<&'static str>,
    strict: bool,
) -> Result<(), StreamError> {
    for key in DEPRECATED_V2026_SAMPLING_KEYS {
        let present = request.get(key).is_some_and(|v| !v.is_null())
            || body.get(key).is_some_and(|v| !v.is_null());
        if present {
            if strict {
                return Err(unexpressible_anthropic_field(key));
            }
            body.remove(key);
            consumed.insert(key);
        }
    }
    Ok(())
}

fn enforce_v2026_input_items(input: Option<&Value>, strict: bool) -> Result<(), StreamError> {
    let Some(Value::Array(items)) = input else {
        return Ok(());
    };
    for item in items {
        let Some(map) = item.as_object() else {
            continue;
        };
        let role = map.get("role").and_then(Value::as_str).unwrap_or("user");
        if role != "assistant" && has_non_empty_citations(map.get("citations")) && strict {
            return Err(unexpressible_anthropic_field("citations"));
        }
    }
    Ok(())
}

fn enforce_v2026_messages(messages: Option<&mut Value>, strict: bool) -> Result<(), StreamError> {
    let Some(Value::Array(msgs)) = messages else {
        return Ok(());
    };
    for msg in msgs.iter_mut() {
        let Some(map) = msg.as_object_mut() else {
            continue;
        };
        let role = map
            .get("role")
            .and_then(Value::as_str)
            .unwrap_or("user")
            .to_string();
        if role == "assistant" {
            sanitize_v2026_assistant_message(map, strict)?;
        } else {
            sanitize_v2026_user_message(map, strict)?;
        }
    }

    msgs.retain(|message| {
        let assistant = message.get("role").and_then(Value::as_str) == Some("assistant");
        let empty = message
            .get("content")
            .and_then(Value::as_array)
            .is_some_and(Vec::is_empty);

        !(assistant && empty)
    });
    coalesce_adjacent_same_role_messages(msgs);
    Ok(())
}

fn coalesce_adjacent_same_role_messages(msgs: &mut Vec<Value>) {
    let mut merged: Vec<Value> = Vec::with_capacity(msgs.len());
    for msg in msgs.drain(..) {
        let role = msg.get("role").and_then(Value::as_str);
        let prev_same_role = merged
            .last()
            .and_then(|last| last.get("role"))
            .and_then(Value::as_str)
            .is_some_and(|prev| Some(prev) == role);
        if prev_same_role && let Some(last) = merged.last_mut() {
            let mut next_blocks = message_content_blocks(&msg);
            let mut prev_blocks = message_content_blocks(last);
            prev_blocks.append(&mut next_blocks);
            if let Some(last_obj) = last.as_object_mut() {
                last_obj.insert("content".to_string(), Value::Array(prev_blocks));
            }
        } else {
            merged.push(msg);
        }
    }
    *msgs = merged;
}

fn message_content_blocks(msg: &Value) -> Vec<Value> {
    match msg.get("content") {
        Some(Value::Array(blocks)) => blocks.clone(),
        Some(Value::String(text)) => {
            vec![serde_json::json!({ "type": "text", "text": text })]
        }
        _ => Vec::new(),
    }
}

fn sanitize_v2026_assistant_message(
    map: &mut Map<String, Value>,
    strict: bool,
) -> Result<(), StreamError> {
    let Some(Value::Array(blocks)) = map.get_mut("content") else {
        return Ok(());
    };
    let has_doc = blocks
        .iter()
        .any(|b| b.get("type").and_then(Value::as_str) == Some("document"));
    if has_doc {
        if strict {
            return Err(unexpressible_anthropic_field("messages.assistant.document"));
        }
        blocks.retain(|b| b.get("type").and_then(Value::as_str) != Some("document"));
    }
    Ok(())
}

fn sanitize_v2026_user_message(
    map: &mut Map<String, Value>,
    strict: bool,
) -> Result<(), StreamError> {
    if has_non_empty_citations(map.get("citations")) {
        if strict {
            return Err(unexpressible_anthropic_field("citations"));
        }
        map.remove("citations");
    }
    let Some(Value::Array(blocks)) = map.get_mut("content") else {
        return Ok(());
    };
    for block in blocks {
        let Some(obj) = block.as_object_mut() else {
            continue;
        };
        if has_non_empty_citations(obj.get("citations")) {
            if strict {
                return Err(unexpressible_anthropic_field("citations"));
            }
            obj.remove("citations");
        } else if matches!(
            obj.get("citations"),
            Some(Value::Array(_)) | Some(Value::Null)
        ) {
            obj.remove("citations");
        }
    }
    Ok(())
}
