//! NDJSON streaming response helper (`application/x-ndjson`).

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use futures::{Stream, StreamExt};
use serde_json::Value;

/// Build a streaming NDJSON response from a stream of JSON values (one line each).
///
/// NDJSON (newline-delimited JSON) lets the client consume command/log output
/// incrementally as it arrives instead of waiting for the whole response — the framing
/// behind the streaming command and log endpoints.
pub fn ndjson_stream<S>(stream: S) -> Response
where
  S: Stream<Item = Value> + Send + 'static,
{
  let lines = stream.map(|value| {
    // Serialization of an already-built `Value` cannot realistically fail; the `{}`
    // fallback just guarantees one valid, parseable frame instead of poisoning the
    // stream if it somehow did. The `\n` is the record separator.
    let mut buffer = serde_json::to_vec(&value).unwrap_or_else(|_| b"{}".to_vec());
    buffer.push(b'\n');
    Ok::<Bytes, std::io::Error>(Bytes::from(buffer))
  });
  (
    [(CONTENT_TYPE, "application/x-ndjson")],
    Body::from_stream(lines),
  )
    .into_response()
}
