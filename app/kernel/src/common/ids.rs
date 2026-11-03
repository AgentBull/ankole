use any_ascii::any_ascii_char;
use uuid::Uuid as UUID;

use crate::common::{KernelError, KernelResult};

const CROCKFORD_LOWER: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
const SHORT_UUID_LEN: usize = 26;
const MAX_PAGE_SLUG_LEN: usize = 60;
const MIN_WORD_BOUNDARY_LEN: usize = 16;

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
    let bits = u128::from_be_bytes(*uuid.as_bytes());
    let mut encoded = String::with_capacity(SHORT_UUID_LEN);
    for step in (0..SHORT_UUID_LEN).rev() {
        let index = ((bits >> (step * 5)) & 0x1f) as usize;
        if let Some(&byte) = CROCKFORD_LOWER.get(index) {
            encoded.push(char::from(byte));
        }
    }
    Ok(encoded)
}

pub fn uuid_expand(value: &str) -> KernelResult<String> {
    let bytes = value.as_bytes();
    if bytes.len() != SHORT_UUID_LEN {
        return Err(KernelError::new("invalid short UUID"));
    }
    let Some(&first) = bytes.first() else {
        return Err(KernelError::new("invalid short UUID"));
    };
    let Some(first_digit) = crockford_digit(first) else {
        return Err(KernelError::new("invalid short UUID"));
    };
    if first_digit > 7 {
        return Err(KernelError::new("invalid short UUID"));
    }
    let mut bits = u128::from(first_digit);
    for &byte in &bytes[1..] {
        let Some(digit) = crockford_digit(byte) else {
            return Err(KernelError::new("invalid short UUID"));
        };
        bits = (bits << 5) | u128::from(digit);
    }
    Ok(UUID::from_bytes(bits.to_be_bytes()).to_string())
}

pub fn page_url_slug(title: &str) -> String {
    let mut transliterated = String::with_capacity(title.len());
    for ch in title.chars() {
        if ch.is_ascii() {
            transliterated.push(ch);
        } else {
            let ascii = any_ascii_char(ch);
            if is_han(ch) {
                transliterated.push(' ');
                transliterated.push_str(ascii);
                transliterated.push(' ');
            } else {
                transliterated.push_str(ascii);
            }
        }
    }

    let mut slug = String::with_capacity(transliterated.len());
    let mut pending_dash = false;
    for byte in transliterated.bytes() {
        if byte == b'.' {
            continue;
        }
        let lower = byte.to_ascii_lowercase();
        if lower.is_ascii_lowercase() || lower.is_ascii_digit() {
            if pending_dash && !slug.is_empty() {
                slug.push('-');
            }
            slug.push(char::from(lower));
            pending_dash = false;
        } else if !slug.is_empty() {
            pending_dash = true;
        }
    }

    truncate_page_slug(&slug).to_string()
}

fn truncate_page_slug(slug: &str) -> &str {
    if slug.len() <= MAX_PAGE_SLUG_LEN {
        return slug;
    }
    let sliced = slug[..MAX_PAGE_SLUG_LEN].trim_end_matches('-');
    if let Some(last_dash) = sliced.rfind('-')
        && last_dash >= MIN_WORD_BOUNDARY_LEN
    {
        return &sliced[..last_dash];
    }
    sliced
}

fn is_han(ch: char) -> bool {
    matches!(
        u32::from(ch),
        0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF | 0x20000..=0x323AF
    )
}

fn crockford_digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'h' => Some(byte - b'a' + 10),
        b'j'..=b'k' => Some(byte - b'j' + 18),
        b'm'..=b'n' => Some(byte - b'm' + 20),
        b'p'..=b't' => Some(byte - b'p' + 22),
        b'v'..=b'z' => Some(byte - b'v' + 27),
        _ => None,
    }
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

    #[test]
    fn page_slugs_follow_shared_pod_url_vectors() {
        let vectors: serde_json::Value =
            serde_json::from_str(include_str!("../../test/vectors/pod_url.json")).unwrap();
        for vector in vectors["slugs"].as_array().unwrap() {
            let title = vector["title"].as_str().unwrap();
            let slug = vector["slug"].as_str().unwrap();
            assert_eq!(page_url_slug(title), slug, "{title}");
        }
    }
}
