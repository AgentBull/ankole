use base64_simd::URL_SAFE_NO_PAD;

use crate::common::{KernelError, KernelResult};

/// Encodes bytes with the URL-safe Base64 alphabet and no padding.
///
/// No padding is intentional: it keeps generated tokens short and avoids `=`
/// characters in places where callers often paste identifiers into URLs or config.
pub fn base64_url_safe_encode(input: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode_to_string(input)
}

/// Decodes the padding-free URL-safe Base64 form used by kernel wire tokens.
pub fn base64_url_safe_decode(input: &str) -> KernelResult<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode_to_vec(input)
        .map_err(|error| KernelError::new(error.to_string()))
}
