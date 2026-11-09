//! The page-tree codec and Wordgard apply path. PostgreSQL remains the document owner.
mod attributes;
mod changeset;
mod comments;
pub use comments::{
    CommentedPage, annotate_comment, comment_info, remove_comment, restore_comments,
};
mod diff;
mod document;
mod document_schema;
#[cfg(feature = "markdown")]
pub mod knowledge;
mod tree;
#[cfg(feature = "markdown")]
pub mod vfs;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tree::{Element, Node, Result};
use unicode_normalization::UnicodeNormalization;

#[derive(Debug, Serialize)]
pub struct Page {
    pub xml: String,
    pub plain_text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PageSection {
    pub level: u8,
    pub heading: String,
    pub start_byte: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PageSections {
    pub plain_text: String,
    pub sections: Vec<PageSection>,
}

pub fn validate(source: &str) -> Result<Page> {
    page(tree::parse(source)?)
}

pub fn sections(source: &str) -> Result<PageSections> {
    let root = tree::parse(source)?;
    let (plain_text, sections) = collect_plain_text(&root, true);
    Ok(PageSections {
        plain_text,
        sections,
    })
}

pub fn rename_principal(source: &str, old: &str, new: &str) -> Result<Page> {
    fn visit(node: &mut Element, old: &str, new: &str) -> bool {
        let mut changed =
            node.name == "mention" && node.attrs.get("principal").is_some_and(|uid| uid == old);
        if changed {
            node.attrs.insert("principal".into(), new.into());
        }
        for child in &mut node.children {
            if let Node::Element(child) = child {
                changed |= visit(child, old, new);
            }
        }
        changed
    }
    let mut root = tree::parse(source)?;
    let changed = visit(&mut root, old, new);
    let mut result = page(root)?;
    if !changed {
        result.xml = source.to_owned();
    }
    Ok(result)
}

pub fn apply(source: &str, changes: &str) -> Result<Page> {
    if changes.len() > tree::SOURCE_LIMIT * 4 {
        return Err("ChangeSet exceeds the request limit".into());
    }
    let changes = decode_changes(changes)?;
    let doc = document::page_document_normalized(&tree::parse(source)?)?;
    let updated = changeset::apply(&doc, &changes)?;
    let root = document::read_tree(&updated)?;
    // Reject batches that omitted the client's normalization transaction. The next
    // batch's offsets refer to the in-memory document, so a lossy write is unsafe.
    if document::page_document_normalized(&root)? != updated {
        return Err("ChangeSet must include the page normalization correction".into());
    }
    page(root)
}

fn decode_changes(source: &str) -> Result<Value> {
    // A document level contains an object and a content array, plus wire envelopes.
    const JSON_DEPTH_LIMIT: usize = 512;
    let (mut depth, mut quoted, mut escaped) = (0usize, false, false);
    for byte in source.bytes() {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'[' | b'{' => {
                    depth += 1;
                    if depth > JSON_DEPTH_LIMIT {
                        return Err("ChangeSet JSON depth limit exceeded".into());
                    }
                }
                b']' | b'}' => depth = depth.saturating_sub(1),
                _ => {}
            }
        }
    }
    let mut decoder = serde_json::Deserializer::from_str(source);
    decoder.disable_recursion_limit();
    let value = Value::deserialize(&mut decoder).map_err(|error| error.to_string())?;
    decoder.end().map_err(|error| error.to_string())?;
    Ok(value)
}
pub fn diff(old: &str, new: &str) -> Result<Value> {
    let old = document::page_document_normalized(&tree::parse(old)?)?;
    let new = document::page_document_normalized(&tree::parse(new)?)?;
    diff::changes(&old, &new)
}
pub fn identity_changes(source: &str) -> Result<String> {
    let doc = document::page_document_normalized(&tree::parse(source)?)?;
    Ok(serde_json::json!([doc.span()]).to_string())
}

fn page(root: Element) -> Result<Page> {
    let xml = tree::print(&root);
    if xml.encode_utf16().count() > tree::SOURCE_LIMIT {
        return Err("page source exceeds the UTF-16 limit".into());
    }
    let (plain_text, _) = collect_plain_text(&root, false);
    Ok(Page { xml, plain_text })
}

fn heading_level(tag: &str) -> Option<u8> {
    match tag {
        "h1" => Some(1),
        "h2" => Some(2),
        "h3" => Some(3),
        "h4" => Some(4),
        "h5" => Some(5),
        "h6" => Some(6),
        _ => None,
    }
}

fn append_search_piece(out: &mut String, piece: &str, normalize_nfkc: bool) {
    if !normalize_nfkc {
        out.push_str(piece);
        return;
    }
    let normalized = piece.replace("\r\n", "\n").replace('\r', "\n");
    out.extend(
        normalized
            .nfkc()
            .filter(|ch| !matches!(*ch, '\0' | '\u{001e}' | '\u{001f}')),
    );
}

fn searchable_url(value: &str, allow_custom_scheme: bool) -> bool {
    let lower = value.trim().to_ascii_lowercase();
    if lower.is_empty()
        || lower.starts_with("data:")
        || lower.starts_with("blob:")
        || lower.starts_with("ankole:")
    {
        return false;
    }
    allow_custom_scheme || lower.starts_with("http://") || lower.starts_with("https://")
}

fn push_unique<'a>(parts: &mut Vec<&'a str>, candidate: Option<&'a String>) {
    if let Some(raw) = candidate {
        let trimmed = raw.trim();
        if !trimmed.is_empty() && !parts.contains(&trimmed) {
            parts.push(trimmed);
        }
    }
}

fn collect_plain_text(root: &Element, record_sections: bool) -> (String, Vec<PageSection>) {
    let mut text = String::new();
    let mut sections = Vec::new();

    fn visit(
        node: &Element,
        text: &mut String,
        sections: &mut Option<&mut Vec<PageSection>>,
        normalize_nfkc: bool,
    ) {
        let level = heading_level(&node.name);
        let block = level.is_some()
            || matches!(node.name.as_str(), "p" | "pre" | "math")
            || attributes::is_source_diagram_tag(&node.name);
        if block && !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        if node.name == "br" {
            text.push('\n');
        }
        let section_start = text.len();

        match node.name.as_str() {
            "media" => {
                let mut parts = Vec::with_capacity(3);
                push_unique(&mut parts, node.attrs.get("title"));
                push_unique(&mut parts, node.attrs.get("description"));
                if let Some(src) = node.attrs.get("src")
                    && searchable_url(src, false)
                {
                    push_unique(&mut parts, Some(src));
                }
                if !parts.is_empty() {
                    if !text.is_empty() && !text.ends_with('\n') {
                        text.push('\n');
                    }
                    append_search_piece(text, &parts.join("\n"), normalize_nfkc);
                }
            }
            "embed" => {
                let mut parts = Vec::with_capacity(3);
                push_unique(&mut parts, node.attrs.get("title"));
                push_unique(&mut parts, node.attrs.get("description"));
                if let Some(href) = node.attrs.get("href")
                    && searchable_url(href, true)
                {
                    push_unique(&mut parts, Some(href));
                }
                if !parts.is_empty() {
                    if !text.is_empty() && !text.ends_with('\n') {
                        text.push('\n');
                    }
                    append_search_piece(text, &parts.join("\n"), normalize_nfkc);
                }
            }
            "img" => {
                let mut parts = Vec::with_capacity(2);
                push_unique(&mut parts, node.attrs.get("alt"));
                push_unique(&mut parts, node.attrs.get("title"));
                if !parts.is_empty() {
                    if !text.is_empty() && !text.ends_with(['\n', ' ', '\t']) {
                        text.push(' ');
                    }
                    append_search_piece(text, &parts.join(" "), normalize_nfkc);
                }
            }
            _ => {}
        }

        if let Some(heading_lvl) = level
            && let Some(sec_list) = sections.as_deref_mut()
        {
            let mut raw_heading = String::new();
            let mut no_sections = None;
            for child in &node.children {
                match child {
                    Node::Text(value) => {
                        raw_heading.push_str(value);
                        append_search_piece(text, value, normalize_nfkc);
                    }
                    Node::Element(child) => {
                        visit(child, &mut raw_heading, &mut no_sections, false);
                        visit(child, text, &mut no_sections, normalize_nfkc);
                    }
                }
            }
            let heading = raw_heading.replace(['\r', '\n'], " ").trim().to_owned();
            if !heading.is_empty() {
                sec_list.push(PageSection {
                    level: heading_lvl,
                    heading,
                    start_byte: section_start,
                });
            }
            return;
        }

        for child in &node.children {
            match child {
                Node::Text(value) => append_search_piece(text, value, normalize_nfkc),
                Node::Element(child) => visit(child, text, sections, normalize_nfkc),
            }
        }
    }

    if record_sections {
        let mut sec_ref = Some(&mut sections);
        visit(root, &mut text, &mut sec_ref, true);
    } else {
        let mut no_sections = None;
        visit(root, &mut text, &mut no_sections, false);
    }
    (text, sections)
}

#[cfg(test)]
mod tests;
