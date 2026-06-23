/// Shared result type for host-neutral kernel code.
pub type KernelResult<T> = Result<T, KernelError>;

/// Carries a stable, host-neutral error message across the Rust core boundary.
///
/// The JS and Elixir bindings translate this into their own error shapes. Keeping
/// the core error as one string avoids leaking napi-rs or Rustler types into the
/// shared implementation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelError {
    message: String,
}

impl KernelError {
    /// Creates a kernel error from a message that is already safe to expose.
    pub(crate) fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for KernelError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for KernelError {}
