pub type KernelResult<T> = Result<T, KernelError>;

/// JS and Elixir bindings translate this string into their own error shapes.
/// The shared error stays one string and does not carry napi-rs or Rustler types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelError {
    message: String,
}

impl KernelError {
    /// The message is already safe to expose.
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
