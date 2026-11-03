use uuid::Uuid;

/// Structured node spellings shared by forward encoding and new-path parsing.
pub const SUFFIXES: [(&str, &str); 4] = [
    ("knowledge", "._awiki.md"),
    ("doc", "._adoc.md"),
    ("base", "._abase"),
    ("applet", "._aapp"),
];

fn tagged(name: &str) -> bool {
    let bytes = name.as_bytes();
    bytes.len() >= 11
        && bytes[bytes.len() - 11] == b'~'
        && bytes[bytes.len() - 10..].iter().all(u8::is_ascii_hexdigit)
}

/// Preserve ordinary names and encode reserved or long names with a stable node tag.
pub fn encode(name: &str, kind: &str, id: &str) -> Result<String, String> {
    use unicode_segmentation::UnicodeSegmentation;

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
}
