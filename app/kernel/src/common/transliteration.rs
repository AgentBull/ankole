/// Transliterates Unicode text to an ASCII approximation.
pub fn any_ascii(input: &str) -> String {
    any_ascii::any_ascii(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transliterates_non_ascii_text() {
        assert_eq!(
            any_ascii("Alpha九宫格因子分域.md"),
            "AlphaJiuGongGeYinZiFenYu.md"
        );
    }

    #[test]
    fn keeps_ascii_text_unchanged() {
        assert_eq!(any_ascii("report-2026_07.pdf"), "report-2026_07.pdf");
    }
}
