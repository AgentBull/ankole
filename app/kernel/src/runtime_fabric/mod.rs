//! Runtime Fabric v1 protobuf envelope protocol.
//!
//! Hosts encode and decode envelopes with codecs generated from
//! `envelope.proto`; this module owns the protocol invariants. Every envelope
//! crossing the transport is validated here so Elixir and Bun see identical
//! semantic errors.

mod body;
mod codec;
mod enums;
#[cfg(test)]
mod tests;
mod validate;

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.runtime_fabric.v1.rs"));

    pub use self::{RpcError as RPCError, RpcRequest as RPCRequest, RpcResponse as RPCResponse};
}

pub mod transport;

pub(crate) use codec::decode_envelope_view;
pub use codec::validate_envelope_bytes;

pub const PROTOCOL_VERSION: u32 = 2;
