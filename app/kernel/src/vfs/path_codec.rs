use std::borrow::Cow;
use unicode_normalization::{UnicodeNormalization, is_nfc};
use uuid::Uuid;

/// Maximum raw UTF-8 byte length accepted before Unicode NFC normalization so decomposed NFD
/// segments near the 255-byte NFC limit normalize cleanly without unbounded allocation.
const MAX_RAW_SEGMENT_BYTES: usize = 1024;

/// Structured node spellings shared by forward encoding and new-path parsing.
pub const SUFFIXES: [(&str, &str); 4] = [
    ("knowledge", "._awiki.md"),
    ("doc", "._adoc.md"),
    ("base", "._abase"),
    ("applet", "._aapp"),
];

/// Normalizes a Drive/WebDAV/FUSE path segment to Unicode NFC without allocating when already NFC.
pub fn normalize_nfc(input: &str) -> Cow<'_, str> {
    if is_nfc(input) {
        Cow::Borrowed(input)
    } else {
        Cow::Owned(input.nfc().collect())
    }
}

fn tagged(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() >= 11
        && bytes[bytes.len() - 11] == b'~'
        && bytes[bytes.len() - 10..].iter().all(u8::is_ascii_hexdigit)
}

/// Preserve ordinary names (normalized to Unicode NFC) and encode reserved or long names with a
/// stable node tag.
pub fn encode(name: &str, kind: &str, id: &str) -> Result<String, String> {
    use unicode_segmentation::UnicodeSegmentation;

    let name = normalize_nfc(name);
    let name = name.as_ref();
    let suffix = SUFFIXES
        .iter()
        .find(|(k, _)| *k == kind)
        .map_or("", |(_, s)| *s);
    let mut stem = name.to_owned();
    if tagged(name) {
        stem.insert(name.len() - 11, '~');
    }
    // Persisted raw names may predate the reserved compound suffixes. Give
    // those files the same identity-qualified spelling used for long names.
    let reserved_raw = matches!(kind, "file" | "folder" | "children")
        && SUFFIXES.iter().any(|(_, s)| name.ends_with(s));
    if stem.len() + suffix.len() > 255 || reserved_raw {
        let id = Uuid::parse_str(id).map_err(|e| e.to_string())?;
        let digest = blake3::hash(id.as_bytes()).to_hex();
        let budget = 255 - suffix.len() - 11;
        stem = name
            .graphemes(true)
            .scan(0, |length, g| {
                *length += g.len();
                (*length <= budget).then_some(g)
            })
            .collect();
        stem.push('~');
        stem.push_str(&digest[..10]);
    }
    Ok(stem + suffix)
}

/// New paths have no identity with which to decode a shortened name. Existing
/// paths are resolved by comparing encode(node) with the requested segment.
pub fn decode_new(segment: &str) -> Result<(String, String), String> {
    if segment.is_empty() || segment.len() > MAX_RAW_SEGMENT_BYTES {
        return Err("invalid Drive path segment".into());
    }
    let normalized = normalize_nfc(segment);
    let segment = normalized.as_ref();
    if segment.is_empty()
        || segment.len() > 255
        || matches!(segment, "." | "..")
        || segment.chars().any(|c| c == '/' || c.is_control())
    {
        return Err("invalid Drive path segment".into());
    }
    let (kind, mut name) = SUFFIXES
        .iter()
        .find_map(|(kind, suffix)| {
            segment
                .strip_suffix(suffix)
                .map(|name| (*kind, name.to_owned()))
        })
        .unwrap_or(("file", segment.to_owned()));
    if tagged(&name) {
        let marker = name.len() - 11;
        if marker > 0 && name.as_bytes()[marker - 1] == b'~' {
            name.remove(marker);
        } else {
            return Err("shortened names can only address existing nodes".into());
        }
    }
    if name.is_empty() {
        return Err("empty Drive name".into());
    }
    Ok((name, kind.into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "019a3d91-c673-7000-8000-000000000001";

    #[test]
    fn names_round_trip_and_truncate_at_graphemes() {
        for name in ["合同", "README.md", "tail~0123456789", "tail~~0123456789"] {
            for (kind, _) in SUFFIXES {
                let encoded = encode(name, kind, ID).unwrap();
                assert_eq!(decode_new(&encoded).unwrap(), (name.into(), kind.into()));
            }
        }
        let name = "界".repeat(85);
        let encoded = encode(&name, "knowledge", ID).unwrap();
        assert!(encoded.len() <= 255);
        assert!(encoded.ends_with("._awiki.md"));
        assert!(decode_new(&encoded).is_err());
        assert_ne!(
            encoded,
            encode(&name, "knowledge", "019a3d91-c673-7000-8000-000000000002").unwrap()
        );
    }

    #[test]
    fn normalizes_macos_nfd_hangul_jamo_and_cjk_compatibility_segments_to_nfc() {
        // Decomposed Latin ("cafe\u{0301}") <-> precomposed NFC ("café")
        let nfd_cafe = "cafe\u{0301}";
        let nfc_cafe = "caf\u{00e9}";
        assert_eq!(
            encode(nfd_cafe, "doc", ID).unwrap(),
            encode(nfc_cafe, "doc", ID).unwrap()
        );
        assert_eq!(
            decode_new(&format!("{nfd_cafe}._adoc.md")).unwrap(),
            (nfc_cafe.to_owned(), "doc".to_owned())
        );
        assert_eq!(
            decode_new(&format!("{nfd_cafe}.txt")).unwrap(),
            (format!("{nfc_cafe}.txt"), "file".to_owned())
        );

        // Decomposed Hangul Jamo ("\u{1100}\u{1161}") <-> precomposed syllable ("가")
        let nfd_hangul = "\u{1100}\u{1161}\u{1102}\u{1161}";
        let nfc_hangul = "가나";
        assert_eq!(
            encode(nfd_hangul, "knowledge", ID).unwrap(),
            format!("{nfc_hangul}._awiki.md")
        );
        assert_eq!(
            decode_new(&format!("{nfd_hangul}._awiki.md")).unwrap(),
            (nfc_hangul.to_owned(), "knowledge".to_owned())
        );

        // CJK canonical singleton compatibility ideograph ("\u{f900}") -> NFC ("豈")
        assert_eq!(encode("\u{f900}劃", "file", ID).unwrap(), "豈劃");
        assert_eq!(
            decode_new("\u{f900}劃.pdf").unwrap(),
            ("豈劃.pdf".to_owned(), "file".to_owned())
        );

        // NFD segment whose decomposed UTF-8 exceeds 255 bytes (>255) but whose NFC form fits (<=255)
        let nfd_near_limit = "e\u{0301}".repeat(125); // 375 UTF-8 bytes in NFD, 250 UTF-8 bytes in NFC
        let nfc_near_limit = "\u{00e9}".repeat(125);
        assert!(nfd_near_limit.len() > 255);
        assert!(nfc_near_limit.len() <= 255);
        assert_eq!(
            decode_new(&nfd_near_limit).unwrap(),
            (nfc_near_limit, "file".to_owned())
        );
    }
}
