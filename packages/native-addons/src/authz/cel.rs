use cel::{Context, Program, Value as CelValue};
use napi::bindgen_prelude::*;
use serde_json::Value as JsonValue;

#[derive(Debug, Eq, PartialEq)]
pub enum BoolEvalError {
  Execution(String),
  ResultType(String),
}

/// Compiles a CEL expression without executing it.
pub fn validate_condition_source(condition: &str) -> Result<()> {
  compile_condition(condition).map(|_| ())
}

/// Compiles a CEL condition used by computed groups or grants.
pub fn compile_condition(condition: &str) -> Result<Program> {
  Program::compile(condition).map_err(|reason| {
    Error::new(
      Status::InvalidArg,
      format!("invalid cel condition: {reason}"),
    )
  })
}

/// Builds the CEL variable context from JSON-compatible values supplied by TS.
///
/// The native addon does not fetch DB state itself; the caller must pass every
/// variable a condition can read.
pub fn build_context(variables: Vec<(&str, JsonValue)>) -> Result<Context<'static>> {
  let mut context = Context::default();

  for (name, value) in variables {
    context.add_variable(name, value).map_err(|reason| {
      Error::new(
        Status::InvalidArg,
        format!("invalid cel variable {name:?}: {reason}"),
      )
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
