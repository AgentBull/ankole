use std::sync::Arc;

use cel::common::types::{self, CelBool};
use cel::common::value::CowVal;
use cel::{Context, Env, Program, Value as CelValue, functions};
use serde_json::Value as JSONValue;

use crate::common::{KernelError, KernelResult};

#[derive(Debug, Eq, PartialEq)]
pub enum BoolEvalError {
    Execution(String),
    ResultType(String),
}

/// Compiles a CEL expression without executing it.
pub fn validate_condition_source(condition: &str) -> KernelResult<()> {
    compile_condition(condition).map(|_| ())
}

/// Compiles a CEL condition used by computed groups or grants.
pub fn compile_condition(condition: &str) -> KernelResult<Program> {
    Program::compile(condition)
        .map_err(|reason| KernelError::new(format!("invalid cel condition: {reason}")))
}

/// Builds the CEL evaluation context with Ankole's supported function surface.
///
/// Persisted AuthZ conditions and signal filters can use list and map
/// `contains`, `max`, and `min`. Register these beside the standard library.
pub fn base_context() -> Context<'static, 'static> {
    let mut env = Env::stdlib();
    for (target, id) in [
        (types::LIST_TYPE, "ankole_list_contains"),
        (types::MAP_TYPE, "ankole_map_contains"),
    ] {
        env.add_member_overload("contains", id, target, vec![types::DYN_TYPE], |args| {
            let container = args[0]
                .as_container()
                .expect("contains receiver is a list or map");
            let contains = container.contains(args[1].as_ref())?;
            Ok(CowVal::owned(CelBool::from(contains)))
        })
        .expect("list and map contains are absent from the CEL standard library");
    }

    let mut context = Context::with_env(Arc::new(env));
    context
        .add_function("max", functions::max)
        .expect("max is absent from the CEL standard library");
    context
        .add_function("min", functions::min)
        .expect("min is absent from the CEL standard library");
    context
}

/// Builds the CEL variable context from JSON-compatible values supplied by the host.
///
/// The kernel does not fetch DB state itself; the caller must pass every
/// variable a condition can read.
pub fn build_context(variables: Vec<(&str, JSONValue)>) -> KernelResult<Context<'static, 'static>> {
    let mut context = base_context();

    for (name, value) in variables {
        context.add_variable(name, value).map_err(|reason| {
            KernelError::new(format!("invalid cel variable {name:?}: {reason}"))
        })?;
    }

    Ok(context)
}

/// Executes a CEL program that must return a boolean.
///
/// Non-boolean results are treated as authorization diagnostics rather than
/// truthy/falsy values, because grants must fail closed when persisted data is
/// invalid.
pub fn execute_bool(
    program: &Program,
    context: &Context<'_, '_>,
) -> std::result::Result<bool, BoolEvalError> {
    match program.execute(context) {
        Ok(CelValue::Bool(value)) => Ok(value),
        Ok(value) => Err(BoolEvalError::ResultType(format!(
            "condition returned {}",
            value.type_of()
        ))),
        Err(reason) => Err(BoolEvalError::Execution(reason.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn preserves_supported_functions_for_host_variables_and_literals() {
        let context = build_context(vec![
            ("roles", json!(["admin", "operator"])),
            ("claims", json!({"active": true})),
        ])
        .unwrap();

        for source in [
            "'hello world'.contains('hello')",
            "roles.contains('admin') && !roles.contains('guest')",
            "claims.contains('active') && !claims.contains('missing')",
            "[1, 2, 3].contains(2) && ![].contains(2)",
            "{1: 'one'}.contains(1) && !{}.contains('missing')",
            "max(1, 3, 2) == 3 && min(4, 2, 8) == 2",
            "max([1, 3, 2]) == 3 && min([4, 2, 8]) == 2",
        ] {
            let program = compile_condition(source).unwrap();
            assert_eq!(execute_bool(&program, &context), Ok(true), "{source}");
        }
    }
}
