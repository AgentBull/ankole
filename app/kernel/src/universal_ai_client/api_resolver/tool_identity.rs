use super::*;

pub(super) fn flattened_namespace_tool_name(namespace: &str, name: &str) -> String {
    let joined = if namespace.is_empty() || namespace == "functions" {
        name.to_string()
    } else if namespace.ends_with('_') || name.starts_with('_') {
        format!("{namespace}{name}")
    } else {
        format!("{namespace}__{name}")
    };

    const MAX_LENGTH: usize = 64;
    const DIGEST_LENGTH: usize = 12;
    const PREFIX_LENGTH: usize = MAX_LENGTH - DIGEST_LENGTH - 1;

    if !joined.is_empty()
        && joined.len() <= MAX_LENGTH
        && joined.bytes().all(provider_tool_name_byte)
    {
        return joined;
    }

    let prefix: String = joined
        .bytes()
        .take(PREFIX_LENGTH)
        .map(|byte| {
            if provider_tool_name_byte(byte) {
                char::from(byte)
            } else {
                '_'
            }
        })
        .collect();
    let digest = blake3::hash(joined.as_bytes()).to_hex().to_string();
    format!("{prefix}_{}", &digest[..DIGEST_LENGTH])
}

fn provider_tool_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}

pub(super) fn restore_tool_namespace(context: &ResponseContext, item: &mut Value) {
    let Some(flattened_name) = item.get("name").and_then(Value::as_str) else {
        return;
    };
    let Some((namespace, function)) = tool_for_flattened_name(context, flattened_name) else {
        return;
    };
    let Some(name) = function.get("name").and_then(Value::as_str) else {
        return;
    };

    item["name"] = json!(name);
    if let Some(namespace) = namespace {
        item["namespace"] = json!(namespace);
    } else if let Some(item) = item.as_object_mut() {
        item.remove("namespace");
    }
}

pub(super) fn tool_for_flattened_name<'a>(
    context: &'a ResponseContext,
    flattened_name: &str,
) -> Option<(Option<&'a str>, &'a Map<String, Value>)> {
    let tools = context
        .request
        .get("tools")
        .or_else(|| context.provider_options.get("tools"))?
        .as_array()?;

    for tool in tools {
        let Some(tool) = tool.as_object() else {
            continue;
        };
        match tool.get("type").and_then(Value::as_str) {
            Some("namespace") => {
                let namespace = tool.get("name").and_then(Value::as_str).unwrap_or_default();
                let Some(children) = tool.get("tools").and_then(Value::as_array) else {
                    continue;
                };
                for child in children {
                    let Some(child) = child.as_object() else {
                        continue;
                    };
                    if !matches!(
                        child.get("type").and_then(Value::as_str),
                        Some("function" | "custom")
                    ) {
                        continue;
                    }
                    let function = child
                        .get("function")
                        .and_then(Value::as_object)
                        .unwrap_or(child);
                    let Some(name) = function.get("name").and_then(Value::as_str) else {
                        continue;
                    };
                    if flattened_namespace_tool_name(namespace, name) == flattened_name {
                        return Some((Some(namespace), function));
                    }
                }
            }
            Some("function" | "custom") => {
                let function = tool
                    .get("function")
                    .and_then(Value::as_object)
                    .unwrap_or(tool);
                if let Some(name) = function.get("name").and_then(Value::as_str)
                    && flattened_namespace_tool_name("", name) == flattened_name
                {
                    return Some((None, function));
                }
            }
            _type => {}
        }
    }

    None
}
