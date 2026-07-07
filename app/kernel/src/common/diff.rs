use imara_diff::{Algorithm, BasicLineDiffPrinter, Diff, InternedInput, UnifiedDiffConfig};

pub fn unified_text_diff(before: &str, after: &str, context_lines: u32) -> String {
    let input = InternedInput::new(before, after);
    let mut diff = Diff::compute(Algorithm::Histogram, &input);
    diff.postprocess_lines(&input);

    let mut config = UnifiedDiffConfig::default();
    config.context_len(context_lines);

    diff.unified_diff(&BasicLineDiffPrinter(&input.interner), config, &input)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unified_text_diff_returns_standard_hunks() {
        let diff = unified_text_diff("one\ntwo\nthree\n", "one\nTWO\nthree\n", 3);

        assert!(diff.contains("@@ -1,3 +1,3 @@"));
        assert!(diff.contains("-two\n"));
        assert!(diff.contains("+TWO\n"));
    }

    #[test]
    fn unified_text_diff_returns_empty_string_for_identical_text() {
        assert_eq!(unified_text_diff("same\n", "same\n", 3), "");
    }
}
