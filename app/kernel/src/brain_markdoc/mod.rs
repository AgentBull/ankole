//! Canonical Brain body analysis over CommonMark block structure.
//!
//! Brain bodies use CommonMark, one root-level `audience` block tag, and
//! comrak wikilinks. Comrak owns code and inline boundaries. This module only
//! recognizes the deliberately small audience grammar at those boundaries.

use std::collections::HashSet;

use comrak::nodes::{LineColumn, NodeValue, Sourcepos};
use comrak::{Arena, Options, parse_document};
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Segment {
    pub scope: String,
    pub text: String,
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

/// Analyzes one Brain body and returns either canonical data or one syntax
/// diagnostic. Grammar errors are data because callers must fail closed without
/// treating invalid user text as a native implementation failure.
pub fn analyze_json(source: &str) -> Result<String, String> {
    let outcome = match analyze(source) {
        Ok(analysis) => AnalysisOutcome::Success(analysis),
        Err(error) => AnalysisOutcome::Error { error },
    };

    serde_json::to_string(&outcome)
        .map_err(|error| format!("failed to encode Brain Markdoc analysis: {error}"))
}

pub fn analyze(source: &str) -> Result<Analysis, AnalysisError> {
    let arena = Arena::new();
    let mut options = Options::default();
    options.extension.wikilinks_title_after_pipe = true;
    let root = parse_document(&arena, source, &options);

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
                if !target.is_empty() && seen_wikilinks.insert(target.to_string()) {
                    wikilinks.push(target.to_string());
                }
            }
            _ => {}
        }
    }

    let lines = source_lines(source);
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
        let text = raw_line.strip_suffix('\n').unwrap_or(raw_line);
        let end = start + text.len();
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
    let bytes = line.as_bytes();
    let mut end = bytes.len();
    while end > 0 && matches!(bytes[end - 1], b' ' | b'\t' | b'\r') {
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
    });
    Ok(segments)
}

#[cfg(test)]
mod tests;
