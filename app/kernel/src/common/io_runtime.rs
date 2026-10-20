//! The shared Tokio runtime for native I/O from BEAM and Node-API callers.

use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

use crate::common::{KernelError, KernelResult};

static RUNTIME: OnceLock<Result<Runtime, std::io::Error>> = OnceLock::new();

pub fn runtime() -> KernelResult<&'static Runtime> {
    RUNTIME
        .get_or_init(|| {
            // OpenDAL's PostgreSQL driver also enables ring. Keep a provider
            // that the host already set before native HTTP starts.
            #[cfg(any(feature = "universal_ai_client", feature = "object_store"))]
            let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

            Builder::new_multi_thread()
                .thread_name("ankole-kernel-io")
                .enable_all()
                .build()
        })
        .as_ref()
        .map_err(|reason| KernelError::new(format!("failed to start Tokio runtime: {reason}")))
}

#[cfg(all(test, any(feature = "universal_ai_client", feature = "object_store")))]
mod tests {
    #[test]
    fn runtime_has_usable_tls_defaults() {
        super::runtime().unwrap();
        let _ = rustls::ClientConfig::builder()
            .with_root_certificates(rustls::RootCertStore::empty())
            .with_no_client_auth();
    }
}
