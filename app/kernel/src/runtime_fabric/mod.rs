//! Runtime Fabric v1 protobuf envelope helpers.
//!
//! The host APIs pass JSON-shaped envelope maps, but this module owns the
//! protocol validation and protobuf bytes. That keeps Elixir and Bun bindings
//! thin while avoiding a second JSON wire protocol.

mod body;
mod codec;
mod enums;
mod from_host_json;
mod json;
#[cfg(test)]
mod tests;
mod to_host_json;
mod validate;

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.runtime_fabric.v1.rs"));

    pub use self::{RpcError as RPCError, RpcRequest as RPCRequest, RpcResponse as RPCResponse};
}

pub mod transport;

pub(crate) use codec::decode_envelope_view;
pub use codec::{decode_envelope, encode_envelope};

const PROTOCOL_VERSION: u32 = 1;
