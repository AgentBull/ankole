//! NDJSON streaming response helper (`application/x-ndjson`).

use axum::body::Body;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use bytes::Bytes;
use futures::{Stream, StreamExt};
use serde_json::Value;

/// Build a streaming NDJSON response from a stream of JSON values (one line each).
pub fn ndjson_stream<S>(stream: S) -> Response
where
  S: Stream<Item = Value> + Send + 'static,
{
  let lines = stream.map(|value| {
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
