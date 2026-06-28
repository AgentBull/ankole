use std::time::Duration;

use serde::Deserialize;

use crate::common::{KernelError, KernelResult};

use super::error::{TransportError, transport_error};

const DEFAULT_ZAP_DOMAIN: &str = "ankole-runtime-fabric";
const DEFAULT_POLL_INTERVAL_MS: u64 = 10;
const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 1_000;
const DEFAULT_IO_TIMEOUT_MS: i32 = 1_000;
const DEFAULT_HWM: i32 = 1_000;
const DEFAULT_LINGER_MS: i32 = 0;
pub(super) const DEFAULT_DEALER_INBOX_MAX_EVENTS: usize = 1_024;
pub(super) const DEFAULT_DEALER_INBOX_MAX_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Debug, Default, Deserialize)]
pub struct SocketOptions {
    #[serde(default)]
    pub sndhwm: Option<i32>,
    #[serde(default)]
    pub rcvhwm: Option<i32>,
    #[serde(default)]
    pub linger_ms: Option<i32>,
    #[serde(default)]
    pub sndtimeo_ms: Option<i32>,
    #[serde(default)]
    pub rcvtimeo_ms: Option<i32>,
}

/// Configuration for the control-plane ROUTER socket.
///
/// The router owns worker routes and uses mandatory send so unknown routes can
/// become retry signals instead of silent message loss.
#[derive(Clone, Debug, Deserialize)]
pub struct RouterConfig {
    #[serde(default)]
    pub endpoint: String,
    #[serde(default)]
    pub worker_auth_key: Option<String>,
    #[serde(default)]
    pub zap_domain: Option<String>,
    #[serde(default)]
    #[serde(flatten)]
    pub socket: SocketOptions,
    #[serde(default)]
    pub poll_interval_ms: Option<u64>,
    #[serde(default)]
    pub command_timeout_ms: Option<u64>,
}

/// Configuration for one computer-worker DEALER socket.
///
/// The DEALER identity is the worker connection route seen by the control plane.
#[derive(Clone, Debug, Deserialize)]
pub struct DealerConfig {
    pub endpoint: String,
    pub identity: String,
    pub username: String,
    pub password: String,
    #[serde(default)]
    #[serde(flatten)]
    pub socket: SocketOptions,
    #[serde(default)]
    pub poll_interval_ms: Option<u64>,
    #[serde(default)]
    pub command_timeout_ms: Option<u64>,
    #[serde(default)]
    pub inbox_max_events: Option<usize>,
    #[serde(default)]
    pub inbox_max_bytes: Option<usize>,
}

impl RouterConfig {
    /// Parses router config from a JSON string passed through a host binding.
    pub fn from_json(json: &str) -> KernelResult<Self> {
        serde_json::from_str(json)
            .map_err(|error| KernelError::new(format!("invalid router config JSON: {error}")))
    }

    pub(super) fn validate(&self) -> Result<(), TransportError> {
        validate_config_non_empty("endpoint", &self.endpoint)?;
        if let Some(key) = &self.worker_auth_key {
            validate_config_non_empty("worker_auth_key", key)?;
        }
        validate_socket_options(&self.socket)?;
        validate_optional_positive_u64("poll_interval_ms", self.poll_interval_ms)?;
        validate_optional_positive_u64("command_timeout_ms", self.command_timeout_ms)?;
        Ok(())
    }

    pub(super) fn zap_domain(&self) -> String {
        self.zap_domain
            .clone()
            .unwrap_or_else(|| DEFAULT_ZAP_DOMAIN.to_string())
    }

    pub(super) fn command_timeout(&self) -> Duration {
        Duration::from_millis(
            self.command_timeout_ms
                .unwrap_or(DEFAULT_COMMAND_TIMEOUT_MS),
        )
    }

    pub(super) fn poll_interval(&self) -> Duration {
        Duration::from_millis(self.poll_interval_ms.unwrap_or(DEFAULT_POLL_INTERVAL_MS))
    }
}

impl DealerConfig {
    /// Parses dealer config from a JSON string passed through a host binding.
    pub fn from_json(json: &str) -> KernelResult<Self> {
        serde_json::from_str(json)
            .map_err(|error| KernelError::new(format!("invalid dealer config JSON: {error}")))
    }

    pub(super) fn validate(&self) -> Result<(), TransportError> {
        validate_config_non_empty("endpoint", &self.endpoint)?;
        validate_config_non_empty("identity", &self.identity)?;
        validate_config_non_empty("username", &self.username)?;
        validate_config_non_empty("password", &self.password)?;
        validate_socket_options(&self.socket)?;
        validate_optional_positive_u64("poll_interval_ms", self.poll_interval_ms)?;
        validate_optional_positive_u64("command_timeout_ms", self.command_timeout_ms)?;
        validate_optional_positive_usize("inbox_max_events", self.inbox_max_events)?;
        validate_optional_positive_usize("inbox_max_bytes", self.inbox_max_bytes)?;
        Ok(())
    }

    pub(super) fn command_timeout(&self) -> Duration {
        Duration::from_millis(
            self.command_timeout_ms
                .unwrap_or(DEFAULT_COMMAND_TIMEOUT_MS),
        )
    }

    pub(super) fn poll_interval(&self) -> Duration {
        Duration::from_millis(self.poll_interval_ms.unwrap_or(DEFAULT_POLL_INTERVAL_MS))
    }
}

// Applies bounded queues and timeouts to both socket roles. Defaults favor
// predictable shutdown and backpressure over unbounded buffering.
pub(super) fn configure_common_socket(
    socket: &zmq::Socket,
    options: &SocketOptions,
) -> Result<(), TransportError> {
    socket
        .set_sndhwm(options.sndhwm.unwrap_or(DEFAULT_HWM))
        .map_err(transport_error)?;
    socket
        .set_rcvhwm(options.rcvhwm.unwrap_or(DEFAULT_HWM))
        .map_err(transport_error)?;
    socket
        .set_linger(options.linger_ms.unwrap_or(DEFAULT_LINGER_MS))
        .map_err(transport_error)?;
    socket
        .set_sndtimeo(options.sndtimeo_ms.unwrap_or(DEFAULT_IO_TIMEOUT_MS))
        .map_err(transport_error)?;
    socket
        .set_rcvtimeo(options.rcvtimeo_ms.unwrap_or(DEFAULT_IO_TIMEOUT_MS))
        .map_err(transport_error)?;
    Ok(())
}

pub(super) fn validate_config_non_empty(field: &str, value: &str) -> Result<(), TransportError> {
    if value.trim().is_empty() {
        Err(TransportError::InvalidConfig(format!(
            "{field} must not be empty"
        )))
    } else {
        Ok(())
    }
}

fn validate_optional_positive(field: &str, value: Option<i32>) -> Result<(), TransportError> {
    match value {
        Some(value) if value <= 0 => Err(TransportError::InvalidConfig(format!(
            "{field} must be positive"
        ))),
        _ => Ok(()),
    }
}

fn validate_socket_options(options: &SocketOptions) -> Result<(), TransportError> {
    validate_optional_positive("sndhwm", options.sndhwm)?;
    validate_optional_positive("rcvhwm", options.rcvhwm)?;
    validate_optional_non_negative_or_infinite("linger_ms", options.linger_ms)?;
    validate_optional_non_negative_or_infinite("sndtimeo_ms", options.sndtimeo_ms)?;
    validate_optional_non_negative_or_infinite("rcvtimeo_ms", options.rcvtimeo_ms)?;
    Ok(())
}

fn validate_optional_non_negative_or_infinite(
    field: &str,
    value: Option<i32>,
) -> Result<(), TransportError> {
    match value {
        Some(value) if value < -1 => Err(TransportError::InvalidConfig(format!(
            "{field} must be -1 or non-negative"
        ))),
        _ => Ok(()),
    }
}

fn validate_optional_positive_u64(field: &str, value: Option<u64>) -> Result<(), TransportError> {
    match value {
        Some(0) => Err(TransportError::InvalidConfig(format!(
            "{field} must be positive"
        ))),
        _ => Ok(()),
    }
}

fn validate_optional_positive_usize(
    field: &str,
    value: Option<usize>,
) -> Result<(), TransportError> {
    match value {
        Some(0) => Err(TransportError::InvalidConfig(format!(
            "{field} must be positive"
        ))),
        _ => Ok(()),
    }
}
