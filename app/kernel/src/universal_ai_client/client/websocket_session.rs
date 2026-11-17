use std::sync::{Arc, Mutex};

use crate::universal_ai_client::error::StreamError;
use crate::universal_ai_client::transport::UpstreamWebSocket;

pub(in crate::universal_ai_client) struct ParkedWebSocket {
    pub(in crate::universal_ai_client) websocket: Box<UpstreamWebSocket>,
    pub(in crate::universal_ai_client) headers: Vec<(String, String)>,
}

enum SessionSlot {
    Empty,
    Leased,
    Parked(ParkedWebSocket),
    Closed,
}

/// Reusable single-lane upstream WebSocket holder shared across model turns.
///
/// Only one stream may lease the session at a time. A stream parks its socket
/// back into the session only when it reaches a clean provider terminal; any
/// cancellation, error, or early drop transitions the session to `Closed` and
/// drops the underlying socket immediately.
pub struct WebSocketSession {
    slot: Mutex<SessionSlot>,
}

impl std::fmt::Debug for WebSocketSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let state = match self.slot.lock() {
            Ok(guard) => match &*guard {
                SessionSlot::Empty => "empty",
                SessionSlot::Leased => "leased",
                SessionSlot::Parked(_) => "parked",
                SessionSlot::Closed => "closed",
            },
            Err(_) => "poisoned",
        };
        formatter
            .debug_struct("WebSocketSession")
            .field("state", &state)
            .finish()
    }
}

impl Default for WebSocketSession {
    fn default() -> Self {
        Self::new()
    }
}

impl WebSocketSession {
    pub fn new() -> Self {
        Self {
            slot: Mutex::new(SessionSlot::Empty),
        }
    }

    /// Closes the session and drops any parked upstream socket immediately.
    pub fn close(&self) {
        let mut guard = self
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard = SessionSlot::Closed;
    }

    pub fn has_parked_socket(&self) -> bool {
        let guard = self
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        matches!(&*guard, SessionSlot::Parked(_))
    }

    pub(in crate::universal_ai_client) fn checkout(
        session: &Arc<Self>,
    ) -> Result<WebSocketSessionLease, StreamError> {
        let mut guard = session
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match std::mem::replace(&mut *guard, SessionSlot::Closed) {
            SessionSlot::Empty => {
                *guard = SessionSlot::Leased;
                Ok(WebSocketSessionLease {
                    session: Arc::clone(session),
                    parked: None,
                    returned: false,
                })
            }
            SessionSlot::Parked(parked) => {
                *guard = SessionSlot::Leased;
                Ok(WebSocketSessionLease {
                    session: Arc::clone(session),
                    parked: Some(parked),
                    returned: false,
                })
            }
            SessionSlot::Leased => {
                *guard = SessionSlot::Leased;
                Err(StreamError::new(
                    "websocket_session_busy",
                    "connect",
                    "upstream WebSocket session already has an active stream",
                ))
            }
            SessionSlot::Closed => {
                *guard = SessionSlot::Closed;
                Err(StreamError::new(
                    "websocket_session_closed",
                    "connect",
                    "upstream WebSocket session is closed",
                ))
            }
        }
    }
}

pub(in crate::universal_ai_client) struct WebSocketSessionLease {
    session: Arc<WebSocketSession>,
    parked: Option<ParkedWebSocket>,
    returned: bool,
}

impl WebSocketSessionLease {
    pub(in crate::universal_ai_client) fn take_parked(&mut self) -> Option<ParkedWebSocket> {
        self.parked.take()
    }

    pub(in crate::universal_ai_client) fn park(
        &mut self,
        websocket: Box<UpstreamWebSocket>,
        headers: Vec<(String, String)>,
    ) {
        let mut guard = self
            .session
            .slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if matches!(&*guard, SessionSlot::Leased) {
            *guard = SessionSlot::Parked(ParkedWebSocket { websocket, headers });
            self.returned = true;
        }
    }
}

impl Drop for WebSocketSessionLease {
    fn drop(&mut self) {
        if !self.returned {
            self.session.close();
        }
    }
}
