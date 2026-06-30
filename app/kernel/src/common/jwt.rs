use jsonwebtoken::{
    Algorithm, DecodingKey, EncodingKey, Header, TokenData, Validation, decode, decode_header,
    encode,
};
use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

/// Signs arbitrary JSON claims with a JSON header description.
pub fn jwt_sign(claims_json: &str, key: &[u8], header_json: &str) -> KernelResult<String> {
    let claims = decode_json_object(claims_json, "claims")?;
    let header = jwt_header_from_json(header_json)?;

    encode(&header, &claims, &EncodingKey::from_secret(key))
        .map_err(|error| KernelError::new(format!("jwt sign failed: {error}")))
}

/// Verifies a JWT and returns its decoded claims as a JSON object string.
pub fn jwt_verify(token: &str, key: &[u8], validation_json: &str) -> KernelResult<String> {
    let validation = jwt_validation_from_json(validation_json)?;

    decode::<Value>(token, &DecodingKey::from_secret(key), &validation)
        .map_err(|error| KernelError::new(format!("jwt verify failed: {error}")))
        .and_then(encode_claims)
}

/// Decodes the JWT header without validating the signature.
pub fn jwt_decode_header(token: &str) -> KernelResult<String> {
    decode_header(token)
        .map_err(|error| KernelError::new(format!("jwt header decode failed: {error}")))
        .map(header_json)
        .and_then(encode_json)
}

fn decode_json_object(input: &str, field: &str) -> KernelResult<Value> {
    let value = serde_json::from_str::<Value>(input)
        .map_err(|error| KernelError::new(format!("{field} must contain valid JSON: {error}")))?;

    match value {
        Value::Object(_) => Ok(value),
        _ => Err(KernelError::new(format!("{field} must be a JSON object"))),
    }
}

fn jwt_header_from_json(input: &str) -> KernelResult<Header> {
    let value = decode_json_object(input, "header")?;
    let algorithm = string_field(&value, &["algorithm", "alg"])
        .as_deref()
        .map(parse_algorithm)
        .transpose()?
        .unwrap_or(Algorithm::HS256);

    let mut header = Header::new(algorithm);
    header.typ = string_field(&value, &["type", "typ"]).or_else(|| Some("JWT".to_string()));
    header.cty = string_field(&value, &["content_type", "cty"]);
    header.kid = string_field(&value, &["key_id", "kid"]);
    header.jku = string_field(&value, &["json_key_url", "jku"]);
    header.x5u = string_field(&value, &["x5_url", "x5u"]);
    header.x5c = string_array_field(&value, &["x5_cert_chain", "x5c"])?;
    header.x5t = string_field(&value, &["x5_cert_thumbprint", "x5t"]);
    header.x5t_s256 = string_field(&value, &["x5t_s256_cert_thumbprint", "x5t#S256"]);

    Ok(header)
}

fn jwt_validation_from_json(input: &str) -> KernelResult<Validation> {
    let value = decode_json_object(input, "validation")?;
    let algorithms = algorithms_field(&value)?;
    let mut validation = Validation::new(algorithms.first().copied().unwrap_or(Algorithm::HS256));
    validation.algorithms = algorithms;

    match string_array_field(&value, &["aud", "audience"])? {
        Some(audience) => validation.set_audience(&audience),
        None => validation.validate_aud = false,
    }

    if let Some(issuer) = string_array_field(&value, &["iss", "issuer"])? {
        validation.set_issuer(&issuer);
    }

    if let Some(required) = string_array_field(&value, &["required_spec_claims"])? {
        validation.set_required_spec_claims(&required);
    }

    if let Some(leeway) = u64_field(&value, "leeway")? {
        validation.leeway = leeway;
    }

    if let Some(validate_exp) = bool_field(&value, "validate_exp")? {
        validation.validate_exp = validate_exp;
    }

    if let Some(validate_nbf) = bool_field(&value, "validate_nbf")? {
        validation.validate_nbf = validate_nbf;
    }

    if let Some(subject) = string_field(&value, &["sub", "subject"]) {
        validation.sub = Some(subject);
    }

    if matches!(bool_field(&value, "validate_signature")?, Some(false)) {
        return Err(KernelError::new(
            "validate_signature=false is not supported by jwt_verify",
        ));
    }

    Ok(validation)
}

fn algorithms_field(value: &Value) -> KernelResult<Vec<Algorithm>> {
    match value.get("algorithms") {
        Some(Value::Array(values)) => values
            .iter()
            .map(|value| match value {
                Value::String(algorithm) => parse_algorithm(algorithm),
                _ => Err(KernelError::new("algorithms must contain strings")),
            })
            .collect(),
        Some(_) => Err(KernelError::new("algorithms must be an array")),
        None => string_field(value, &["algorithm", "alg"])
            .map(|algorithm| parse_algorithm(&algorithm).map(|algorithm| vec![algorithm]))
            .unwrap_or_else(|| Ok(vec![Algorithm::HS256])),
    }
}

fn parse_algorithm(input: &str) -> KernelResult<Algorithm> {
    match input {
        "HS256" => Ok(Algorithm::HS256),
        "HS384" => Ok(Algorithm::HS384),
        "HS512" => Ok(Algorithm::HS512),
        algorithm => Err(KernelError::new(format!(
            "unsupported jwt algorithm: {algorithm}"
        ))),
    }
}

fn header_json(header: Header) -> Value {
    let mut object = Map::new();
    object.insert(
        "algorithm".to_string(),
        Value::String(algorithm_name(header.alg)),
    );
    insert_optional_string(&mut object, "type", header.typ);
    insert_optional_string(&mut object, "content_type", header.cty);
    insert_optional_string(&mut object, "key_id", header.kid);
    insert_optional_string(&mut object, "json_key_url", header.jku);
    insert_optional_string(&mut object, "x5_url", header.x5u);
    insert_optional_array(&mut object, "x5_cert_chain", header.x5c);
    insert_optional_string(&mut object, "x5_cert_thumbprint", header.x5t);
    insert_optional_string(&mut object, "x5t_s256_cert_thumbprint", header.x5t_s256);

    Value::Object(object)
}

fn encode_claims(token: TokenData<Value>) -> KernelResult<String> {
    match token.claims {
        Value::Object(_) => encode_json(token.claims),
        _ => Err(KernelError::new("jwt claims must be a JSON object")),
    }
}

fn encode_json(value: Value) -> KernelResult<String> {
    serde_json::to_string(&value)
        .map_err(|error| KernelError::new(format!("failed to encode JSON: {error}")))
}

fn string_field(value: &Value, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| match value.get(*name) {
        Some(Value::String(value)) => Some(value.clone()),
        _ => None,
    })
}

fn string_array_field(value: &Value, names: &[&str]) -> KernelResult<Option<Vec<String>>> {
    for name in names {
        match value.get(*name) {
            Some(Value::Array(values)) => {
                let strings = values
                    .iter()
                    .map(|value| match value {
                        Value::String(value) => Ok(value.clone()),
                        _ => Err(KernelError::new(format!("{name} must contain strings"))),
                    })
                    .collect::<KernelResult<Vec<_>>>()?;

                return Ok(Some(strings));
            }
            Some(Value::String(value)) => return Ok(Some(vec![value.clone()])),
            Some(_) => return Err(KernelError::new(format!("{name} must be a string array"))),
            None => {}
        }
    }

    Ok(None)
}

fn bool_field(value: &Value, name: &str) -> KernelResult<Option<bool>> {
    match value.get(name) {
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(KernelError::new(format!("{name} must be a boolean"))),
        None => Ok(None),
    }
}

fn u64_field(value: &Value, name: &str) -> KernelResult<Option<u64>> {
    match value.get(name) {
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| KernelError::new(format!("{name} must be a non-negative integer"))),
        Some(_) => Err(KernelError::new(format!("{name} must be an integer"))),
        None => Ok(None),
    }
}

fn insert_optional_string(object: &mut Map<String, Value>, key: &str, value: Option<String>) {
    if let Some(value) = value {
        object.insert(key.to_string(), Value::String(value));
    }
}

fn insert_optional_array(object: &mut Map<String, Value>, key: &str, value: Option<Vec<String>>) {
    if let Some(values) = value {
        object.insert(
            key.to_string(),
            Value::Array(values.into_iter().map(Value::String).collect()),
        );
    }
}

fn algorithm_name(algorithm: Algorithm) -> String {
    match algorithm {
        Algorithm::HS256 => "HS256",
        Algorithm::HS384 => "HS384",
        Algorithm::HS512 => "HS512",
        _ => "unsupported",
    }
    .to_string()
}
