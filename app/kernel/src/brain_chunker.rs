//! CJK-aware recursive text chunking and exact `o200k_base` token counting for
//! Brain retrieval positions.

use crate::common::estimate_o200k_base_tokens;
use std::fmt;
use unicode_segmentation::UnicodeSegmentation;

/// Upper bound on a single chunking call (32 MiB, above SourceLearning's 10 MiB
/// source body limit) so a single call cannot tie up a dirty CPU scheduler.
pub const MAX_CHUNK_INPUT_BYTES: usize = 32 * 1024 * 1024;

const CJK_DENSITY_THRESHOLD: f64 = 0.30;
const DENSITY_PROBE_CHARS: usize = 2_000;
const DELIMITER_LEVELS: usize = 5;

/// Input validation error returned by [`chunk_text_with_tokens`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChunkError {
    InputTooLarge { max_bytes: usize },
    ZeroChunkSize,
    OverlapAtLeastChunkSize,
    ZeroMaxChars,
    ZeroMaxTokens,
}

impl fmt::Display for ChunkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge { max_bytes } => {
                write!(
                    f,
                    "text exceeds maximum chunker input size of {max_bytes} bytes"
                )
            }
            Self::ZeroChunkSize => f.write_str("chunk_size must be positive"),
            Self::OverlapAtLeastChunkSize => {
                f.write_str("chunk_overlap must be less than chunk_size")
            }
            Self::ZeroMaxChars => f.write_str("max_chars must be positive"),
            Self::ZeroMaxTokens => f.write_str("max_tokens must be positive"),
        }
    }
}

impl std::error::Error for ChunkError {}

#[derive(Clone, Copy, Debug, Default)]
struct WordStats {
    non_ws_graphemes: usize,
    cjk_chars: usize,
    ws_runs: usize,
}

impl WordStats {
    fn from_str(text: &str) -> Self {
        if text.is_empty() {
            return Self::default();
        }

        let non_ws_graphemes = count_non_ws_graphemes(text);
        let mut cjk_chars = 0usize;
        let mut ws_runs = 0usize;
        let mut in_run = false;

        for ch in text.chars() {
            if is_cjk_char(ch) {
                cjk_chars += 1;
            }

            if ch.is_whitespace() {
                in_run = false;
            } else if !in_run {
                ws_runs += 1;
                in_run = true;
            }
        }

        Self {
            non_ws_graphemes,
            cjk_chars,
            ws_runs,
        }
    }

    fn word_count(self) -> usize {
        if self.non_ws_graphemes == 0 {
            0
        } else if (self.cjk_chars as f64) / (self.non_ws_graphemes as f64) >= CJK_DENSITY_THRESHOLD
        {
            self.non_ws_graphemes
        } else {
            self.ws_runs
        }
    }
}

fn has_non_whitespace(text: &str) -> bool {
    text.chars().any(|ch| !ch.is_whitespace())
}

fn has_regional_indicator(text: &str) -> bool {
    text.chars()
        .any(|ch| matches!(u32::from(ch), 0x1f1e6..=0x1f1ff))
}

fn count_non_ws_graphemes(text: &str) -> usize {
    text.graphemes(true)
        .filter(|grapheme| has_non_whitespace(grapheme))
        .count()
}

fn boundary_tail_window(text: &str) -> &str {
    let mut start = text.len();
    for (idx, grapheme) in text.grapheme_indices(true).rev() {
        start = idx;
        if !has_regional_indicator(grapheme) {
            break;
        }
    }
    text.get(start..).unwrap_or("")
}

fn boundary_head_window(text: &str) -> &str {
    let mut end = 0usize;
    for (idx, grapheme) in text.grapheme_indices(true) {
        end = idx + grapheme.len();
        if !has_regional_indicator(grapheme) {
            break;
        }
    }
    text.get(..end).unwrap_or("")
}

fn combine_word_stats(
    left: &str,
    left_stats: WordStats,
    right: &str,
    right_stats: WordStats,
) -> WordStats {
    let Some(c1) = left.chars().next_back() else {
        return right_stats;
    };
    let Some(c2) = right.chars().next() else {
        return left_stats;
    };

    // Under UAX #29, the only ASCII pair that does not break is CR+LF, where
    // both characters are whitespace and contribute 0 non-whitespace graphemes.
    let non_ws_graphemes = if c1.is_ascii() && c2.is_ascii() {
        left_stats.non_ws_graphemes + right_stats.non_ws_graphemes
    } else {
        let tail = boundary_tail_window(left);
        let head = boundary_head_window(right);
        let mut joined = String::with_capacity(tail.len() + head.len());
        joined.push_str(tail);
        joined.push_str(head);
        let before = count_non_ws_graphemes(tail) + count_non_ws_graphemes(head);
        let after = count_non_ws_graphemes(&joined);
        (left_stats.non_ws_graphemes + right_stats.non_ws_graphemes + after).saturating_sub(before)
    };

    let ws_runs = left_stats.ws_runs + right_stats.ws_runs
        - usize::from(!c1.is_whitespace() && !c2.is_whitespace());

    WordStats {
        non_ws_graphemes,
        cjk_chars: left_stats.cjk_chars + right_stats.cjk_chars,
        ws_runs,
    }
}

fn is_cjk_char(ch: char) -> bool {
    matches!(
        u32::from(ch),
        0x4e00..=0x9fff | 0x3040..=0x309f | 0x30a0..=0x30ff | 0xac00..=0xd7af
    )
}

/// CJK-aware word count matching `Ankole.Brain.Chunker.count_words/1`.
pub fn count_words(text: &str) -> usize {
    WordStats::from_str(text).word_count()
}

/// Chunks one single-scope text and returns `(chunk_text, exact_token_count)` pairs.
pub fn chunk_text_with_tokens(
    text: &str,
    chunk_size: usize,
    chunk_overlap: usize,
    max_chars: usize,
    max_tokens: u64,
) -> Result<Vec<(String, u64)>, ChunkError> {
    if text.len() > MAX_CHUNK_INPUT_BYTES {
        return Err(ChunkError::InputTooLarge {
            max_bytes: MAX_CHUNK_INPUT_BYTES,
        });
    }
    if chunk_size == 0 {
        return Err(ChunkError::ZeroChunkSize);
    }
    if chunk_overlap >= chunk_size {
        return Err(ChunkError::OverlapAtLeastChunkSize);
    }
    if max_chars == 0 {
        return Err(ChunkError::ZeroMaxChars);
    }
    if max_tokens == 0 {
        return Err(ChunkError::ZeroMaxTokens);
    }

    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }

    let full_stats = WordStats::from_str(text);
    let mut out = Vec::new();

    if full_stats.word_count() <= chunk_size {
        cap_chunk(trimmed, max_chars, max_tokens, None, &mut out);
        return Ok(out);
    }

    let mut pieces = Vec::new();
    recursive_split(text, 0, chunk_size, &mut pieces);
    let merged = greedy_merge(pieces, chunk_size);
    let overlapped = apply_overlap(merged, chunk_overlap);

    for chunk in overlapped {
        cap_chunk(chunk.trim(), max_chars, max_tokens, None, &mut out);
    }

    Ok(out)
}

fn recursive_split<'a>(
    text: &'a str,
    level: usize,
    target: usize,
    out: &mut Vec<(&'a str, WordStats)>,
) {
    if level + 1 >= DELIMITER_LEVELS {
        split_on_whitespace(text, target, out);
        return;
    }

    let pieces = split_at_level(text, level);
    if pieces.len() <= 1 {
        recursive_split(text, level + 1, target, out);
        return;
    }

    for piece in pieces {
        let piece_stats = WordStats::from_str(piece);
        if piece_stats.word_count() > target {
            recursive_split(piece, level + 1, target, out);
        } else {
            out.push((piece, piece_stats));
        }
    }
}

/// Splits `text` in a single linear pass at the delimiters of `level`, keeping
/// each delimiter attached to the end of the piece before it and dropping
/// whitespace-only pieces.
fn split_at_level(text: &str, level: usize) -> Vec<&str> {
    let mut pieces = Vec::new();
    let mut piece_start = 0usize;
    let mut iter = text.char_indices().peekable();

    while let Some((idx, ch)) = iter.next() {
        let delim_end = match level {
            0 => {
                if ch == '\n' && iter.peek().is_some_and(|&(_, next)| next == '\n') {
                    iter.next();
                    Some(idx + 2)
                } else {
                    None
                }
            }
            1 => (ch == '\n').then_some(idx + 1),
            2 => match ch {
                '.' | '!' | '?' => {
                    if iter
                        .peek()
                        .is_some_and(|&(_, next)| next == ' ' || next == '\n')
                    {
                        iter.next();
                        Some(idx + 2)
                    } else {
                        None
                    }
                }
                '。' | '！' | '？' => Some(idx + ch.len_utf8()),
                _ => None,
            },
            3 => match ch {
                ';' | ':' | ',' => {
                    if iter.peek().is_some_and(|&(_, next)| next == ' ') {
                        iter.next();
                        Some(idx + 2)
                    } else {
                        None
                    }
                }
                '；' | '：' | '，' | '、' => Some(idx + ch.len_utf8()),
                _ => None,
            },
            _ => None,
        };

        if let Some(end) = delim_end {
            if let Some(piece) = text.get(piece_start..end)
                && !piece.trim().is_empty()
            {
                pieces.push(piece);
            }
            piece_start = end;
        }
    }

    if piece_start < text.len()
        && let Some(remaining) = text.get(piece_start..)
        && !remaining.trim().is_empty()
    {
        pieces.push(remaining);
    }

    pieces
}

fn scan_word_runs(text: &str) -> Vec<(usize, usize)> {
    let mut runs = Vec::new();
    let mut iter = text.char_indices().peekable();

    while let Some(&(start, ch)) = iter.peek() {
        if ch.is_whitespace() {
            iter.next();
            continue;
        }

        while let Some(&(_, c)) = iter.peek() {
            if c.is_whitespace() {
                break;
            }
            iter.next();
        }

        while let Some(&(_, c)) = iter.peek() {
            if !c.is_whitespace() {
                break;
            }
            iter.next();
        }

        let end = iter.peek().map_or(text.len(), |&(idx, _)| idx);
        runs.push((start, end));
    }

    runs
}

fn split_on_whitespace<'a>(text: &'a str, target: usize, out: &mut Vec<(&'a str, WordStats)>) {
    let runs = scan_word_runs(text);
    let step = target.max(1);

    let no_useful_whitespace = match runs.as_slice() {
        [] => true,
        &[(start, end)] => text
            .get(start..end)
            .is_none_or(|run| run.graphemes(true).count() > target),
        _ => false,
    };

    if no_useful_whitespace {
        if text.trim().is_empty() {
            return;
        }

        let mut slice_start = 0usize;
        let mut count_in_slice = 0usize;

        for (idx, grapheme) in text.grapheme_indices(true) {
            if count_in_slice == 0 {
                slice_start = idx;
            }
            count_in_slice += 1;

            if count_in_slice == step {
                let end = idx + grapheme.len();
                if let Some(piece) = text.get(slice_start..end)
                    && !piece.trim().is_empty()
                {
                    out.push((piece, WordStats::from_str(piece)));
                }
                count_in_slice = 0;
            }
        }

        if count_in_slice > 0
            && let Some(piece) = text.get(slice_start..)
            && !piece.trim().is_empty()
        {
            out.push((piece, WordStats::from_str(piece)));
        }
    } else {
        for group in runs.chunks(step) {
            if let (Some(&(start, _)), Some(&(_, end))) = (group.first(), group.last())
                && let Some(piece) = text.get(start..end)
                && !piece.trim().is_empty()
            {
                out.push((piece, WordStats::from_str(piece)));
            }
        }
    }
}

fn greedy_merge(pieces: Vec<(&str, WordStats)>, target: usize) -> Vec<String> {
    let mut iter = pieces.into_iter();
    let Some((first, first_stats)) = iter.next() else {
        return Vec::new();
    };

    let limit = target.saturating_mul(3).div_ceil(2);
    let mut chunks = Vec::new();
    let mut current = String::from(first);
    let mut current_stats = first_stats;

    for (piece, piece_stats) in iter {
        let combined_stats = combine_word_stats(&current, current_stats, piece, piece_stats);
        if combined_stats.word_count() <= limit {
            current.push_str(piece);
            current_stats = combined_stats;
        } else {
            chunks.push(current);
            current = String::from(piece);
            current_stats = piece_stats;
        }
    }

    if !current.trim().is_empty() {
        chunks.push(current);
    }

    chunks
}

fn apply_overlap(chunks: Vec<String>, overlap_words: usize) -> Vec<String> {
    if chunks.len() <= 1 || overlap_words == 0 {
        return chunks;
    }

    let mut out = Vec::with_capacity(chunks.len());
    if let Some(first) = chunks.first() {
        out.push(first.clone());
    }

    for pair in chunks.windows(2) {
        if let [previous, current] = pair {
            let trailing = extract_trailing_context(previous, overlap_words);
            if trailing.is_empty() {
                out.push(current.clone());
            } else {
                let mut merged = String::with_capacity(trailing.len() + current.len());
                merged.push_str(trailing);
                merged.push_str(current);
                out.push(merged);
            }
        }
    }

    out
}

fn extract_trailing_context(text: &str, target_words: usize) -> &str {
    let runs = scan_word_runs(text);
    let trailing = if count_words(text) > runs.len() {
        let starts: Vec<usize> = text.grapheme_indices(true).map(|(idx, _)| idx).collect();
        let Some(keep_from) = starts.len().checked_sub(target_words).filter(|&i| i > 0) else {
            return "";
        };
        let Some(&start_byte) = starts.get(keep_from) else {
            return "";
        };
        let Some(slice) = text.get(start_byte..) else {
            return "";
        };
        slice
    } else {
        let Some(first_kept) = runs.len().checked_sub(target_words).filter(|&i| i > 0) else {
            return "";
        };
        let (Some(&(start_byte, _)), Some(&(_, last_end))) = (runs.get(first_kept), runs.last())
        else {
            return "";
        };
        let Some(slice) = text.get(start_byte..last_end) else {
            return "";
        };
        slice
    };

    if let Some((start, length)) = first_sentence_boundary(trailing)
        && start < trailing.len() / 2
        && let Some(after_sentence) = trailing.get(start + length..)
        && !after_sentence.trim().is_empty()
    {
        return after_sentence;
    }

    trailing
}

fn first_sentence_boundary(text: &str) -> Option<(usize, usize)> {
    let mut iter = text.char_indices().peekable();
    while let Some((start, ch)) = iter.next() {
        match ch {
            '.' | '!' | '?' => {
                if iter.peek().is_some_and(|&(_, next)| next.is_whitespace()) {
                    while let Some(&(_, next)) = iter.peek() {
                        if !next.is_whitespace() {
                            break;
                        }
                        iter.next();
                    }
                    let end = iter.peek().map_or(text.len(), |&(idx, _)| idx);
                    return Some((start, end - start));
                }
            }
            '。' | '！' | '？' => {
                while let Some(&(_, next)) = iter.peek() {
                    if !next.is_whitespace() {
                        break;
                    }
                    iter.next();
                }
                let end = iter.peek().map_or(text.len(), |&(idx, _)| idx);
                return Some((start, end - start));
            }
            _ => {}
        }
    }
    None
}

fn cap_chunk(
    text: &str,
    max_chars: usize,
    max_tokens: u64,
    known_est: Option<u64>,
    out: &mut Vec<(String, u64)>,
) {
    if text.is_empty() {
        return;
    }

    let grapheme_ends: Vec<usize> = text
        .grapheme_indices(true)
        .map(|(idx, grapheme)| idx + grapheme.len())
        .collect();
    let text_length = grapheme_ends.len();

    let est = match known_est {
        Some(tokens) => tokens,
        None => probe_tokens(text, &grapheme_ends),
    };

    let window = if est <= max_tokens {
        max_chars
    } else {
        let scaled_u128 = ((text_length as u128) * u128::from(max_tokens) / u128::from(est))
            .min(max_chars as u128);
        let scaled = usize::try_from(scaled_u128).unwrap_or(max_chars);
        scaled.max(1)
    };

    if text_length <= window {
        if let Some(exact) = known_est {
            out.push((text.to_string(), exact));
        } else if text_length <= DENSITY_PROBE_CHARS {
            out.push((text.to_string(), est));
        } else {
            let exact = estimate_o200k_base_tokens(text);
            if exact <= max_tokens {
                out.push((text.to_string(), exact));
            } else {
                cap_chunk(text, max_chars, max_tokens, Some(exact), out);
            }
        }
        return;
    }

    let overlap = 500usize.min(window / 10);
    let stride = 1usize.max(window.saturating_sub(overlap));
    let mut pos = 0usize;

    loop {
        let end_g = text_length.min(pos + window);
        let start_byte = if pos == 0 {
            0
        } else {
            grapheme_ends.get(pos - 1).copied().unwrap_or(0)
        };
        let end_byte = grapheme_ends
            .get(end_g.saturating_sub(1))
            .copied()
            .unwrap_or(text.len());
        let slice = text.get(start_byte..end_byte).unwrap_or("").trim();

        if !slice.is_empty() {
            let slice_est = estimate_o200k_base_tokens(slice);
            if slice_est > max_tokens {
                cap_chunk(slice, max_chars, max_tokens, Some(slice_est), out);
            } else {
                out.push((slice.to_string(), slice_est));
            }
        }

        if text_length - pos <= window {
            break;
        }
        pos += stride;
    }
}

fn probe_tokens(text: &str, grapheme_ends: &[usize]) -> u64 {
    let text_length = grapheme_ends.len();
    if text_length <= DENSITY_PROBE_CHARS {
        estimate_o200k_base_tokens(text)
    } else {
        let head_end = grapheme_ends
            .get(DENSITY_PROBE_CHARS - 1)
            .copied()
            .unwrap_or(text.len());
        let head = text.get(..head_end).unwrap_or(text);
        let head_tokens = u128::from(estimate_o200k_base_tokens(head));
        let total = (head_tokens * (text_length as u128)).div_ceil(DENSITY_PROBE_CHARS as u128);
        u64::try_from(total).unwrap_or(u64::MAX)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_count_handles_latin_cjk_and_blank_inputs() {
        assert_eq!(count_words(""), 0);
        assert_eq!(count_words("   \n\t "), 0);
        assert_eq!(count_words("one two three"), 3);
        assert_eq!(count_words("这是一个中文句子"), 8);

        let mixed = "an english sentence with one 词 in the middle of many latin words";
        assert_eq!(count_words(mixed), mixed.split_whitespace().count());
    }

    #[test]
    fn word_stats_combination_matches_direct_count_including_uax29_boundaries() {
        let samples = [
            ("hello ", "world"),
            ("hel", "lo"),
            ("中文", "测试"),
            ("alpha beta ", "中文内容占比超过阈值测试"),
            ("   \n", "leading"),
            ("e", "\u{0301}"),
            ("🇺🇸", "🇺🇸"),
            ("🇺", "🇸"),
            ("🇺", "🇸🇺🇸"),
            ("中文🇺🇸", "🇺🇸测试"),
            ("👨\u{200d}", "👩\u{200d}👧\u{200d}👦中文"),
            ("line\r", "\n中文测试"),
        ];

        for (left, right) in samples {
            let combined = format!("{left}{right}");
            let via_combine = combine_word_stats(
                left,
                WordStats::from_str(left),
                right,
                WordStats::from_str(right),
            )
            .word_count();
            assert_eq!(
                via_combine,
                count_words(&combined),
                "mismatch on {left:?} + {right:?} -> {combined:?}"
            );
        }
    }

    #[test]
    fn chunk_text_validates_bounds_and_handles_short_or_blank_text() {
        assert_eq!(
            chunk_text_with_tokens("hi", 0, 0, 100, 100),
            Err(ChunkError::ZeroChunkSize)
        );
        assert_eq!(
            chunk_text_with_tokens("hi", 10, 10, 100, 100),
            Err(ChunkError::OverlapAtLeastChunkSize)
        );
        assert_eq!(
            chunk_text_with_tokens("hi", 10, 0, 0, 100),
            Err(ChunkError::ZeroMaxChars)
        );
        assert_eq!(
            chunk_text_with_tokens("hi", 10, 0, 100, 0),
            Err(ChunkError::ZeroMaxTokens)
        );

        assert_eq!(
            chunk_text_with_tokens("  \n ", 300, 50, 6_000, 1_500),
            Ok(Vec::new())
        );

        assert_eq!(
            chunk_text_with_tokens("short text", 300, 50, 6_000, 1_500),
            Ok(vec![(
                "short text".to_string(),
                estimate_o200k_base_tokens("short text")
            )])
        );
    }

    #[test]
    fn chunk_text_enforces_overlap_zero_overlap_and_extreme_token_caps() {
        let cjk: String = (0x4e00u32..=0x4e50u32).filter_map(char::from_u32).collect();
        let Ok(chunks) = chunk_text_with_tokens(&cjk, 20, 6, 6_000, 1_500) else {
            panic!("expected valid CJK chunks");
        };
        assert!(chunks.len() > 1);

        let (Some((first_text, _)), Some((second_text, _))) = (chunks.first(), chunks.get(1))
        else {
            panic!("expected at least two chunks");
        };
        let first_chars: Vec<char> = first_text.chars().collect();
        let suffix: String = first_chars
            .get(first_chars.len().saturating_sub(6)..)
            .unwrap_or(&[])
            .iter()
            .collect();
        assert!(second_text.starts_with(&suffix));

        // Zero overlap produces disjoint slices without panicking.
        let Ok(no_overlap) = chunk_text_with_tokens(&cjk, 20, 0, 6_000, 1_500) else {
            panic!("expected valid zero-overlap chunks");
        };
        assert!(no_overlap.len() > 1);

        let dense = "知识空间中的一段稠密中文内容。".repeat(40);
        let Ok(capped) = chunk_text_with_tokens(&dense, 300, 50, 6_000, 60) else {
            panic!("expected valid capped chunks");
        };
        assert!(capped.len() > 1);
        for (chunk, tokens) in &capped {
            assert_eq!(*tokens, estimate_o200k_base_tokens(chunk));
            assert!(*tokens <= 60);
        }

        // Single multi-token grapheme with max_tokens = 1 must terminate cleanly.
        let Ok(tiny_emoji) = chunk_text_with_tokens("👨‍👩‍👧‍👦👨‍👩‍👧‍👦", 300, 0, 6_000, 1)
        else {
            panic!("expected termination on irreducible multi-token grapheme");
        };
        assert_eq!(tiny_emoji.len(), 2);
        for (chunk, tokens) in &tiny_emoji {
            assert_eq!(chunk, "👨‍👩‍👧‍👦");
            assert_eq!(*tokens, estimate_o200k_base_tokens("👨‍👩‍👧‍👦"));
        }
    }
}
