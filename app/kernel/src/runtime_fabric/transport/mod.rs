//! Bounded ZeroMQ transport for RuntimeFabric envelopes and file frames.
//!
//! One Rust thread owns each socket. Host bindings submit commands and receive
//! typed events without operating ZeroMQ sockets directly.

mod auth;
mod config;
mod dealer;
mod error;
mod framing;
mod router;
#[cfg(test)]
mod tests;
mod types;

pub use config::{DealerConfig, RouterConfig, SocketOptions};
pub use dealer::{DealerHandle, start_dealer};
pub use error::TransportError;
pub use router::{RouterEventSink, RouterHandle, start_router};
pub use types::{DealerEvent, RouterEvent, SendOutcome};
