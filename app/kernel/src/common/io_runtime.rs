//! The shared Tokio runtime for native I/O that BEAM callers start and then wait for.

use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

use crate::common::{KernelError, KernelResult};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> KernelResult<&'static Runtime> {
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }

    // OpenDAL's PostgreSQL driver also enables ring. Select the HTTP client's
    // provider before TLS starts; keep a provider that the host already set.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    let runtime = Builder::new_multi_thread()
        .thread_name("ankole-kernel-io")
        .enable_all()
        .build()
        .map_err(|reason| KernelError::new(format!("failed to start Tokio runtime: {reason}")))?;

    let _ = RUNTIME.set(runtime);
    RUNTIME
        .get()
        .ok_or_else(|| KernelError::new("failed to initialize Tokio runtime"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn runtime_has_usable_tls_defaults() {
        super::runtime().unwrap();
        let _ = rustls::ClientConfig::builder()
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth();
    }
}
