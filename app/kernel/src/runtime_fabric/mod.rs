//! Runtime Fabric v1 protobuf envelope helpers.
//!
//! The host APIs pass JSON-shaped envelope maps, but this module owns the
//! protocol validation and protobuf bytes. That keeps Elixir and Bun bindings
//! thin while avoiding a second JSON wire protocol.

mod codec;
mod decode;
mod encode;
mod enums;
mod json;
#[cfg(test)]
mod tests;
mod validate;

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.runtime_fabric.v1.rs"));
}

pub mod transport;

pub use codec::{decode_envelope, encode_envelope};

const PROTOCOL_VERSION: u32 = 1;
