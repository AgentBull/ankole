//! These functions validate BEAM terms, keep values binary-safe, and forward behavior to host-neutral modules.

use rustler::env::{OwnedEnv, SavedTerm};
use rustler::types::atom as rustler_atom;
use rustler::types::binary::{Binary, OwnedBinary};
use rustler::{Encoder, Env, Error, LocalPid, Monitor, NifResult as NIFResult, ResourceArc, Term};
use serde_json::Value as JSONValue;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use crate::authz;
use crate::common;
use crate::object_store;
use crate::signals;
use crate::universal_ai_client;

mod atoms {
    rustler::atoms! {
        ok,
        universal_ai_client,
        universal_ai_client_request,
        object_store,
        ready,
        chunk,
        provider,
        client,
        done,
        error,
        aborted,
        metadata,
        private,
        public,
        applet_runtime,
        call,
    }
}

/// Lives across BEAM demand calls.
pub struct UniversalAIClientStreamResource(pub universal_ai_client::StreamHandle);

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

pub struct ObjectStoreResource(pub object_store::Store);

/// Retained by the completion sink until the native request ends. The monitor
/// cancels its I/O if the BEAM owner exits while waiting for a provider.
pub struct UniversalAIClientRequestResource {
    handle: Mutex<Option<universal_ai_client::RequestHandle>>,
    cancelled: AtomicBool,
}

impl UniversalAIClientRequestResource {
    fn new() -> Self {
        Self {
            handle: Mutex::new(None),
            cancelled: AtomicBool::new(false),
        }
    }

    fn install(&self, handle: universal_ai_client::RequestHandle) {
        let mut current = self
            .handle
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if self.cancelled.load(Ordering::SeqCst) {
            handle.cancel();
        }
        *current = Some(handle);
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        if let Some(handle) = self
            .handle
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .as_ref()
        {
            handle.cancel();
        }
    }
}

#[rustler::resource_impl]
impl rustler::Resource for UniversalAIClientRequestResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        self.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.cancel();
    }
}

#[rustler::resource_impl]
impl rustler::Resource for ObjectStoreResource {}

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

#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_decrypt(ciphertext: Term<'_>, key: Term<'_>) -> NIFResult<OwnedBinary> {
    let ciphertext = decode_string(ciphertext, "ciphertext")?;
    let key = decode_string(key, "key")?;

    common::aead_decrypt(&ciphertext, &key)
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Uses the shared AEAD token format.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NIFResult<String> {
    let plaintext = decode_binary(plaintext, "plaintext")?;
    let key = decode_string(key, "key")?;

    common::aead_encrypt(plaintext.as_slice(), &key).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn normalize_model_image_nif(bytes: Term<'_>) -> NIFResult<OwnedBinary> {
    let bytes = decode_binary(bytes, "image")?;
    crate::model_image::normalize(bytes.as_slice())
        .map_err(error)
        .and_then(binary_from_vec)
}

/// Grammar errors stay encoded JSON. A NIF error means the native boundary failed.
#[cfg(feature = "brain_markdoc")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn brain_markdoc_analyze_nif(body: Term<'_>) -> NIFResult<String> {
    let body = decode_string(body, "body")?;
    crate::brain_markdoc::analyze_json(&body).map_err(error_message)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_validate_nif(source: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    // Page normalization is recursive up to the editor's declared depth limit.
    let page = stacker::grow(8 * 1024 * 1024, || crate::page_document::validate(&source))
        .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn page_apply_nif(source: Term<'_>, changes: Term<'_>) -> NIFResult<(String, String)> {
    let source = decode_string(source, "source")?;
    let changes = decode_string(changes, "changes")?;
    let page = stacker::grow(8 * 1024 * 1024, || {
        crate::page_document::apply(&source, &changes)
    })
    .map_err(error_message)?;
    Ok((page.xml, page.plain_text))
}

#[cfg(feature = "markdown")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn markdown_code_ranges_nif(source: Term<'_>) -> NIFResult<Vec<(usize, usize)>> {
    let source = decode_string(source, "source")?;
    Ok(crate::markdown::code_ranges(&source))
}

/// Runs to completion or the next pending tool-call batch.
/// One call owns a V8 isolate until the program timeout.
/// Program semantics stay behind the JSON boundary.
#[cfg(feature = "program_runner")]
#[rustler::nif(schedule = "DirtyCpu")]
pub fn program_run_nif(run_id: Term<'_>, request: Term<'_>) -> NIFResult<String> {
    let run_id = decode_string(run_id, "run_id")?;
    let request = decode_string(request, "request")?;

    crate::program_runner::run_json(&run_id, &request).map_err(error_message)
}

/// Cancels a native program even when DirtyCpu schedulers are occupied by V8.
///
/// The registry lookup and V8 thread-safe termination signal are bounded, so
/// keeping this on a normal scheduler is both safe and required for liveness.
#[cfg(feature = "program_runner")]
#[rustler::nif]
pub fn program_cancel_nif(run_id: Term<'_>) -> NIFResult<bool> {
    let run_id = decode_string(run_id, "run_id")?;
    crate::program_runner::cancel(&run_id).map_err(error_message)
}

pub struct AppletRuntimeResource(pub crate::applet_runtime::Handle);

#[rustler::resource_impl]
impl rustler::Resource for AppletRuntimeResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        self.0.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.0.cancel();
    }
}

/// Retains transport binaries without copying their bytes on the scheduler.
struct AppletJSON {
    env: OwnedEnv,
    term: SavedTerm,
}

impl AppletJSON {
    fn new(term: Term<'_>) -> Self {
        let env = OwnedEnv::new();
        Self {
            term: env.save(term),
            env,
        }
    }

    fn decode<T: serde::de::DeserializeOwned>(self) -> Result<T, String> {
        self.env.run(|env| {
            let binary: Binary<'_> = self
                .term
                .load(env)
                .decode()
                .map_err(|_| "Expected JSON binary".to_string())?;
            serde_json::from_slice(binary.as_slice()).map_err(|error| error.to_string())
        })
    }
}

/// Only retains the BEAM binary and starts the invocation thread. JSON decode,
/// isolate execution, and capability waits do not occupy any scheduler.
#[rustler::nif]
pub fn applet_start_nif<'a>(
    env: Env<'a>,
    run_id: String,
    request_json: Binary<'a>,
) -> NIFResult<Term<'a>> {
    let request = AppletJSON::new(request_json.encode(env));
    let owner = env.pid();
    let sink = Arc::new(move |event| {
        let mut owned_env = OwnedEnv::new();
        let _ = owned_env.send_and_clear(&owner, |env| match event {
            crate::applet_runtime::Event::Call {
                id,
                operation,
                arguments,
            } => (
                atoms::applet_runtime(),
                &run_id,
                atoms::call(),
                id,
                operation,
                arguments.to_string(),
            )
                .encode(env),
            crate::applet_runtime::Event::Done(outcome) => (
                atoms::applet_runtime(),
                &run_id,
                atoms::done(),
                outcome.to_string(),
            )
                .encode(env),
        });
    });
    let handle =
        crate::applet_runtime::start_with(move || request.decode(), sink).map_err(error_message)?;
    let resource = ResourceArc::new(AppletRuntimeResource(handle));
    let _ = resource.monitor(Some(env), &owner);
    Ok(resource.encode(env))
}

/// Sends a retained binary to the same live invocation thread for decoding.
#[rustler::nif]
pub fn applet_reply_nif(
    resource: ResourceArc<AppletRuntimeResource>,
    call_id: u64,
    reply: Term<'_>,
) -> NIFResult<bool> {
    let _ = decode_binary(reply, "reply")?;
    let reply = AppletJSON::new(reply);
    Ok(resource.0.reply_with(call_id, move || reply.decode()))
}

#[rustler::nif]
pub fn applet_cancel_nif(resource: ResourceArc<AppletRuntimeResource>) -> bool {
    resource.0.cancel();
    true
}

// CEL's recursive parser needs more stack than BEAM's default dirty CPU stack.
// Keep compilation, evaluation, and program cleanup on this stack on the same
// scheduler thread. Host-neutral callers retain their own stack policy.
fn with_cel_stack<R>(call: impl FnOnce() -> R) -> R {
    stacker::grow(8 * 1024 * 1024, call)
}

/// Authorizes one exact action on one concrete resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = with_cel_stack(|| authz::authorize_value(snapshot)).map_err(error)?;

    encode_json(decision)
}

/// Authorizes every requested action against the same resource from an encoded snapshot.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_authorize_all_nif(snapshot: Term<'_>) -> NIFResult<String> {
    let snapshot = decode_json(snapshot, "snapshot")?;
    let decision = with_cel_stack(|| authz::authorize_all_value(snapshot)).map_err(error)?;

    encode_json(decision)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_condition(condition: Term<'_>) -> NIFResult<bool> {
    let condition = decode_string(condition, "condition")?;

    with_cel_stack(|| authz::validate_condition_source(&condition))
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_validate_filter(filter_source: Term<'_>) -> NIFResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;

    with_cel_stack(|| signals::validate_filter_source(&filter_source))
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn signals_filter_match_nif(filter_source: Term<'_>, context: Term<'_>) -> NIFResult<bool> {
    let filter_source = decode_string(filter_source, "filter_source")?;
    let context = decode_json(context, "context")?;

    with_cel_stack(|| signals::evaluate_filter(&filter_source, context)).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_validate_resource_pattern(pattern: Term<'_>) -> NIFResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;

    authz::validate_pattern_source(&pattern)
        .map(|_| true)
        .map_err(error)
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_open_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    stream_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
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
) -> NIFResult<rustler::Atom> {
    let count = decode_u64(count, "count")?;
    stream.0.read(count).map_err(error)?;
    Ok(atoms::ok())
}

#[rustler::nif]
pub fn universal_ai_client_cancel_nif(
    stream: ResourceArc<UniversalAIClientStreamResource>,
) -> NIFResult<rustler::Atom> {
    stream.0.cancel().map_err(error)?;
    Ok(atoms::ok())
}

/// The result arrives later as one `{:universal_ai_client_request, ref, result}` message.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_model_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let resource = ResourceArc::new(UniversalAIClientRequestResource::new());
    let monitored = resource.monitor(Some(env), &owner_pid).is_some();
    let deliver =
        monitored_request_sink(owner_pid, BeamStreamRef::new(request_ref), resource.clone());

    match universal_ai_client::start_model_request(&encoded_spec, deliver) {
        Ok(handle) => {
            if !monitored {
                resource.cancel();
            }
            resource.install(handle);
            Ok(atoms::ok().encode(env))
        }
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
}

/// No model normalization. Same result message as `universal_ai_client_model_request_nif`.
#[rustler::nif(schedule = "DirtyIo")]
pub fn universal_ai_client_raw_request_nif<'a>(
    env: Env<'a>,
    encoded_spec: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let encoded_spec = decode_string(encoded_spec, "encoded_spec")?;
    let resource = ResourceArc::new(UniversalAIClientRequestResource::new());
    let monitored = resource.monitor(Some(env), &owner_pid).is_some();
    let deliver =
        monitored_request_sink(owner_pid, BeamStreamRef::new(request_ref), resource.clone());

    match universal_ai_client::start_raw_request(&encoded_spec, deliver) {
        Ok(handle) => {
            if !monitored {
                resource.cancel();
            }
            resource.install(handle);
            Ok(atoms::ok().encode(env))
        }
        Err(reason) => Ok((atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)),
    }
}

fn monitored_request_sink(
    owner_pid: LocalPid,
    request_ref: BeamStreamRef,
    resource: ResourceArc<UniversalAIClientRequestResource>,
) -> universal_ai_client::RequestResultSink {
    let deliver = universal_ai_client_request_sink(owner_pid, request_ref);
    Box::new(move |result| {
        deliver(result);
        // Drop the owner resource only after delivery. A fast provider result
        // must not race resource registration in the starting NIF call.
        drop(resource);
    })
}

fn universal_ai_client_request_sink(
    owner_pid: LocalPid,
    request_ref: BeamStreamRef,
) -> universal_ai_client::RequestResultSink {
    Box::new(move |result| {
        let mut env = OwnedEnv::new();
        let _ = env.send_and_clear(&owner_pid, |env| {
            let request_ref = request_ref.encode(env);
            let result = match &result {
                Ok(response) => (atoms::ok(), encode_json_value(env, response)).encode(env),
                Err(reason) => {
                    (atoms::error(), encode_json_value(env, &reason.to_json())).encode(env)
                }
            };
            (atoms::universal_ai_client_request(), request_ref, result).encode(env)
        });
    })
}

/// Opens one object store from its JSON spec.
///
/// Opening does no network I/O. The fs scheme creates its root and temporary
/// directory, which is why the NIF runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_open_nif<'a>(env: Env<'a>, spec: Term<'a>) -> NIFResult<Term<'a>> {
    let spec = decode_string(spec, "spec")?;

    match object_store::open(&spec) {
        Ok(store) => Ok((atoms::ok(), ResourceArc::new(ObjectStoreResource(store))).encode(env)),
        Err(reason) => Ok((atoms::error(), encode_object_store_error(env, &reason)).encode(env)),
    }
}

/// The result arrives later as one `{:object_store, ref, result}` message.
#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_read_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::Read { key },
        owner_pid,
        request_ref,
    )
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_read_to_file_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    path: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    let path = decode_string(path, "path")?.into();
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::ReadToFile { key, path },
        owner_pid,
        request_ref,
    )
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_write_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    bytes: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    let bytes = decode_binary(bytes, "bytes")?.as_slice().to_vec();
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::Write { key, bytes },
        owner_pid,
        request_ref,
    )
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_write_from_file_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    path: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    let path = decode_string(path, "path")?.into();
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::WriteFromFile { key, path },
        owner_pid,
        request_ref,
    )
}

/// Deleting a missing object succeeds.
#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_delete_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::Delete { key },
        owner_pid,
        request_ref,
    )
}

fn start_object_store_operation<'a>(
    env: Env<'a>,
    store: &ResourceArc<ObjectStoreResource>,
    operation: object_store::Operation,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let request_ref = BeamStreamRef::new(request_ref);
    let sink: object_store::ResultSink = Box::new(move |result| {
        let mut env = OwnedEnv::new();
        let _ = env.send_and_clear(&owner_pid, |env| {
            let request_ref = request_ref.encode(env);
            let result = match result {
                Ok(object_store::Outcome::Done) => atoms::ok().encode(env),
                Ok(object_store::Outcome::Bytes(buffer)) => match binary_from_buf(buffer) {
                    Some(binary) => (atoms::ok(), binary.release(env)).encode(env),
                    None => (
                        atoms::error(),
                        encode_object_store_error(
                            env,
                            &object_store::StoreError {
                                code: "allocation_failed",
                                message: "failed to allocate the object binary".to_string(),
                            },
                        ),
                    )
                        .encode(env),
                },
                Err(reason) => {
                    (atoms::error(), encode_object_store_error(env, &reason)).encode(env)
                }
            };
            (atoms::object_store(), request_ref, result).encode(env)
        });
    });

    match object_store::start(&store.0, operation, sink) {
        Ok(()) => Ok(atoms::ok().encode(env)),
        Err(reason) => Ok((atoms::error(), encode_object_store_error(env, &reason)).encode(env)),
    }
}

fn encode_object_store_error<'a>(env: Env<'a>, error: &object_store::StoreError) -> Term<'a> {
    encode_json_value(
        env,
        &serde_json::json!({"code": error.code, "message": error.message}),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn authz_match_resource_pattern(pattern: Term<'_>, resource: Term<'_>) -> NIFResult<bool> {
    let pattern = decode_string(pattern, "pattern")?;
    let resource = decode_string(resource, "resource")?;

    authz::pattern_matches(&pattern, &resource).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn estimate_o200k_base_tokens(text: Term<'_>) -> NIFResult<u64> {
    let text = decode_string(text, "text")?;

    Ok(common::estimate_o200k_base_tokens(&text))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn reciprocal_rank_fusion_nif(ranked_lists: Term<'_>, k: Term<'_>) -> NIFResult<String> {
    let ranked_lists = decode_json(ranked_lists, "ranked_lists")?;
    let ranked_lists: Vec<Vec<String>> = serde_json::from_value(ranked_lists)
        .map_err(|_| error_message("ranked_lists must contain a JSON array of string arrays"))?;
    let k = decode_u64(k, "k")?;
    let fused = common::reciprocal_rank_fusion(&ranked_lists, k);
    let fused = serde_json::to_value(fused)
        .map_err(|reason| error_message(format!("failed to encode RRF results: {reason}")))?;

    encode_json(fused)
}

/// Non-cryptographic observation fingerprint.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn xxh3_128_hex(input: Term<'_>) -> NIFResult<String> {
    let input = decode_binary(input, "input")?;

    Ok(common::xxh3_128_hex(input.as_slice()))
}

/// Key seeds are binaries, so they can contain non-UTF-8 bytes.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn derive_key(
    key_seed: Term<'_>,
    sub_key_id: Term<'_>,
    extra_context: Term<'_>,
) -> NIFResult<String> {
    let key_seed = decode_binary(key_seed, "key_seed")?;
    let sub_key_id = decode_string(sub_key_id, "sub_key_id")?;
    let extra_context = decode_optional_string(extra_context, "extra_context")?;

    Ok(common::derive_key(
        key_seed.as_slice(),
        &sub_key_id,
        extra_context.as_deref(),
    ))
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_sign_pem_nif(
    claims: Term<'_>,
    private_key_pem: Term<'_>,
    header: Term<'_>,
) -> NIFResult<String> {
    let claims = decode_string(claims, "claims")?;
    let private_key_pem = decode_string(private_key_pem, "private_key_pem")?;
    let header = decode_string(header, "header")?;

    common::jwt_sign_pem(&claims, &private_key_pem, &header).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn jwt_verify_jwk_nif(
    token: Term<'_>,
    jwk: Term<'_>,
    validation: Term<'_>,
) -> NIFResult<String> {
    let token = decode_string(token, "token")?;
    let jwk = decode_string(jwk, "jwk")?;
    let validation = decode_string(validation, "validation")?;

    common::jwt_verify_jwk(&token, &jwk, &validation).map_err(error)
}

/// Hashes a password with Argon2id and returns a PHC-format string.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn argon2id_hash(password: Term<'_>) -> NIFResult<String> {
    let password = decode_string(password, "password")?;

    common::argon2id_hash(&password).map_err(error)
}

/// Verifies a password against a PHC-format Argon2id hash string.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn argon2id_verify(password: Term<'_>, phc_hash: Term<'_>) -> NIFResult<bool> {
    let password = decode_string(password, "password")?;
    let phc_hash = decode_string(phc_hash, "phc_hash")?;

    common::argon2id_verify(&password, &phc_hash).map_err(error)
}

#[derive(rustler::NifMap)]
struct WebURLFactsNIF {
    scheme: String,
    host: Option<String>,
    host_class: Option<rustler::Atom>,
}

/// Parses a web URL with WHATWG semantics and classifies its host.
#[rustler::nif]
pub fn web_url_facts_nif(url: Term<'_>) -> NIFResult<WebURLFactsNIF> {
    let url = decode_string(url, "url")?;
    let facts = common::web_url_facts(&url).map_err(error)?;

    Ok(WebURLFactsNIF {
        scheme: facts.scheme,
        host: facts.host,
        host_class: facts.host_class.map(|host_class| match host_class {
            common::HostClass::Metadata => atoms::metadata(),
            common::HostClass::Private => atoms::private(),
            common::HostClass::Public => atoms::public(),
        }),
    })
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
#[rustler::nif]
pub fn generate_key() -> String {
    common::generate_key()
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn phone_normalize_e164(phone: Term<'_>) -> NIFResult<String> {
    let phone = decode_string(phone, "phone")?;

    common::phone_normalize_e164(&phone).map_err(error)
}

#[rustler::nif]
pub fn gen_uuid() -> String {
    common::gen_uuid()
}

#[rustler::nif]
pub fn gen_uuid_v7() -> String {
    common::gen_uuid_v7()
}

#[rustler::nif]
pub fn uuid_shorten(value: Term<'_>) -> NIFResult<String> {
    common::uuid_shorten(&decode_string(value, "uuid")?).map_err(error)
}

#[rustler::nif]
pub fn uuid_expand(value: Term<'_>) -> NIFResult<String> {
    common::uuid_expand(&decode_string(value, "short_uuid")?).map_err(error)
}

/// Copies Rust-owned bytes into an Elixir-owned binary.
///
/// Returning `Vec<u8>` directly would be encoded by Rustler as a list of byte
/// integers. `OwnedBinary` keeps the Elixir API binary-safe and matches caller
/// expectations for decrypted and decoded payloads.
fn binary_from_vec(bytes: Vec<u8>) -> NIFResult<OwnedBinary> {
    let mut binary =
        OwnedBinary::new(bytes.len()).ok_or_else(|| error_message("failed to allocate binary"))?;
    binary.as_mut_slice().copy_from_slice(&bytes);

    Ok(binary)
}

fn binary_from_buf(mut buffer: impl bytes::Buf) -> Option<OwnedBinary> {
    let mut binary = OwnedBinary::new(buffer.remaining())?;
    buffer.copy_to_slice(binary.as_mut_slice());
    Some(binary)
}

/// The error text stays stable and does not use Rustler's conversion wording.
fn decode_binary<'a>(term: Term<'a>, field: &str) -> NIFResult<Binary<'a>> {
    if !term.is_binary() {
        return Err(error_message(format!("{field} must be a binary")));
    }

    Binary::from_term(term).map_err(|_| error_message(format!("{field} must be a binary")))
}

fn decode_json(term: Term<'_>, field: &str) -> NIFResult<JSONValue> {
    let json = decode_string(term, field)?;

    serde_json::from_str(&json)
        .map_err(|reason| error_message(format!("{field} must contain valid JSON: {reason}")))
}

fn decode_optional_string(term: Term<'_>, field: &str) -> NIFResult<Option<String>> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string or nil")))
}

fn decode_u64(term: Term<'_>, field: &str) -> NIFResult<u64> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a non-negative integer")))
}

fn decode_string(term: Term<'_>, field: &str) -> NIFResult<String> {
    term.decode()
        .map_err(|_| error_message(format!("{field} must be a string")))
}

fn encode_json(value: JSONValue) -> NIFResult<String> {
    serde_json::to_string(&value)
        .map_err(|reason| error_message(format!("failed to encode JSON: {reason}")))
}

fn error(error: common::KernelError) -> Error {
    error_message(error.to_string())
}

fn error_message(message: impl Into<String>) -> Error {
    Error::Term(Box::new(message.into()))
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
            universal_ai_client::StreamEvent::Chunk { seq, origin, bytes } => {
                let origin = match origin {
                    universal_ai_client::ChunkOrigin::Provider => atoms::provider(),
                    universal_ai_client::ChunkOrigin::Client => atoms::client(),
                };
                match binary_term(env, bytes) {
                    Ok(binary) => (
                        atoms::universal_ai_client(),
                        stream_ref,
                        atoms::chunk(),
                        seq,
                        origin,
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

fn binary_term<'a>(env: Env<'a>, bytes: Vec<u8>) -> Result<Term<'a>, String> {
    let Some(mut binary) = OwnedBinary::new(bytes.len()) else {
        return Err("failed to allocate universal AI client chunk binary".to_string());
    };

    binary.as_mut_slice().copy_from_slice(&bytes);
    Ok(binary.release(env).encode(env))
}

fn encode_json_value<'a>(env: Env<'a>, value: &JSONValue) -> Term<'a> {
    match value {
        JSONValue::Null => rustler_atom::nil().encode(env),
        JSONValue::Bool(value) => value.encode(env),
        JSONValue::Number(number) => {
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
        JSONValue::String(value) => value.encode(env),
        JSONValue::Array(values) => values
            .iter()
            .map(|value| encode_json_value(env, value))
            .collect::<Vec<_>>()
            .encode(env),
        JSONValue::Object(values) => {
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

rustler::init!("Elixir.Ankole.Kernel");
