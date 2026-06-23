#![allow(dead_code)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde_json::Value as JsonValue;

use crate::authz;
use crate::core;

/// Converts a core error into the generic N-API error shape.
///
/// The kernel does not define JS-specific error classes yet. Preserving the
/// message keeps the public JS behavior aligned with the Elixir binding.
fn napi_error(error: core::KernelError) -> Error {
    Error::new(Status::GenericFailure, error.to_string())
}

/// Normalizes JS string-or-Buffer input into bytes for the shared Rust core.
///
/// Strings become UTF-8 bytes. That mirrors how JavaScript already represents
/// text and keeps binary-safe paths available through `Buffer`.
fn bytes_from_either(input: Either<String, Buffer>) -> Vec<u8> {
    match input {
        Either::A(value) => value.into_bytes(),
        Either::B(value) => value.to_vec(),
    }
}

/// Converts napi-rs optional string arguments into Rust `Option<String>`.
///
/// napi-rs represents an omitted optional value as unit in this signature style,
/// so the binding normalizes it before calling the host-neutral core function.
fn optional_string(input: Either<String, ()>) -> Option<String> {
    match input {
        Either::A(value) => Some(value),
        Either::B(_) => None,
    }
}

/// Decrypts a compact AEAD token and returns the plaintext as a Buffer.
///
/// Returning a Buffer avoids forcing arbitrary plaintext bytes through UTF-8.
#[napi]
pub fn aead_decrypt(cipher: String, key: String) -> Result<Buffer> {
    core::aead_decrypt(&cipher, &key)
        .map(Buffer::from)
        .map_err(napi_error)
}

/// Encrypts a JS string or Buffer with the shared AEAD token format.
#[napi]
pub fn aead_encrypt(plain: Either<String, Buffer>, key: String) -> Result<String> {
    core::aead_encrypt(&bytes_from_either(plain), &key).map_err(napi_error)
}

/// Authorizes one exact action on one concrete resource.
#[napi(ts_args_type = "snapshot: any", ts_return_type = "any")]
pub fn authz_authorize(snapshot: JsonValue) -> Result<JsonValue> {
    authz::authorize_json(snapshot).map_err(napi_error)
}

/// Authorizes every requested action against the same concrete resource.
#[napi(ts_args_type = "snapshot: any", ts_return_type = "any")]
pub fn authz_authorize_all(snapshot: JsonValue) -> Result<JsonValue> {
    authz::authorize_all_json(snapshot).map_err(napi_error)
}

/// Returns whether a CEL authorization condition compiles.
#[napi]
pub fn authz_validate_condition(condition: String) -> Result<bool> {
    authz::validate_condition_source(&condition)
        .map(|_| true)
        .map_err(napi_error)
}

/// Returns whether a resource pattern is valid.
#[napi]
pub fn authz_validate_resource_pattern(pattern: String) -> Result<bool> {
    authz::validate_pattern_source(&pattern)
        .map(|_| true)
        .map_err(napi_error)
}

/// Returns whether a resource pattern matches a concrete resource key.
#[napi]
pub fn authz_match_resource_pattern(pattern: String, resource: String) -> Result<bool> {
    authz::pattern_matches(&pattern, &resource).map_err(napi_error)
}

/// Converts Unicode text into a best-effort ASCII representation for JS callers.
#[napi(js_name = "anyAscii")]
pub fn js_any_ascii(input: String) -> String {
    core::any_ascii(&input)
}

/// Decodes Base58 text and returns the raw bytes as a Buffer.
#[napi]
pub fn base58_decode(input: String) -> Result<Buffer> {
    core::base58_decode(&input)
        .map(Buffer::from)
        .map_err(napi_error)
}

/// Encodes a JS string or Buffer as Base58 text.
#[napi]
pub fn base58_encode(input: Either<String, Buffer>) -> String {
    core::base58_encode(&bytes_from_either(input))
}

/// Decodes padding-free URL-safe Base64 and returns the raw bytes as a Buffer.
#[napi(js_name = "base64UrlSafeDecode")]
pub fn js_base64_url_safe_decode(input: String) -> Result<Buffer> {
    core::base64_url_safe_decode(&input)
        .map(Buffer::from)
        .map_err(napi_error)
}

/// Encodes a JS string or Buffer with URL-safe Base64 and no padding.
#[napi(js_name = "base64UrlSafeEncode")]
pub fn js_base64_url_safe_encode(input: Either<String, Buffer>) -> String {
    core::base64_url_safe_encode(&bytes_from_either(input))
}

/// Hashes data with BLAKE3 and returns the digest in Base58 form.
///
/// The custom TypeScript argument annotation keeps the generated declaration
/// ergonomic while the Rust signature still uses napi-rs `Either` for decoding.
#[napi(ts_args_type = "data: string | Buffer, salt?: string")]
pub fn bs58_hash(data: Either<String, Buffer>, salt: Either<String, ()>) -> Result<String> {
    let salt = optional_string(salt);

    core::bs58_hash(&bytes_from_either(data), salt.as_deref()).map_err(napi_error)
}

/// Computes CRC32 over a Buffer-like value or string.
///
/// This signature allows borrowed byte slices for binary input so large Buffers
/// do not need the extra allocation used by the more general `bytes_from_either`
/// helper.
#[napi]
pub fn crc32(input: Either<&[u8], String>, initial_state: Option<u32>) -> u32 {
    core::crc32(input.as_ref(), initial_state)
}

/// Computes CRC32 and formats it as lowercase hexadecimal text.
#[napi]
pub fn crc32_hex(input: Either<&[u8], String>, initial_state: Option<u32>) -> String {
    core::crc32_hex(input.as_ref(), initial_state)
}

/// Derives a deterministic BLAKE3 sub-key for JS callers.
///
/// `context` stays optional at the JS boundary, but the core always receives an
/// explicit `Option` so omitted and empty-string contexts remain distinguishable.
#[napi(ts_args_type = "keySeed: string | Buffer, subKeyId: string, context?: string")]
pub fn derive_key(
    key_seed: Either<String, Buffer>,
    sub_key_id: String,
    extra_context: Either<String, ()>,
) -> String {
    let extra_context = optional_string(extra_context);

    core::derive_key(
        &bytes_from_either(key_seed),
        &sub_key_id,
        extra_context.as_deref(),
    )
}

/// Generates a random UUIDv4 encoded as lowercase Base36.
#[napi(js_name = "genBase36UUID")]
pub fn gen_base36_uuid() -> String {
    core::gen_base36_uuid()
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
#[napi]
pub fn generate_key() -> String {
    core::generate_key()
}

/// Hashes data with BLAKE3 and returns the digest as lowercase hex text.
#[napi(ts_args_type = "data: string | Buffer, salt?: string")]
pub fn generic_hash(data: Either<String, Buffer>, salt: Either<String, ()>) -> Result<String> {
    let salt = optional_string(salt);

    core::generic_hash(&bytes_from_either(data), salt.as_deref()).map_err(napi_error)
}

/// Parses and validates an international phone number, returning E.164 text.
#[napi(js_name = "phoneNormalizeE164")]
pub fn js_phone_normalize_e164(phone: String) -> Result<String> {
    core::phone_normalize_e164(&phone).map_err(napi_error)
}

/// Generates a random UUIDv4 encoded from raw UUID bytes as Base58.
#[napi(js_name = "genShortUUID")]
pub fn gen_short_uuid() -> String {
    core::gen_short_uuid()
}

/// Generates a standard hyphenated UUIDv4 string.
#[napi(js_name = "genUUID")]
pub fn gen_uuid() -> String {
    core::gen_uuid()
}

/// Generates a standard hyphenated UUIDv7 string.
#[napi(js_name = "genUUIDv7")]
pub fn gen_uuid_v7() -> String {
    core::gen_uuid_v7()
}
