//! The page-tree codec and Wordgard apply path. PostgreSQL remains the document owner.
mod changeset;
mod document;
mod tree;

use serde::Serialize;
use serde_json::Value;
use tree::{Element, Node, Result};

#[derive(Debug, Serialize)]
pub struct Page {
    pub xml: String,
    pub plain_text: String,
}

pub fn validate(source: &str) -> Result<Page> {
    page(tree::parse(source)?)
}
pub fn apply(source: &str, changes: &str) -> Result<Page> {
    if changes.len() > tree::SOURCE_LIMIT * 4 {
        return Err("ChangeSet exceeds the request limit".into());
    }
    let changes: Value = serde_json::from_str(changes).map_err(|e| e.to_string())?;
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
fn page(root: Element) -> Result<Page> {
    let xml = tree::print(&root);
    if xml.encode_utf16().count() > tree::SOURCE_LIMIT {
        return Err("page source exceeds the UTF-16 limit".into());
    }
    let mut text = String::new();
    fn visit(node: &Element, text: &mut String) {
        let block = matches!(
            node.name.as_str(),
            "p" | "h1" | "h2" | "h3" | "h4" | "h5" | "h6" | "pre"
        );
        if block && !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        if node.name == "br" {
            text.push('\n');
        }
        for child in &node.children {
            match child {
                Node::Text(value) => text.push_str(value),
                Node::Element(child) => visit(child, text),
            }
        }
    }
    visit(&root, &mut text);
    Ok(Page {
        xml,
        plain_text: text,
    })
}

#[cfg(test)]
mod tests;
