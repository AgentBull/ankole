use std::fmt;

use crate::common::KernelError;

#[derive(Clone, Debug)]
pub enum TransportError {
    UnknownRoute,
    Backpressure,
    Timeout,
    SocketClosed,
    InvalidConfig(String),
    InvalidEnvelope(String),
    InvalidFrame(String),
    Zmq(String),
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownRoute => write!(f, "unknown_route"),
            Self::Backpressure => write!(f, "backpressure"),
            Self::Timeout => write!(f, "timeout"),
            Self::SocketClosed => write!(f, "socket_closed"),
            Self::InvalidConfig(reason) => write!(f, "invalid_config: {reason}"),
            Self::InvalidEnvelope(reason) => write!(f, "invalid_envelope: {reason}"),
            Self::InvalidFrame(reason) => write!(f, "invalid_frame: {reason}"),
            Self::Zmq(reason) => write!(f, "zmq: {reason}"),
        }
    }
}

impl std::error::Error for TransportError {}

impl From<TransportError> for KernelError {
    fn from(error: TransportError) -> Self {
        KernelError::new(error.to_string())
    }
}

// Maps ZeroMQ send failures into actor-runtime scheduling language.
pub(super) fn map_send_error(error: zmq::Error) -> TransportError {
    match error {
        zmq::Error::EHOSTUNREACH => TransportError::UnknownRoute,
        zmq::Error::EAGAIN => TransportError::Backpressure,
        zmq::Error::ETERM => TransportError::SocketClosed,
        error => transport_error(error),
    }
}

pub(super) fn transport_error(error: zmq::Error) -> TransportError {
    TransportError::Zmq(error.to_string())
}

impl From<KernelError> for TransportError {
    fn from(error: KernelError) -> Self {
        TransportError::InvalidEnvelope(error.to_string())
    }
}
