use super::error::TransportError;

pub(super) const FILE_TRANSFER_PROTOCOL: &[u8] = b"ANKOLE_FILE/1";

#[derive(Debug)]
pub(super) enum RouterInbound {
    Envelope { route: String, payload: Vec<u8> },
    FileFrame { route: String, frames: Vec<Vec<u8>> },
}

// Parses ROUTER frames from DEALER workers. A leading empty delimiter is
// tolerated so tests and proxies can use common multipart conventions.
pub(super) fn parse_router_frames(
    mut frames: Vec<Vec<u8>>,
) -> Result<RouterInbound, (Option<String>, TransportError)> {
    if frames.len() < 2 {
        return Err((
            None,
            TransportError::InvalidFrame("router message must include route and payload".into()),
        ));
    }

    let route_frame = frames.remove(0);
    let route = String::from_utf8(route_frame).map_err(|error| {
        (
            None,
            TransportError::InvalidFrame(format!("route identity must be UTF-8: {error}")),
        )
    })?;

    if frames.len() >= 2 && frames[0].is_empty() {
        frames.remove(0);
    }

    if frames.first().map(Vec::as_slice) == Some(FILE_TRANSFER_PROTOCOL) {
        Ok(RouterInbound::FileFrame { route, frames })
    } else {
        let payload = frames.remove(0);
        Ok(RouterInbound::Envelope { route, payload })
    }
}

pub(super) fn validate_file_transfer_frames(frames: &[Vec<u8>]) -> Result<(), TransportError> {
    match frames.first() {
        Some(protocol) if protocol.as_slice() == FILE_TRANSFER_PROTOCOL => Ok(()),
        Some(_) => Err(TransportError::InvalidFrame(
            "worker file frames must start with ANKOLE_FILE/1".into(),
        )),
        None => Err(TransportError::InvalidFrame(
            "worker file frame set must not be empty".into(),
        )),
    }
}
