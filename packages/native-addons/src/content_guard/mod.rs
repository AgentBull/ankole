use napi_derive::napi;
use regex::Regex;
use std::sync::LazyLock;

const SPECIAL_TOKEN_REPLACEMENT: &str = "[REMOVED_SPECIAL_TOKEN]";
const FULLWIDTH_ASCII_OFFSET: u32 = 0xfee0;

const LLM_SPECIAL_TOKEN_LITERALS: &[&str] = &[
  "<|im_start|>",
  "<|im_end|>",
  "<|endoftext|>",
  "<|begin_of_text|>",
  "<|end_of_text|>",
  "<|start_header_id|>",
  "<|end_header_id|>",
  "<|eot_id|>",
  "<|python_tag|>",
  "<|eom_id|>",
  "[INST]",
  "[/INST]",
  "<<SYS>>",
  "<</SYS>>",
  "<s>",
  "</s>",
  "<|channel|>",
  "<|message|>",
  "<|return|>",
  "<|call|>",
  "<start_of_turn>",
  "<end_of_turn>",
];

static RESERVED_SPECIAL_TOKEN: LazyLock<Regex> =
  LazyLock::new(|| Regex::new(r"<\|reserved_special_token_\d+\|>").expect("static regex"));

static MARKER_HINT: LazyLock<Regex> =
  LazyLock::new(|| Regex::new(r"(?i)external[\s_]+untrusted[\s_]+content").expect("static regex"));

static START_MARKER: LazyLock<Regex> = LazyLock::new(|| {
  Regex::new(r#"(?i)<<<\s*EXTERNAL[\s_]+UNTRUSTED[\s_]+CONTENT(?:\s+id="[^"]{1,128}")?\s*>>>"#)
    .expect("static regex")
});

static END_MARKER: LazyLock<Regex> = LazyLock::new(|| {
  Regex::new(
    r#"(?i)<<<\s*END[\s_]+EXTERNAL[\s_]+UNTRUSTED[\s_]+CONTENT(?:\s+id="[^"]{1,128}")?\s*>>>"#,
  )
  .expect("static regex")
});

/// Confusable angle-bracket code points folded to ASCII `<` / `>` before the
/// marker scan, so external content cannot smuggle wrapper markers past the
/// scanner with lookalike glyphs.
fn fold_char(ch: char) -> char {
  let code = ch as u32;
  // Fullwidth ASCII letters (A-Z / a-z).
  if (0xff21..=0xff3a).contains(&code) || (0xff41..=0xff5a).contains(&code) {
    return char::from_u32(code - FULLWIDTH_ASCII_OFFSET).unwrap_or(ch);
  }
  match code {
    0xff1c | 0x2329 | 0x3008 | 0x2039 | 0x27e8 | 0xfe64 | 0x00ab | 0x300a | 0x27ea => '<',
    0xff1e | 0x232a | 0x3009 | 0x203a | 0x27e9 | 0xfe65 | 0x00bb | 0x300b | 0x27eb => '>',
    _ => ch,
  }
}

/// Zero-width and soft-hyphen code points the scanner skips entirely.
fn is_ignorable(ch: char) -> bool {
  matches!(
    ch as u32,
    0x200b | 0x200c | 0x200d | 0x2060 | 0xfeff | 0x00ad
  )
}

struct FoldedText {
  folded: String,
  /// Byte offset in the original string where each folded byte's source char starts.
  original_start: Vec<usize>,
  /// Byte offset in the original string just past each folded byte's source char.
  original_end: Vec<usize>,
}

fn fold_with_index_map(input: &str) -> FoldedText {
  let mut folded = String::with_capacity(input.len());
  let mut original_start = Vec::with_capacity(input.len());
  let mut original_end = Vec::with_capacity(input.len());
  for (byte_index, ch) in input.char_indices() {
    if is_ignorable(ch) {
      continue;
    }
    let mapped = fold_char(ch);
    let before = folded.len();
    folded.push(mapped);
    let char_end = byte_index + ch.len_utf8();
    for _ in before..folded.len() {
      original_start.push(byte_index);
      original_end.push(char_end);
    }
  }
  FoldedText {
    folded,
    original_start,
    original_end,
  }
}

fn replace_markers(content: &str) -> String {
  let folded = fold_with_index_map(content);
  if !MARKER_HINT.is_match(&folded.folded) {
    return content.to_string();
  }

  let mut replacements: Vec<(usize, usize, &str)> = Vec::new();
  for (regex, value) in [
    (&*START_MARKER, "[[MARKER_SANITIZED]]"),
    (&*END_MARKER, "[[END_MARKER_SANITIZED]]"),
  ] {
    for found in regex.find_iter(&folded.folded) {
      let start = folded
        .original_start
        .get(found.start())
        .copied()
        .unwrap_or(found.start());
      let end = folded
        .original_end
        .get(found.end().saturating_sub(1))
        .copied()
        .unwrap_or(found.end());
      replacements.push((start, end, value));
    }
  }

  if replacements.is_empty() {
    return content.to_string();
  }
  replacements.sort_by_key(|(start, _, _)| *start);
  let mut output = String::with_capacity(content.len());
  let mut cursor = 0usize;
  for (start, end, value) in replacements {
    if start < cursor {
      continue;
    }
    output.push_str(&content[cursor..start]);
    output.push_str(value);
    cursor = end;
  }
  output.push_str(&content[cursor..]);
  output
}

fn replace_llm_special_tokens(content: &str) -> String {
  let mut output = content.to_string();
  for literal in LLM_SPECIAL_TOKEN_LITERALS {
    if output.contains(literal) {
      output = output.replace(literal, SPECIAL_TOKEN_REPLACEMENT);
    }
  }
  RESERVED_SPECIAL_TOKEN
    .replace_all(&output, SPECIAL_TOKEN_REPLACEMENT)
    .into_owned()
}

/// Neutralizes wrapper-marker forgeries (including fullwidth/lookalike glyph
/// and zero-width-character evasions) and known LLM special tokens in external
/// untrusted content, before the host wraps it with authentic markers.
#[napi]
pub fn sanitize_external_content_text(content: String) -> String {
  replace_llm_special_tokens(&replace_markers(&content))
}
