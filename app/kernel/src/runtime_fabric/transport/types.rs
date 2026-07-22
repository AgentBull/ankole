#[derive(Clone, Debug)]
pub enum RouterEvent {
    Received {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        envelope_bytes: Vec<u8>,
    },
    FileFrame {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        frames: Vec<Vec<u8>>,
    },
    DecodeFailed {
        transport_route: String,
        reason: String,
    },
    SocketError {
        reason: String,
    },
}

#[derive(Debug)]
pub enum DealerEvent {
    RawFrames(Vec<Vec<u8>>),
    SocketError(String),
}

#[derive(Debug)]
pub enum SendOutcome {
    SentOrQueued,
}
