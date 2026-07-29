//! SignalsGateway native policy helpers.
//!
//! The gateway supplies a normalized JSON context. This module only evaluates
//! CEL against that context; it does not know how to load bindings, provider
//! state, actor state, or database rows.

use ::cel::{Context, Program};
use serde_json::Value as JSONValue;
use std::sync::{Arc, OnceLock};

use crate::authz::cel::{self, BoolEvalError};
use crate::common::bounded_cache::BoundedCache;
use crate::common::{KernelError, KernelResult};

static FILTER_CACHE: OnceLock<BoundedCache<String, Arc<Program>>> = OnceLock::new();

const MAX_FILTER_CACHE_ENTRIES: usize = 1024;

/// Compiles a SignalsGateway CEL filter without executing it.
pub fn validate_filter_source(source: &str) -> KernelResult<()> {
    compile_filter(source).map(|_| ())
}

/// Evaluates a SignalsGateway CEL filter against a host-supplied context.
pub fn evaluate_filter(source: &str, context_json: JSONValue) -> KernelResult<bool> {
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
    let cache = FILTER_CACHE.get_or_init(|| BoundedCache::new(MAX_FILTER_CACHE_ENTRIES));
    let source = source.to_owned();
    cache.get_if(&source, |_cached| true, Arc::clone)
}

fn store_cached_filter_program(source: &str, program: &Arc<Program>) {
    let cache = FILTER_CACHE.get_or_init(|| BoundedCache::new(MAX_FILTER_CACHE_ENTRIES));
    cache.insert(source.to_owned(), Arc::clone(program));
}

fn build_filter_context(context_json: JSONValue) -> KernelResult<Context<'static>> {
    let object = context_json
        .as_object()
        .ok_or_else(|| KernelError::new("signal filter context must be a JSON object"))?;

    let binding = required_context_object(object, "binding")?;
    let signal = required_context_object(object, "signal")?;

    let mut context = cel::base_context();
    context
        .add_variable("binding", binding)
        .map_err(|reason| KernelError::new(format!("invalid signal filter binding: {reason}")))?;
    context
        .add_variable("signal", signal)
        .map_err(|reason| KernelError::new(format!("invalid signal filter signal: {reason}")))?;

    Ok(context)
}

fn required_context_object(
    object: &serde_json::Map<String, JSONValue>,
    field: &str,
) -> KernelResult<JSONValue> {
    // The host bridge owns the fixed CEL variable envelope. Missing or scalar
    // variables are caller bugs, so fail closed instead of evaluating against an
    // empty object that could make `true` admit a signal.
    match object.get(field) {
        Some(value @ JSONValue::Object(_)) => Ok(value.clone()),
        Some(_) => Err(KernelError::new(format!(
            "signal filter context {field} must be a JSON object"
        ))),
        None => Err(KernelError::new(format!(
            "signal filter context must include {field}"
        ))),
    }
}

fn execute_bool(program: &Program, context: &Context<'_>) -> KernelResult<bool> {
    match cel::execute_bool(program, context) {
        Ok(value) => Ok(value),
        Err(BoolEvalError::ResultType(reason)) => {
            let value_type = reason
                .strip_prefix("condition returned ")
                .unwrap_or(reason.as_str());
            Err(KernelError::new(format!(
                "signal filter returned {value_type}"
            )))
        }
        Err(BoolEvalError::Execution(reason)) => Err(KernelError::new(format!(
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

        assert!(evaluate_filter("true", context.clone()).unwrap());
        assert!(!evaluate_filter("false", context.clone()).unwrap());
        assert!(
            evaluate_filter(
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
              && max(1, 3, 2) == 3
              && min(4, 2, 8) == 2
        "#;

        assert!(evaluate_filter(expression, context).unwrap());
    }

    #[test]
    fn reports_syntax_runtime_and_non_boolean_errors() {
        assert!(validate_filter_source("signal.").is_err());
        assert!(validate_filter_source(" ").is_err());

        let context = filter_context();
        let non_bool = evaluate_filter("signal.entry.text", context.clone()).unwrap_err();
        assert!(non_bool.to_string().contains("returned string"));

        let missing_path = evaluate_filter("signal.entry.missing == true", context).unwrap_err();
        assert!(
            missing_path
                .to_string()
                .contains("signal filter execution failed")
        );
    }

    #[test]
    fn rejects_malformed_filter_contexts() {
        let missing_binding = evaluate_filter("true", json!({"signal": {}})).unwrap_err();
        assert!(missing_binding.to_string().contains("must include binding"));

        let invalid_signal = evaluate_filter(
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

    #[test]
    fn filter_cache_evicts_when_full() {
        clear_filter_cache();

        for index in 0..=MAX_FILTER_CACHE_ENTRIES {
            cached_filter_program(&format!("binding.name == 'bot-{index}'")).unwrap();
        }

        assert_eq!(filter_cache_len(), MAX_FILTER_CACHE_ENTRIES);
    }

    fn filter_context() -> JSONValue {
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
                    "actor_event_type": "im.message.addressed",
                    "text": "hello world",
                    "metadata": {
                        "event_type": "message",
                        "repository": "ankole"
                    }
                }
            }
        })
    }

    fn clear_filter_cache() {
        FILTER_CACHE
            .get_or_init(|| BoundedCache::new(MAX_FILTER_CACHE_ENTRIES))
            .clear();
    }

    fn filter_cache_len() -> usize {
        FILTER_CACHE
            .get_or_init(|| BoundedCache::new(MAX_FILTER_CACHE_ENTRIES))
            .len()
    }
}
