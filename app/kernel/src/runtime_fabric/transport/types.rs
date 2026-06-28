#[derive(Clone, Debug)]
pub enum RouterEvent {
    Received {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        authenticated_key_revision: Option<i64>,
        envelope_json: String,
    },
    FileFrame {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        authenticated_key_revision: Option<i64>,
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
    Received(Vec<u8>),
    FileFrame(Vec<Vec<u8>>),
    DecodeFailed(String),
    SocketError(String),
}

#[derive(Debug)]
pub enum SendOutcome {
    SentOrQueued,
}
