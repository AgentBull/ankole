//! Tracing initialization. `BULLX_LOG_LEVEL` (or `RUST_LOG`) controls verbosity;
//! `BULLX_LOG_FORMAT=json` switches to structured logs for production.

use tracing_subscriber::EnvFilter;

/// Initializes tracing once for the worker process.
///
/// `BULLX_LOG_LEVEL` wins over generic `RUST_LOG` so app and worker deployment
/// values can be named consistently, while local Rust tooling can still use the
/// standard env var.
pub fn init() {
  let filter = EnvFilter::try_from_env("BULLX_LOG_LEVEL")
    .or_else(|_| EnvFilter::try_from_default_env())
    .unwrap_or_else(|_| EnvFilter::new("info"));

  let json = std::env::var("BULLX_LOG_FORMAT")
    .map(|value| value == "json")
    .unwrap_or(false);
  let builder = tracing_subscriber::fmt().with_env_filter(filter);
  if json {
    builder.json().init();
  } else {
    builder.init();
  }
}
