#![allow(dead_code)]

use napi::bindgen_prelude::*;
use napi_derive::napi;
use serde_json::Value as JsonValue;
use std::path::Path;
use std::time::Duration;

use crate::authz;
use crate::common;
use crate::runtime_fabric;
use crate::runtime_fabric::transport::{DealerEvent, DealerHandle, TransportError};
use crate::signals_gateway;

/// Converts a common kernel error into the generic N-API error shape.
///
/// The kernel does not define JS-specific error classes yet. Preserving the
/// message keeps the public JS behavior aligned with the Elixir binding.
fn napi_error(error: common::KernelError) -> Error {
    Error::new(Status::GenericFailure, error.to_string())
}

#[napi(js_name = "estimateO200kBaseTokens")]
pub fn estimate_o200k_base_tokens(text: String) -> u32 {
    common::estimate_o200k_base_tokens(&text).min(u32::MAX.into()) as u32
}

fn runtime_fabric_error(error: TransportError) -> Error {
    Error::new(Status::GenericFailure, error.ffi_message())
}

/// Authorizes one exact action on one concrete resource.
#[napi(ts_args_type = "snapshot: any", ts_return_type = "any")]
pub fn authz_authorize(snapshot: JsonValue) -> Result<JsonValue> {
    authz::authorize_value(snapshot).map_err(napi_error)
}

/// Authorizes every requested action against the same concrete resource.
#[napi(ts_args_type = "snapshot: any", ts_return_type = "any")]
pub fn authz_authorize_all(snapshot: JsonValue) -> Result<JsonValue> {
    authz::authorize_all_value(snapshot).map_err(napi_error)
}

/// Returns whether a CEL authorization condition compiles.
#[napi]
pub fn authz_validate_condition(condition: String) -> Result<bool> {
    authz::validate_condition_source(&condition)
        .map(|_| true)
        .map_err(napi_error)
}

/// Returns whether a SignalsGateway CEL admission filter compiles.
#[napi(js_name = "signalsGatewayValidateFilter")]
pub fn js_signals_gateway_validate_filter(filter_source: String) -> Result<bool> {
    signals_gateway::validate_filter_source(&filter_source)
        .map(|_| true)
        .map_err(napi_error)
}

/// Evaluates a SignalsGateway CEL admission filter.
#[napi(
    js_name = "signalsGatewayFilterMatch",
    ts_args_type = "filterSource: string, context: any"
)]
pub fn js_signals_gateway_filter_match(filter_source: String, context: JsonValue) -> Result<bool> {
    signals_gateway::evaluate_filter(&filter_source, context).map_err(napi_error)
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
    runtime_fabric::encode_envelope(envelope)
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
    runtime_fabric::decode_envelope(bytes.as_ref()).map_err(napi_error)
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
            socket: Default::default(),
            poll_interval_ms: None,
            command_timeout_ms: None,
            inbox_max_events: None,
            inbox_max_bytes: None,
        };

        runtime_fabric::transport::start_dealer(config)
            .map(|handle| Self { handle })
            .map_err(napi_error)
    }

    #[napi(ts_args_type = "envelope: any")]
    pub fn send_envelope(&self, envelope: JsonValue) -> Result<()> {
        self.handle
            .send_envelope(envelope)
            .map(|_| ())
            .map_err(runtime_fabric_error)
    }

    #[napi(ts_args_type = "frames: Buffer[]")]
    pub fn send_file_frame(&self, frames: Vec<Buffer>) -> Result<()> {
        let frames = frames.into_iter().map(|frame| frame.to_vec()).collect();

        self.handle
            .send_file_frame(frames)
            .map(|_| ())
            .map_err(runtime_fabric_error)
    }

    #[napi(ts_return_type = "Promise<Buffer[] | null>")]
    pub fn recv_raw_async(&self, timeout_ms: u32) -> AsyncTask<RecvRawTask> {
        AsyncTask::new(RecvRawTask {
            handle: self.handle.clone(),
            timeout_ms,
        })
    }

    #[napi]
    pub fn stop(&self) -> Result<()> {
        self.handle.stop().map_err(runtime_fabric_error)
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
            .map_err(runtime_fabric_error)
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

/// Computes the non-cryptographic XXH3 128-bit observation fingerprint.
#[napi(js_name = "xxh3File128Hex")]
pub fn js_xxh3_file_128_hex(path: String) -> Result<String> {
    common::xxh3_128_file_hex(Path::new(&path)).map_err(napi_error)
}

/// Computes the non-cryptographic XXH3 128-bit fingerprint for a UTF-8 string.
#[napi(js_name = "xxh3String128Hex")]
pub fn js_xxh3_string_128_hex(input: String) -> String {
    common::xxh3_128_hex(input.as_bytes())
}

/// Compresses one worker-file lane block into a self-contained zstd frame.
///
/// Runs on a libuv worker thread so the JS event loop is not blocked while a
/// block is being compressed. `level` follows the zstd CLI scale (1..=22).
#[napi(js_name = "zstdCompressBlock", ts_return_type = "Promise<Buffer>")]
pub fn js_zstd_compress_block(data: Buffer, level: i32) -> AsyncTask<ZstdCompressTask> {
    AsyncTask::new(ZstdCompressTask {
        input: data.to_vec(),
        level,
    })
}

/// Decompresses one worker-file lane zstd frame with a hard output bound.
///
/// `max_out` rejects oversized payloads, capping zip-bomb exposure at one block.
/// Runs on a libuv worker thread so the JS event loop is not blocked.
#[napi(js_name = "zstdDecompressBlock", ts_return_type = "Promise<Buffer>")]
pub fn js_zstd_decompress_block(data: Buffer, max_out: u32) -> AsyncTask<ZstdDecompressTask> {
    AsyncTask::new(ZstdDecompressTask {
        input: data.to_vec(),
        max_out: u64::from(max_out),
    })
}

pub struct ZstdCompressTask {
    input: Vec<u8>,
    level: i32,
}

impl Task for ZstdCompressTask {
    type Output = Vec<u8>;
    type JsValue = Buffer;

    fn compute(&mut self) -> Result<Self::Output> {
        common::zstd_compress_block(&self.input, self.level).map_err(napi_error)
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(Buffer::from(output))
    }
}

pub struct ZstdDecompressTask {
    input: Vec<u8>,
    max_out: u64,
}

impl Task for ZstdDecompressTask {
    type Output = Vec<u8>;
    type JsValue = Buffer;

    fn compute(&mut self) -> Result<Self::Output> {
        let max_out = usize::try_from(self.max_out).unwrap_or(usize::MAX);
        common::zstd_decompress_block(&self.input, max_out).map_err(napi_error)
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(Buffer::from(output))
    }
}

/// Computes a standard unified text diff body using the native kernel diff primitive.
#[napi(js_name = "unifiedTextDiff", ts_return_type = "Promise<string>")]
pub fn js_unified_text_diff(
    before: String,
    after: String,
    context_lines: u32,
) -> AsyncTask<UnifiedTextDiffTask> {
    AsyncTask::new(UnifiedTextDiffTask {
        before,
        after,
        context_lines,
    })
}

pub struct UnifiedTextDiffTask {
    before: String,
    after: String,
    context_lines: u32,
}

impl Task for UnifiedTextDiffTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        Ok(common::unified_text_diff(
            &self.before,
            &self.after,
            self.context_lines,
        ))
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}
