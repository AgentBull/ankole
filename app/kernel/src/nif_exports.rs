//! Rustler binding layer for the Elixir runtime.
//!
//! These functions stay thin on purpose: they validate BEAM terms, preserve
//! binary-safe values, and forward real behavior to host-neutral modules.

use rustler::env::{OwnedEnv, SavedTerm};
use rustler::types::atom as rustler_atom;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Encoder, Env, Error, LocalPid, Monitor, NifResult, ResourceArc, Term};
use serde_json::Value as JsonValue;
use std::sync::{Arc, Mutex};

use crate::authz;
use crate::common;
use crate::runtime_fabric;
use crate::runtime_fabric::transport::{RouterEvent, RouterHandle};
use crate::signals_gateway;
use crate::universal_ai_client;

mod atoms {
    rustler::atoms! {
        ok,
        runtime_fabric_router_received,
        runtime_fabric_router_file_frame,
        runtime_fabric_router_decode_failed,
        runtime_fabric_router_socket_error,
        universal_ai_client,
        ready,
        chunk,
        sse,
        websocket_text,
        done,
        error,
        aborted,
    }
}

/// Owns the native RuntimeFabric ROUTER handle across BEAM calls.
///
/// Rustler stores this in a `ResourceArc` so Elixir can pass the router between
/// start, send, endpoint, and stop calls without exposing the ZeroMQ socket.
pub struct RuntimeFabricRouterResource(pub RouterHandle);

#[rustler::resource_impl]
impl rustler::Resource for RuntimeFabricRouterResource {}

/// Owns a native UniversalAIClient stream task across BEAM demand calls.
pub struct UniversalAIClientStreamResource(pub universal_ai_client::StreamHandle);

impl std::panic::RefUnwindSafe for UniversalAIClientStreamResource {}
impl std::panic::UnwindSafe for UniversalAIClientStreamResource {}

#[rustler::resource_impl]
impl rustler::Resource for UniversalAIClientStreamResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        let _ = self.0.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        let _ = self.0.cancel();
    }
}

/// Holds the Elixir stream ref in an owned environment so Rust-owned async tasks
/// can tag messages without keeping a BEAM scheduler thread occupied.
struct BeamStreamRef {
    env: OwnedEnv,
    term: SavedTerm,
}

impl BeamStreamRef {
    fn new(term: Term<'_>) -> Self {
        let env = OwnedEnv::new();
        Self {
            term: env.save(term),
            env,
        }
    }
}

impl Encoder for BeamStreamRef {
    fn encode<'a>(&self, dest: Env<'a>) -> Term<'a> {
        self.env.run(|env| self.term.load(env).in_env(dest))
    }
}

/// Decrypts an AEAD token for Elixir callers and returns a BEAM binary.
///
/// The function is scheduled on DirtyCpu because runtime cost depends on payload
/// size and cryptographic work should not risk blocking normal BEAM schedulers.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_decrypt(ciphertext: Term<'_>, key: Term<'_>) -> NifResult<OwnedBinary> {
    let ciphertext = decode_string(ciphertext, "ciphertext")?;
    let key = decode_string(key, "key")?;

    common::aead_decrypt(&ciphertext, &key)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encrypts an Elixir binary with the shared AEAD token format.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NifResult<String> {
    let plaintext = decode_binary(plaintext, "plaintext")?;
    let key = decode_string(key, "key")?;

    common::aead_encrypt(plaintext.as_slice(), &key).map_err(error)
}

/// Authorizes one exact action on one concrete resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_nif(snapshot: Term<'_>) -> NifResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = authz::authorize_value(snapshot).map_err(error)?;

    encode_json(decision)
}

/// Authorizes every requested action against the same resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_all_nif(snapshot: Term<'_>) -> NifResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = authz::authorize_all_value(snapshot).map_err(error)?;

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

/// Returns whether a SignalsGateway CEL admission filter compiles.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_gateway_validate_filter(filter_source: Term<'_>) -> NifResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;

    signals_gateway::validate_filter_source(&filter_source)
        .map(|_| true)
        .map_err(error)
}

/// Evaluates a SignalsGateway CEL admission filter from an encoded context.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_gateway_filter_match_nif(
    filter_source: Term<'_>,
    context: Term<'_>,
) -> NifResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;
    let context = decode_json(context, "context")?;

    signals_gateway::evaluate_filter(&filter_source, context).map_err(error)
}

/// Returns whether a resource pattern is valid.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_resource_pattern(pattern: Term<'_>) -> NifResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;

    authz::validate_pattern_source(&pattern)
        .map(|_| true)
        .map_err(error)
}

/// Encodes a RuntimeFabric v1 envelope map as protobuf bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn runtime_fabric_encode_envelope_nif(envelope: Term<'_>) -> NifResult<OwnedBinary> {
    let envelope = decode_json(envelope, "envelope")?;

    runtime_fabric::encode_envelope(envelope)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Decodes RuntimeFabric v1 protobuf bytes into the host envelope shape.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn runtime_fabric_decode_envelope_nif(envelope_bytes: Term<'_>) -> NifResult<String> {
    let envelope_bytes = decode_binary(envelope_bytes, "envelope_bytes")?;
    let envelope = runtime_fabric::decode_envelope(envelope_bytes.as_slice()).map_err(error)?;

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

/// Opens a native UniversalAIClient stream from a prepared request spec.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_open_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    stream_ref: Term<'a>,
) -> NifResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let stream_ref = Arc::new(Mutex::new(BeamStreamRef::new(stream_ref)));
    let sink = {
        let stream_ref = Arc::clone(&stream_ref);
        Arc::new(move |event| {
            send_universal_ai_client_event(owner_pid, Arc::clone(&stream_ref), event)
        })
    };

    match universal_ai_client::start_stream(&encoded_spec, sink) {
        Ok(handle) => {
            let resource = ResourceArc::new(UniversalAIClientStreamResource(handle));
            let _ = resource.monitor(Some(env), &owner_pid);
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(reason) => Ok((
            atoms::error(),
            encode_json_value(
                env,
                &serde_json::json!({
                    "code": "stream_open_failed",
                    "stage": "open",
                    "message": reason.to_string()
                }),
            ),
        )
            .encode(env)),
    }
}

/// Grants downstream chunk credit to a native UniversalAIClient stream.
#[rustler::nif]
pub fn universal_ai_client_read_nif(
    stream: ResourceArc<UniversalAIClientStreamResource>,
    count: Term<'_>,
) -> NifResult<rustler::Atom> {
    let count = decode_u64(count, "count")?;
    stream.0.read(count).map_err(error)?;
    Ok(atoms::ok())
}

/// Cancels a native UniversalAIClient stream.
#[rustler::nif]
pub fn universal_ai_client_cancel_nif(
    stream: ResourceArc<UniversalAIClientStreamResource>,
) -> NifResult<rustler::Atom> {
    stream.0.cancel().map_err(error)?;
    Ok(atoms::ok())
}

/// Sends one non-streaming UniversalAIClient model request.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_model_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
) -> NifResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;

    match universal_ai_client::send_model_request(&encoded_spec) {
        Ok(response) => Ok((atoms::ok(), encode_json_value(env, &response)).encode(env)),
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
}

/// Sends one raw UniversalAIClient HTTP request without model normalization.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_raw_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
) -> NifResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;

    match universal_ai_client::send_raw_request(&encoded_spec) {
        Ok(response) => Ok((atoms::ok(), encode_json_value(env, &response)).encode(env)),
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
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

    Ok(common::any_ascii(&input))
}

/// Decodes Base58 text and returns a BEAM binary instead of a list of integers.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_string(input, "input")?;

    common::base58_decode(&input)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encodes an Elixir binary as Base58 text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base58_encode(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(common::base58_encode(input.as_slice()))
}

/// Decodes padding-free URL-safe Base64 and returns a BEAM binary.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_string(input, "input")?;

    common::base64_url_safe_decode(&input)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Encodes an Elixir binary with URL-safe Base64 and no padding.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn base64_url_safe_encode(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(common::base64_url_safe_encode(input.as_slice()))
}

/// Hashes an Elixir binary with BLAKE3 and returns the digest in Base58 form.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn bs58_hash(data: Term<'_>, salt: Term<'_>) -> NifResult<String> {
    let data = decode_binary(data, "data")?;
    let salt = decode_optional_string(salt, "salt")?;

    common::bs58_hash(data.as_slice(), salt.as_deref()).map_err(error)
}

/// Computes CRC32 over an Elixir binary, optionally continuing a prior state.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32(input: Term<'_>, initial_state: Term<'_>) -> NifResult<u32> {
    let input = decode_binary(input, "input")?;
    let initial_state = decode_optional_u32(initial_state, "initial_state")?;

    Ok(common::crc32(input.as_slice(), initial_state))
}

/// Computes CRC32 and formats it as lowercase hexadecimal text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn crc32_hex(input: Term<'_>, initial_state: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;
    let initial_state = decode_optional_u32(initial_state, "initial_state")?;

    Ok(common::crc32_hex(input.as_slice(), initial_state))
}

/// Computes the non-cryptological XXH3 128-bit observation fingerprint.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn xxh3_128_hex(input: Term<'_>) -> NifResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(common::xxh3_128_hex(input.as_slice()))
}

/// Compresses one worker-file lane block into a self-contained zstd frame.
///
/// Each call produces one independent frame, so the wire is a concatenation of
/// frames that a receiver can decompress per chunk. `level` follows the zstd
/// CLI scale and is not negotiated on the wire.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn zstd_compress_block(input: Term<'_>, level: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_binary(input, "input")?;
    let level = decode_i32(level, "level")?;

    common::zstd_compress_block(input.as_slice(), level)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Decompresses one worker-file lane zstd frame with a hard output bound.
///
/// `max_out` rejects oversized payloads, capping zip-bomb exposure at one block.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn zstd_decompress_block(input: Term<'_>, max_out: Term<'_>) -> NifResult<OwnedBinary> {
    let input = decode_binary(input, "input")?;
    let max_out = decode_u64(max_out, "max_out")?;

    common::zstd_decompress_block(
        input.as_slice(),
        usize::try_from(max_out).unwrap_or(usize::MAX),
    )
    .map_err(error)
    .and_then(binary_from_vec)
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

    Ok(common::derive_key(
        key_seed.as_slice(),
        &sub_key_id,
        extra_context.as_deref(),
    ))
}

/// Decodes a JWT header without validating the token signature.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_decode_header_nif(token: Term<'_>) -> NifResult<String> {
    let token = decode_string(token, "token")?;

    common::jwt_decode_header(&token).map_err(error)
}

/// Signs claims with a JWT header and binary key.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_sign_nif(claims: Term<'_>, key: Term<'_>, header: Term<'_>) -> NifResult<String> {
    let claims = decode_string(claims, "claims")?;
    let key = decode_binary(key, "key")?;
    let header = decode_string(header, "header")?;

    common::jwt_sign(&claims, key.as_slice(), &header).map_err(error)
}

/// Verifies a JWT with a binary key and validation options.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_verify_nif(token: Term<'_>, key: Term<'_>, validation: Term<'_>) -> NifResult<String> {
    let token = decode_string(token, "token")?;
    let key = decode_binary(key, "key")?;
    let validation = decode_string(validation, "validation")?;

    common::jwt_verify(&token, key.as_slice(), &validation).map_err(error)
}

/// Generates a random UUIDv4 encoded as lowercase Base36.
#[rustler::nif]
pub fn gen_base36_uuid() -> String {
    common::gen_base36_uuid()
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
#[rustler::nif]
pub fn generate_key() -> String {
    common::generate_key()
}

/// Hashes an Elixir binary with BLAKE3 and returns lowercase hexadecimal text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn generic_hash(data: Term<'_>, salt: Term<'_>) -> NifResult<String> {
    let data = decode_binary(data, "data")?;
    let salt = decode_optional_string(salt, "salt")?;

    common::generic_hash(data.as_slice(), salt.as_deref()).map_err(error)
}

/// Parses and validates an international phone number, returning E.164 text.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn phone_normalize_e164(phone: Term<'_>) -> NifResult<String> {
    let phone = decode_string(phone, "phone")?;

    common::phone_normalize_e164(&phone).map_err(error)
}

/// Generates a random UUIDv4 encoded from raw UUID bytes as Base58.
#[rustler::nif]
pub fn gen_short_uuid() -> String {
    common::gen_short_uuid()
}

/// Generates a standard hyphenated UUIDv4 string.
#[rustler::nif]
pub fn gen_uuid() -> String {
    common::gen_uuid()
}

/// Generates a standard hyphenated UUIDv7 string.
#[rustler::nif]
pub fn gen_uuid_v7() -> String {
    common::gen_uuid_v7()
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

/// Decodes a non-negative 64-bit integer.
fn decode_u64(term: Term<'_>, field: &str) -> NifResult<u64> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a non-negative integer")))
}

/// Decodes a signed 32-bit integer.
fn decode_i32(term: Term<'_>, field: &str) -> NifResult<i32> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be an integer")))
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
fn error(error: common::KernelError) -> Error {
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
            match encode_binary_frame_list(env, frames) {
                Ok(frame_terms) => (
                    atoms::runtime_fabric_router_file_frame(),
                    transport_route,
                    worker_id,
                    key_revision,
                    frame_terms,
                )
                    .encode(env),
                Err(reason) => (atoms::runtime_fabric_router_socket_error(), reason).encode(env),
            }
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

fn send_universal_ai_client_event(
    owner_pid: LocalPid,
    stream_ref: Arc<Mutex<BeamStreamRef>>,
    event: universal_ai_client::StreamEvent,
) {
    let mut env = OwnedEnv::new();

    let _ = env.send_and_clear(&owner_pid, |env| {
        let stream_ref = stream_ref
            .lock()
            .map(|stream_ref| stream_ref.encode(env))
            .unwrap_or_else(|_| "stream_ref_unavailable".encode(env));

        match event {
            universal_ai_client::StreamEvent::Ready(meta) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::ready(),
                encode_json_value(env, &meta),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Chunk { seq, kind, bytes } => {
                match binary_term(env, bytes) {
                    Ok(binary) => (
                        atoms::universal_ai_client(),
                        stream_ref,
                        atoms::chunk(),
                        seq,
                        downstream_kind_atom(kind),
                        binary,
                    )
                        .encode(env),
                    Err(reason) => (
                        atoms::universal_ai_client(),
                        stream_ref,
                        atoms::error(),
                        encode_json_value(
                            env,
                            &serde_json::json!({
                                "code": "chunk_encoding_failed",
                                "stage": "beam",
                                "message": reason
                            }),
                        ),
                    )
                        .encode(env),
                }
            }
            universal_ai_client::StreamEvent::Done(summary) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::done(),
                encode_json_value(env, &summary),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Error(error) => (
                atoms::universal_ai_client(),
                stream_ref,
                atoms::error(),
                encode_json_value(env, &error),
            )
                .encode(env),
            universal_ai_client::StreamEvent::Aborted => {
                (atoms::universal_ai_client(), stream_ref, atoms::aborted()).encode(env)
            }
        }
    });
}

fn downstream_kind_atom(kind: universal_ai_client::DownstreamKind) -> rustler::Atom {
    match kind {
        universal_ai_client::DownstreamKind::Sse => atoms::sse(),
        universal_ai_client::DownstreamKind::WebsocketText => atoms::websocket_text(),
    }
}

fn binary_term<'a>(env: Env<'a>, bytes: Vec<u8>) -> Result<Term<'a>, String> {
    let Some(mut binary) = OwnedBinary::new(bytes.len()) else {
        return Err("failed to allocate universal AI client chunk binary".to_string());
    };

    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env).encode(env))
}

fn encode_json_value<'a>(env: Env<'a>, value: &JsonValue) -> Term<'a> {
    match value {
        JsonValue::Null => rustler_atom::nil().encode(env),
        JsonValue::Bool(value) => value.encode(env),
        JsonValue::Number(number) => {
            if let Some(value) = number.as_i64() {
                value.encode(env)
            } else if let Some(value) = number.as_u64() {
                value.encode(env)
            } else if let Some(value) = number.as_f64() {
                value.encode(env)
            } else {
                rustler_atom::nil().encode(env)
            }
        }
        JsonValue::String(value) => value.encode(env),
        JsonValue::Array(values) => values
            .iter()
            .map(|value| encode_json_value(env, value))
            .collect::<Vec<_>>()
            .encode(env),
        JsonValue::Object(values) => {
            let mut map = Term::map_new(env);
            for (key, value) in values {
                map = map
                    .map_put(key.as_str(), encode_json_value(env, value))
                    .unwrap_or(map);
            }
            map
        }
    }
}

fn encode_binary_frame_list<'a>(env: Env<'a>, frames: Vec<Vec<u8>>) -> Result<Term<'a>, String> {
    let mut terms: Vec<Term<'a>> = Vec::with_capacity(frames.len());

    for frame in frames {
        let Some(mut binary) = OwnedBinary::new(frame.len()) else {
            return Err("failed to allocate runtime fabric binary frame".to_string());
        };

        binary.as_mut_slice().copy_from_slice(&frame);
        terms.push(binary.release(env).encode(env));
    }

    Ok(terms.encode(env))
}

rustler::init!("Elixir.Ankole.Kernel");
