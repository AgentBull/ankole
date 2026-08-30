//! Runtime Fabric v1 protobuf envelope protocol.
//!
//! Hosts encode and decode messages with codecs generated from `envelope.proto`
//! and `rpc.proto`; this module owns the envelope protocol invariants. Every
//! envelope crossing the transport is validated here so Elixir and Bun see
//! identical semantic errors. RPC business payloads stay opaque to transport.

mod body;
mod codec;
mod enums;
#[cfg(test)]
mod tests;
mod validate;

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.runtime_fabric.v1.rs"));
}

pub mod transport;

pub(crate) use codec::decode_envelope_view;
pub use codec::{seal_envelope_bytes, validate_envelope_bytes};

pub const PROTOCOL_VERSION: u32 = 5;
