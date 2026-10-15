use comrak::nodes::NodeValue;
use comrak::{Arena, Options, parse_document};

/// Offsets include code delimiters. Source text is never reconstructed from AST text.
pub fn code_ranges(source: &str) -> Vec<(usize, usize)> {
    let arena = Arena::new();
    let root = parse_document(&arena, source, &Options::default());
    let lines = line_offsets(source);
    let mut ranges = Vec::new();

    for node in root.descendants() {
        let data = node.data.borrow();
        if !matches!(data.value, NodeValue::Code(_) | NodeValue::CodeBlock(_)) {
            continue;
        }
        let position = data.sourcepos;
        let start = lines[position.start.line - 1] + position.start.column.saturating_sub(1);
        let end = (lines[position.end.line - 1] + position.end.column).min(source.len());
        if start < end {
            ranges.push((start, end));
        }
    }

    ranges.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(ranges.len());
    for (start, end) in ranges {
        if let Some(previous) = merged.last_mut()
            && start <= previous.1
        {
            previous.1 = previous.1.max(end);
        } else {
            merged.push((start, end));
        }
    }
    merged
        .into_iter()
        .map(|(start, end)| (start, end - start))
        .collect()
}

fn line_offsets(source: &str) -> Vec<usize> {
    let bytes = source.as_bytes();
    let mut lines = vec![0];
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\r' => {
                index += 1;
                if bytes.get(index) == Some(&b'\n') {
                    index += 1;
                }
                lines.push(index);
            }
            b'\n' => {
                index += 1;
                lines.push(index);
            }
            _ => index += 1,
        }
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::code_ranges;

    fn slices(source: &str) -> Vec<&str> {
        code_ranges(source)
            .into_iter()
            .map(|(start, length)| &source[start..start + length])
            .collect()
    }

    #[test]
    fn inline_ranges_keep_delimiters_unicode_and_newlines() {
        for newline in ["\n", "\r\n", "\r"] {
            let source = format!("中文 ``a`b`` and ` first{newline}  second ` tail");
            assert_eq!(
                slices(&source),
                vec!["``a`b``", &format!("` first{newline}  second `")]
            );
            let source = format!("中文 `first{newline}  <span> second` tail");
            assert_eq!(
                slices(&source),
                vec![&format!("`first{newline}  <span> second`")]
            );
            // An HTML block interrupts a paragraph before its closing backtick.
            assert!(code_ranges(&format!("中文 `first{newline}  <div> second` tail")).is_empty());
        }
    }

    #[test]
    fn fences_follow_actual_marker_and_length() {
        let source =
            "before\n````yaml\n```\n---\n~~~~\nVec<String>\n````\nafter\n~~~rust\n<div>\n~~~\n";
        assert_eq!(
            slices(source),
            vec![
                "````yaml\n```\n---\n~~~~\nVec<String>\n````",
                "~~~rust\n<div>\n~~~"
            ]
        );
    }

    #[test]
    fn quoted_indented_and_unclosed_code_uses_source_bytes() {
        let source = "> ```\n> <div>\n> ```\n\n    <x>\n    - [x] literal\n\n```unclosed\n---\n";
        let code = slices(source);
        assert_eq!(code[0], "```\n> <div>\n> ```");
        assert!(code[1].contains("<x>\n    - [x] literal"));
        assert_eq!(code[2], "```unclosed\n---");
    }

    #[test]
    fn tabs_nul_and_crlf_keep_original_byte_positions() {
        assert_eq!(
            slices("\tVec<String>\r\n\t---\r\n"),
            vec!["Vec<String>\r\n\t---"]
        );
        assert_eq!(slices("中文\0 `a\0b` end"), vec!["`a\0b`"]);
        assert_eq!(slices("\u{feff}中文 `code`"), vec!["`code`"]);
    }

    #[test]
    fn escaped_backticks_are_prose_and_code_offsets_are_byte_offsets() {
        let source = "中文 \\`literal\\` `Vec<String>`";
        assert_eq!(slices(source), vec!["`Vec<String>`"]);
        assert_eq!(code_ranges("plain text"), vec![]);
    }
}
