use std::sync::OnceLock;

use tokio::runtime::{Builder, Runtime};

use crate::common::{KernelError, KernelResult};

static RUNTIME: OnceLock<Runtime> = OnceLock::new();

pub fn runtime() -> KernelResult<&'static Runtime> {
    if let Some(runtime) = RUNTIME.get() {
        return Ok(runtime);
    }

    let runtime = Builder::new_multi_thread()
        .thread_name("ankole-universal-ai-client")
        .enable_all()
        .build()
        .map_err(|reason| KernelError::new(format!("failed to start Tokio runtime: {reason}")))?;

    let _ = RUNTIME.set(runtime);
    RUNTIME
        .get()
        .ok_or_else(|| KernelError::new("failed to initialize Tokio runtime"))
}
