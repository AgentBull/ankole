use std::collections::HashMap;

use cel::{Context, Program, Value as CelValue};
use rustler::types::list::ListIterator;
use rustler::types::map::MapIterator;
use rustler::{NifResult, Term, TermType};
use serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue};

use crate::encoding::error;

#[derive(Debug, Eq, PartialEq)]
pub enum BoolEvalError {
  Execution(String),
  ResultType(String),
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn rule_engine_cel_condition_validate(condition: Term<'_>) -> NifResult<bool> {
  let condition: String = condition
    .decode()
    .map_err(|_| error("condition must be a string"))?;

  compile_condition(&condition).map_err(error)?;
  Ok(true)
}

pub fn compile_condition(condition: &str) -> Result<Program, String> {
  Program::compile(condition).map_err(|e| format!("invalid cel condition: {e}"))
}

pub fn build_context(variables: Vec<(&str, JsonValue)>) -> NifResult<Context<'static>> {
  let mut context = Context::default();

  for (name, value) in variables {
    context
      .add_variable(name, value)
      .map_err(|e| error(format!("invalid cel variable {name:?}: {e}")))?;
  }

  Ok(context)
}

pub fn execute_bool(program: &Program, context: &Context<'_>) -> Result<bool, BoolEvalError> {
  match program.execute(context) {
    Ok(CelValue::Bool(value)) => Ok(value),
    Ok(value) => Err(BoolEvalError::ResultType(format!(
      "condition returned {}",
      value.type_of()
    ))),
    Err(reason) => Err(BoolEvalError::Execution(reason.to_string())),
  }
}

pub fn require_map<'a>(term: Term<'a>, field: &str) -> NifResult<HashMap<String, Term<'a>>> {
  if term.get_type() != TermType::Map {
    return Err(error(format!("{field} must be a map")));
  }

  let mut out = HashMap::new();

  for (k, v) in MapIterator::new(term).ok_or_else(|| error(format!("{field} must be a map")))? {
    let key = map_key_to_string(k, field)?;

    if key != "__struct__" {
      out.insert(key, v);
    }
  }

  Ok(out)
}

pub fn require_field<'a>(map: &HashMap<String, Term<'a>>, key: &str) -> NifResult<Term<'a>> {
  map
    .get(key)
    .copied()
    .ok_or_else(|| error(format!("missing required field {key:?}")))
}

pub fn require_string_field(map: &HashMap<String, Term<'_>>, key: &str) -> NifResult<String> {
  require_field(map, key)?
    .decode()
    .map_err(|_| error(format!("field {key:?} must be a string")))
}

pub fn require_object<'a>(
  value: &'a JsonValue,
  field: &str,
) -> NifResult<&'a JsonMap<String, JsonValue>> {
  value
    .as_object()
    .ok_or_else(|| error(format!("{field} must be a map")))
}

pub fn require_json_string_field(value: &JsonValue, key: &str, field: &str) -> NifResult<()> {
  let object = require_object(value, field)?;

  match object.get(key).and_then(JsonValue::as_str) {
    Some(_value) => Ok(()),
    None => Err(error(format!("{field}.{key} must be a string"))),
  }
}

pub fn term_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  match term.get_type() {
    TermType::Atom => atom_to_json(term),
    TermType::Binary => term
      .decode::<String>()
      .map(JsonValue::String)
      .map_err(|_| error("binary value must be valid utf-8")),
    TermType::Integer => term
      .decode::<i64>()
      .map(|n| JsonValue::Number(JsonNumber::from(n)))
      .map_err(|_| error("integer out of range")),
    TermType::Float => term
      .decode::<f64>()
      .map_err(|_| error("invalid float value"))
      .and_then(float_to_json),
    TermType::List => list_to_json(term),
    TermType::Map => map_to_json(term),
    other => Err(error(format!("unsupported term type: {other:?}"))),
  }
}

fn atom_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let atom_name: String = term
    .atom_to_string()
    .map_err(|_| error("atom decode failed"))?;

  match atom_name.as_str() {
    "true" => Ok(JsonValue::Bool(true)),
    "false" => Ok(JsonValue::Bool(false)),
    "nil" => Ok(JsonValue::Null),
    _other => Err(error("atom values are not allowed")),
  }
}

fn float_to_json(value: f64) -> NifResult<JsonValue> {
  JsonNumber::from_f64(value)
    .map(JsonValue::Number)
    .ok_or_else(|| error("float value must be finite"))
}

fn list_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let iter: ListIterator = term.decode().map_err(|_| error("invalid list value"))?;

  let mut values = Vec::new();
  for element in iter {
    values.push(term_to_json(element)?);
  }

  Ok(JsonValue::Array(values))
}

fn map_to_json(term: Term<'_>) -> NifResult<JsonValue> {
  let mut object = JsonMap::new();

  for (k, v) in MapIterator::new(term).ok_or_else(|| error("invalid map value"))? {
    let key = map_key_to_string(k, "map")?;

    if key == "__struct__" {
      return Err(error("struct values are not allowed"));
    }

    object.insert(key, term_to_json(v)?);
  }

  Ok(JsonValue::Object(object))
}

fn map_key_to_string(term: Term<'_>, field: &str) -> NifResult<String> {
  match term.get_type() {
    TermType::Atom => term
      .atom_to_string()
      .map_err(|_| error(format!("{field} atom key decode failed"))),
    TermType::Binary => term
      .decode()
      .map_err(|_| error(format!("{field} binary key must be valid utf-8"))),
    _other => Err(error(format!("{field} keys must be strings or atoms"))),
  }
}

#[cfg(test)]
mod tests {
  use super::*;
  use serde_json::json;

  #[test]
  fn execute_bool_classifies_non_boolean_and_execution_errors() {
    let context = build_context(vec![("context", json!({"request": {}}))]).unwrap();

    let non_bool = compile_condition(r#""hello""#).unwrap();
    assert_eq!(
      execute_bool(&non_bool, &context),
      Err(BoolEvalError::ResultType(
        "condition returned string".to_owned()
      ))
    );

    let missing = compile_condition("context.request.enabled").unwrap();
    assert!(matches!(
      execute_bool(&missing, &context),
      Err(BoolEvalError::Execution(_reason))
    ));
  }
}
