/// A single RFC 9110 byte range. Multiple ranges are deliberately unsupported.
pub fn byte_range(value: &str, size: u64) -> Result<(u64, u64), String> {
    let value = value.strip_prefix("bytes=").ok_or("invalid range unit")?;
    let (start, end) = value.split_once('-').ok_or("invalid byte range")?;
    let number = |s: &str| {
        s.parse::<u64>()
            .map_err(|_| "invalid byte offset".to_owned())
    };
    if size == 0 {
        return Err("unsatisfiable range".into());
    }
    let (start, end) = if start.is_empty() {
        let count = number(end)?;
        if count == 0 {
            return Err("unsatisfiable range".into());
        }
        (size.saturating_sub(count), size - 1)
    } else {
        (
            number(start)?,
            if end.is_empty() {
                size - 1
            } else {
                number(end)?.min(size - 1)
            },
        )
    };
    if start > end || start >= size {
        return Err("unsatisfiable range".into());
    }
    Ok((start, end - start + 1))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tail_and_open_ranges_are_bounded() {
        assert_eq!(byte_range("bytes=-5", 100).unwrap(), (95, 5));
        assert_eq!(byte_range("bytes=90-", 100).unwrap(), (90, 10));
        assert_eq!(byte_range("bytes=90-500", 100).unwrap(), (90, 10));
        for value in ["bytes=100-", "bytes=-0", "bytes=10-5", "bytes=1-2,4-5"] {
            assert!(byte_range(value, 100).is_err());
        }
        assert!(byte_range("bytes=0-", 0).is_err());
    }
}
