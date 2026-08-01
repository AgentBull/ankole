//! Native async streaming model client.
//!
//! Elixir supplies connection, auth, endpoint, headers, transport preferences,
//! and the resolved request context. This module owns the per-protocol request
//! body encoding, the transport, upstream stream parsing, response
//! normalization, downstream-ready chunk encoding, demand credit, and
//! cancellation mechanics. Each protocol's request-body builder and response
//! state machine live paired in `api_resolver/<protocol>.rs`.

mod api_resolver;
mod client;
mod downstream;
mod error;
mod hosted_responses;
mod request_builder;
mod runtime;
mod spec;
mod transport;
mod wire;

pub use client::{
    APIResolverKind, DownstreamKind, EventSink, ModelRequestSpec, RawRequestSpec, StreamEvent,
    StreamHandle, StreamLimits, StreamSpec, UpstreamKind, send_model_request, send_raw_request,
    start_stream,
};
