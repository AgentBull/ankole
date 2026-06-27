//! SignalsGateway native policy helpers.
//!
//! The gateway supplies a normalized JSON context. This module only evaluates
//! CEL against that context; it does not know how to load bindings, provider
//! state, actor state, or database rows.

use cel::{Context, Program, Value as CelValue};
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use crate::common::{KernelError, KernelResult};

struct CachedFilter {
    source: String,
    program: Arc<Program>,
}

static FILTER_CACHE: OnceLock<Mutex<HashMap<String, CachedFilter>>> = OnceLock::new();

/// Compiles a SignalsGateway CEL filter without executing it.
pub fn validate_filter_source(source: &str) -> KernelResult<()> {
    compile_filter(source).map(|_| ())
}

/// Evaluates a SignalsGateway CEL filter against a host-supplied JSON context.
pub fn evaluate_filter_json(source: &str, context_json: JsonValue) -> KernelResult<bool> {
    let program = cached_filter_program(source)?;
    let context = build_filter_context(context_json)?;

    execute_bool(&program, &context)
}

fn compile_filter(source: &str) -> KernelResult<Program> {
    if source.trim().is_empty() {
        return Err(KernelError::new(
            "invalid signal filter: expression must not be blank",
        ));
    }

    Program::compile(source)
        .map_err(|reason| KernelError::new(format!("invalid signal filter: {reason}")))
}

fn cached_filter_program(source: &str) -> KernelResult<Arc<Program>> {
    if let Some(program) = lookup_cached_filter_program(source) {
        return Ok(program);
    }

    let program = Arc::new(compile_filter(source)?);
    store_cached_filter_program(source, &program);
    Ok(program)
}

fn lookup_cached_filter_program(source: &str) -> Option<Arc<Program>> {
    let cache = FILTER_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let guard = cache.try_lock().ok()?;
    let cached = guard.get(source)?;

    if cached.source == source {
        Some(Arc::clone(&cached.program))
    } else {
        None
    }
}

fn store_cached_filter_program(source: &str, program: &Arc<Program>) {
    let cache = FILTER_CACHE.get_or_init(|| Mutex::new(HashMap::new()));

    if let Ok(mut guard) = cache.try_lock() {
        guard.insert(
            source.to_owned(),
            CachedFilter {
                source: source.to_owned(),
                program: Arc::clone(program),
            },
        );
    }
}

fn build_filter_context(context_json: JsonValue) -> KernelResult<Context<'static>> {
    let object = context_json
        .as_object()
        .ok_or_else(|| KernelError::new("signal filter context must be a JSON object"))?;

    let binding = required_context_object(object, "binding")?;
    let signal = required_context_object(object, "signal")?;

    let mut context = Context::default();
    context
        .add_variable("binding", binding)
        .map_err(|reason| KernelError::new(format!("invalid signal filter binding: {reason}")))?;
    context
        .add_variable("signal", signal)
        .map_err(|reason| KernelError::new(format!("invalid signal filter signal: {reason}")))?;

    Ok(context)
}

fn required_context_object(
    object: &serde_json::Map<String, JsonValue>,
    field: &str,
) -> KernelResult<JsonValue> {
    // The host bridge owns the fixed CEL variable envelope. Missing or scalar
    // variables are caller bugs, so fail closed instead of evaluating against an
    // empty object that could make `true` admit a signal.
    match object.get(field) {
        Some(value @ JsonValue::Object(_)) => Ok(value.clone()),
        Some(_) => Err(KernelError::new(format!(
            "signal filter context {field} must be a JSON object"
        ))),
        None => Err(KernelError::new(format!(
            "signal filter context must include {field}"
        ))),
    }
}

fn execute_bool(program: &Program, context: &Context<'_>) -> KernelResult<bool> {
    match program.execute(context) {
        Ok(CelValue::Bool(value)) => Ok(value),
        Ok(value) => Err(KernelError::new(format!(
            "signal filter returned {}",
            value.type_of()
        ))),
        Err(reason) => Err(KernelError::new(format!(
            "signal filter execution failed: {reason}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn evaluates_boolean_filters() {
        let context = filter_context();

        assert!(evaluate_filter_json("true", context.clone()).unwrap());
        assert!(!evaluate_filter_json("false", context.clone()).unwrap());
        assert!(
            evaluate_filter_json(
                "binding.name == 'bot' && signal.channel.id == 'lark:chat:group-a'",
                context
            )
            .unwrap()
        );
    }

    #[test]
    fn exposes_common_cel_functions_and_macros() {
        let context = filter_context();
        let expression = r#"
            signal.entry.sender_key.startsWith('lark:user:')
              && signal.entry.sender_key.matches('^lark:user:[a-z]+$')
              && signal.entry.text.contains('hello')
              && ['lark:chat:group-a', 'lark:chat:group-b'].contains(signal.channel.id)
              && [1, 2, 3].all(n, n > 0)
              && ['a', 'bb', 'ccc'].filter(v, v.size() > 1).map(v, v.size()).exists(size, size == 3)
        "#;

        assert!(evaluate_filter_json(expression, context).unwrap());
    }

    #[test]
    fn reports_syntax_runtime_and_non_boolean_errors() {
        assert!(validate_filter_source("signal.").is_err());
        assert!(validate_filter_source(" ").is_err());

        let context = filter_context();
        let non_bool = evaluate_filter_json("signal.entry.text", context.clone()).unwrap_err();
        assert!(non_bool.to_string().contains("returned string"));

        let missing_path =
            evaluate_filter_json("signal.entry.missing == true", context).unwrap_err();
        assert!(
            missing_path
                .to_string()
                .contains("signal filter execution failed")
        );
    }

    #[test]
    fn rejects_malformed_filter_contexts() {
        let missing_binding = evaluate_filter_json("true", json!({"signal": {}})).unwrap_err();
        assert!(missing_binding.to_string().contains("must include binding"));

        let invalid_signal = evaluate_filter_json(
            "true",
            json!({
                "binding": {},
                "signal": "entry"
            }),
        )
        .unwrap_err();
        assert!(
            invalid_signal
                .to_string()
                .contains("signal must be a JSON object")
        );
    }

    fn filter_context() -> JsonValue {
        json!({
            "binding": {
                "name": "bot",
                "adapter": "lark"
            },
            "signal": {
                "kind": "entry_received",
                "channel": {
                    "id": "lark:chat:group-a",
                    "kind": "im_group",
                    "reply_mode": "entry",
                    "name": "Ops",
                    "metadata": {
                        "realm": "ops",
                        "repository": "ankole"
                    }
                },
                "entry": {
                    "id": "msg-1",
                    "thread_id": "thread-1",
                    "sender_key": "lark:user:alice",
                    "actor_input_type": "im.message.addressed",
                    "text": "hello world",
                    "metadata": {
                        "event_type": "message",
                        "repository": "ankole"
                    }
                }
            }
        })
    }
}
