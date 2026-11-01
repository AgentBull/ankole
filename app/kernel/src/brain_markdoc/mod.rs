//! Brain bodies use CommonMark, one root-level `audience` block tag, and
//! comrak wikilinks. Comrak owns code and inline boundaries. This module only
//! recognizes the deliberately small audience grammar at those boundaries.

use std::collections::{HashMap, HashSet};
use std::ops::Range;

use comrak::nodes::{LineColumn, NodeValue, Sourcepos};
use comrak::{Arena, Options, parse_document};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Segment {
    pub scope: String,
    pub text: String,
    pub tagged: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Analysis {
    pub segments: Vec<Segment>,
    pub wikilinks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AnalysisError {
    pub code: &'static str,
    pub line: usize,
}

#[derive(Serialize)]
#[serde(untagged)]
enum AnalysisOutcome {
    Success(Analysis),
    Error { error: AnalysisError },
}

#[derive(Clone, Copy)]
struct SourceRange {
    start: LineColumn,
    end: LineColumn,
}

impl SourceRange {
    fn contains(self, line: usize, column: usize) -> bool {
        let position = LineColumn { line, column };
        self.start <= position && position <= self.end
    }

    fn contains_line(self, line: usize) -> bool {
        self.start.line <= line && line <= self.end.line
    }
}

impl From<Sourcepos> for SourceRange {
    fn from(sourcepos: Sourcepos) -> Self {
        Self {
            start: sourcepos.start,
            end: sourcepos.end,
        }
    }
}

struct SourceLine<'a> {
    number: usize,
    start: usize,
    end: usize,
    text: &'a str,
}

enum AudienceTag {
    Open(String),
    Close,
}

struct TagToken {
    line: usize,
    start: usize,
    end: usize,
    tag: AudienceTag,
}

/// Grammar errors are JSON data, so invalid user text is not a native failure.
pub fn analyze_json(source: &str) -> Result<String, String> {
    let outcome = match analyze(source) {
        Ok(analysis) => AnalysisOutcome::Success(analysis),
        Err(error) => AnalysisOutcome::Error { error },
    };

    serde_json::to_string(&outcome)
        .map_err(|error| format!("failed to encode Brain Markdoc analysis: {error}"))
}

pub fn analyze(source: &str) -> Result<Analysis, AnalysisError> {
    analyze_with_references(source, |_, _| {})
}

/// Rewrites only audience values and parsed wikilink destinations. Source
/// offsets preserve prose, code examples, labels and whitespace byte for byte.
pub fn rewrite_references(
    source: &str,
    replacements: &HashMap<String, String>,
) -> Result<String, AnalysisError> {
    let mut edits = Vec::new();
    analyze_with_references(source, |target, range| {
        if let Some(replacement) = replacements.get(target) {
            edits.push((range, replacement));
        }
    })?;
    edits.sort_by_key(|(range, _)| range.start);
    let mut rewritten = source.to_string();
    for (range, replacement) in edits.into_iter().rev() {
        rewritten.replace_range(range, replacement);
    }
    Ok(rewritten)
}

fn analyze_with_references(
    source: &str,
    mut reference: impl FnMut(&str, Range<usize>),
) -> Result<Analysis, AnalysisError> {
    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.wikilinks_title_after_pipe = true;
    let root = parse_document(&arena, source, &options);
    let lines = source_lines(source);

    let mut code_blocks = Vec::new();
    let mut inline_code = Vec::new();
    let mut html_blocks = Vec::new();
    let mut wikilinks = Vec::new();
    let mut seen_wikilinks = HashSet::new();

    for node in root.descendants() {
        let data = node.data.borrow();
        let range = SourceRange::from(data.sourcepos);

        match &data.value {
            NodeValue::CodeBlock(_) => code_blocks.push(range),
            NodeValue::Code(_) => inline_code.push(range),
            NodeValue::HtmlBlock(_) => html_blocks.push(range),
            NodeValue::WikiLink(link) => {
                let target = link.url.trim();
                let reported = lines[range.start.line - 1].start + range.start.column - 1;
                let marker: &[u8] = if link.embed { b"![[" } else { b"[[" };
                // Comrak 0.59 inserts up to three spaces for a partially consumed
                // indentation tab, but includes those spaces in inline columns.
                // Locate this parsed delimiter in the original bytes. A wikilink
                // cannot contain an unescaped [[, so this window is unambiguous.
                let start = (reported.saturating_sub(3)..=reported)
                    .rev()
                    .find(|&offset| {
                        source.as_bytes().get(offset..offset + marker.len()) == Some(marker)
                    })
                    .ok_or(AnalysisError {
                        code: "invalid_source_position",
                        line: range.start.line,
                    })?;
                // Comrak has already recognized [[destination|label]]. Its
                // destination ends at the first unescaped separator or bracket.
                let inner = start + marker.len();
                let mut end = inner;
                let bytes = source.as_bytes();
                while end < bytes.len() && !matches!(bytes[end], b'|' | b']') {
                    if bytes[end] == b'\\' && end + 1 < bytes.len() {
                        end += 1;
                    }
                    end += 1;
                }
                let raw = &source[inner..end];
                let leading = raw.len() - raw.trim_start().len();
                reference(target, inner + leading..inner + raw.trim_end().len());
                if !target.is_empty() && seen_wikilinks.insert(target.to_string()) {
                    wikilinks.push(target.to_string());
                }
            }
            _ => {}
        }
    }

    let mut tags = Vec::new();
    let mut tag_lines = HashSet::new();

    for line in &lines {
        let in_code_block = code_blocks
            .iter()
            .any(|range| range.contains_line(line.number));
        let in_inline_code = inline_code
            .iter()
            .any(|range| range.contains(line.number, 1));
        let in_html_block = html_blocks
            .iter()
            .any(|range| range.contains_line(line.number));

        if !in_code_block
            && !in_inline_code
            && !in_html_block
            && let Some(tag) = parse_tag_line(line.text)
        {
            if let AudienceTag::Open(scope) = &tag {
                let start =
                    line.start + line.text.find('"').expect("parsed scope opening quote") + 1;
                reference(scope, start..start + scope.len());
            }
            tag_lines.insert(line.number);
            tags.push(TagToken {
                line: line.number,
                start: line.start,
                end: line.end,
                tag,
            });
        }
    }

    for line in &lines {
        for column in audience_candidate_columns(line.text) {
            let in_code = code_blocks
                .iter()
                .any(|range| range.contains_line(line.number))
                || inline_code
                    .iter()
                    .any(|range| range.contains(line.number, column));

            if !tag_lines.contains(&line.number) && !in_code {
                return Err(AnalysisError {
                    code: "misplaced_audience_tag",
                    line: line.number,
                });
            }
        }
    }

    let segments = build_segments(source, tags)?;
    Ok(Analysis {
        segments,
        wikilinks,
    })
}

fn source_lines(source: &str) -> Vec<SourceLine<'_>> {
    let mut lines = Vec::new();
    let mut start = 0;

    for (index, raw_line) in source.split_inclusive('\n').enumerate() {
        let without_lf = raw_line.strip_suffix('\n').unwrap_or(raw_line);
        let end = start + without_lf.len();
        let text = without_lf.strip_suffix('\r').unwrap_or(without_lf);
        lines.push(SourceLine {
            number: index + 1,
            start,
            end,
            text,
        });
        start += raw_line.len();
    }

    lines
}

fn parse_tag_line(line: &str) -> Option<AudienceTag> {
    let line = line.strip_suffix('\r').unwrap_or(line);
    let bytes = line.as_bytes();
    let mut end = bytes.len();
    while end > 0 && matches!(bytes[end - 1], b' ' | b'\t') {
        end -= 1;
    }

    let bytes = &bytes[..end];
    let mut cursor = 0;
    consume_exact(bytes, &mut cursor, b"{%")?;
    consume_spaces(bytes, &mut cursor);

    if bytes.get(cursor) == Some(&b'/') {
        cursor += 1;
        consume_exact(bytes, &mut cursor, b"audience")?;
        consume_spaces(bytes, &mut cursor);
        consume_exact(bytes, &mut cursor, b"%}")?;
        return (cursor == bytes.len()).then_some(AudienceTag::Close);
    }

    consume_exact(bytes, &mut cursor, b"audience")?;
    let before_scope = cursor;
    consume_spaces(bytes, &mut cursor);
    if cursor == before_scope {
        return None;
    }
    consume_exact(bytes, &mut cursor, b"scope=\"")?;
    let scope_start = cursor;
    while cursor < bytes.len() && bytes[cursor] != b'"' {
        cursor += 1;
    }
    if cursor == bytes.len() {
        return None;
    }
    let scope = std::str::from_utf8(&bytes[scope_start..cursor])
        .ok()?
        .to_string();
    cursor += 1;
    consume_spaces(bytes, &mut cursor);
    consume_exact(bytes, &mut cursor, b"%}")?;

    (cursor == bytes.len()).then_some(AudienceTag::Open(scope))
}

fn audience_candidate_columns(line: &str) -> Vec<usize> {
    let bytes = line.as_bytes();
    let mut columns = Vec::new();
    let mut search_from = 0;

    while let Some(relative) = line[search_from..].find("{%") {
        let start = search_from + relative;
        let mut cursor = start + 2;
        consume_spaces(bytes, &mut cursor);
        if bytes.get(cursor) == Some(&b'/') {
            cursor += 1;
            consume_spaces(bytes, &mut cursor);
        }

        if bytes[cursor..].starts_with(b"audience") {
            columns.push(start + 1);
        }
        search_from = start + 2;
    }

    columns
}

fn consume_exact(bytes: &[u8], cursor: &mut usize, expected: &[u8]) -> Option<()> {
    if bytes.get(*cursor..)?.starts_with(expected) {
        *cursor += expected.len();
        Some(())
    } else {
        None
    }
}

fn consume_spaces(bytes: &[u8], cursor: &mut usize) {
    while matches!(bytes.get(*cursor), Some(b' ' | b'\t')) {
        *cursor += 1;
    }
}

fn build_segments(source: &str, tags: Vec<TagToken>) -> Result<Vec<Segment>, AnalysisError> {
    let mut segments = Vec::new();
    let mut cursor = 0;
    let mut open: Option<(String, usize)> = None;

    for token in tags {
        match (&token.tag, &open) {
            (AudienceTag::Open(_), Some(_)) => {
                return Err(AnalysisError {
                    code: "nested_audience_tag",
                    line: token.line,
                });
            }
            (AudienceTag::Open(scope), None) => {
                segments.push(Segment {
                    scope: "world".to_string(),
                    text: source[cursor..token.start].to_string(),
                    tagged: false,
                });
                cursor = token.end;
                open = Some((scope.clone(), token.line));
            }
            (AudienceTag::Close, None) => {
                return Err(AnalysisError {
                    code: "unopened_audience_tag",
                    line: token.line,
                });
            }
            (AudienceTag::Close, Some((scope, _))) => {
                segments.push(Segment {
                    scope: scope.clone(),
                    text: source[cursor..token.start].to_string(),
                    tagged: true,
                });
                cursor = token.end;
                open = None;
            }
        }
    }

    if let Some((_, line)) = open {
        return Err(AnalysisError {
            code: "unclosed_audience_tag",
            line,
        });
    }

    segments.push(Segment {
        scope: "world".to_string(),
        text: source[cursor..].to_string(),
        tagged: false,
    });
    Ok(segments)
}

#[cfg(test)]
mod tests;
