#![allow(dead_code)]
//! Rustler binding layer for the Elixir runtime.
//!
//! These functions stay thin on purpose: they validate BEAM terms, preserve
//! binary-safe values, and forward all real behavior to `core`.

use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Error, NifResult, Term};
use serde_json::Value as JsonValue;

use crate::authz;
use crate::core;

/// Decrypts an AEAD token for Elixir callers and returns a BEAM binary.
///
/// The function is scheduled on DirtyCpu because runtime cost depends on payload
/// size and cryptographic work should not risk blocking normal BEAM schedulers.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_decrypt(ciphertext: Term<'_>, key: Term<'_>) -> NifResult<OwnedBinary> {
    let ciphertext = decode_string(ciphertext, "ciphertext")?;
    let key = decode_string(key, "key")?;

    core::aead_decrypt(&ciphertext, &key)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encrypts an Elixir binary with the shared AEAD token format.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NifResult<String> {
    let plaintext = decode_binary(plaintext, "plaintext")?;
    let key = decode_string(key, "key")?;

    core::aead_encrypt(plaintext.as_slice(), &key).map_err(error)
}

/// Authorizes one exact action on one concrete resource from a JSON snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_json(snapshot_json: Term<'_>) -> NifResult<String> {
    let snapshot = decode_json(snapshot_json, "snapshot_json")?;
    let decision = authz::authorize_json(snapshot).map_err(error)?;

    encode_json(decision)
}

/// Authorizes every requested action against the same resource from a JSON snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_all_json(snapshot_json: Term<'_>) -> NifResult<String> {
    let snapshot = decode_json(snapshot_json, "snapshot_json")?;
    let decision = authz::authorize_all_json(snapshot).map_err(error)?;

    encode_json(decision)
}

/// Returns whether a CEL authorization condition compiles.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_condition(condition: Term<'_>) -> NifResult<bool> {
    let condition = decode_string(condition, "condition")?;

    authz::validate_condition_source(&condition)
        .map(|_| true)
        .map_err(error)
}

/// Returns whether a resource pattern is valid.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_resource_pattern(pattern: Term<'_>) -> NifResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;

    authz::validate_pattern_source(&pattern)
        .map(|_| true)
        .map_err(error)
}

/// Returns whether a resource pattern matches a concrete resource key.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_match_resource_pattern(pattern: Term<'_>, resource: Term<'_>) -> NifResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;
    let resource = decode_string(resource, "resource")?;

    authz::pattern_matches(&pattern, &resource).map_err(error)
}

/// Converts Unicode text into a best-effort ASCII representation.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn any_ascii(input: Term<'_>) -> NifResult<String> {
    let input = decode_string(input, "input")?;

    Ok(core::any_ascii(&input))
}

/// Decodes Base58 text and returns a BEAM binary instead of a list of integers.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_string(input, "input")?;

    core::base58_decode(&input)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encodes an Elixir binary as Base58 text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_encode(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(core::base58_encode(input.as_slice()))
}

/// Decodes padding-free URL-safe Base64 and returns a BEAM binary.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_string(input, "input")?;

    core::base64_url_safe_decode(&input)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encodes an Elixir binary with URL-safe Base64 and no padding.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_encode(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(core::base64_url_safe_encode(input.as_slice()))
}

/// Hashes an Elixir binary with BLAKE3 and returns the digest in Base58 form.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn bs58_hash(data: Term<'_>, salt: Term<'_>) -> NifResult<String> {
    let data = decode_binary(data, "data")?;
    let salt = decode_optional_string(salt, "salt")?;

    core::bs58_hash(data.as_slice(), salt.as_deref()).map_err(error)
}

/// Computes CRC32 over an Elixir binary, optionally continuing a prior state.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32(input: Term<'_>, initial_state: Term<'_>) -> NifResult<u32> {
    let input = decode_binary(input, "input")?;
    let initial_state = decode_optional_u32(initial_state, "initial_state")?;

    Ok(core::crc32(input.as_slice(), initial_state))
}

/// Computes CRC32 and formats it as lowercase hexadecimal text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32_hex(input: Term<'_>, initial_state: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;
    let initial_state = decode_optional_u32(initial_state, "initial_state")?;

    Ok(core::crc32_hex(input.as_slice(), initial_state))
}

/// Derives a deterministic BLAKE3 sub-key for Elixir callers.
///
/// Binary input is decoded as `Binary` so key seeds can contain arbitrary bytes,
/// not only UTF-8 text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_key(
    key_seed: Term<'_>,
    sub_key_id: Term<'_>,
    extra_context: Term<'_>,
) -> NifResult<String> {
    let key_seed = decode_binary(key_seed, "key_seed")?;
    let sub_key_id = decode_string(sub_key_id, "sub_key_id")?;
    let extra_context = decode_optional_string(extra_context, "extra_context")?;

    Ok(core::derive_key(
        key_seed.as_slice(),
        &sub_key_id,
        extra_context.as_deref(),
    ))
}

/// Generates a random UUIDv4 encoded as lowercase Base36.
#[rustler::nif]
pub fn gen_base36_uuid() -> String {
    core::gen_base36_uuid()
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
#[rustler::nif]
pub fn generate_key() -> String {
    core::generate_key()
}

/// Hashes an Elixir binary with BLAKE3 and returns lowercase hexadecimal text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn generic_hash(data: Term<'_>, salt: Term<'_>) -> NifResult<String> {
    let data = decode_binary(data, "data")?;
    let salt = decode_optional_string(salt, "salt")?;

    core::generic_hash(data.as_slice(), salt.as_deref()).map_err(error)
}

/// Parses and validates an international phone number, returning E.164 text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn phone_normalize_e164(phone: Term<'_>) -> NifResult<String> {
    let phone = decode_string(phone, "phone")?;

    core::phone_normalize_e164(&phone).map_err(error)
}

/// Generates a random UUIDv4 encoded from raw UUID bytes as Base58.
#[rustler::nif]
pub fn gen_short_uuid() -> String {
    core::gen_short_uuid()
}

/// Generates a standard hyphenated UUIDv4 string.
#[rustler::nif]
pub fn gen_uuid() -> String {
    core::gen_uuid()
}

/// Generates a standard hyphenated UUIDv7 string.
#[rustler::nif]
pub fn gen_uuid_v7() -> String {
    core::gen_uuid_v7()
}

/// Copies Rust-owned bytes into an Elixir-owned binary.
///
/// Returning `Vec<u8>` directly would be encoded by Rustler as a list of byte
/// integers. `OwnedBinary` keeps the Elixir API binary-safe and matches caller
/// expectations for decrypted and decoded payloads.
fn binary_from_vec(bytes: Vec<u8>) -> NifResult<OwnedBinary> {
    let mut binary =
        OwnedBinary::new(bytes.len()).ok_or_else(|| error_message("failed to allocate binary"))?;
    binary.as_mut_slice().copy_from_slice(&bytes);

    Ok(binary)
}

/// Decodes a BEAM term as binary and reports the field name on failure.
///
/// The explicit `is_binary` check gives callers a stable, simple error message
/// instead of exposing Rustler's lower-level conversion wording.
fn decode_binary<'a>(term: Term<'a>, field: &str) -> NifResult<Binary<'a>> {
    if !term.is_binary() {
        return Err(error_message(format!("{field} must be a binary")));
    }

    Binary::from_term(term).map_err(|_| error_message(format!("{field} must be a binary")))
}

/// Decodes a JSON string into the host-neutral serde value used by AuthZ.
fn decode_json(term: Term<'_>, field: &str) -> NifResult<JsonValue> {
    let json = decode_string(term, field)?;

    serde_json::from_str(&json)
        .map_err(|reason| error_message(format!("{field} must contain valid JSON: {reason}")))
}

/// Decodes an optional Elixir string, where `nil` maps to `None`.
fn decode_optional_string(term: Term<'_>, field: &str) -> NifResult<Option<String>> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string or nil")))
}

/// Decodes an optional Elixir unsigned 32-bit integer, where `nil` maps to `None`.
fn decode_optional_u32(term: Term<'_>, field: &str) -> NifResult<Option<u32>> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a non-negative integer or nil")))
}

/// Decodes an Elixir string and reports the field name on failure.
fn decode_string(term: Term<'_>, field: &str) -> NifResult<String> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string")))
}

/// Encodes a host-neutral JSON value into a string for Elixir.
fn encode_json(value: JsonValue) -> NifResult<String> {
    serde_json::to_string(&value)
        .map_err(|reason| error_message(format!("failed to encode JSON: {reason}")))
}

/// Converts a host-neutral kernel error into Rustler's NIF error path.
fn error(error: core::KernelError) -> Error {
    error_message(error.to_string())
}

/// Builds a Rustler term error from a message intended for Elixir callers.
fn error_message(message: impl Into<String>) -> Error {
    Error::Term(Box::new(message.into()))
}

rustler::init!("Elixir.Ankole.Kernel");
