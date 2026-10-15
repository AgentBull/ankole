use base64_simd::URL_SAFE_NO_PAD;

use crate::common::{KernelError, KernelResult};

pub fn base64_url_safe_encode(input: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode_to_string(input)
}

/// Kernel wire tokens use this padding-free form.
pub fn base64_url_safe_decode(input: &str) -> KernelResult<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode_to_vec(input)
        .map_err(|error| KernelError::new(error.to_string()))
}
