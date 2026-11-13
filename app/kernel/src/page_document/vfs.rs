//! Editable Markdown blocks with opaque anchors for content Markdown cannot express.
use super::tree::{self, Element, Node, Result};
use super::{Page, knowledge};
use std::collections::{BTreeMap, BTreeSet};

struct BlockProjection {
    marker: String,
    markdown: String,
    node: Element,
    editable: bool,
}

/// Empty editor paragraphs and whitespace do not create a Markdown file.
/// Structural and rich blocks remain content even without searchable text.
pub fn is_empty(source: &str) -> Result<bool> {
    fn empty_node(node: &Node) -> bool {
        match node {
            Node::Text(text) => text.trim().is_empty(),
            Node::Element(element) => {
                matches!(element.name.as_str(), "p" | "br")
                    && element.attrs.is_empty()
                    && element.children.iter().all(empty_node)
            }
        }
    }
    Ok(tree::parse(source)?.children.iter().all(empty_node))
}

fn blocks(source: &str) -> Result<Vec<BlockProjection>> {
    let root = tree::parse(source)?;
    root.children
        .into_iter()
        .enumerate()
        .map(|(index, child)| {
            let Node::Element(node) = child else {
                return Err("document has bare text".into());
            };
            let xml = tree::print(&node);
            let id = format!("{index}-{}", &blake3::hash(xml.as_bytes()).to_hex()[..10]);
            let marker = format!("<!-- ankole:block id=\"{id}\" kind=\"{}\" -->", node.name);
            let page = format!("<page>{xml}</page>");
            let markdown = knowledge::export_document(&page);
            let editable = markdown.is_ok();
            let markdown = markdown.unwrap_or_else(|_| {
                format!("<!-- {} -->", tree::text_of(&node).replace("--", "—"))
            });
            Ok(BlockProjection {
                marker,
                markdown,
                node,
                editable,
            })
        })
        .collect()
}

/// Project editable blocks and opaque rich-block anchors without losing identity.
pub fn export(source: &str) -> Result<String> {
    blocks(source).map(|blocks| {
        blocks
            .into_iter()
            .map(|block| format!("{}\n{}", block.marker, block.markdown))
            .collect::<Vec<_>>()
            .join("\n\n")
    })
}

/// Apply edited Markdown while preserving anchored rich subtrees from `source`.
pub fn reconcile(source: &str, markdown: &str) -> Result<Page> {
    let original = blocks(source)?;
    let by_marker: BTreeMap<_, _> = original
        .iter()
        .map(|block| (block.marker.as_str(), block))
        .collect();
    let mut seen = BTreeSet::new();
    let mut children = Vec::new();
    let mut rest = markdown;
    while let Some(offset) = rest.find("<!-- ankole:block ") {
        append_markdown(&mut children, &rest[..offset])?;
        rest = &rest[offset..];
        let end = rest.find("-->").ok_or("damaged document anchor")? + 3;
        let marker = &rest[..end];
        let block = by_marker
            .get(marker)
            .ok_or("unknown or damaged document anchor")?;
        if !seen.insert(marker) {
            return Err("duplicate document anchor".into());
        }
        rest = &rest[end..];
        let boundary = rest.find("<!-- ankole:block ").unwrap_or(rest.len());
        let edited = rest[..boundary].trim();
        if edited == block.markdown.trim() {
            children.push(Node::Element(block.node.clone()));
        } else if block.editable {
            append_markdown(&mut children, edited)?;
        } else {
            return Err("edit rich blocks in Pod; keep their Markdown anchors intact".into());
        }
        rest = &rest[boundary..];
    }
    append_markdown(&mut children, rest)?;
    if original
        .iter()
        .any(|block| !block.editable && !seen.contains(block.marker.as_str()))
    {
        return Err("missing rich-block anchor".into());
    }
    let mut root = tree::parse(source)?;
    root.children = children;
    super::page(root)
}

fn append_markdown(children: &mut Vec<Node>, markdown: &str) -> Result<()> {
    if !markdown.trim().is_empty() {
        children.extend(tree::parse(&knowledge::parse_document(markdown)?.xml)?.children);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_paragraphs_are_directories_but_structural_content_is_not_empty() {
        for xml in ["<page />", "<page><p> \n <br /></p><p /></page>"] {
            assert!(is_empty(xml).unwrap());
        }
        for xml in [
            "<page><p>body</p></page>",
            "<page><image src=\"image.png\" /></page>",
            "<page><table /></page>",
            "<page><pre /></page>",
            "<page><mermaid /></page>",
            "<page><infographic /></page>",
            "<page><hr /></page>",
        ] {
            assert!(!is_empty(xml).unwrap());
        }
    }
    #[test]
    fn preserves_rich_subtrees_and_edits_adjacent_text() {
        let xml = "<page><p>before</p><columns><column><p>left</p></column><column><p>right</p></column></columns><p>after</p></page>";
        let projected = export(xml).unwrap();
        assert_eq!(
            reconcile(xml, &projected).unwrap().xml,
            tree::print(&tree::parse(xml).unwrap())
        );
        let changed = reconcile(xml, &projected.replace("\nbefore\n", "\nchanged\n")).unwrap();
        assert!(changed.xml.contains("<p>changed</p>"));
        assert!(changed.xml.contains("<columns>"));
        assert!(reconcile(xml, "discarded everything").is_err());

        let diagrams = "<page><mermaid>flowchart LR\n  A --&gt; B</mermaid><mermaid view=\"diagram\">flowchart TD\n  X --&gt; Y</mermaid><infographic>infographic list-row</infographic></page>";
        let projected_diagrams = export(diagrams).unwrap();
        assert!(projected_diagrams.contains("```mermaid\nflowchart LR\n  A --> B\n```"));
        let edited_diagrams =
            reconcile(diagrams, &projected_diagrams.replace("A --> B", "A --> C")).unwrap();
        assert!(
            edited_diagrams
                .xml
                .contains("<mermaid>flowchart LR\n  A --&gt; C</mermaid>")
        );
        assert!(
            edited_diagrams
                .xml
                .contains("<mermaid view=\"diagram\">flowchart TD\n  X --&gt; Y</mermaid>")
        );
        assert!(
            edited_diagrams
                .xml
                .contains("<infographic>infographic list-row</infographic>")
        );
    }

    #[test]
    fn document_markdown_writes_infographics_and_diagram_view_and_theme() {
        let created = reconcile(
            "<page />",
            "```infographic\ninfographic list-row\n  data\n```\n\n<mermaid view=\"code\" theme=\"dark\">\n```mermaid\nflowchart LR\n\n  A --> B\n```\n</mermaid>\n\n```infographic title\nkept as code\n```",
        )
        .unwrap();
        assert_eq!(
            created.xml,
            "<page><infographic>infographic list-row\n  data</infographic><mermaid theme=\"dark\" view=\"code\">flowchart LR\n\n  A --&gt; B</mermaid><pre lang=\"infographic\" meta=\"title\">kept as code</pre></page>"
        );

        // Every diagram projects as editable Markdown and survives an unchanged and an edited round trip.
        let xml = "<page><infographic view=\"diagram\">infographic list-row</infographic><mermaid theme=\"light\">flowchart TD\n  X --&gt; Y</mermaid><pre lang=\"infographic\">explicit code</pre></page>";
        let projected = export(xml).unwrap();
        assert!(!projected.contains("<!-- infographic"), "{projected}");
        assert!(
            projected.contains(
                "<mermaid theme=\"light\">\n```mermaid\nflowchart TD\n  X --> Y\n```\n</mermaid>"
            ),
            "{projected}"
        );
        let unchanged = projected.replace("<!-- ankole:block", "\n<!-- ankole:block");
        assert_eq!(
            reconcile(xml, &unchanged).unwrap().xml,
            tree::print(&tree::parse(xml).unwrap())
        );
        let edited = reconcile(
            xml,
            &projected
                .replace("X --> Y", "X --> Z")
                .replace("list-row", "list-grid"),
        )
        .unwrap();
        assert!(
            edited
                .xml
                .contains("<infographic view=\"diagram\">infographic list-grid</infographic>")
        );
        assert!(
            edited
                .xml
                .contains("<mermaid theme=\"light\">flowchart TD\n  X --&gt; Z</mermaid>")
        );
        assert!(
            edited
                .xml
                .contains("<pre lang=\"infographic\">explicit code</pre>")
        );

        // A wrapper shown inside a code example stays code.
        let example = reconcile(
            "<page />",
            "````markdown\n<mermaid view=\"code\">\n```mermaid\nA\n```\n</mermaid>\n````",
        )
        .unwrap();
        assert!(
            example.xml.starts_with("<page><pre lang=\"markdown\">"),
            "{}",
            example.xml
        );
    }
}
