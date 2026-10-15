//! Elixir supplies connection, auth, endpoint, headers, transport preferences,
//! and the resolved request context. This module owns the per-protocol request
//! body encoding, the transport, upstream stream parsing, response
//! and error normalization, the terminal for each call, downstream-ready chunk
//! encoding, demand credit, and cancellation mechanics. Credential policy and
//! the public Ankole Response lifecycle stay with the host. Each protocol's request-body builder and response
//! state machine live paired in `api_resolver/<protocol>.rs`.

mod api_resolver;
mod client;
mod downstream;
mod error;
mod hosted_responses;
mod request_builder;
mod spec;
mod transport;
mod wire;

pub use client::{
    APIResolverKind, ChunkOrigin, EventSink, ModelRequestSpec, RawRequestSpec, RequestResultSink,
    StreamEvent, StreamHandle, StreamLimits, StreamSpec, UpstreamKind, start_model_request,
    start_raw_request, start_stream,
};
