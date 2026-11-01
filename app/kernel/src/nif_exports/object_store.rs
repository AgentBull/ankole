//! BEAM resources, owner monitors and asynchronous replies for object storage.

use super::{
    BeamStreamRef, atoms, binary_from_buf, decode_binary, decode_string, decode_u64,
    encode_json_value,
};
use crate::object_store;
use rustler::env::OwnedEnv;
use rustler::types::binary::Binary;
use rustler::{Encoder, Env, Error, LocalPid, Monitor, NifResult as NIFResult, ResourceArc, Term};

pub struct ObjectStoreResource(pub object_store::Store);

pub struct ObjectStoreWriteResource {
    handle: object_store::WriteHandle,
    owner: LocalPid,
}

#[rustler::resource_impl]
impl rustler::Resource for ObjectStoreWriteResource {
    const IMPLEMENTS_DESTRUCTOR: bool = true;
    const IMPLEMENTS_DOWN: bool = true;

    fn destructor(self, _env: Env<'_>) {
        self.handle.cancel();
    }

    fn down<'a>(&'a self, _env: Env<'a>, _pid: LocalPid, _monitor: Monitor) {
        self.handle.cancel();
    }
}

#[rustler::resource_impl]
impl rustler::Resource for ObjectStoreResource {}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_open_nif<'a>(env: Env<'a>, spec: Term<'a>) -> NIFResult<Term<'a>> {
    let spec = decode_string(spec, "spec")?;

    match object_store::open(&spec) {
        Ok(store) => Ok((atoms::ok(), ResourceArc::new(ObjectStoreResource(store))).encode(env)),
        Err(reason) => Ok((atoms::error(), encode_object_store_error(env, &reason)).encode(env)),
    }
}

#[rustler::nif]
pub fn object_store_write_limit_nif(store: ResourceArc<ObjectStoreResource>) -> u64 {
    object_store::write_limit(&store.0)
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
pub fn object_store_read_range_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    offset: Term<'a>,
    length: Term<'a>,
    owner_pid: LocalPid,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    let offset = decode_u64(offset, "offset")?;
    let length = decode_u64(length, "length")?;
    start_object_store_operation(
        env,
        &store,
        object_store::Operation::ReadRange {
            key,
            offset,
            length,
        },
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

/// Opens an owner-monitored writer and acknowledges readiness asynchronously.
#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_writer_open_nif<'a>(
    env: Env<'a>,
    store: ResourceArc<ObjectStoreResource>,
    key: Term<'a>,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    let key = decode_string(key, "key")?;
    let owner = env.pid();
    match object_store::start_write(&store.0, key, object_store_sink(owner, request_ref)) {
        Ok(handle) => {
            let resource = ResourceArc::new(ObjectStoreWriteResource { handle, owner });
            let _ = resource.monitor(Some(env), &owner);
            Ok((atoms::ok(), resource).encode(env))
        }
        Err(reason) => Ok((atoms::error(), encode_object_store_error(env, &reason)).encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_writer_write_nif<'a>(
    env: Env<'a>,
    writer: ResourceArc<ObjectStoreWriteResource>,
    bytes: Binary<'a>,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    if env.pid() != writer.owner {
        return Err(Error::BadArg);
    }
    if bytes.len() > object_store::WRITE_CHUNK_BYTES {
        return Err(Error::BadArg);
    }
    let result = writer.handle.write(
        bytes::Bytes::copy_from_slice(bytes.as_slice()),
        object_store_sink(writer.owner, request_ref),
    );
    Ok(encode_object_store_start(env, result))
}

#[rustler::nif(schedule = "DirtyIo")]
pub fn object_store_writer_close_nif<'a>(
    env: Env<'a>,
    writer: ResourceArc<ObjectStoreWriteResource>,
    request_ref: Term<'a>,
) -> NIFResult<Term<'a>> {
    if env.pid() != writer.owner {
        return Err(Error::BadArg);
    }
    let result = writer
        .handle
        .finish(object_store_sink(writer.owner, request_ref));
    Ok(encode_object_store_start(env, result))
}

#[rustler::nif]
pub fn object_store_writer_abort_nif(
    env: Env<'_>,
    writer: ResourceArc<ObjectStoreWriteResource>,
) -> NIFResult<rustler::Atom> {
    if env.pid() != writer.owner {
        return Err(Error::BadArg);
    }
    writer.handle.cancel();
    Ok(atoms::ok())
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
    let sink = object_store_sink(owner_pid, request_ref);
    Ok(encode_object_store_start(
        env,
        object_store::start(&store.0, operation, sink),
    ))
}

fn encode_object_store_start(
    env: Env<'_>,
    result: Result<(), object_store::StoreError>,
) -> Term<'_> {
    match result {
        Ok(()) => atoms::ok().encode(env),
        Err(reason) => (atoms::error(), encode_object_store_error(env, &reason)).encode(env),
    }
}

fn object_store_sink(owner_pid: LocalPid, request_ref: Term<'_>) -> object_store::ResultSink {
    let request_ref = BeamStreamRef::new(request_ref);
    Box::new(move |result| {
        let mut env = OwnedEnv::new();
        let _ = env.send_and_clear(&owner_pid, |env| {
            let request_ref = request_ref.encode(env);
            let result = match result {
                Ok(object_store::Outcome::Done) => atoms::ok().encode(env),
                Ok(object_store::Outcome::Bytes(buffer)) => {
                    (atoms::ok(), binary_from_buf(buffer).release(env)).encode(env)
                }
                Err(reason) => {
                    (atoms::error(), encode_object_store_error(env, &reason)).encode(env)
                }
            };
            (atoms::object_store(), request_ref, result).encode(env)
        });
    })
}

fn encode_object_store_error<'a>(env: Env<'a>, error: &object_store::StoreError) -> Term<'a> {
    encode_json_value(
        env,
        &serde_json::json!({"code": error.code, "message": error.message}),
    )
}
