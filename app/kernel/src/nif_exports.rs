#![allow(dead_code)]
//! Rustler binding layer for the Elixir runtime.
//!
//! These functions stay thin on purpose: they validate BEAM terms, preserve
//! binary-safe values, and forward all real behavior to `core`.

use rustler::env::OwnedEnv;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Encoder, Env, Error, LocalPid, NifResult, ResourceArc, Term};
use serde_json::Value as JsonValue;
use std::sync::Arc;

use crate::authz;
use crate::core;
use crate::runtime_fabric;
use crate::runtime_fabric::transport::{RouterEvent, RouterHandle};

mod atoms {
    rustler::atoms! {
        runtime_fabric_router_received,
        runtime_fabric_router_file_frame,
        runtime_fabric_router_decode_failed,
        runtime_fabric_router_socket_error,
    }
}

/// Owns the native RuntimeFabric ROUTER handle across BEAM calls.
///
/// Rustler stores this in a `ResourceArc` so Elixir can pass the router between
/// start, send, endpoint, and stop calls without exposing the ZeroMQ socket.
pub struct RuntimeFabricRouterResource(pub RouterHandle);

#[rustler::resource_impl]
impl rustler::Resource for RuntimeFabricRouterResource {}

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

/// Encodes a RuntimeFabric v1 envelope JSON map as protobuf bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn runtime_fabric_encode_envelope_json(envelope_json: Term<'_>) -> NifResult<OwnedBinary> {
    let envelope = decode_json(envelope_json, "envelope_json")?;

    runtime_fabric::encode_envelope_json(envelope)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Decodes RuntimeFabric v1 protobuf bytes into the host JSON envelope shape.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn runtime_fabric_decode_envelope_json(envelope_bytes: Term<'_>) -> NifResult<String> {
    let envelope_bytes = decode_binary(envelope_bytes, "envelope_bytes")?;
    let envelope =
        runtime_fabric::decode_envelope_json(envelope_bytes.as_slice()).map_err(error)?;

    encode_json(envelope)
}

/// Starts a Rust-owned ZeroMQ ROUTER socket for RuntimeFabric traffic.
#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_fabric_router_start(
    endpoint: Term<'_>,
    owner_pid: LocalPid,
    opts_json: Term<'_>,
) -> NifResult<ResourceArc<RuntimeFabricRouterResource>> {
    let endpoint = decode_string(endpoint, "endpoint")?;
    let opts_json = decode_string(opts_json, "opts_json")?;
    let mut config =
        runtime_fabric::transport::RouterConfig::from_json(&opts_json).map_err(error)?;
    config.endpoint = endpoint;

    let sink = Arc::new(move |event| send_router_event(owner_pid, event));
    let handle = runtime_fabric::transport::start_router(config, sink).map_err(error)?;

    Ok(ResourceArc::new(RuntimeFabricRouterResource(handle)))
}

/// Returns the bound ROUTER endpoint, after wildcard port expansion.
#[rustler::nif]
pub fn runtime_fabric_router_endpoint(
    router: ResourceArc<RuntimeFabricRouterResource>,
) -> NifResult<String> {
    Ok(router.0.endpoint().to_string())
}

/// Sends a RuntimeFabric envelope to one ROUTER identity with mandatory routing.
#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_fabric_router_send_mandatory(
    router: ResourceArc<RuntimeFabricRouterResource>,
    transport_route: Term<'_>,
    envelope_json: Term<'_>,
) -> NifResult<String> {
    let transport_route = decode_string(transport_route, "transport_route")?;
    let envelope = decode_json(envelope_json, "envelope_json")?;

    router
        .0
        .send_mandatory(transport_route, envelope)
        .map(|_| "sent_or_queued".to_string())
        .map_err(|error| error_message(error.to_string()))
}

/// Sends raw RuntimeFabric worker-file multipart frames to one ROUTER identity.
#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_fabric_router_send_file_frame(
    router: ResourceArc<RuntimeFabricRouterResource>,
    transport_route: Term<'_>,
    frames: Term<'_>,
) -> NifResult<String> {
    let transport_route = decode_string(transport_route, "transport_route")?;
    let frames = decode_binary_frames(frames, "frames")?;

    router
        .0
        .send_file_frame(transport_route, frames)
        .map(|_| "sent_or_queued".to_string())
        .map_err(|error| error_message(error.to_string()))
}

/// Stops a ROUTER socket owner thread.
#[rustler::nif(schedule = "DirtyIo")]
pub fn runtime_fabric_router_stop(
    router: ResourceArc<RuntimeFabricRouterResource>,
) -> NifResult<bool> {
    router
        .0
        .stop()
        .map(|_| true)
        .map_err(|error| error_message(error.to_string()))
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

/// Computes the non-cryptographic XXH3 128-bit observation fingerprint.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn xxh3_128_hex(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(core::xxh3_128_hex(input.as_slice()))
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

/// Decodes a JWT header without validating the token signature.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_decode_header_json(token: Term<'_>) -> NifResult<String> {
    let token = decode_string(token, "token")?;

    core::jwt_decode_header_json(&token).map_err(error)
}

/// Signs JSON claims with a JSON JWT header and binary key.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_sign_json(
    claims_json: Term<'_>,
    key: Term<'_>,
    header_json: Term<'_>,
) -> NifResult<String> {
    let claims_json = decode_string(claims_json, "claims_json")?;
    let key = decode_binary(key, "key")?;
    let header_json = decode_string(header_json, "header_json")?;

    core::jwt_sign_json(&claims_json, key.as_slice(), &header_json).map_err(error)
}

/// Verifies a JWT with a binary key and JSON validation options.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_verify_json(
    token: Term<'_>,
    key: Term<'_>,
    validation_json: Term<'_>,
) -> NifResult<String> {
    let token = decode_string(token, "token")?;
    let key = decode_binary(key, "key")?;
    let validation_json = decode_string(validation_json, "validation_json")?;

    core::jwt_verify_json(&token, key.as_slice(), &validation_json).map_err(error)
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

/// Decodes a BEAM list of binaries into owned frame bytes.
fn decode_binary_frames(term: Term<'_>, field: &str) -> NifResult<Vec<Vec<u8>>> {
    let frames: Vec<Binary<'_>> = term
        .decode()
        .map_err(|_| error_message(format!("{field} must be a list of binaries")))?;

    Ok(frames
        .into_iter()
        .map(|frame| frame.as_slice().to_vec())
        .collect())
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

fn send_router_event(owner_pid: LocalPid, event: RouterEvent) {
    let mut env = OwnedEnv::new();

    let _ = env.send_and_clear(&owner_pid, |env| match event {
        RouterEvent::Received {
            transport_route,
            authenticated_worker_id,
            authenticated_key_revision,
            envelope_json,
        } => {
            let worker_id = authenticated_worker_id.unwrap_or_default();
            let key_revision = authenticated_key_revision.unwrap_or_default();

            (
                atoms::runtime_fabric_router_received(),
                transport_route,
                worker_id,
                key_revision,
                envelope_json,
            )
                .encode(env)
        }
        RouterEvent::FileFrame {
            transport_route,
            authenticated_worker_id,
            authenticated_key_revision,
            frames,
        } => {
            let worker_id = authenticated_worker_id.unwrap_or_default();
            let key_revision = authenticated_key_revision.unwrap_or_default();
            let frame_terms = encode_binary_frame_list(env, frames);

            (
                atoms::runtime_fabric_router_file_frame(),
                transport_route,
                worker_id,
                key_revision,
                frame_terms,
            )
                .encode(env)
        }
        RouterEvent::DecodeFailed {
            transport_route,
            reason,
        } => (
            atoms::runtime_fabric_router_decode_failed(),
            transport_route,
            reason,
        )
            .encode(env),
        RouterEvent::SocketError { reason } => {
            (atoms::runtime_fabric_router_socket_error(), reason).encode(env)
        }
    });
}

fn encode_binary_frame_list<'a>(env: Env<'a>, frames: Vec<Vec<u8>>) -> Term<'a> {
    let terms: Vec<Term<'a>> = frames
        .into_iter()
        .filter_map(|frame| {
            let mut binary = OwnedBinary::new(frame.len())?;
            binary.as_mut_slice().copy_from_slice(&frame);
            Some(binary.release(env).encode(env))
        })
        .collect();

    terms.encode(env)
}

rustler::init!("Elixir.Ankole.Kernel");
