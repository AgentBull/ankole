#![allow(dead_code)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde_json::Value as JsonValue;
use std::path::Path;
use std::time::Duration;

use crate::authz;
use crate::core;
use crate::runtime_fabric;
use crate::runtime_fabric::transport::{DealerEvent, DealerHandle};

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

/// Encodes a RuntimeFabric v1 envelope into protobuf bytes.
#[napi(
    js_name = "runtimeFabricEncodeEnvelope",
    ts_args_type = "envelope: any"
)]
pub fn js_runtime_fabric_encode_envelope(envelope: JsonValue) -> Result<Buffer> {
    runtime_fabric::encode_envelope_json(envelope)
        .map(Buffer::from)
        .map_err(napi_error)
}

/// Decodes RuntimeFabric v1 protobuf bytes into a JSON-shaped envelope.
#[napi(
    js_name = "runtimeFabricDecodeEnvelope",
    ts_args_type = "bytes: Buffer",
    ts_return_type = "any"
)]
pub fn js_runtime_fabric_decode_envelope(bytes: Buffer) -> Result<JsonValue> {
    runtime_fabric::decode_envelope_json(bytes.as_ref()).map_err(napi_error)
}

/// Bun/Node DEALER-side RuntimeFabric client.
#[napi(js_name = "RuntimeFabricDealer")]
pub struct JsRuntimeFabricDealer {
    handle: DealerHandle,
}

#[napi]
impl JsRuntimeFabricDealer {
    #[napi(constructor)]
    pub fn new(
        endpoint: String,
        identity: String,
        username: String,
        password: String,
    ) -> Result<Self> {
        let config = runtime_fabric::transport::DealerConfig {
            endpoint,
            identity,
            username,
            password,
            sndhwm: None,
            rcvhwm: None,
            linger_ms: None,
            sndtimeo_ms: None,
            rcvtimeo_ms: None,
            poll_interval_ms: None,
            command_timeout_ms: None,
        };

        runtime_fabric::transport::start_dealer(config)
            .map(|handle| Self { handle })
            .map_err(napi_error)
    }

    #[napi(ts_args_type = "envelope: any")]
    pub fn send_envelope(&self, envelope: JsonValue) -> Result<String> {
        self.handle
            .send_envelope(envelope)
            .map(|_| "sent_or_queued".to_string())
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
    }

    #[napi(ts_args_type = "frames: Buffer[]")]
    pub fn send_file_frame(&self, frames: Vec<Buffer>) -> Result<String> {
        let frames = frames.into_iter().map(|frame| frame.to_vec()).collect();

        self.handle
            .send_file_frame(frames)
            .map(|_| "sent_or_queued".to_string())
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
    }

    #[napi]
    pub fn recv(&self, timeout_ms: u32) -> Result<Option<Buffer>> {
        match self
            .handle
            .recv(Duration::from_millis(u64::from(timeout_ms)))
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?
        {
            Some(DealerEvent::Received(payload)) => Ok(Some(Buffer::from(payload))),
            Some(DealerEvent::FileFrame(_frames)) => Err(Error::new(
                Status::GenericFailure,
                "received worker file lane frame; use recvRaw".to_string(),
            )),
            Some(DealerEvent::DecodeFailed(reason)) | Some(DealerEvent::SocketError(reason)) => {
                Err(Error::new(Status::GenericFailure, reason))
            }
            None => Ok(None),
        }
    }

    #[napi(ts_return_type = "Buffer[] | null")]
    pub fn recv_raw(&self, timeout_ms: u32) -> Result<Option<Vec<Buffer>>> {
        recv_raw_output(
            self.handle
                .recv(Duration::from_millis(u64::from(timeout_ms)))
                .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))?,
        )
        .map_err(|error| Error::new(Status::GenericFailure, error))
    }

    #[napi(ts_return_type = "Promise<Buffer[] | null>")]
    pub fn recv_raw_async(&self, timeout_ms: u32) -> AsyncTask<RecvRawTask> {
        AsyncTask::new(RecvRawTask {
            handle: self.handle.clone(),
            timeout_ms,
        })
    }

    #[napi]
    pub fn stop(&self) -> Result<bool> {
        self.handle
            .stop()
            .map(|_| true)
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
    }
}

pub struct RecvRawTask {
    handle: DealerHandle,
    timeout_ms: u32,
}

impl Task for RecvRawTask {
    type Output = Option<RawDealerFrames>;
    type JsValue = Option<Vec<Buffer>>;

    fn compute(&mut self) -> Result<Self::Output> {
        self.handle
            .recv(Duration::from_millis(u64::from(self.timeout_ms)))
            .map_err(|error| Error::new(Status::GenericFailure, error.to_string()))
            .and_then(|event| {
                raw_dealer_frames(event).map_err(|error| Error::new(Status::GenericFailure, error))
            })
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output.map(raw_frames_to_buffers))
    }
}

pub enum RawDealerFrames {
    Envelope(Vec<u8>),
    FileFrame(Vec<Vec<u8>>),
}

fn recv_raw_output(event: Option<DealerEvent>) -> std::result::Result<Option<Vec<Buffer>>, String> {
    Ok(raw_dealer_frames(event)?.map(raw_frames_to_buffers))
}

fn raw_dealer_frames(
    event: Option<DealerEvent>,
) -> std::result::Result<Option<RawDealerFrames>, String> {
    match event {
        Some(DealerEvent::Received(payload)) => Ok(Some(RawDealerFrames::Envelope(payload))),
        Some(DealerEvent::FileFrame(frames)) => Ok(Some(RawDealerFrames::FileFrame(frames))),
        Some(DealerEvent::DecodeFailed(reason)) | Some(DealerEvent::SocketError(reason)) => {
            Err(reason)
        }
        None => Ok(None),
    }
}

fn raw_frames_to_buffers(frames: RawDealerFrames) -> Vec<Buffer> {
    match frames {
        RawDealerFrames::Envelope(payload) => vec![Buffer::from(payload)],
        RawDealerFrames::FileFrame(frames) => frames.into_iter().map(Buffer::from).collect(),
    }
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

/// Computes the non-cryptographic XXH3 128-bit observation fingerprint.
#[napi(js_name = "xxh3File128Hex")]
pub fn js_xxh3_file_128_hex(path: String) -> Result<String> {
    core::xxh3_128_file_hex(Path::new(&path)).map_err(napi_error)
}

/// Computes XXH3 128-bit over a JS string or Buffer.
#[napi(js_name = "xxh3_128_hex", ts_args_type = "data: string | Buffer")]
pub fn js_xxh3_128_hex(data: Either<String, Buffer>) -> String {
    core::xxh3_128_hex(&bytes_from_either(data))
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

/// Decodes a JWT header without validating the token signature.
#[napi(js_name = "jwtDecodeHeader", ts_return_type = "any")]
pub fn js_jwt_decode_header(token: String) -> Result<JsonValue> {
    core::jwt_decode_header_json(&token)
        .and_then(|json| {
            serde_json::from_str(&json)
                .map_err(|error| core::KernelError::new(format!("invalid header JSON: {error}")))
        })
        .map_err(napi_error)
}

/// Signs JSON claims with a JSON JWT header and string-or-buffer key.
#[napi(
    js_name = "jwtSign",
    ts_args_type = "claims: any, key: string | Buffer, header?: any"
)]
pub fn js_jwt_sign(
    claims: JsonValue,
    key: Either<String, Buffer>,
    header: Option<JsonValue>,
) -> Result<String> {
    let claims_json = serde_json::to_string(&claims).map_err(|error| {
        Error::new(
            Status::InvalidArg,
            format!("claims must be JSON serializable: {error}"),
        )
    })?;
    let header_json =
        serde_json::to_string(&header.unwrap_or_else(|| JsonValue::Object(Default::default())))
            .map_err(|error| {
                Error::new(
                    Status::InvalidArg,
                    format!("header must be JSON serializable: {error}"),
                )
            })?;

    core::jwt_sign_json(&claims_json, &bytes_from_either(key), &header_json).map_err(napi_error)
}

/// Verifies a JWT with a string-or-buffer key and JSON validation options.
#[napi(
    js_name = "jwtVerify",
    ts_args_type = "token: string, key: string | Buffer, validation?: any",
    ts_return_type = "any"
)]
pub fn js_jwt_verify(
    token: String,
    key: Either<String, Buffer>,
    validation: Option<JsonValue>,
) -> Result<JsonValue> {
    let validation_json =
        serde_json::to_string(&validation.unwrap_or_else(|| JsonValue::Object(Default::default())))
            .map_err(|error| {
                Error::new(
                    Status::InvalidArg,
                    format!("validation must be JSON serializable: {error}"),
                )
            })?;

    core::jwt_verify_json(&token, &bytes_from_either(key), &validation_json)
        .and_then(|json| {
            serde_json::from_str(&json)
                .map_err(|error| core::KernelError::new(format!("invalid claims JSON: {error}")))
        })
        .map_err(napi_error)
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
