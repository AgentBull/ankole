//! Graceful-shutdown signal future (SIGINT / SIGTERM).

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
