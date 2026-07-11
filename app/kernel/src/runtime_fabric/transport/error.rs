use std::fmt;

#[derive(Clone, Debug)]
pub enum TransportError {
    UnknownRoute,
    Backpressure,
    Timeout,
    SocketClosed,
    InvalidConfig(String),
    InvalidEnvelope(String),
    InvalidFrame(String),
    ZMQ(String),
}

impl TransportError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownRoute => "unknown_route",
            Self::Backpressure => "backpressure",
            Self::Timeout => "timeout",
            Self::SocketClosed => "socket_closed",
            Self::InvalidConfig(_reason) => "invalid_config",
            Self::InvalidEnvelope(_reason) => "invalid_envelope",
            Self::InvalidFrame(_reason) => "invalid_frame",
            Self::ZMQ(_reason) => "zmq",
        }
    }

    pub fn ffi_message(&self) -> String {
        match self {
            Self::UnknownRoute | Self::Backpressure | Self::Timeout | Self::SocketClosed => {
                self.code().to_string()
            }
            Self::InvalidConfig(reason)
            | Self::InvalidEnvelope(reason)
            | Self::InvalidFrame(reason)
            | Self::ZMQ(reason) => format!("{}: {reason}", self.code()),
        }
    }

    pub(super) fn invalid_envelope(error: crate::common::KernelError) -> Self {
        Self::InvalidEnvelope(error.to_string())
    }
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.ffi_message())
    }
}

impl std::error::Error for TransportError {}

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
    TransportError::ZMQ(error.to_string())
}
