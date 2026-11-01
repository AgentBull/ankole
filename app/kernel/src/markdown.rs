use comrak::nodes::{AstNode, NodeValue, Sourcepos};
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
        if let Some((start, end)) = sourcepos_byte_range(source, &lines, data.sourcepos) {
            ranges.push((start, end));
        }
    }

    merge_ranges(ranges)
        .into_iter()
        .map(|(start, end)| (start, end - start))
        .collect()
}

/// Repairs common model-emitted Markdown defects outside code, math, links, HTML, and wikilinks.
///
/// Satisfies `repair_generated_markdown(&repair_generated_markdown(x)) == repair_generated_markdown(x)`.
pub fn repair_generated_markdown(source: &str) -> String {
    if source.is_empty() {
        return String::new();
    }

    let options = repair_options();
    let step1 = {
        let arena = Arena::new();
        let root = parse_document(&arena, source, &options);
        let lines = line_offsets(source);
        let text_ranges = collect_text_ranges(source, &lines, root);
        apply_step1_to_text(source, &text_ranges)
    };

    let arena = Arena::new();
    let root = parse_document(&arena, &step1, &options);
    let lines = line_offsets(&step1);
    apply_steps_2_and_3(&step1, &lines, root)
}

fn repair_options() -> Options<'static> {
    let mut options = Options::default();
    options.extension.strikethrough = true;
    options.extension.table = true;
    options.extension.autolink = true;
    options.extension.tasklist = true;
    options.extension.math_dollars = true;
    options.extension.math_code = true;
    options.extension.wikilinks_title_after_pipe = true;
    options
}

fn is_protected_node(value: &NodeValue) -> bool {
    matches!(
        value,
        NodeValue::Code(_)
            | NodeValue::CodeBlock(_)
            | NodeValue::Math(_)
            | NodeValue::Link(_)
            | NodeValue::Image(_)
            | NodeValue::HtmlBlock(_)
            | NodeValue::HtmlInline(_)
            | NodeValue::WikiLink(_)
    )
}

fn has_protected_ancestor<'a>(node: &'a AstNode<'a>) -> bool {
    node.ancestors()
        .skip(1)
        .any(|ancestor| is_protected_node(&ancestor.data.borrow().value))
}

fn sourcepos_byte_range(source: &str, lines: &[usize], pos: Sourcepos) -> Option<(usize, usize)> {
    if pos.start.line == 0 || pos.end.line == 0 {
        return None;
    }
    let start_line = *lines.get(pos.start.line - 1)?;
    let end_line = *lines.get(pos.end.line - 1)?;
    let start = (start_line + pos.start.column.saturating_sub(1)).min(source.len());
    let end = (end_line + pos.end.column).min(source.len());
    (start < end && source.is_char_boundary(start) && source.is_char_boundary(end))
        .then_some((start, end))
}

fn merge_ranges(mut ranges: Vec<(usize, usize)>) -> Vec<(usize, usize)> {
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
}

fn collect_text_ranges<'a>(
    source: &str,
    lines: &[usize],
    root: &'a AstNode<'a>,
) -> Vec<(usize, usize)> {
    let mut ranges = Vec::new();
    for node in root.descendants() {
        let data = node.data.borrow();
        if matches!(data.value, NodeValue::Text(_))
            && !has_protected_ancestor(node)
            && let Some(range) = sourcepos_byte_range(source, lines, data.sourcepos)
        {
            ranges.push(range);
        }
    }
    merge_ranges(ranges)
}

fn apply_step1_to_text(source: &str, text_ranges: &[(usize, usize)]) -> String {
    let mut out = String::with_capacity(source.len());
    let mut cursor = 0;
    for &(start, end) in text_ranges {
        out.push_str(&source[cursor..start]);
        out.push_str(&recover_structural_newlines(&source[start..end]));
        cursor = end;
    }
    out.push_str(&source[cursor..]);
    out
}

fn recover_structural_newlines(segment: &str) -> String {
    let bytes = segment.as_bytes();
    let mut out = String::with_capacity(segment.len());
    let mut index = 0;

    while index < bytes.len() {
        if index + 1 < bytes.len() && bytes[index] == b'\\' && bytes[index + 1] == b'\\' {
            out.push_str("\\\\");
            index += 2;
            continue;
        }

        if index + 1 < bytes.len() && bytes[index] == b'\\' && bytes[index + 1] == b'n' {
            let mut run = 0;
            while index + run * 2 + 1 < bytes.len()
                && bytes[index + run * 2] == b'\\'
                && bytes[index + run * 2 + 1] == b'n'
            {
                run += 1;
            }

            if run >= 2 {
                for _ in 0..run {
                    out.push('\n');
                }
                index += run * 2;
                continue;
            }

            if starts_structural_marker(&segment[index + 2..]) {
                out.push('\n');
                index += 2;
                continue;
            }
        }

        if let Some(ch) = segment[index..].chars().next() {
            out.push(ch);
            index += ch.len_utf8();
        } else {
            break;
        }
    }

    out
}

fn starts_structural_marker(rest: &str) -> bool {
    let bytes = rest.as_bytes();
    let mut spaces = 0;
    while spaces < 3 && bytes.get(spaces) == Some(&b' ') {
        spaces += 1;
    }
    let trimmed = &bytes[spaces..];
    if trimmed.len() < 2 {
        return false;
    }

    if matches!(trimmed[0], b'-' | b'*' | b'+') && trimmed[1] == b' ' {
        return true;
    }

    if trimmed[0] == b'#' {
        let mut hashes = 0;
        while hashes < 6 && trimmed.get(hashes) == Some(&b'#') {
            hashes += 1;
        }
        return trimmed.get(hashes) == Some(&b' ');
    }

    if trimmed[0].is_ascii_digit() {
        let mut digits = 0;
        while digits < 9 && trimmed.get(digits).is_some_and(u8::is_ascii_digit) {
            digits += 1;
        }
        return trimmed.get(digits) == Some(&b'.') && trimmed.get(digits + 1) == Some(&b' ');
    }

    false
}

fn apply_steps_2_and_3<'a>(source: &str, lines: &[usize], root: &'a AstNode<'a>) -> String {
    let mut edits: Vec<(usize, usize, String)> = Vec::new();
    let mut text_ranges: Vec<(usize, usize)> = Vec::new();

    for node in root.descendants() {
        if has_protected_ancestor(node) {
            continue;
        }
        let data = node.data.borrow();
        match &data.value {
            NodeValue::Strikethrough => {
                if let Some((start, end)) = sourcepos_byte_range(source, lines, data.sourcepos) {
                    let raw = &source[start..end];
                    if raw.len() >= 3
                        && raw.starts_with('~')
                        && !raw.starts_with("~~")
                        && raw.ends_with('~')
                        && !raw.ends_with("~~")
                    {
                        edits.push((start, start + 1, "\\~".to_string()));
                        edits.push((end - 1, end, "\\~".to_string()));
                    }
                }
            }
            NodeValue::Text(_) => {
                if let Some(range) = sourcepos_byte_range(source, lines, data.sourcepos) {
                    text_ranges.push(range);
                }
            }
            _ => {}
        }
    }

    text_ranges.sort_unstable();
    let mut merged_text: Vec<(usize, usize)> = Vec::with_capacity(text_ranges.len());
    for (start, end) in text_ranges {
        if let Some(prev) = merged_text.last_mut()
            && prev.1 == start
        {
            prev.1 = end;
        } else if merged_text.last().is_none_or(|prev| start >= prev.1) {
            merged_text.push((start, end));
        }
    }

    for (start, end) in merged_text {
        collect_strong_whitespace_edits(&source[start..end], start, &mut edits);
    }

    if edits.is_empty() {
        return source.to_string();
    }

    edits.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));
    let mut out = String::with_capacity(source.len() + edits.len() * 2);
    let mut cursor = 0;
    for (start, end, replacement) in edits {
        if start < cursor || end > source.len() {
            continue;
        }
        out.push_str(&source[cursor..start]);
        out.push_str(&replacement);
        cursor = end;
    }
    out.push_str(&source[cursor..]);
    out
}

fn collect_strong_whitespace_edits(
    segment: &str,
    base_offset: usize,
    edits: &mut Vec<(usize, usize, String)>,
) {
    let bytes = segment.as_bytes();
    let mut index = 0;

    while index < bytes.len() {
        let can_open = index + 1 < bytes.len()
            && bytes[index] == b'*'
            && bytes[index + 1] == b'*'
            && (index == 0 || bytes[index - 1] != b'*')
            && (index + 2 >= bytes.len() || bytes[index + 2] != b'*')
            && trailing_backslashes(&bytes[..index]).is_multiple_of(2);

        if can_open {
            let mut close = index + 2;
            while close < bytes.len()
                && bytes[close] != b'*'
                && bytes[close] != b'\n'
                && bytes[close] != b'\r'
            {
                close += 1;
            }

            if close + 1 < bytes.len()
                && bytes[close] == b'*'
                && bytes[close + 1] == b'*'
                && (close + 2 >= bytes.len() || bytes[close + 2] != b'*')
            {
                let inner = &segment[index + 2..close];
                let inner_bytes = inner.as_bytes();
                let mut ws_start = inner_bytes.len();
                while ws_start > 0 && matches!(inner_bytes[ws_start - 1], b' ' | b'\t') {
                    ws_start -= 1;
                }
                let content = &inner[..ws_start];
                let ws = &inner[ws_start..];
                if !ws.is_empty()
                    && !content.is_empty()
                    && !matches!(content.as_bytes()[0], b' ' | b'\t')
                    && trailing_backslashes(content.as_bytes()).is_multiple_of(2)
                {
                    edits.push((
                        base_offset + index,
                        base_offset + close + 2,
                        format!("**{content}**{ws}"),
                    ));
                    index = close + 2;
                    continue;
                }
            }
        }

        if let Some(ch) = segment[index..].chars().next() {
            index += ch.len_utf8();
        } else {
            break;
        }
    }
}

fn trailing_backslashes(bytes: &[u8]) -> usize {
    bytes.iter().rev().take_while(|&&b| b == b'\\').count()
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
    use super::{code_ranges, repair_generated_markdown};
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct GoldenCase {
        name: String,
        input: String,
        expected: String,
    }

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

    #[test]
    fn repair_generated_markdown_matches_golden_cases_and_is_idempotent() {
        let raw =
            include_str!("../../control_plane/test/fixtures/generated_markdown_repair_cases.json");
        let cases: Vec<GoldenCase> = serde_json::from_str(raw).expect("valid golden JSON");
        assert!(!cases.is_empty());

        for case in cases {
            let repaired = repair_generated_markdown(&case.input);
            assert_eq!(repaired, case.expected, "case failed: {}", case.name);
            let second_pass = repair_generated_markdown(&repaired);
            assert_eq!(second_pass, repaired, "idempotency failed: {}", case.name);
        }
    }
}
