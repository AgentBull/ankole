use super::{read, write};
use crate::common;
use crate::page_document::tree::{self, Attrs, Element, Node, Result};
use crate::page_document::{self, Page};
use serde::Serialize;
use serde_json::{Map, Value};

/// A normalized knowledge document and its independently editable business metadata.
#[derive(Debug, Serialize)]
pub struct Knowledge {
    pub xml: String,
    pub plain_text: String,
    pub metadata: Map<String, Value>,
}

/// Parse OKF Markdown and YAML frontmatter into the supported page vocabulary.
pub fn parse(source: &str) -> Result<Knowledge> {
    if source.encode_utf16().count() > tree::SOURCE_LIMIT {
        return Err("knowledge source exceeds the UTF-16 limit".into());
    }
    let source = source.trim_start_matches('\u{feff}');
    let (metadata, body) = frontmatter(source)?;
    let root = read::body(body)?;
    let page = page_document::page(root)?;
    Ok(Knowledge {
        xml: page.xml,
        plain_text: page.plain_text,
        metadata,
    })
}

fn frontmatter(source: &str) -> Result<(Map<String, Value>, &str)> {
    let Some(start) = source
        .find('\n')
        .filter(|&end| source[..end].trim_end() == "---")
    else {
        return Ok((Map::new(), source));
    };
    let mut offset = start + 1;
    for line in source[offset..].split_inclusive('\n') {
        if matches!(line.trim_end(), "---" | "...") {
            let value: Value =
                serde_yaml_ng::from_str(&source[start + 1..offset]).map_err(|e| e.to_string())?;
            let metadata = match value {
                Value::Null => Map::new(),
                Value::Object(map) => map,
                _ => return Err("knowledge frontmatter must be a mapping".into()),
            };
            return Ok((metadata, &source[offset + line.len()..]));
        }
        offset += line.len();
    }
    Err("knowledge frontmatter has no closing delimiter".into())
}

/// Reject page constructs that cannot round-trip through knowledge Markdown.
pub fn validate(source: &str) -> Result<Page> {
    let root = tree::parse(source)?;
    validate_tree(&root)?;
    page_document::page(root)
}

/// Export normalized page XML and caller-selected business metadata as OKF Markdown.
pub fn export(source: &str, metadata: &Value) -> Result<String> {
    let root = tree::parse(source)?;
    validate_tree(&root)?;
    let metadata = metadata
        .as_object()
        .ok_or("knowledge metadata must be an object")?;
    let mut result = String::new();
    if !metadata.is_empty() {
        // serde_json's map is ordered; YAML keys are deterministic at every nesting level.
        result.push_str("---\n");
        result.push_str(&serde_yaml_ng::to_string(metadata).map_err(|e| e.to_string())?);
        result.push_str("---\n\n");
    }
    result.push_str(&write::body(&root)?);
    Ok(result)
}

/// The caller adds only the children visible in its current RequestContext.
pub fn overview(source: &str, metadata: &Value) -> Result<String> {
    let root = tree::parse(source)?;
    validate_tree(&root)?;
    let metadata = metadata
        .as_object()
        .ok_or("knowledge metadata must be an object")?;
    let selected = ["summary", "description", "entity_type", "aliases", "tags"]
        .into_iter()
        .filter_map(|key| {
            metadata
                .get(key)
                .map(|value| (key.to_owned(), value.clone()))
        })
        .collect::<Map<_, _>>();
    let mut children = Vec::new();
    let mut introduction = true;
    let mut remaining = 400;
    let mut omitted = false;
    for child in &root.children {
        let Node::Element(node) = child else { continue };
        if node.name == "h2" {
            introduction = false;
            children.push(Node::Element(node.clone()));
        } else if introduction && !omitted {
            let block = overview_block(node);
            let markdown = write::body(&tree::element(
                "page",
                Attrs::new(),
                vec![Node::Element(block.clone())],
            ))?;
            let tokens = common::estimate_o200k_base_tokens(&format!("{markdown}\n\n"));
            if tokens <= remaining {
                children.push(Node::Element(block));
                remaining -= tokens;
            } else {
                // A partial block is a plain-text preview, never broken Markdown or XML.
                let preview = common::truncate_o200k_base_tokens(&tree::text_of(&block), remaining);
                if !preview.is_empty() {
                    children.push(Node::Element(tree::element(
                        "p",
                        Attrs::new(),
                        vec![Node::Text(preview)],
                    )));
                }
                children.push(Node::Element(tree::element(
                    "p",
                    Attrs::new(),
                    vec![Node::Text(
                        "[Introduction shortened. Read L2 for the complete page.]".into(),
                    )],
                )));
                omitted = true;
            }
        }
    }
    export(
        &tree::print(&tree::element("page", Attrs::new(), children)),
        &Value::Object(selected),
    )
}

fn overview_block(node: &Element) -> Element {
    let folded = match node.name.as_str() {
        "pre" => {
            let text = tree::text_of(node);
            let lines = text.lines().count();
            (lines > 12 || text.chars().count() > 1_200)
                .then(|| format!("[Code block: {lines} lines. Read the full page for the code.]"))
        }
        tag if page_document::attributes::knowledge_source_diagram_by_tag(tag).is_some() => {
            let spec = page_document::attributes::knowledge_source_diagram_by_tag(tag)
                .expect("checked source diagram tag");
            let text = tree::text_of(node);
            let lines = text.lines().count();
            (lines > 12 || text.chars().count() > 1_200).then(|| {
                format!(
                    "[{}: {lines} lines. Read the full page for the diagram.]",
                    spec.overview_label
                )
            })
        }
        "table" => {
            let rows = node.children.len();
            (rows > 6 || tree::text_of(node).chars().count() > 1_200)
                .then(|| format!("[Table: {rows} rows. Read the full page for the table.]"))
        }
        _ => None,
    };
    if let Some(text) = folded {
        return tree::element("p", Attrs::new(), vec![Node::Text(text)]);
    }
    let mut node = node.clone();
    node.children = node
        .children
        .iter()
        .map(|child| match child {
            Node::Element(child) => Node::Element(overview_block(child)),
            other => other.clone(),
        })
        .collect();
    node
}

pub(super) fn validate_tree(node: &Element) -> Result<()> {
    let attrs: &[&str] = match node.name.as_str() {
        "page" | "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "strong" | "em" | "s" | "code"
        | "br" | "hr" | "blockquote" | "ul" | "table" | "tr" => &[],
        "a" => &["href", "title"],
        "img" => &["src", "alt", "title"],
        "ol" => &["start"],
        "li" => &["task"],
        "pre" => &["lang", "meta"],
        tag if page_document::attributes::knowledge_source_diagram_by_tag(tag).is_some() => {
            page_document::attributes::knowledge_source_diagram_by_tag(tag)
                .and_then(|spec| spec.knowledge_attrs)
                .unwrap_or(&[])
        }
        "callout" => &["tone", "icon"],
        "th" | "td" => &["align"],
        "media" => &["src", "title", "description", "kind"],
        "mention" => &["page", "principal"],
        other => return Err(format!("knowledge pages do not support <{other}>")),
    };
    if let Some(key) = node.attrs.keys().find(|key| !attrs.contains(&key.as_str())) {
        return Err(format!(
            "knowledge pages do not support {}.{key}",
            node.name
        ));
    }
    if node.name == "media" && node.attrs.get("kind").is_some_and(|value| value != "image") {
        return Err("knowledge media must be an image".into());
    }
    if node.name == "table" {
        validate_table(node)?;
    }
    for child in &node.children {
        if let Node::Element(child) = child {
            validate_tree(child)?;
        }
    }
    Ok(())
}

fn validate_table(node: &Element) -> Result<()> {
    let rows = node
        .children
        .iter()
        .filter_map(|node| match node {
            Node::Element(row) => Some(row),
            _ => None,
        })
        .collect::<Vec<_>>();
    let width = rows.first().map_or(0, |row| row.children.len());
    if width == 0 {
        return Err("knowledge tables need a header row".into());
    }
    for (index, row) in rows.iter().enumerate() {
        if row.children.len() != width {
            return Err("knowledge tables must be rectangular".into());
        }
        for cell in &row.children {
            let Node::Element(cell) = cell else {
                return Err("invalid knowledge table cell".into());
            };
            if cell.name != if index == 0 { "th" } else { "td" }
                || cell.children.len() != 1
                || !matches!(cell.children.first(), Some(Node::Element(p)) if p.name == "p")
            {
                return Err(
                    "knowledge tables use one header row and one paragraph per cell".into(),
                );
            }
        }
    }
    Ok(())
}
