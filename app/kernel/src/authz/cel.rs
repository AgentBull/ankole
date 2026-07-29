use cel::{Context, Program, Value as CelValue, functions};
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
/// The cel 0.14 default library dropped `contains` on lists and maps, `max`,
/// and `min`. Persisted AuthZ conditions and signal filters can use them, so
/// register the crate's own implementations again.
pub fn base_context() -> Context<'static> {
    let mut context = Context::default();
    context.add_function("contains", functions::contains);
    context.add_function("max", functions::max);
    context.add_function("min", functions::min);
    context
}

/// Builds the CEL variable context from JSON-compatible values supplied by the host.
///
/// The kernel does not fetch DB state itself; the caller must pass every
/// variable a condition can read.
pub fn build_context(variables: Vec<(&str, JSONValue)>) -> KernelResult<Context<'static>> {
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
    context: &Context<'_>,
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
