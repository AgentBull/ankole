use jsonwebtoken::{
    Algorithm, DecodingKey, EncodingKey, Header, TokenData, Validation, decode, encode,
};
use serde_json::Value;

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

/// Signs JSON claims with an RSA private key in PEM form.
///
/// Only the RS* algorithm family is accepted here (default RS256); HMAC
/// signing stays on `jwt_sign`. The header JSON takes the same fields as
/// `jwt_sign`, including `kid` for key selection at the receiving side.
pub fn jwt_sign_pem(
    claims_json: &str,
    private_key_pem: &str,
    header_json: &str,
) -> KernelResult<String> {
    let claims = decode_json_object(claims_json, "claims")?;
    let header = jwt_rsa_header_from_json(header_json)?;
    let key = EncodingKey::from_rsa_pem(private_key_pem.as_bytes())
        .map_err(|error| KernelError::new(format!("invalid rsa pem key: {error}")))?;

    encode(&header, &claims, &key)
        .map_err(|error| KernelError::new(format!("jwt sign failed: {error}")))
}

/// Verifies an RSA-signed JWT against a JWK and returns its claims as JSON.
///
/// The key is a single RFC 7517 JWK object with `kty: "RSA"` and base64url
/// `n`/`e` components, as served by provider JWKS documents. Only the RS*
/// algorithm family is accepted here; HMAC verification stays on `jwt_verify`.
pub fn jwt_verify_jwk(token: &str, jwk_json: &str, validation_json: &str) -> KernelResult<String> {
    let validation = jwt_rsa_validation_from_json(validation_json)?;
    let key = decoding_key_from_rsa_jwk(jwk_json)?;

    decode::<Value>(token, &key, &validation)
        .map_err(|error| KernelError::new(format!("jwt verify failed: {error}")))
        .and_then(encode_claims)
}

fn decoding_key_from_rsa_jwk(input: &str) -> KernelResult<DecodingKey> {
    let value = decode_json_object(input, "jwk")?;

    match string_field(&value, &["kty"]).as_deref() {
        Some("RSA") => {
            let modulus = string_field(&value, &["n"])
                .ok_or_else(|| KernelError::new("jwk must contain an n component"))?;
            let exponent = string_field(&value, &["e"])
                .ok_or_else(|| KernelError::new("jwk must contain an e component"))?;

            DecodingKey::from_rsa_components(&modulus, &exponent)
                .map_err(|error| KernelError::new(format!("invalid rsa jwk: {error}")))
        }
        Some(kty) => Err(KernelError::new(format!("unsupported jwk kty: {kty}"))),
        None => Err(KernelError::new("jwk must contain kty")),
    }
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
    header_from_json(input, parse_hmac_algorithm, Algorithm::HS256)
}

fn jwt_rsa_header_from_json(input: &str) -> KernelResult<Header> {
    header_from_json(input, parse_rsa_algorithm, Algorithm::RS256)
}

fn header_from_json(
    input: &str,
    parse_algorithm: fn(&str) -> KernelResult<Algorithm>,
    default_algorithm: Algorithm,
) -> KernelResult<Header> {
    let value = decode_json_object(input, "header")?;
    let algorithm = string_field(&value, &["algorithm", "alg"])
        .as_deref()
        .map(parse_algorithm)
        .transpose()?
        .unwrap_or(default_algorithm);

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
    validation_from_json(input, parse_hmac_algorithm, Algorithm::HS256)
}

fn jwt_rsa_validation_from_json(input: &str) -> KernelResult<Validation> {
    validation_from_json(input, parse_rsa_algorithm, Algorithm::RS256)
}

fn validation_from_json(
    input: &str,
    parse_algorithm: fn(&str) -> KernelResult<Algorithm>,
    default_algorithm: Algorithm,
) -> KernelResult<Validation> {
    let value = decode_json_object(input, "validation")?;
    let algorithms = algorithms_field(&value, parse_algorithm, default_algorithm)?;
    let mut validation = Validation::new(algorithms.first().copied().unwrap_or(default_algorithm));
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

fn algorithms_field(
    value: &Value,
    parse_algorithm: fn(&str) -> KernelResult<Algorithm>,
    default_algorithm: Algorithm,
) -> KernelResult<Vec<Algorithm>> {
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
            .unwrap_or_else(|| Ok(vec![default_algorithm])),
    }
}

fn parse_hmac_algorithm(input: &str) -> KernelResult<Algorithm> {
    match input {
        "HS256" => Ok(Algorithm::HS256),
        "HS384" => Ok(Algorithm::HS384),
        "HS512" => Ok(Algorithm::HS512),
        algorithm => Err(KernelError::new(format!(
            "unsupported jwt algorithm: {algorithm}"
        ))),
    }
}

fn parse_rsa_algorithm(input: &str) -> KernelResult<Algorithm> {
    match input {
        "RS256" => Ok(Algorithm::RS256),
        "RS384" => Ok(Algorithm::RS384),
        "RS512" => Ok(Algorithm::RS512),
        algorithm => Err(KernelError::new(format!(
            "unsupported jwk jwt algorithm: {algorithm}"
        ))),
    }
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
