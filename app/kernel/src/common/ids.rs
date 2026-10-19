use uuid::Uuid as UUID;

use crate::common::{KernelError, KernelResult, base64_url_safe_decode, base64_url_safe_encode};

pub fn gen_uuid() -> String {
    UUID::new_v4().to_string()
}

pub fn gen_uuid_v7() -> String {
    UUID::now_v7().to_string()
}

pub fn uuid_shorten(value: &str) -> KernelResult<String> {
    let uuid = UUID::parse_str(value).map_err(|_| KernelError::new("invalid canonical UUID"))?;
    if uuid.to_string() != value {
        return Err(KernelError::new("invalid canonical UUID"));
    }
    Ok(base64_url_safe_encode(uuid.as_bytes()))
}

pub fn uuid_expand(value: &str) -> KernelResult<String> {
    if value.len() != 22 {
        return Err(KernelError::new("invalid short UUID"));
    }
    let bytes = base64_url_safe_decode(value)?;
    if bytes.len() != 16 || base64_url_safe_encode(&bytes) != value {
        return Err(KernelError::new("invalid short UUID"));
    }
    UUID::from_slice(&bytes)
        .map(|uuid| uuid.to_string())
        .map_err(|_| KernelError::new("invalid short UUID"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_ids_follow_shared_canonical_vectors() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../../test/vectors/uuid_url.json")).unwrap();
        for vector in vectors["valid"].as_array().unwrap() {
            let uuid = vector["uuid"].as_str().unwrap();
            let short = vector["short"].as_str().unwrap();
            assert_eq!(uuid_shorten(uuid).unwrap(), short);
            assert_eq!(uuid_expand(short).unwrap(), uuid);
        }
        for value in vectors["invalid_short"].as_array().unwrap() {
            assert!(uuid_expand(value.as_str().unwrap()).is_err(), "{value}");
        }
        for value in vectors["invalid_uuid"].as_array().unwrap() {
            assert!(uuid_shorten(value.as_str().unwrap()).is_err(), "{value}");
        }
    }
}
