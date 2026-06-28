use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

pub(super) fn object<'a>(value: &'a Value, field: &str) -> KernelResult<&'a Map<String, Value>> {
    match value {
        Value::Object(object) => Ok(object),
        _value => Err(KernelError::new(format!("{field} must be an object"))),
    }
}

pub(super) fn required_value<'a>(
    object: &'a Map<String, Value>,
    field: &str,
) -> KernelResult<&'a Value> {
    object
        .get(field)
        .ok_or_else(|| KernelError::new(format!("{field} is required")))
}

pub(super) fn required_string(object: &Map<String, Value>, field: &str) -> KernelResult<String> {
    match required_value(object, field)? {
        Value::String(value) if !value.trim().is_empty() => Ok(value.clone()),
        _value => Err(KernelError::new(format!(
            "{field} must be a non-empty string"
        ))),
    }
}

pub(super) fn optional_string(
    object: &Map<String, Value>,
    field: &str,
) -> KernelResult<Option<String>> {
    match object.get(field) {
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!("{field} must be a string"))),
    }
}

pub(super) fn required_u64(object: &Map<String, Value>, field: &str) -> KernelResult<u64> {
    optional_u64(object, field)?.ok_or_else(|| KernelError::new(format!("{field} is required")))
}

pub(super) fn optional_u64(object: &Map<String, Value>, field: &str) -> KernelResult<Option<u64>> {
    match object.get(field) {
        Some(Value::Number(value)) => number_to_u64(value, field).map(Some),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!(
            "{field} must be an unsigned integer"
        ))),
    }
}

pub(super) fn required_u32(object: &Map<String, Value>, field: &str) -> KernelResult<u32> {
    let value = required_u64(object, field)?;

    u32::try_from(value).map_err(|_| KernelError::new(format!("{field} is outside u32 range")))
}

pub(super) fn optional_u32(object: &Map<String, Value>, field: &str) -> KernelResult<Option<u32>> {
    optional_u64(object, field)?
        .map(|value| {
            u32::try_from(value)
                .map_err(|_| KernelError::new(format!("{field} is outside u32 range")))
        })
        .transpose()
}

pub(super) fn optional_i64(object: &Map<String, Value>, field: &str) -> KernelResult<Option<i64>> {
    match object.get(field) {
        Some(Value::Number(value)) => number_to_i64(value, field).map(Some),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!("{field} must be an integer"))),
    }
}

fn number_to_u64(value: &serde_json::Number, field: &str) -> KernelResult<u64> {
    if let Some(value) = value.as_u64() {
        return Ok(value);
    }

    match value.as_f64() {
        Some(value)
            if value.is_finite()
                && value.fract() == 0.0
                && value >= 0.0
                && value <= u64::MAX as f64 =>
        {
            Ok(value as u64)
        }
        _value => Err(KernelError::new(format!(
            "{field} must be an unsigned integer"
        ))),
    }
}

fn number_to_i64(value: &serde_json::Number, field: &str) -> KernelResult<i64> {
    if let Some(value) = value.as_i64() {
        return Ok(value);
    }

    match value.as_f64() {
        Some(value)
            if value.is_finite()
                && value.fract() == 0.0
                && value >= i64::MIN as f64
                && value <= i64::MAX as f64 =>
        {
            Ok(value as i64)
        }
        _value => Err(KernelError::new(format!("{field} must be an integer"))),
    }
}

pub(super) fn string_list(value: Option<&Value>) -> KernelResult<Vec<String>> {
    array(value, "string array")?
        .into_iter()
        .map(|value| match value {
            Value::String(text) => Ok(text.clone()),
            _value => Err(KernelError::new("array values must be strings")),
        })
        .collect()
}

pub(super) fn array<'a>(value: Option<&'a Value>, field: &str) -> KernelResult<Vec<&'a Value>> {
    match value {
        Some(Value::Array(values)) => Ok(values.iter().collect()),
        Some(Value::Null) | None => Ok(Vec::new()),
        Some(_value) => Err(KernelError::new(format!("{field} must be an array"))),
    }
}

pub(super) fn optional_message<T>(
    value: Option<&Value>,
    parser: fn(&Value) -> KernelResult<T>,
) -> KernelResult<Option<T>> {
    match value {
        Some(Value::Null) | None => Ok(None),
        Some(value) => parser(value).map(Some),
    }
}

// Stores arbitrary JSON payload fields as bytes inside protobuf messages. This
// keeps the protocol typed where it matters and flexible for provider-specific
// payloads that the kernel should not understand.
pub(super) fn json_bytes(value: Option<&Value>) -> KernelResult<Option<Vec<u8>>> {
    match value {
        Some(Value::Null) | None => Ok(None),
        Some(value) => serde_json::to_vec(value)
            .map(Some)
            .map_err(|error| KernelError::new(format!("failed to encode JSON bytes: {error}"))),
    }
}

// Decodes JSON payload bytes when possible and falls back to a string for
// legacy or debugging payloads that are not valid JSON.
pub(super) fn bytes_to_json(bytes: &[u8]) -> KernelResult<Value> {
    if bytes.is_empty() {
        return Ok(Value::Null);
    }

    match serde_json::from_slice(bytes) {
        Ok(value) => Ok(value),
        Err(_error) => Ok(Value::String(String::from_utf8_lossy(bytes).to_string())),
    }
}

pub(super) fn normalized_enum(value: &Value) -> KernelResult<String> {
    match value {
        Value::String(text) => Ok(normalized_name(text)),
        _value => Err(KernelError::new("enum value must be a string")),
    }
}

// Normalizes enum-like input from both generated names and human-friendly names
// without accepting arbitrary body types.
pub(super) fn normalized_name(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace('-', "_")
}

pub(super) fn json_object<const N: usize>(entries: [(&str, Value); N]) -> Value {
    Value::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect(),
    )
}

pub(super) fn string_array(values: &[String]) -> Value {
    Value::Array(
        values
            .iter()
            .map(|value| Value::from(value.clone()))
            .collect(),
    )
}
