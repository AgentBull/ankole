//! Graceful-shutdown signal future (SIGINT / SIGTERM).

/// Resolves the first time the process is asked to stop.
///
/// Awaits either Ctrl-C (SIGINT, dev/interactive) or SIGTERM (the signal an
/// orchestrator like K8s sends on pod termination), whichever arrives first.
/// On non-Unix targets there is no SIGTERM, so only Ctrl-C can complete it.
/// The caller turns this into an axum graceful shutdown with a drain deadline.
pub async fn signal() {
  let ctrl_c = async {
    let _ = tokio::signal::ctrl_c().await;
  };

  #[cfg(unix)]
  let terminate = async {
    if let Ok(mut stream) =
      tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
    {
      stream.recv().await;
    }
  };

  #[cfg(not(unix))]
  let terminate = std::future::pending::<()>();

  tokio::select! {
    _ = ctrl_c => {},
    _ = terminate => {},
  }
  tracing::info!("shutdown signal received");
}
