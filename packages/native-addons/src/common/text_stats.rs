use napi_derive::napi;

/// CJK-aware character weight used by the token estimator: CJK-family code
/// points count as a full estimated token (4 chars), everything else counts
/// its UTF-16 length. Matches the host-side compaction calibration.
fn char_weight(ch: char) -> u32 {
  let cp = ch as u32;
  let is_cjk = matches!(
    cp,
    0x2e80..=0x9fff | 0xa000..=0xa4ff | 0xac00..=0xd7af | 0xf900..=0xfaff | 0x20000..=0x2fa1f
  );
  if is_cjk { 4 } else { ch.len_utf16() as u32 }
}

/// Estimated character count for token estimation: CJK code points are
/// weighted so that one CJK character ~= one token under the 4-chars/token
/// heuristic. Hot path of the compaction trigger.
#[napi]
pub fn estimate_string_chars(text: String) -> u32 {
  text.chars().map(char_weight).sum()
}
