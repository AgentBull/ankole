//! Block-level zstd compression used by the worker file lane.
//!
//! Each call compresses one logical file block (≤ the lane chunk size) into a
//! self-contained zstd frame. The wire is a concatenation of independent frames,
//! one per `DATA` chunk, so a receiver can decompress each chunk in isolation
//! without reassembling the whole stream first.
//!
//! Decompression is bounded by `max_out`: a block that decodes to more bytes is
//! rejected. That caps zip-bomb exposure at one chunk and removes the need for an
//! external `zstd` binary on either host.

use std::io::{Cursor, Read, Seek};

use crate::common::{KernelError, KernelResult};

/// Compresses one logical block into a single self-contained zstd frame.
///
/// `level` follows the zstd CLI scale (1..=22). The caller picks the level; the
/// kernel does not negotiate it because the wire never advertises per-block
/// parameters.
pub fn zstd_compress_block(raw: &[u8], level: i32) -> KernelResult<Vec<u8>> {
    zstd::encode_all(raw, level).map_err(|error| KernelError::new(error.to_string()))
}

/// Decompresses exactly one zstd frame, rejecting output larger than `max_out`.
///
/// `single_frame` stops the decoder after the first frame. The cursor position
/// is then inspected: if it is short of the full input, the chunk contained more
/// than one frame and is rejected. This enforces the wire invariant that one
/// `DATA` chunk carries exactly one independent frame. Output is bounded by
/// `max_out`, capping zip-bomb exposure at one block.
pub fn zstd_decompress_block(wire: &[u8], max_out: usize) -> KernelResult<Vec<u8>> {
    let mut decoder = zstd::Decoder::new(Cursor::new(wire))
        .map_err(|error| KernelError::new(error.to_string()))?
        .single_frame();

    let mut output = Vec::new();
    let mut buffer = [0u8; 8192];

    loop {
        let read = decoder
            .read(&mut buffer)
            .map_err(|error| KernelError::new(error.to_string()))?;
        if read == 0 {
            break;
        }
        output.extend_from_slice(&buffer[..read]);
        if output.len() > max_out {
            return Err(KernelError::new(format!(
                "zstd decompressed block exceeds max_out ({max_out} bytes)"
            )));
        }
    }

    let mut cursor = decoder.finish();
    let position = cursor
        .stream_position()
        .map_err(|error| KernelError::new(error.to_string()))?;
    if (position as usize) < wire.len() {
        return Err(KernelError::new(
            "zstd chunk contained more than one frame; wire invariant is one DATA chunk = one frame",
        ));
    }

    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_arbitrary_payloads() {
        let payload = b"the quick brown fox jumps over the lazy dog".repeat(64);

        let compressed = zstd_compress_block(&payload, 3).unwrap();
        let decompressed = zstd_decompress_block(&compressed, payload.len()).unwrap();

        assert_eq!(decompressed, payload);
        assert!(compressed.len() < payload.len());
    }

    #[test]
    fn round_trips_an_empty_block() {
        let compressed = zstd_compress_block(&[], 3).unwrap();
        let decompressed = zstd_decompress_block(&compressed, 0).unwrap();

        assert_eq!(decompressed, b"");
    }

    #[test]
    fn rejects_oversized_decompression() {
        let payload = vec![0u8; 4096];
        let compressed = zstd_compress_block(&payload, 3).unwrap();

        let result = zstd_decompress_block(&compressed, 1024);
        assert!(result.is_err());
    }

    #[test]
    fn rejects_malformed_frame() {
        let result = zstd_decompress_block(b"not a zstd frame", 1024);
        assert!(result.is_err());
    }

    #[test]
    fn rejects_multi_frame_chunk() {
        // The wire invariant is one DATA chunk = one independent zstd frame. A
        // chunk that concatenates two frames must be rejected so a receiver never
        // silently decodes more than one block from a single chunk.
        let frame_a = zstd_compress_block(b"alpha".repeat(512).as_slice(), 3).unwrap();
        let frame_b = zstd_compress_block(b"beta".repeat(512).as_slice(), 3).unwrap();
        let mut wire = Vec::new();
        wire.extend_from_slice(&frame_a);
        wire.extend_from_slice(&frame_b);

        let result = zstd_decompress_block(&wire, 2 * 1024 * 1024);
        assert!(result.is_err(), "multi-frame chunk must be rejected");
    }
}
