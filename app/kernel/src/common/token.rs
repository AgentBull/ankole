use tiktoken_rs::o200k_base_singleton;
use unicode_segmentation::UnicodeSegmentation;

/// Budgeting only. This does not select a concrete model.
/// The Elixir NIF and the Node addon call this function.
pub fn estimate_o200k_base_tokens(text: &str) -> u64 {
    u64::try_from(o200k_base_singleton().count_with_special_tokens(text)).unwrap_or(u64::MAX)
}

/// Truncates `text` at a Unicode grapheme boundary to fit within `budget`
/// `o200k_base` tokens, trimming trailing whitespace when a cut occurs.
pub fn truncate_o200k_base_tokens(text: &str, budget: u64) -> String {
    if budget == 0 || text.is_empty() {
        return String::new();
    }

    if estimate_o200k_base_tokens(text) <= budget {
        return text.to_string();
    }

    let ends: Vec<usize> = text
        .grapheme_indices(true)
        .map(|(idx, grapheme)| idx + grapheme.len())
        .collect();

    let mut low = 0usize;
    let mut high = ends.len();

    while low < high {
        let mid = low + (high - low).div_ceil(2);
        let fits = if mid == ends.len() {
            false
        } else if let Some(&end_byte) = ends.get(mid.saturating_sub(1))
            && let Some(prefix) = text.get(..end_byte)
        {
            estimate_o200k_base_tokens(prefix) <= budget
        } else {
            false
        };

        if fits {
            low = mid;
        } else {
            high = mid - 1;
        }
    }

    if low == 0 {
        String::new()
    } else if let Some(&end_byte) = ends.get(low - 1)
        && let Some(prefix) = text.get(..end_byte)
    {
        prefix.trim_end().to_string()
    } else {
        String::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_handles_zero_and_fitting_budgets() {
        assert_eq!(truncate_o200k_base_tokens("Hello world", 0), "");
        assert_eq!(truncate_o200k_base_tokens("", 10), "");
        // Fitting input preserves trailing whitespace unchanged.
        assert_eq!(truncate_o200k_base_tokens("Hello   ", 10), "Hello   ");
    }

    #[test]
    fn truncate_cuts_on_grapheme_boundaries_and_trims_trailing_whitespace() {
        let text = "alpha beta gamma delta epsilon";
        let cut = truncate_o200k_base_tokens(text, 3);
        assert!(!cut.is_empty());
        assert!(estimate_o200k_base_tokens(&cut) <= 3);
        assert_eq!(cut, cut.trim_end());

        // Single grapheme exceeding budget returns empty string cleanly.
        assert_eq!(truncate_o200k_base_tokens("👨‍👩‍👧‍👦", 1), "");
        // Leading whitespace followed by oversized grapheme trims down to empty.
        assert_eq!(truncate_o200k_base_tokens("   👨‍👩‍👧‍👦", 1), "");

        // Multi-codepoint ZWJ emoji grapheme cluster must never split mid-cluster.
        let emoji_text = "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦";
        for budget in 1..15 {
            let sliced = truncate_o200k_base_tokens(emoji_text, budget);
            assert!(estimate_o200k_base_tokens(&sliced) <= budget);
            for grapheme in sliced.graphemes(true) {
                assert_eq!(grapheme, "👨‍👩‍👧‍👦");
            }
        }
    }
}
