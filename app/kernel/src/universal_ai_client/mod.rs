//! Elixir supplies connection, auth, endpoint, headers, transport preferences,
//! and the resolved request context. This module owns the per-protocol request
//! body encoding, the transport, upstream stream parsing, response
//! and error normalization, the terminal for each call, downstream-ready chunk
//! encoding, demand credit, and cancellation mechanics. Credential policy and
//! the public Ankole Response lifecycle stay with the host. Each protocol's request-body builder and response
//! state machine live paired in `api_resolver/<protocol>.rs`.

pub mod api_resolver;
mod aws_sigv4;
mod client;
mod downstream;
mod error;
mod hosted_responses;
mod request_builder;
mod spec;
mod transport;
pub mod wire;

pub use api_resolver::APIResolver;
pub use client::{
    ChunkOrigin, EventSink, RequestHandle, RequestResultSink, StreamEvent, StreamHandle,
    start_model_request, start_raw_request, start_stream,
};
pub use error::StreamError;
pub use spec::{
    APIResolverKind, ConversionPolicy, ResponseContext, TimeoutSpec, TransportSpec, UpstreamKind,
    UpstreamSpec,
};
pub use transport::{HTTPResponse, HTTPStream, HttpTransport, SemanticIdle, safe_response_headers};
pub use wire::{SSEEvent, SSEFrame, SSEParser};
